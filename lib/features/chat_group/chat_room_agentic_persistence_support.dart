part of 'chat_room_page.dart';

extension _ChatRoomAgenticPersistenceSupport on _ChatRoomPageState {
  Future<void> _persistAgentContextSummary(
    AICharacter character,
    ContextSummary summary,
  ) async {}

  /// 每次 agent 进度上报：更新内存态、落库任务检查点、刷新进度气泡文案。
  ///
  /// 落库检查点是任务可恢复的前提——App 崩溃后靠它续跑。
  Future<void> _persistAgentProgress(
    AgentTask task,
    AgentRuntimeProgress progress,
  ) async {
    _lastAgentProgress[task.id] = progress;
    // P2：仅首个非空值写入，天然幂等（后续 progress.runStartedAtMs 一致，不漂移）。
    // 若上报未携带 runStartedAtMs，则回退到当前时刻，保证耗时可展示。
    _progressStartTimes[task.id] ??=
        progress.runStartedAtMs ?? DateTime.now().millisecondsSinceEpoch;
    task.markProgress(
      step: progress.executedRequests.length,
      operations: progress.executedRequests
          .map((request) => request.toJsonString())
          .toList(),
      pendingToolJson: progress.pendingRequest?.toJsonString() ?? '',
    );
    await _db.agentTaskBox.put(task.id, task);
    final character = _db.aiCharacterBox.get(task.characterId);
    await _upsertAgentProgressMessage(
      task,
      agentProgressMessageContent(
        characterName: character?.name ?? 'AI',
        progress: progress,
      ),
    );
  }

  /// 原地更新（或首次插入）任务的进度气泡消息。
  ///
  /// 消息 id 由任务派生（[WorkModeTaskLifecycle.progressMessageId]），
  /// 保证多次进度上报复用同一条消息，而不是刷出一串进度消息。
  Future<void> _upsertAgentProgressMessage(
    AgentTask task,
    String content,
  ) async {
    final id = WorkModeTaskLifecycle.progressMessageId(task);
    final existing = _db.messageBox.get(id);
    if (existing != null) {
      existing.content = content;
      await _repository.updateMessage(existing);
      if (_canTouchUi) {
        _setUiState(() {
          final idx = _messages.indexWhere((m) => m.id == id);
          if (idx >= 0) {
            _messages[idx] = existing;
          }
        });
      }
      return;
    }
    await _appendMessage(Message(
      id: id,
      groupId: task.groupId,
      senderId: task.characterId,
      senderType: 'ai',
      content: content,
    ));
  }

  /// 结算一个 agentic 任务的终态：写入状态/摘要，并处理进度气泡的去留。
  ///
  /// 状态判定：完成 → completed；未完成但有已执行操作 → 部分完成（可恢复）；
  /// 什么都没做成 → failed。
  Future<void> _finishAgentTask(
    AgentTask task,
    AgentRuntimeResult result,
  ) async {
    task
      ..resultSummary = result.message
      ..updatedAt = DateTime.now()
      ..pendingToolRequestJson =
          result.pendingToolRequest?.toJsonString() ?? '';
    if (result.status == AgentRuntimeStatus.completed) {
      task
        ..status = AgentTaskStatus.completed
        ..lastError = '';
    } else if (result.executedToolRequests.isNotEmpty) {
      task.markPartiallyCompleted(result.message);
    } else {
      task
        ..status = AgentTaskStatus.failed
        ..lastError = result.message;
    }
    await _db.agentTaskBox.put(task.id, task);
    // 终态气泡处理：
    // - 工作模式：仅 cancelled 删除；completed/failed/partiallyCompleted 保留，
    //   并刷新为终态 ✅ 摘要（末行 ⏳→✅、去光标）。
    // - 非工作模式：沿用旧行为，终态即删除，避免普通回复路径出现残留气泡。
    final removeProgress = task.workModeTask
        ? WorkModeTaskLifecycle.shouldRemoveProgress(task.status)
        : task.isTerminal;
    if (removeProgress) {
      await _removeAgentProgressMessage(task);
    } else {
      final lastProgress = _lastAgentProgress[task.id];
      final character = _db.aiCharacterBox.get(task.characterId);
      // 终态冻结耗时：基于 _progressStartTimes 记录的运行起点计算秒数，
      // 烘焙进终态摘要首行（⏱ Ns），即使随后清理 map 也不丢失耗时展示。
      final startMs = _progressStartTimes[task.id];
      final elapsed = startMs == null
          ? null
          : ((DateTime.now().millisecondsSinceEpoch - startMs) / 1000).round();
      await _upsertAgentProgressMessage(
        task,
        agentProgressMessageContent(
          characterName: character?.name ?? 'AI',
          progress: lastProgress,
          finalResult: true,
          elapsedSeconds: elapsed,
        ),
      );
    }
    // 终态清理：移除内存表里的进度与耗时起点，避免随任务数无界增长。
    // 终态内容已烘焙耗时，气泡不再依赖该表 live 计算，清理后展示不受影响。
    _lastAgentProgress.remove(task.id);
    _progressStartTimes.remove(task.id);
  }

  /// 删除任务对应的进度气泡消息（内存与库中同时移除）。
  Future<void> _removeAgentProgressMessage(AgentTask task) async {
    final id = WorkModeTaskLifecycle.progressMessageId(task);
    await _repository.deleteMessage(id, invalidateGroupMemory: false);
    if (_canTouchUi) {
      _setUiState(() {
        _messages = List<Message>.from(_messages)
          ..removeWhere((message) => message.id == id);
      });
    }
  }

  /// 取消一个 agentic 任务：标记取消原因、落库、删除进度气泡并清理内存表。
  Future<void> _cancelAgentTask(
    AgentTask task, {
    required String reason,
  }) async {
    WorkModeTaskLifecycle.cancelTask(task, reason: reason);
    await _db.agentTaskBox.put(task.id, task);
    await _removeAgentProgressMessage(task);
    // 终态清理：cancelled 气泡已删，无需展示耗时，移除内存表条目避免无界增长。
    _lastAgentProgress.remove(task.id);
    _progressStartTimes.remove(task.id);
  }

  /// 生成"任务部分完成"的用户可读报告：列出已完成的工具操作与中断原因，
  /// 并提示可从检查点继续或放弃。
  String _partialCompletionReport(AgentRuntimeResult result) {
    final operations = result.executedToolRequests.map((request) {
      final path = request.args['path']?.toString();
      return path == null || path.isEmpty
          ? request.tool.wireName
          : '${request.tool.wireName}：$path';
    }).join('；');
    return '任务部分完成，已完成的工具操作和文件均已保留。\n'
        '已完成：$operations\n'
        '中断原因：${result.message}\n'
        '你可以选择“继续执行”从检查点恢复，或“放弃”结束任务。';
  }

  /// 把用户输入解释为对"待审批工具调用"的裁决并执行。
  ///
  /// 返回 true 表示这条输入已被当作审批指令消耗掉（不应再作为普通消息落库）。
  ///
  /// 三种裁决：
  /// - [WorkModeApprovalAction.reject]：跳过该工具，让 agent 换个方式继续；
  /// - [WorkModeApprovalAction.cancelPending]：用户发了新指令，取消旧任务
  ///   （返回 false，让这条新输入继续走正常发送流程）；
  /// - 其余（批准）：执行该工具并继续 agent 循环。
  ///
  /// 批准/拒绝后都可能再次遇到新的待审批工具，此时递归回到
  /// [_presentPendingAgentApproval] 形成多步审批链。
}
