part of 'default_work_task_runner.dart';

extension _DefaultWorkTaskRunnerMutationPolicy on DefaultWorkTaskRunner {
  List<WorkToolDefinition> _skillDefinitions(
    AgentTask task,
    AICharacter character,
    WorkToolResult Function(ToolPermission) permission,
  ) =>
      [
        WorkToolDefinition(
          name: AgentToolName.skillCreate,
          access: WorkToolAccess.mutation,
          schema: const WorkToolSchema(
            fields: {
              'name': WorkToolValueType.string,
              'domain': WorkToolValueType.string,
              'description': WorkToolValueType.string,
              'instructions': WorkToolValueType.stringList,
              'permissions': WorkToolValueType.stringList,
            },
            required: {'name', 'domain', 'description', 'instructions'},
          ),
          mutationPipeline: _skillMutationPipeline(
            task: task,
            label: '创建应用内 Skill',
          ),
          handler: (invocation) async {
            final denied = permission(ToolPermission.skillCreate);
            if (!denied.succeeded) return denied;
            return _mapSkillResult(
              await _serializeSkillMutation(
                () => _createSkill(character, invocation.arguments),
              ),
            );
          },
        ),
        WorkToolDefinition(
          name: AgentToolName.skillDownload,
          access: WorkToolAccess.mutation,
          schema: const WorkToolSchema(
            fields: {
              'templateId': WorkToolValueType.string,
              'id': WorkToolValueType.string,
              'skillId': WorkToolValueType.string,
              'name': WorkToolValueType.string,
              'url': WorkToolValueType.string,
              'source': WorkToolValueType.string,
            },
            allowAdditional: false,
          ),
          mutationPipeline: _skillMutationPipeline(
            task: task,
            label: '安装应用内 Skill 模板',
          ),
          handler: (invocation) async {
            final denied = permission(ToolPermission.skillDownload);
            if (!denied.succeeded) return denied;
            return _mapSkillResult(
              await _serializeSkillMutation(
                () => _downloadSkill(character, invocation.arguments),
              ),
            );
          },
        ),
      ];

  WorkToolMutationPipeline _mutationPipeline({
    required AgentTask task,
    required Stage02WorkspaceFileTool stage02,
    required WorkspaceMutationService mutations,
    required WorkApprovalScope? approvalScope,
  }) {
    return WorkToolMutationPipeline(
      policy: (invocation) async {
        if (_isDirectWordPatch(task, invocation.call)) {
          return const WorkToolResult.failed(
            message:
                '用户明确要求 Word 时，workspace.patch 只能写入 Markdown 转换源，不能直接写入伪 DOCX。请使用 command.run 调用已验证的转换工具。',
            failureCode: 'binaryArtifactNotSupported',
          );
        }
        final plan = await _planForFileInvocation(
          task,
          invocation.call,
          stage02,
          mutations,
        );
        if (plan == null) {
          return const WorkToolResult.pathRejected(
            message: '无法在授权目录内解析精确文件路径。',
          );
        }
        stage02.updateImplicitScopeAllowed(
          folderGrantService?.settings.confirmOrdinaryWrites == false,
        );
        // Keep policy and approval in one gate. This prevents a high-risk
        // command (or a no-snapshot write) from being approved by one gate and
        // then silently reusing the same decision in a second gate.
        var approvalAccepted = false;
        final result = await _mutationApprovalGate(
          task,
          invocation,
          plan,
          workspaceRoot: stage02.workspaceRoot,
          onApprovalEvaluated: (accepted) => approvalAccepted = accepted,
        );
        final currentDecision = _approvalDecision(task.executionStateJson);
        final currentScope = _approvalScope(task.executionStateJson);
        final currentCapability = _approvalCapability(task);
        final retainsMutationApproval =
            currentDecision?.permitsExecution == true &&
                currentCapability == WorkApprovalCapability.mutation &&
                currentScope != null;
        // Keep an explicit mutation scope when it is still present in the
        // durable checkpoint. If it does not cover this plan, Stage 02 must
        // reject it; falling back to the ordinary-write setting would turn a
        // stale or foreign approval into broader authority.
        if (result == null &&
            !approvalAccepted &&
            stage02.approvalDecision != null &&
            !retainsMutationApproval) {
          // The registry is created once per runner invocation, while the
          // task checkpoint is consumed after each approved mutation. Clear
          // the old Stage 02 scope before the next handler uses it.
          stage02.clearApprovalForMutation(
            allowImplicitScope:
                folderGrantService?.settings.confirmOrdinaryWrites == false,
          );
        }
        return result;
      },
      approval: null,
      snapshot: (invocation) async {
        final plan = await _planForFileInvocation(
          task,
          invocation.call,
          stage02,
          mutations,
        );
        if (plan == null || plan.snapshotAvailable) return null;
        return const WorkToolResult.waitingForApproval(
          message: '当前文件变更无法创建可撤销快照，请明确批准后继续。',
          data: {'noUndoRequired': true},
        );
      },
      // Stage02WorkspaceFileTool and WorkspaceMutationService own the actual
      // path/file locks. This named gate documents that ownership without
      // introducing a second lock owner around the same mutation.
      lock: (_) => null,
    );
  }

  WorkToolMutationPipeline _commandPipeline({
    required AgentTask task,
    required AICharacter character,
    required String workspaceRoot,
  }) {
    return WorkToolMutationPipeline(
      policy: (invocation) async {
        if (!_permissionsForTask(task, character)
            .contains(ToolPermission.commandRun)) {
          return const WorkToolResult.permissionDenied(
            message: '角色未授予 commandRun 工具权限。',
          );
        }
        final command = _commandFromCall(invocation.call, workspaceRoot);
        if (command == null) {
          return const WorkToolResult.failed(
            message:
                '命令必须使用 executable、arguments、workingDirectory 和 declaredImpact。',
            failureCode: 'invalidCommand',
          );
        }
        final policy = _commandPolicyFor(character, workspaceRoot).evaluate(
          command,
          taskId: task.id,
          userExplicitlyRequested: _requestsExplicitValidation(
            WorkDiscussionState.currentRequestScope(task),
          ),
        );
        final writableResult = await _commandWritableCapabilityGate(
          task,
          command,
          policy,
        );
        if (writableResult != null) return writableResult;
        if (!policy.allowed) {
          if (policy.requiresExplicitRequest) {
            if (policy.changePlan != null) {
              task.executionStateJson = _withApprovalPlan(
                task.executionStateJson,
                policy.changePlan!,
              );
            }
            task.executionStateJson = _withExplicitCommandRequest(
              task.executionStateJson,
            );
            return WorkToolResult.paused(
              message: policy.reason,
              data: {
                'impact': policy.impact.wireName,
                'requiresApproval': policy.requiresApproval,
                'requiresSeparateConfirmation':
                    policy.requiresSeparateConfirmation,
                'requiresExplicitRequest': policy.requiresExplicitRequest,
              },
            );
          }
          final data = <String, dynamic>{
            'impact': policy.impact.wireName,
            'rejectionKind': policy.rejectionKind.name,
            'commandDisplay': _safeCommandDisplay(command),
          };
          return policy.rejectionKind == WorkCommandRejectionKind.pathRejected
              ? WorkToolResult.pathRejected(
                  message: policy.reason,
                  data: data,
                )
              : WorkToolResult.failed(
                  message: policy.reason,
                  data: data,
                  failureCode: 'modelProtocol',
                );
        }
        // Read-only commands share the mutation-shaped registry entry so the
        // command name cannot bypass the closed schema, but they must not be
        // forced through a file-change approval plan.
        if (policy.isReadOnly) return null;
        final plan = policy.changePlan;
        return plan == null
            ? const WorkToolResult.failed(
                message: '命令影响范围无法形成审批计划，未执行。',
                failureCode: 'commandPlanMissing',
              )
            : _mutationApprovalGate(
                task,
                invocation,
                plan,
                workspaceRoot: workspaceRoot,
              );
      },
      approval: null,
      snapshot: (invocation) async {
        final command = _commandFromCall(invocation.call, workspaceRoot);
        if (command == null) return null;
        final evaluation = _commandPolicyFor(character, workspaceRoot).evaluate(
          command,
          taskId: task.id,
          userExplicitlyRequested: _requestsExplicitValidation(
            WorkDiscussionState.currentRequestScope(task),
          ),
        );
        final plan = evaluation.changePlan;
        if (evaluation.isReadOnly || plan == null) return null;
        if (_approvalDecision(task.executionStateJson)?.permitsWithoutUndo ==
            true) {
          return null;
        }
        task.executionStateJson = _withApprovalPlan(
          task.executionStateJson,
          plan,
        );
        return const WorkToolResult.waitingForApproval(
          message: '命令无法创建可撤销快照，请明确选择“无撤销执行”后继续。',
          data: {'noUndoRequired': true},
        );
      },
      // The handler acquires this exact impact set for the process lifetime;
      // the named gate still rejects a mutation plan that cannot identify any
      // directory, preventing an unscoped command from reaching the handler.
      lock: (invocation) {
        final command = _commandFromCall(invocation.call, workspaceRoot);
        if (command == null) return null;
        final evaluation = _commandPolicyFor(character, workspaceRoot).evaluate(
          command,
          taskId: task.id,
          userExplicitlyRequested: _requestsExplicitValidation(
            WorkDiscussionState.currentRequestScope(task),
          ),
        );
        final plan = evaluation.changePlan;
        if (evaluation.isReadOnly || plan == null) return null;
        if (plan.knownAffectedDirectories.isEmpty) {
          return const WorkToolResult.failed(
            message: '命令缺少可锁定的影响目录，未执行。',
            failureCode: 'commandLockScopeMissing',
          );
        }
        if (resourceLockManager == null) {
          return const WorkToolResult.failed(
            message: '命令变更缺少资源锁管理器，未执行。',
            failureCode: 'commandLockUnavailable',
          );
        }
        return null;
      },
    );
  }

  WorkToolMutationPipeline _skillMutationPipeline({
    required AgentTask task,
    required String label,
  }) {
    Future<WorkToolResult?> gate(WorkToolInvocation invocation) async {
      if (_isQaReportTask(task)) {
        return const WorkToolResult.pathRejected(
          message: '当前 QA 阶段仅允许写入合同指定的 Markdown 测试报告；应用内 Skill 配置未执行。',
          data: {'stageBoundary': 'qaReportOnly'},
        );
      }
      final decision = _approvalDecision(task.executionStateJson);
      if (decision == WorkChangeApprovalDecision.rejected) {
        task.executionStateJson = _withoutApprovalCheckpoint(
          task.executionStateJson,
        );
        return WorkToolResult.success(
          message: '用户拒绝了$label，未更新应用内技能。',
          data: const {'rejected': true},
        );
      }
      final fingerprint = WorkApprovalFingerprint.mutation(
        call: invocation.call,
      );
      if (_approvalAllowsMutation(
        task,
        invocation,
        fingerprint: fingerprint,
        // Skill changes have no filesystem plan, so the capability fingerprint
        // is their exact scope.
        scopeAllows: true,
        requiresFresh: true,
      )) {
        return null;
      }
      task.executionStateJson = _withApprovalMetadata(
        task.executionStateJson,
        capability: WorkApprovalCapability.mutation,
        fingerprint: fingerprint,
      );
      return WorkToolResult.waitingForApproval(
        message: '$label会修改应用内技能配置，请确认后继续。',
      );
    }

    return WorkToolMutationPipeline(
      policy: gate,
      approval: null,
      // Skill metadata lives in Hive rather than the workspace snapshot store.
      // Ordinary approval is therefore not enough: require the same explicit
      // no-undo decision used for an unsnapshotable file/command mutation.
      snapshot: (_) {
        final decision = _approvalDecision(task.executionStateJson);
        if (decision?.permitsWithoutUndo == true) return null;
        return const WorkToolResult.waitingForApproval(
          message: '应用内技能配置没有文件快照，必须明确选择“无撤销执行”后继续。',
          data: {'noUndoRequired': true},
        );
      },
      // The actual Hive mutation is wrapped by [_serializeSkillMutation]. The
      // named gate remains present so registry inspection cannot mistake this
      // tool for a mutation without a lock boundary.
      lock: (_) => null,
    );
  }

  Future<WorkToolResult?> _mutationApprovalGate(
    AgentTask task,
    WorkToolInvocation invocation,
    WorkChangePlan plan, {
    required String workspaceRoot,
    void Function(bool accepted)? onApprovalEvaluated,
  }) async {
    final scopeViolation = await _qaReportMutationViolation(
      task,
      plan,
      workspaceRoot: workspaceRoot,
    );
    if (scopeViolation != null) {
      return WorkToolResult.pathRejected(
        message: scopeViolation,
        data: const {'stageBoundary': 'qaReportOnly'},
      );
    }
    final settings = WorkChangePolicySettings(
      confirmOrdinaryWrites:
          folderGrantService?.settings.confirmOrdinaryWrites ?? true,
    );
    final decision = _approvalDecision(task.executionStateJson);
    final scope = _approvalScope(task.executionStateJson);
    if (decision == WorkChangeApprovalDecision.rejected) {
      task.executionStateJson = _withoutApprovalCheckpoint(
        task.executionStateJson,
      );
      return const WorkToolResult.success(
        message: '用户拒绝了该变更，未执行。',
        data: {'rejected': true},
      );
    }
    final fingerprint = WorkApprovalFingerprint.mutation(
      call: invocation.call,
      plan: plan,
    );
    final policy = WorkChangePolicy.evaluate(
      plan: plan,
      settings: settings,
      scope: scope,
    );
    final approvalAccepted = _approvalAllowsMutation(
      task,
      invocation,
      fingerprint: fingerprint,
      scopeAllows: scope?.allows(plan) == true,
      requiresFresh: _requiresFreshApproval(plan),
    );
    onApprovalEvaluated?.call(approvalAccepted);
    if (approvalAccepted) {
      return null;
    }
    final sensitiveMutation = plan.exactPaths.any(
      (path) => workspaceFileService?.isSensitivePath(path) == true,
    );
    if (sensitiveMutation) {
      // Sensitive files are always per-operation approvals.  This branch is
      // intentionally before the ordinary-write setting so disabling routine
      // prompts can never turn a credential/config mutation into a silent
      // write.
      task.executionStateJson = _withApprovalPlan(
        task.executionStateJson,
        plan,
        call: invocation.call,
      );
      return WorkToolResult.waitingForApproval(
        message: '修改、重命名或删除敏感文件必须再次确认。影响范围：${_displayPlan(plan)}',
        data: {
          'approvalPlan': plan.toJson(),
          'sensitive': true,
        },
      );
    }
    if (!policy.requiresPrompt) return null;
    task.executionStateJson = _withApprovalPlan(
      task.executionStateJson,
      plan,
      call: invocation.call,
    );
    return WorkToolResult.waitingForApproval(
      message: '${policy.reason} 影响范围：${_displayPlan(plan)}',
      data: {'approvalPlan': plan.toJson()},
    );
  }

  Future<String?> _qaReportMutationViolation(
    AgentTask task,
    WorkChangePlan plan, {
    required String workspaceRoot,
  }) async {
    if (!_isQaReportTask(task)) return null;

    // QA may create or update the named report, but even the report itself
    // cannot be renamed, deleted, or changed through an opaque command.
    if (!const <WorkChangeActionType>{
      WorkChangeActionType.create,
      WorkChangeActionType.modify,
      WorkChangeActionType.patch,
    }.contains(plan.actionType)) {
      return '当前 QA 阶段仅允许创建或修改合同指定的 Markdown 测试报告；重命名、删除和命令变更均未执行。';
    }
    if (plan.exactPaths.isEmpty) {
      return '当前 QA 阶段仅允许写入合同指定的 Markdown 测试报告；不透明命令变更未执行。';
    }

    final state = WorkDiscussionState.decodeExecutionState(
      task.executionStateJson,
    );
    final contract = _effectiveQaContract(task, state);
    final location = contract?['location'];
    try {
      if (location is! String || location.trim().isEmpty) {
        return '无法安全确认 QA 报告的精确输出路径，所有文件变更均已拒绝。';
      }
      final isWindows = workspaceFileService?.pathPolicy.isWindows ??
          RegExp(r'^[A-Za-z]:').hasMatch(workspaceRoot);
      // The user-facing contract may include the authorized root leaf
      // (Desktop/report.md) while workspaceRoot already points at Desktop.
      // Share the stripping rule with _effectivePath so QA report writes do not
      // resolve to Desktop/Desktop/report.md and get rejected as "other".
      final normalizedRoot = workspaceRoot.replaceAll('\\', '/');
      final rawTarget =
          _stripAuthorizedRootLeaf(location.trim(), normalizedRoot);
      final expected = WorkspacePathPolicy.normalizePath(
        _isAbsolutePath(rawTarget) ? rawTarget : '$normalizedRoot/$rawTarget',
        isWindows: isWindows,
      );
      final files = workspaceFileService;
      if (files == null) {
        return '无法安全确认 QA 报告的精确输出路径，所有文件变更均已拒绝。';
      }
      final resolvedExpected = await files.pathPolicy.resolve(
        expected,
        allowMissing: true,
      );
      if (plan.exactPaths.any((path) => path != resolvedExpected.path)) {
        return '当前 QA 阶段仅允许写入合同指定的 Markdown 测试报告；HTML 和其他路径均未执行。';
      }
    } on Object {
      return '无法安全确认 QA 报告的精确输出路径，所有文件变更均已拒绝。';
    }
    return null;
  }

  bool _isQaReportTask(AgentTask task) {
    final state = WorkDiscussionState.decodeExecutionState(
      task.executionStateJson,
    );
    final latest = WorkDiscussionState.latestRequestScope(task).toLowerCase();
    final current = WorkDiscussionState.currentRequestScope(task).toLowerCase();
    final stage = '$latest\n$current';
    final qaOnlyStage = stage.contains('qa-only') || stage.contains('qa only');
    final developerStage = !qaOnlyStage &&
        (latest.contains('developer') ||
            latest.contains('dev fix') ||
            latest.contains('developer stage') ||
            latest.contains('开发阶段') ||
            latest.contains('纯开发'));
    if (developerStage) return false;
    final contract = _effectiveQaContract(task, state);
    final scope = stage;
    final location = contract?['location'];
    return state.isValid &&
        state.state?.conversationId == task.groupId &&
        contract?['format'] == 'markdown' &&
        RegExp(r'测试|验证|回归|验收|\bqa\b|quality assurance|\btest(?:ing)?\b',
                caseSensitive: false)
            .hasMatch(scope) &&
        RegExp(r'\.(?:md|markdown)$', caseSensitive: false)
            .hasMatch(location is String ? location.trim() : '');
  }

  /// A failed developer run can leave an HTML contract in the checkpoint even
  /// after a queued QA request becomes the active stage.  Re-derive only the
  /// narrow QA report fields from the newest request; this never broadens the
  /// allowed path and keeps the original contract as the fallback.
  Map<String, dynamic>? _effectiveQaContract(
    AgentTask task,
    WorkDiscussionDecodeResult decoded,
  ) {
    final persisted = decoded.state?.deliverableContract;
    final latest = WorkDiscussionState.latestRequestScope(task).trim();
    if (latest.isEmpty) return persisted;
    final derived = WorkRoleRouter.deliverableContractForRequest(
      latest,
      requestRevision: decoded.state?.requestRevision ?? 1,
    );
    if (derived.format != 'markdown' ||
        !RegExp(r'\.(?:md|markdown)$', caseSensitive: false)
            .hasMatch(derived.location)) {
      return persisted;
    }
    return <String, dynamic>{
      ...?persisted,
      'deliverableType': 'document',
      'format': 'markdown',
      'location': derived.location,
      'contentScope': latest,
    };
  }

  bool _approvalAllowsMutation(
    AgentTask task,
    WorkToolInvocation invocation, {
    required String fingerprint,
    required bool scopeAllows,
    required bool requiresFresh,
  }) {
    final checkpoint = _decodeMap(task.executionStateJson);
    final decision = WorkChangeApprovalDecision.fromWire(
      checkpoint['approvalDecision'],
    );
    if (decision?.permitsExecution != true || !scopeAllows) return false;
    if (checkpoint['approvalCapability'] != WorkApprovalCapability.mutation ||
        checkpoint['approvalOperationFingerprint'] != fingerprint) {
      return false;
    }
    if (!requiresFresh) return true;
    final retryAttempt = invocation.context.state['toolRetryAttempt'];
    final isRetry = retryAttempt is int && retryAttempt > 0;
    final consumed = checkpoint['approvalConsumed'] == true;
    if (consumed && !isRetry) return false;
    if (!isRetry) {
      checkpoint['approvalConsumed'] = true;
      task.executionStateJson = jsonEncode(checkpoint);
    }
    return true;
  }

  bool _requiresFreshApproval(WorkChangePlan plan) {
    if (plan.actionType == WorkChangeActionType.delete ||
        plan.actionType == WorkChangeActionType.command) {
      return true;
    }
    return !plan.snapshotAvailable || !plan.reversible;
  }
}
