part of 'work_discussion_runner.dart';

extension _V2DiscussionRequests on _V2DiscussionSession {
  Future<WorkDiscussionV2Turn?> _request(_DiscussionMember member) async {
    final token = CancelToken();
    unawaited(cancellation.whenCancelled.then((_) => token.cancel()));
    try {
      if (state.phase == 'reviewing' && !await _loadDeliveryEvidence()) {
        return null;
      }
      final messages = await runWithUnifiedMemory<List<Map<String, dynamic>>>(
        selector: MemoryContextSelector(runner.database),
        conversationHistory: _messages(member),
        observerCharacterId: member.character.id,
        actor: member.character,
        maximumPromptCharacters: runner._discussionPromptCharacters(member),
        participantCharacterIds: state.activeMembers,
        userMessage: state.scope,
        projectScopeId: runner.database.workModeWorkspaceBox
            .get(task.groupId)
            ?.projectScopeId,
        conversationId: task.groupId,
        contextBoundary: WorkContextBoundary.readAt(
            runner.database.appSettingsBox, task.groupId),
        run: (prepared) async => prepared,
      );
      final inputLimit = runner._discussionPromptCharacters(member);
      if (messages.fold<int>(
              0,
              (total, message) =>
                  total +
                  (message['content'] is String
                      ? (message['content'] as String).length
                      : 0)) >
          inputLimit) {
        // Never clip authority-bearing questions, protocol or approvals.
        await _decision(
            'question', '', '当前必要讨论上下文超过成员模型窗口，请选择更大窗口模型。', '未截掉问题或认可。');
        return null;
      }
      return await _requestProtocol(member, messages, token);
    } on TimeoutException {
      if (!cancellation.isCancelled) {
        await _memberGap(member.character.id, '成员模型请求超时，请恢复连接或配置后继续。');
      }
      return null;
    } on DioException catch (error) {
      if (!cancellation.isCancelled) {
        await _memberGap(member.character.id, sanitizeWorkTaskError(error));
      }
      return null;
    } on Object catch (error) {
      lastValidationError = sanitizeWorkTaskError(error);
      return null;
    } finally {
      token.cancel();
    }
  }

  Future<WorkDiscussionV2Turn?> _requestProtocol(_DiscussionMember member,
      List<Map<String, dynamic>> messages, CancelToken token) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final response = await runner._sendTurnRequest(
          member: member,
          conversationId: task.groupId,
          messages: messages,
          timeout: runner.roleTimeout,
          cancelToken: token);
      if (response['success'] == false) {
        final reason = WorkDiscussionTurn.fromResponse(response).failureReason;
        if (AiRequestGateway.isBlockedMessage(response['message'] as String?)) {
          await _decision('question', member.character.id,
              '成员模型请求被现有治理规则拦截，请处理预算或配置。', sanitizeWorkTaskError(reason));
        } else {
          await _memberGap(member.character.id, sanitizeWorkTaskError(reason));
        }
        return null;
      }
      final parsed = WorkDiscussionV2Turn.parse(response);
      if (parsed != null) return parsed;
      if (attempt == 0) {
        messages.add({
          'role': 'user',
          'content': '上一响应不符合严格 v2 协议。只修复结构，不从预览推导认可或完成，保留全部问题和必要解释。'
        });
      }
    }
    return null;
  }

  Future<void> _attachDetail(Map<String, dynamic> proposal, String responseRef,
      String fileName) async {
    final store = runner.eventStore;
    if (store == null) {
      throw StateError('方案详情存储不可用');
    }
    final text = jsonEncode(proposal.containsKey('result')
        ? {
            ...proposal,
            'result': (workDocumentContextWithoutImageBytes({
              'recentToolResults': [
                {
                  'tool': proposal['tool'],
                  'status': 'success',
                  'data': proposal['result']
                }
              ]
            })['recentToolResults'] as List)
                .single['data']
          }
        : proposal);
    final ref = _key('proposal', text);
    final file =
        await store.writeDiscussionDetail(task.id, ref.substring(9), text);
    final message = runner.database.messageBox.get(responseRef);
    if (message != null) {
      message.media = [
        ...?message.media,
        MediaAttachment(
            type: 'file',
            localPath: file.path,
            fileName: fileName,
            fileSize: await file.length(),
            mimeType: 'application/json')
      ];
      await runner.database.persistMessage(message);
    }
  }
}
