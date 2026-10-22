part of 'work_discussion_runner.dart';

extension _WorkDiscussionGroupStream on WorkDiscussionRunner {
  Future<Map<String, dynamic>> _boundedGroupStream(
      AgentTask task,
      _DiscussionMember member,
      List<Map<String, dynamic>> messages,
      Duration timeout,
      CancelToken token,
      int? runBoundary) async {
    var received = 0;
    var activitySeen = false;
    var activityCount = 0;
    DateTime? lastActivityAt;
    final startedAt = DateTime.now();
    final elapsed = Stopwatch()..start();
    final streamToken = CancelToken();
    unawaited(token.whenCancel.then((_) => streamToken.cancel()));
    Future<void>? activityWrite;
    final stalled = Completer<Map<String, dynamic>>();
    Map<String, dynamic> failure(String code, String message) => {
          'success': false,
          'message': message,
          'failureCode': code,
          'responseActivitySeen': activitySeen,
          'responseActivityCount': activityCount,
          if (lastActivityAt != null)
            'lastResponseActivityMs':
                lastActivityAt!.difference(startedAt).inMilliseconds,
          'receivedCharacters': received
        };
    Map<String, dynamic> deadline() {
      token.cancel('成员请求达到总时限');
      return failure('modelCompletionTimeout',
          '成员请求 ${timeout.inSeconds} 秒内仅收到 $received 个正文字符，未取得完整响应，未采纳状态');
    }

    final timer = firstByteTimeout < timeout
        ? Timer(firstByteTimeout, () {
            if (received > 0 || token.isCancelled) return;
            stalled.complete(failure('modelFirstByteStall',
                '成员请求 ${firstByteTimeout.inSeconds} 秒未收到正文，未采纳状态'));
            streamToken.cancel('成员正文首字节停滞');
          })
        : null;
    try {
      await _recordDiagnostic(task,
          '当前模型 ${member.config!.modelName} 使用流式接收；首段正文时限 ${firstByteTimeout.inSeconds} 秒，总时限 ${timeout.inSeconds} 秒。推理活动不代表正文，部分输出不作为正式方案。',
          title: '群讨论请求通道已确认', kind: WorkTaskEventKind.planning);
      final response = await Future.any([
        stalled.future,
        _completeGroupStream(
            task, member, messages, timeout, streamToken, runBoundary, (count) {
          received = count;
          if (count > 0) timer?.cancel();
        }, () {
          if (token.isCancelled || streamToken.isCancelled) return;
          activityCount++;
          lastActivityAt = DateTime.now();
          if (activitySeen) return;
          activitySeen = true;
          activityWrite = _recordDiagnostic(
              task, '已收到模型生成活动，仍在等待最终正文；首段正文与总时限保持不变。这不代表方案或测试取得进展，你无需操作。',
              title: '模型已有响应活动', kind: WorkTaskEventKind.planning);
        }),
      ]).timeout(timeout, onTimeout: deadline);
      if (!const {'modelFirstByteStall', 'emptyResponse'}
              .contains(response['failureCode']) ||
          token.isCancelled) {
        return response;
      }
      timer?.cancel();
      streamToken.cancel();
      // Cancel only the stalled transport; its replacement shares the original deadline.
      await _recordDiagnostic(
          task,
          '流式请求没有取得最终正文，已停止该通道；仅回退一次非流式请求，共用原总时限，你无需操作。'
          '依据：failureCode=${response['failureCode']}；receivedCharacters=$received；'
          'responseActivityCount=$activityCount。',
          title: '成员请求兼容回退',
          kind: WorkTaskEventKind.planning);
      final remaining = timeout - elapsed.elapsed;
      if (remaining <= Duration.zero) return deadline();
      if (token.isCancelled) return response;
      return await _complete(
              character: member.character,
              config: member.config!,
              apiKey: member.apiKey!,
              provider: member.provider!,
              taskId: task.id,
              runBoundary: runBoundary,
              conversationId: task.groupId,
              messages: messages,
              timeout: remaining,
              cancelToken: token)
          .timeout(remaining, onTimeout: deadline);
    } finally {
      timer?.cancel();
      streamToken.cancel();
      await activityWrite;
    }
  }

  Future<Map<String, dynamic>> _completeGroupStream(
      AgentTask task,
      _DiscussionMember member,
      List<Map<String, dynamic>> messages,
      Duration timeout,
      CancelToken token,
      int? runBoundary,
      void Function(int) received,
      void Function() onActivity) async {
    final buffer = StringBuffer();
    var bytes = 0;
    var completed = false;
    var lastProgress = DateTime.fromMillisecondsSinceEpoch(0);
    final started = DateTime.now();
    Map<String, dynamic> result = {
      'success': false,
      'message': '成员响应未完整结束',
      'failureCode': 'incompleteStream'
    };
    await for (final event in gateway.streamChatMessage(
      apiKey: member.apiKey!,
      provider: member.provider!,
      apiProtocol: member.config!.protocol,
      promptCacheKey: member.config!.workPromptCacheKey(member.character.id),
      customBaseUrl:
          WorkDiscussionRunner.structuredDiscussionBaseUrlFor(member.config!),
      model: member.config!.modelName,
      messages: messages,
      purpose: AiRequestPurpose.agent,
      conversationId: task.groupId,
      characterId: member.character.id,
      taskId: task.id,
      runBoundary: runBoundary,
      temperature: WorkDiscussionRunner.defaultDiscussionTemperature,
      maxTokens: member.config!.protocol == ApiProtocol.anthropicMessages
          ? _discussionOutputTokens(member.provider!, member.config!.modelName)
          : 0,
      receiveTimeout: timeout,
      cancelToken: token,
      userInitiated: true,
      onResponseActivity: onActivity,
      finishOnTerminalFrame: true,
      reasoningEffort:
          member.config!.modelName.trim().toLowerCase() == 'step-5-preview'
              ? 'low'
              : null,
    )) {
      if (token.isCancelled) return {'success': false, 'message': '成员请求已取消'};
      if (event.type == ChatStreamEventType.error) {
        return {
          'success': false,
          'message': sanitizeWorkTaskError(event.message),
          'failureCode': 'discussionStreamFailed'
        };
      }
      if (event.type == ChatStreamEventType.token) {
        final delta = event.delta ?? '';
        bytes += utf8.encode(delta).length;
        if (bytes > WorkDiscussionRunner.maxResponseBytes) {
          token.cancel();
          return {
            'success': false,
            'message': '成员响应超过安全大小上限，未采纳部分响应',
            'failureCode': 'responseTooLarge'
          };
        }
        buffer.write(delta);
        received(buffer.length);
        final now = DateTime.now();
        if (delta.isNotEmpty &&
            now.difference(lastProgress) >= const Duration(seconds: 15)) {
          lastProgress = now;
          await _recordDiagnostic(task,
              '已接收 ${buffer.length} 个正文字符；请求已耗时 ${now.difference(started).inSeconds} 秒。完整响应与协议校验完成前不采纳方案，你无需操作。',
              title: '正在接收成员模型响应', kind: WorkTaskEventKind.planning);
        }
      }
      if (event.type == ChatStreamEventType.done) {
        final content = (event.content ?? '').isNotEmpty
            ? event.content!
            : buffer.toString();
        if (utf8.encode(content).length >
            WorkDiscussionRunner.maxResponseBytes) {
          return {
            'success': false,
            'message': '成员响应超过安全大小上限',
            'failureCode': 'responseTooLarge'
          };
        }
        completed = true;
        result = {
          'success': content.trim().isNotEmpty,
          'message': content,
          if (content.trim().isEmpty) 'failureCode': 'emptyResponse',
          'truncated': event.truncated,
          'promptTokens': event.promptTokens,
          'completionTokens': event.completionTokens,
          'cachedTokens': event.cachedTokens
        };
        // A completed response must not wait for a provider to close its stream.
        break;
      }
    }
    return completed
        ? result
        : {
            'success': false,
            'message': '成员连接结束但没有完整响应，未采纳部分正文',
            'failureCode': 'incompleteStream'
          };
  }
}
