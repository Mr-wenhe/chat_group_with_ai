part of 'default_work_task_runner.dart';

extension _DefaultWorkTaskRunnerTools on DefaultWorkTaskRunner {
  WorkToolRegistry _registryFor({
    required AgentTask task,
    required AICharacter character,
    required String workspaceRoot,
    required WorkspaceFileService files,
    required WorkspaceMutationService mutations,
    required CancelToken cancellationToken,
    required WorkChangeApprovalDecision? approvalDecision,
    required WorkApprovalScope? approvalScope,
    required ModelCapability modelCapability,
  }) {
    // A mutation approval without an exact file scope belongs to an
    // application-skill mutation (or a stale checkpoint), not to Stage 02.
    // Do not pass that decision into the file boundary: when ordinary-write
    // confirmations are disabled, Stage 02 may derive its own narrow scope;
    // otherwise the mutation policy will request a fresh file plan.
    final approvalCapability = _approvalCapability(task);
    final hasScopedMutationApproval = approvalDecision != null &&
        approvalScope != null &&
        approvalCapability == WorkApprovalCapability.mutation;
    final stage02ApprovalDecision = hasScopedMutationApproval
        ? approvalDecision
        : approvalCapability == WorkApprovalCapability.sensitiveRead
            ? approvalDecision
            : null;
    final stage02ApprovalScope =
        hasScopedMutationApproval ? approvalScope : null;
    final allowImplicitStage02Scope = stage02ApprovalDecision == null &&
        (folderGrantService?.settings.confirmOrdinaryWrites == false);
    final stage02 = Stage02WorkspaceFileTool(
      files: files,
      mutations: mutations,
      pathPolicy: files.pathPolicy,
      task: task,
      workspaceRoot: workspaceRoot,
      approvalDecision: stage02ApprovalDecision,
      approvalScope: stage02ApprovalScope,
      approvedSensitiveOperation: _approvedSensitiveOperation(task),
      approvalCapability: approvalCapability,
      allowImplicitScope: allowImplicitStage02Scope,
      allowWithoutUndo: stage02ApprovalDecision?.permitsWithoutUndo == true,
      resourceLockManager: resourceLockManager,
      onSensitiveRead: (path, operation) => unawaited(_record(
        task,
        WorkTaskEventKind.toolOutput,
        '已识别敏感文件读取',
        detail: operation,
        safeMetadata: {'path': path, 'sensitive': true},
      )),
    );
    // A routed task can change its current character between stages. In that
    // case intersect the task's requested capability set with the active
    // character's own permissions; a stale first-role list must never grant
    // the next role extra tools.
    final permissions = _permissionsForTask(task, character);
    final attachmentPaths = _attachmentPathsForTask(task);
    WorkToolResult permission(ToolPermission required) =>
        permissions.contains(required)
            ? const WorkToolResult.success()
            : WorkToolResult.permissionDenied(
                message: '角色未授予 ${required.name} 工具权限。',
              );
    bool attachmentDocumentPermission(WorkToolInvocation invocation) {
      if (permissions.contains(ToolPermission.workspaceRead)) return true;
      final path = invocation.arguments['path'];
      // ponytail: exact user attachments are the smallest safe exception;
      // arbitrary workspace reads still require the explicit role capability.
      return path is String &&
          _isReferencedAttachmentPath(
            path,
            attachmentPaths,
            isWindows: files.pathPolicy.isWindows,
          );
    }

    final documentDefinition = WorkDocumentTool.definition(
      pathPolicy: files.pathPolicy,
      workspaceRoot: workspaceRoot,
      modelCapability: modelCapability,
      attachmentPaths: attachmentPaths,
      isSensitivePath: files.isSensitivePath,
      allowSensitivePath: (path) => _sensitiveReadAllowed(
        task,
        stage02,
        operation: 'document',
        path: path,
      ),
      onSensitiveRead: (path) => _recordSensitiveReadApproval(
        task,
        stage02,
        <String, dynamic>{'requiresApproval': true, 'sensitive': true},
        operation: 'document',
        path: path,
      ),
    );
    Future<WorkToolResult> documentHandler(
      WorkToolInvocation invocation,
    ) async {
      if (!attachmentDocumentPermission(invocation)) {
        return permission(ToolPermission.workspaceRead);
      }
      final result = await documentDefinition.handler(invocation);
      if (_approvalDecision(task.executionStateJson) ==
              WorkChangeApprovalDecision.rejected &&
          result.data['requiresApproval'] == true &&
          result.data['sensitive'] == true) {
        task.executionStateJson = _withoutApprovalCheckpoint(
          task.executionStateJson,
        );
        return const WorkToolResult.success(
          message: '用户拒绝读取敏感文件，已跳过本次文档分析。',
          data: {'rejected': true, 'skipped': true, 'sensitive': true},
        );
      }
      if (_approvalDecision(task.executionStateJson) ==
          WorkChangeApprovalDecision.rejected) {
        task.executionStateJson = _withoutApprovalCheckpoint(
          task.executionStateJson,
        );
      }
      return result;
    }

    final definitions = <WorkToolDefinition>[
      WorkToolDefinition(
        name: AgentToolName.weatherForecast,
        access: WorkToolAccess.readOnly,
        schema: const WorkToolSchema(
          fields: {
            'location': WorkToolValueType.string,
            'days': WorkToolValueType.integer,
          },
        ),
        handler: (invocation) async {
          final rawDays = invocation.arguments['days'];
          if (rawDays != null && rawDays is! int) {
            return const WorkToolResult.failed(
              message: '天气查询天数必须是整数。',
              failureCode: 'modelProtocol',
            );
          }
          final days = rawDays as int? ?? WeatherForecastService.maxDays;
          final rawLocation = invocation.arguments['location'];
          final location = rawLocation is String ? rawLocation : null;
          final service = weatherForecastService ??
              WeatherForecastService(
                defaultLocation: _defaultWeatherLocation(),
              );
          try {
            final forecast = await service.fetch(
              location: location,
              days: days,
              cancelToken: cancellationToken,
            );
            return WorkToolResult.success(
              message:
                  '已获取${forecast.location}未来${forecast.days.length}天的真实天气数据。',
              data: {
                ...forecast.toMap(),
                'recommendedFileName': forecast.recommendedFileName,
              },
            );
          } on WeatherForecastException catch (error) {
            return error.retryable
                ? WorkToolResult.retryableFailure(message: error.message)
                : WorkToolResult.failed(
                    message: error.message,
                    failureCode: 'weatherDataInvalid',
                  );
          } on ArgumentError catch (error) {
            return WorkToolResult.failed(
              message: error.message ?? '天气查询参数无效。',
              failureCode: 'modelProtocol',
            );
          }
        },
      ),
      WorkToolDefinition(
        name: AgentToolName.workspaceList,
        access: WorkToolAccess.readOnly,
        schema: const WorkToolSchema(
          fields: {
            'path': WorkToolValueType.string,
            'page': WorkToolValueType.integer,
            'pageSize': WorkToolValueType.integer,
            'recursive': WorkToolValueType.boolean,
          },
        ),
        handler: (invocation) async {
          final denied = permission(ToolPermission.workspaceRead);
          if (!denied.succeeded) return denied;
          return _mapFileResult(await stage02.listWithOptions(
            // A missing, null or blank path means "the authorized workspace
            // root". Stringifying it produced the literal path "null", which
            // the path policy then rejected as a non-existent target and the
            // loop reported as a fatal internal failure.
            path: _workspaceListPath(invocation.arguments['path']),
            page: _intArgument(invocation.arguments['page'], 0),
            pageSize: _intArgument(invocation.arguments['pageSize'], 200),
            recursive: invocation.arguments['recursive'] == true,
          ));
        },
      ),
      WorkToolDefinition(
        name: AgentToolName.workspaceRead,
        access: WorkToolAccess.readOnly,
        schema: const WorkToolSchema(
          fields: {
            'path': WorkToolValueType.string,
            'startByte': WorkToolValueType.integer,
            'byteLength': WorkToolValueType.integer,
          },
          required: {'path'},
        ),
        handler: (invocation) async {
          final denied = permission(ToolPermission.workspaceRead);
          if (!denied.succeeded) return denied;
          final args = invocation.arguments;
          final path = args['path'] as String;
          if (_requiresDocumentTool(path)) {
            // workspace.read has a strict UTF-8 contract. Redirect known
            // binary document extensions to the parser boundary so a model
            // choosing the text tool cannot turn a valid XLSX into a false
            // task failure.
            return documentHandler(invocation);
          }
          final startByte = _intArgument(args['startByte'], 0);
          final byteLength = _nullableInt(args['byteLength']);
          final approved = _sensitiveReadAllowed(
            task,
            stage02,
            operation: 'readTextRange',
            path: path,
            startByte: _intArgument(invocation.arguments['startByte'], 0),
            byteLength: byteLength,
          );
          final result = await stage02.readWithOptions(
            path,
            startByte: startByte,
            byteLength: byteLength,
            allowSensitive: approved,
          );
          if (_approvalDecision(task.executionStateJson) ==
                  WorkChangeApprovalDecision.rejected &&
              result['requiresApproval'] == true &&
              result['sensitive'] == true) {
            task.executionStateJson = _withoutApprovalCheckpoint(
              task.executionStateJson,
            );
            return const WorkToolResult.success(
              message: '用户拒绝读取敏感文件，已跳过本次读取。',
              data: {'rejected': true, 'skipped': true, 'sensitive': true},
            );
          }
          if (_approvalDecision(task.executionStateJson) ==
              WorkChangeApprovalDecision.rejected) {
            // A stale rejection from another operation must not poison later
            // ordinary reads; clear it after the safe, non-sensitive result.
            task.executionStateJson = _withoutApprovalCheckpoint(
              task.executionStateJson,
            );
          }
          _recordSensitiveReadApproval(task, stage02, result,
              operation: 'readTextRange',
              path: path,
              startByte: startByte,
              byteLength: byteLength);
          return _mapFileResult(result);
        },
      ),
      WorkToolDefinition(
        name: AgentToolName.workspaceSearch,
        access: WorkToolAccess.readOnly,
        schema: const WorkToolSchema(
          fields: {
            'path': WorkToolValueType.string,
            'query': WorkToolValueType.string,
            'recursive': WorkToolValueType.boolean,
            'caseSensitive': WorkToolValueType.boolean,
          },
          required: {'path', 'query'},
        ),
        handler: (invocation) async {
          final denied = permission(ToolPermission.workspaceRead);
          if (!denied.succeeded) return denied;
          final args = invocation.arguments;
          final path = args['path'] as String;
          final query = args['query'] as String;
          final recursive = args['recursive'] == true;
          final caseSensitive = args['caseSensitive'] != false;
          final approved = _sensitiveReadAllowed(
            task,
            stage02,
            operation: 'search',
            path: path,
            query: query,
            recursive: recursive,
            caseSensitive: caseSensitive,
          );
          final result = await stage02.search(
            path,
            query,
            recursive: recursive,
            caseSensitive: caseSensitive,
            allowSensitive: approved,
          );
          if (_approvalDecision(task.executionStateJson) ==
                  WorkChangeApprovalDecision.rejected &&
              result['requiresApproval'] == true &&
              result['sensitive'] == true) {
            task.executionStateJson = _withoutApprovalCheckpoint(
              task.executionStateJson,
            );
            return const WorkToolResult.success(
              message: '用户拒绝读取敏感文件，已跳过本次搜索。',
              data: {'rejected': true, 'skipped': true, 'sensitive': true},
            );
          }
          if (_approvalDecision(task.executionStateJson) ==
              WorkChangeApprovalDecision.rejected) {
            task.executionStateJson = _withoutApprovalCheckpoint(
              task.executionStateJson,
            );
          }
          _recordSensitiveReadApproval(task, stage02, result,
              operation: 'search',
              path: path,
              query: query,
              recursive: recursive,
              caseSensitive: caseSensitive);
          return _mapFileResult(result);
        },
      ),
      WorkToolDefinition(
        name: documentDefinition.name,
        access: documentDefinition.access,
        schema: documentDefinition.schema,
        handler: documentHandler,
      ),
      WorkToolDefinition(
        name: AgentToolName.workspacePatch,
        access: WorkToolAccess.mutation,
        schema: const WorkToolSchema(
          fields: {
            'path': WorkToolValueType.string,
            'content': WorkToolValueType.string,
            'append': WorkToolValueType.boolean,
            'parts': WorkToolValueType.stringList,
            'expectedSha256': WorkToolValueType.string,
            'expectedFragment': WorkToolValueType.string,
            'replacement': WorkToolValueType.string,
            'overwrite': WorkToolValueType.boolean,
          },
          required: {'path'},
        ),
        mutationPipeline: _mutationPipeline(
          task: task,
          stage02: stage02,
          mutations: mutations,
          approvalScope: approvalScope,
        ),
        handler: (invocation) async {
          final denied = permission(ToolPermission.workspacePatch);
          if (!denied.succeeded) return denied;
          final args = invocation.arguments;
          final path = await _mutationPath(
            task,
            stage02,
            args['path'],
            allowAutoRename: !_isExactPatch(args) && !_isMergePatch(args),
          );
          final parts = args['parts'];
          if (parts is List && parts.every((part) => part is String)) {
            return _mergeStagedParts(
              task,
              stage02,
              args,
              path,
              parts.cast<String>(),
            );
          }
          final content = args['content'];
          if (content is String) {
            final refusal = await _overwriteRefusal(args, path);
            if (refusal != null) return refusal;
            if (args['append'] == true) {
              return _mapFileResult(await stage02.append(path, content));
            }
            final raw = await stage02.write(path, content);
            return _mapFileResult(raw);
          }
          final patch = <String, dynamic>{
            'path': path,
            'expectedSha256': args['expectedSha256'],
            'expectedFragment': args['expectedFragment'],
            'replacement': args['replacement'],
          };
          return _mapFileResult(await stage02.applyPatch(jsonEncode(patch)));
        },
      ),
      WorkToolDefinition(
        name: AgentToolName.workspaceRename,
        access: WorkToolAccess.mutation,
        schema: const WorkToolSchema(
          fields: {
            'path': WorkToolValueType.string,
            'destinationPath': WorkToolValueType.string,
          },
          required: {'path', 'destinationPath'},
        ),
        mutationPipeline: _mutationPipeline(
          task: task,
          stage02: stage02,
          mutations: mutations,
          approvalScope: approvalScope,
        ),
        handler: (invocation) async {
          final denied = permission(ToolPermission.workspacePatch);
          if (!denied.succeeded) return denied;
          return _mapFileResult(await stage02.rename(
            _effectivePath(task, workspaceRoot, invocation.arguments['path']),
            _effectivePath(
              task,
              workspaceRoot,
              invocation.arguments['destinationPath'],
              enforceRevision: false,
            ),
          ));
        },
      ),
      WorkToolDefinition(
        name: AgentToolName.workspaceDelete,
        access: WorkToolAccess.mutation,
        schema: const WorkToolSchema(
          fields: {'path': WorkToolValueType.string},
          required: {'path'},
        ),
        mutationPipeline: _mutationPipeline(
          task: task,
          stage02: stage02,
          mutations: mutations,
          approvalScope: approvalScope,
        ),
        handler: (invocation) async {
          final denied = permission(ToolPermission.workspacePatch);
          if (!denied.succeeded) return denied;
          return _mapFileResult(await stage02.delete(
            _effectivePath(task, workspaceRoot, invocation.arguments['path']),
          ));
        },
      ),
      WorkToolDefinition(
        name: AgentToolName.commandRun,
        access: WorkToolAccess.mutation,
        schema: const WorkToolSchema(
          fields: {
            'executable': WorkToolValueType.string,
            'arguments': WorkToolValueType.stringList,
            'workingDirectory': WorkToolValueType.string,
            'declaredImpact': WorkToolValueType.stringList,
          },
          required: {
            'executable',
            'arguments',
            'workingDirectory',
            'declaredImpact',
          },
        ),
        mutationPipeline: _commandPipeline(
          task: task,
          character: character,
          workspaceRoot: workspaceRoot,
        ),
        handler: (invocation) => _runCommand(
          task,
          invocation,
          character,
          workspaceRoot,
        ),
      ),
      ..._skillDefinitions(task, character, permission),
    ];
    return WorkToolRegistry(definitions: definitions);
  }

  /// `overwrite:false` 在 `workspace.patch` 的每种形态下同义：不许碰已存在的
  /// 文件。
  ///
  /// 让整文件写遵守它、而追加与合并照样覆盖，等于把模型写下的"别碰已有文件"
  /// 静默丢掉——同一个参数在工具各形态下必须同义，否则模型无法用它保护旧产物。
  Future<WorkToolResult?> _overwriteRefusal(
    Map<String, dynamic> args,
    String path,
  ) async {
    if (args['overwrite'] != false || !await File(path).exists()) return null;
    return const WorkToolResult.failed(
      message: '目标文件已存在且 overwrite=false，未执行写入。',
      failureCode: 'targetExists',
    );
  }

  /// `parts` 形态：把模型给的分段按顺序合并成 [path]。
  ///
  /// 目标路径（含"合并形态不自动改名"）已由 handler 解析完，这里只管分段：
  /// 先过 `overwrite` 闸门，再解析分段路径，最后才碰 stage02。分段路径非法时
  /// 必须按"路径被拒"返回：裸抛 `FormatException` 会被注册表兜成 `internal`，
  /// 模型看到的是一句"工具执行失败"，而不是"这个路径不允许"。
  Future<WorkToolResult> _mergeStagedParts(
    AgentTask task,
    Stage02WorkspaceFileTool stage02,
    Map<String, dynamic> args,
    String path,
    List<String> parts,
  ) async {
    final refusal = await _overwriteRefusal(args, path);
    if (refusal != null) return refusal;
    final effective = <String>[];
    for (final part in parts) {
      try {
        effective.add(_effectivePath(task, stage02.workspaceRoot, part));
      } on FormatException catch (error) {
        final reason = error.message.toString().trim();
        return WorkToolResult.pathRejected(
          message: reason.isEmpty ? '分段文件路径无效。' : reason,
        );
      }
    }
    final sensitivePart = await _sensitiveMergePart(stage02, effective);
    if (sensitivePart != null) {
      return WorkToolResult.failed(
        message: '工作模式不支持把敏感文件合并进产物；'
            '请改用 command.run 或先把内容复制成普通文件。',
        data: {'path': sensitivePart},
        failureCode: 'sensitivePartUnsupported',
      );
    }
    return _mapFileResult(await stage02.merge(path: path, parts: effective));
  }
}
