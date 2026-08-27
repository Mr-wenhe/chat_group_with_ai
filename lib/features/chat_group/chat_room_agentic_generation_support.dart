part of 'chat_room_page.dart';

extension _ChatRoomAgenticGenerationSupport on _ChatRoomPageState {
  Future<String> _generateAgenticReply({
    required AICharacter character,
    required ApiConfig config,
    required ApiProvider provider,
    required String userMessage,
    List<MediaAttachment>? media,
    List<Message>? context,
    AgentTask? resumeTask,
    bool workMode = false,
    CancelToken? cancelToken,
    WorkModeRunHandle? workModeRun,
  }) async {
    // 并发兜底：同一角色已在执行 agentic 任务时，跳过本次重复调用，
    // 避免重入导致重复文件生成 / 重复消息。该角色的本轮任务由首次调用负责。
    if (_agenticRunningCharacterIds.contains(character.id)) {
      return '';
    }
    _agenticRunningCharacterIds.add(character.id);
    try {
      final task = resumeTask ??
          AgentTask(
            groupId: widget.groupId,
            characterId: character.id,
            userRequest: userMessage,
            requestedPermissions: character.toolPermissions,
            workModeTask: workMode,
          );
      task
        ..status = AgentTaskStatus.planning
        ..updatedAt = DateTime.now();
      // 先落库任务：即使 App 崩溃也能在下次打开时提供恢复入口。
      await _db.agentTaskBox.put(task.id, task);
      // 在聊天流里插入一条"正在执行"的进度消息，后续原地更新。
      await _upsertAgentProgressMessage(
        task,
        agentProgressMessageContent(characterName: character.name),
      );
      final runtime = _agentRuntimeFor(
        character: character,
        config: config,
        provider: provider,
        task: task,
        workMode: workMode,
        cancelToken: cancelToken,
        workModeRun: workModeRun,
      );

      // 把附件（图片/文档）解析成文本描述并拼进请求，让 agent 能"看到"附件。
      final mediaEnhancedRequest =
          await AgentAttachmentContext.enhanceCurrentRequest(
        userRequest: userMessage,
        media: media,
      );
      final conversationHistory = await _agenticHistory(
        userMessage,
        characterId: character.id,
        messages: context,
      );
      final restoredRequests = resumeTask == null
          ? const <ToolRequest>[]
          : _restoredExecutedRequests(resumeTask);
      // 恢复场景：显式告知模型哪些工具操作已完成，防止重复写文件 / 重复执行副作用。
      if (restoredRequests.isNotEmpty) {
        conversationHistory.insert(0, {
          'role': 'system',
          'content': '这是从检查点恢复的任务。以下工具操作已经完成，'
              '不要重复执行：${restoredRequests.map((request) => request.toJsonString()).join('；')}',
        });
      }
      // 依据请求内容匹配该角色可用的技能（含是否需要新建技能的判断）。
      final skillResolution =
          CharacterSkillResolver.resolveFor(character, userMessage);

      Future<AgentRuntimeResult> runRuntime(
        List<Map<String, dynamic>> preparedHistory,
      ) {
        return runtime.run(
          character: character,
          skills: _agenticSkillsFor(
            character,
            userMessage,
            resolution: skillResolution,
          ),
          userRequest: mediaEnhancedRequest,
          conversationHistory: preparedHistory,
          priorExecutedRequests: restoredRequests,
          // 已有保存过的匹配技能时就不再强制创建，避免重复造轮子。
          forceSkillCreation: skillResolution.needsSkillCreation &&
              !_savedSkillMatchesRequest(character, userMessage),
          workModeContext:
              workMode ? WorkModePolicy.planningContext(character) : '',
        );
      }

      final result = workMode
          ? await runWithUnifiedMemory(
              selector: _memoryContextSelector,
              conversationHistory: conversationHistory,
              observerCharacterId: character.id,
              participantCharacterIds: _characters.map((c) => c.id).toList(),
              userMessage: userMessage,
              run: runRuntime,
            )
          : await runRuntime(conversationHistory);
      // 路径一：需要用户批准某个工具调用，任务挂起等待。
      if (result.status == AgentRuntimeStatus.waitingForApproval &&
          result.pendingToolRequest != null) {
        final approval = PendingAgentToolApproval(
          character: character,
          config: config,
          provider: provider,
          userRequest: mediaEnhancedRequest,
          request: result.pendingToolRequest!,
          priorExecutedRequests: result.executedToolRequests,
          conversationHistory: conversationHistory,
          task: task,
        );
        await _presentPendingAgentApproval(approval);
        return result.message;
      }
      await _finishAgentTask(task, result);
      // 路径二：未跑完（超步数 / 超时 / 失败）。有已执行操作时给出部分完成报告。
      if (result.status != AgentRuntimeStatus.completed) {
        final rawContent = result.executedToolRequests.isEmpty
            ? result.message
            : _partialCompletionReport(result);
        final content = _stripNamePrefix(rawContent, character.name);
        final message = Message(
          groupId: widget.groupId,
          senderId: character.id,
          senderType: 'ai',
          content: content,
        );
        await _appendMessage(message);
        // 已有实际进展才值得提示恢复，否则从头重跑更简单。
        if (result.executedToolRequests.isNotEmpty) {
          _scheduleAgentTaskRecovery();
        }
        return content;
      }
      // 路径三：正常完成。把工具产出的文件作为附件挂在消息上。
      final content = _stripNamePrefix(result.message, character.name);
      final attachments = await _attachmentsForAgentToolResult(
        character: character,
        result: result,
      );
      final message = Message(
        groupId: widget.groupId,
        senderId: character.id,
        senderType: 'ai',
        content: content,
        media: attachments.isEmpty ? null : attachments,
      );
      await _appendMessage(message);
      await _recordReplyUsage(character);
      _registerUserMentionIfNeeded(message);
      return content;
    } finally {
      // 无论成功失败都要释放并发标记，否则该角色将永久无法再触发 agentic。
      _agenticRunningCharacterIds.remove(character.id);
    }
  }

  /// 把 agentic 工具产出的工作区文件复制成可在聊天里查看的附件。
  ///
  /// 只处理 [AgentToolName.workspacePatch] 类工具：从 patch 与参数里收集目标路径，
  /// 经 [WorkspacePathGuard] 过滤掉越权路径（如 `../`），最多取 6 个文件。
  /// 每个文件按优先级取内容：工具回读 → patch 里的 content → 通过桥接重新读盘。
  Future<List<MediaAttachment>> _attachmentsForAgentToolResult({
    required AICharacter character,
    required AgentRuntimeResult result,
  }) async {
    final request = result.pendingToolRequest;
    final patchRequests = <ToolRequest>[
      ...result.executedToolRequests
          .where((request) => request.tool == AgentToolName.workspacePatch),
      if (request != null && request.tool == AgentToolName.workspacePatch)
        request,
    ];
    if (patchRequests.isEmpty) {
      return const [];
    }
    final requestedPaths = <String>[];

    /// 归一化并去重收集安全的相对路径；越权路径直接丢弃。
    void addPath(String raw) {
      final path = WorkspacePathGuard.normalizeToRelative(raw);
      if (!WorkspacePathGuard.isSafeRelativePath(path)) return;
      if (!requestedPaths.contains(path)) requestedPaths.add(path);
    }

    // 路径来源有两处：工具参数里的 path，以及 patch 文本里的 +++ / diff --git 行。
    for (final request in patchRequests) {
      final directPath = request.args['path'];
      if (directPath is String) {
        addPath(directPath);
      }
      for (final path in _pathsFromPatch(
        request.args['patch'] as String? ?? '',
      )) {
        addPath(path);
      }
    }
    // 不同工具用 ok / exitCode 表达成功，两者任一成立即视为成功。
    final resultOk =
        result.toolResult?['ok'] == true || result.toolResult?['exitCode'] == 0;
    final normalizedResultPath = result.toolResult?['path'] is String
        ? WorkspacePathGuard.normalizeToRelative(
            result.toolResult!['path'] as String,
          )
        : null;
    // 汇总"请求写入的路径"与"工具实际报告的路径"，得到最终产物清单。
    final paths = resolveAgentArtifactPaths(
      requestedPaths: requestedPaths,
      actualResultPath: normalizedResultPath,
      resultSucceeded: resultOk,
    ).where(WorkspacePathGuard.isSafeRelativePath).toList();
    if (paths.isEmpty) return const [];

    final attachments = <MediaAttachment>[];
    final bridge = LocalAgentBridgeClient();
    final workspaceTool = WorkspaceFileTool(
      bridge,
      conversationId: widget.groupId,
    );
    // 取最后一个带 content 的 patch：多次修改同一文件时后写的才是最终内容。
    final lastPatchWithContent = patchRequests.reversed.firstWhere(
      (request) => request.args['content'] is String,
      orElse: () => patchRequests.last,
    );
    // 上限 6 个附件，防止一次任务产出大量文件把聊天界面撑爆。
    for (final path in paths.take(6)) {
      try {
        // 优先级 1：工具执行后自己回读的内容，最可信。
        final readback = resultOk && path == normalizedResultPath
            ? result.toolResult!['readbackContent']
            : null;
        if (readback is String && readback.isNotEmpty) {
          attachments.add(await _db.writeBytesToAiCharacterDir(
            bytes: utf8.encode(readback),
            fileName: fileNameFromPath(path),
            characterId: character.id,
            characterName: character.name,
            type: _attachmentTypeForPath(path),
          ));
          continue;
        }
        // 优先级 2：patch 请求里携带的完整内容。
        final generatedContent = resultOk &&
                (path == normalizedResultPath || normalizedResultPath == null)
            ? lastPatchWithContent.args['content']
            : null;
        if (generatedContent is String && generatedContent.isNotEmpty) {
          attachments.add(await _db.writeBytesToAiCharacterDir(
            bytes: utf8.encode(generatedContent),
            fileName: fileNameFromPath(path),
            characterId: character.id,
            characterName: character.name,
            type: _attachmentTypeForPath(path),
          ));
          continue;
        }
        // Always read through the active bridge. Resolving [path] against the
        // app process cwd can attach a same-named file from the old workspace
        // immediately after the user switches project directories.
        // 优先级 3：通过桥接重新读盘（必须走桥接，不能按进程 cwd 解析）。
        final read = await workspaceTool.read(path);
        final content = read['content'];
        if (content is String) {
          attachments.add(await _db.writeBytesToAiCharacterDir(
            bytes: utf8.encode(content),
            fileName: fileNameFromPath(path),
            characterId: character.id,
            characterName: character.name,
            type: _attachmentTypeForPath(path),
          ));
        }
      } catch (_) {
        // A single generated file failing to copy must not expose its path.
        // 单个文件复制失败不影响其余附件，也不把路径泄漏到 UI 上。
      }
    }
    return attachments;
  }

  /// 从 unified diff 文本里提取被修改的目标文件路径。
  ///
  /// 识别两种行：`+++ b/path`（新文件内容侧）与 `diff --git a/x b/y`（取 b 侧）。
  /// `/dev/null`（删除文件）与越权路径会被跳过。
  List<String> _pathsFromPatch(String patch) {
    final paths = <String>[];
    void addPath(String raw) {
      final path = raw.trim();
      if (path.isEmpty || path == '/dev/null') return;
      // 去掉 diff 惯例的 `b/` 前缀，得到工作区相对路径。
      final normalized = path.startsWith('b/') ? path.substring(2) : path;
      if (!WorkspacePathGuard.isSafeRelativePath(normalized)) return;
      if (!paths.contains(normalized)) paths.add(normalized);
    }

    for (final line in const LineSplitter().convert(patch)) {
      final plus = RegExp(r'^\+\+\+\s+(.+)$').firstMatch(line);
      if (plus != null) {
        addPath(plus.group(1) ?? '');
        continue;
      }
      final diff = RegExp(r'^diff --git\s+a/(.+?)\s+b/(.+)$').firstMatch(line);
      if (diff != null) {
        addPath(diff.group(2) ?? '');
      }
    }
    return paths;
  }

  /// 为一次 agentic 运行组装 [AgentRuntime]（补全回调、工具集、审批策略等）。
  ///
  /// 关键约定：
  /// - 输出 token 上限取"运行时偏好值"与"模型能力上限"的较小者；
  /// - 所有 LLM 调用都经 [_aiGateway]，由网关统一做预算预检与重试；
  /// - 工作模式下放开全部工具权限并使用工作模式的审批策略；
  /// - 停止检查绑定到本次 run 的句柄（而非共享标志），避免新 run 复活旧 run。
  AgentRuntime _agentRuntimeFor({
    required AICharacter character,
    required ApiConfig config,
    required ApiProvider provider,
    required AgentTask task,
    bool workMode = false,
    CancelToken? cancelToken,
    WorkModeRunHandle? workModeRun,
  }) {
    final bridge = LocalAgentBridgeClient();
    final capability = _aiGateway.capability(provider, config.modelName);
    final agentMaxTokens =
        min(AgentRuntime.preferredMaxOutputTokens, capability.maxOutput);
    final summaryMaxTokens =
        min(AgentRuntime.preferredSummaryOutputTokens, capability.maxOutput);
    return AgentRuntime(
      // agentic 主循环的补全回调：每一步"思考/决定调用哪个工具"都走这里。
      complete: (messages) async {
        final apiKey = await _credentialResolver.resolve(config);
        if (apiKey == null) {
          return const {'success': false, 'message': 'API 凭据不可用'};
        }
        return _aiGateway.sendChatMessageStreamed(
          apiKey: apiKey,
          provider: provider,
          customBaseUrl: config.customBaseUrl,
          model: config.modelName,
          messages: messages,
          maxTokens: agentMaxTokens,
          receiveTimeout: AgentRuntime.completionTimeout,
          cancelToken: cancelToken,
          purpose: AiRequestPurpose.agent,
          conversationId: widget.groupId,
          characterId: character.id,
          requiresTools: true,
          userInitiated: true,
        );
      },
      workspaceFileTool: WorkspaceFileTool(
        bridge,
        conversationId: widget.groupId,
      ),
      browserContextTool: BrowserContextTool(bridge),
      skillCreateHandler: (args) => _saveGeneratedSkillFromArgs(
        character: character,
        args: args,
      ),
      skillDownloadHandler: (args) => _downloadExpertSkillFromArgs(
        character: character,
        args: args,
      ),
      // 关闭本地快速规划器：它原本会绕过 LLM 直接写死一个空壳模板，
      // 导致用户“生成个人主页”却只得到 <p>内容由AI生成</p>。关闭后由 LLM
      // 通过 planning prompt 生成真实文件内容（args.content 放完整内容）。
      enableLocalFilePlanner: false,
      // 统一网关负责逐次预算预检和重试；Runtime 不再嵌套重试。
      completionMaxRetries: 0,
      onProgress: (progress) => _persistAgentProgress(task, progress),
      // 上下文接近模型窗口时自动摘要压缩；阈值 = 窗口 - 输出预留，并夹到安全区间。
      contextWindowManager: ContextWindowManager(
        maxRetries: 0,
        thresholdTokens: (capability.contextWindow - agentMaxTokens)
            .clamp(4096, kContextCompressThresholdTokens)
            .toInt(),
        // 压缩用低温度、独立的 summary 预算通道，与主循环区分计费用途。
        complete: (contextMessages) async {
          final apiKey = await _credentialResolver.resolve(config);
          if (apiKey == null) {
            return const {'success': false, 'message': 'API 凭据不可用'};
          }
          return _aiGateway.sendChatMessage(
            apiKey: apiKey,
            provider: provider,
            customBaseUrl: config.customBaseUrl,
            model: config.modelName,
            messages: contextMessages,
            temperature: 0.3,
            maxTokens: summaryMaxTokens,
            cancelToken: cancelToken,
            purpose: AiRequestPurpose.summary,
            conversationId: widget.groupId,
            characterId: character.id,
            userInitiated: true,
          );
        },
      ),
      contextIsDirectChat: _isDirectChat,
      onContextSummary: _persistAgentContextSummary,
      approvalPolicy: workMode
          ? WorkModePolicy.requiresApproval
          : AgentRuntime.requiresApproval,
      // 工作模式默认授予全部工具权限（仍受审批策略约束）。
      grantedPermissions: workMode ? ToolPermission.values.toSet() : null,
      // per-run 停止状态：捕获本 run 的句柄，而非共享标志。新 run 的 beginRun
      // 不会把旧 run 复活，旧 run 在自己的检查点读到的是自己的停止状态。
      shouldCancel:
          workMode ? () => workModeRun?.isRequestedStop ?? false : null,
    );
  }

  /// Agentic 摘要只在当前运行时使用；长期记忆统一由 ObservationEntry 管理。
}
