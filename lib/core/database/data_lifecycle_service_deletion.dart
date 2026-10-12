part of 'data_lifecycle_service.dart';

extension _DataLifecycleServiceDeletion on DataLifecycleService {
  /// 带任务交付物的消息不能按消息自己的路径清附件：交付物可能仍被任务面板
  /// 引用，所以整批改走孤儿回收（与单条删除同一判据）。
  bool _anyMessageHasDelivery(Iterable<String> messageIds) => messageIds
      .any((id) => db.messageBox.get(id)?.workDelivery != null);

  Future<DataLifecycleResult> _runMessagesDeletion(
    String groupId, {
    required DeletionTargets targets,
  }) async {
    final incomplete = <String>[];
    final ids = targets
        .keysFor(DeletionTargetNames.messages)
        .whereType<String>()
        .toList(growable: false);
    if (ids.isEmpty) return _finish(incomplete);
    // 判据必须在删除前取：删完再看就永远为 false，交付物的附件会被当普通
    // 消息附件清掉。
    final hasDelivery = _anyMessageHasDelivery(ids);
    await _runner.attempt('消息删除失败', incomplete, () async {
      await db.deleteMessageRecordsAndIndex(ids, groupId: groupId);
    });
    await _applyMessageSettings(targets, incomplete);
    return _finish(
      incomplete,
      hasDelivery
          ? await cleanupOrphanMedia()
          : await cleanupMediaPaths(targets.mediaPaths),
    );
  }

  /// 「清空聊天记录」：删消息 + 清指向消息的设置，其余一概不动。
  Future<DataLifecycleResult> _runConversationMessageClear(
    String conversationId, {
    required DeletionTargets targets,
  }) async {
    final incomplete = <String>[];
    final ids = targets
        .keysFor(DeletionTargetNames.messages)
        .whereType<String>()
        .toList(growable: false);
    final hasDelivery = _anyMessageHasDelivery(ids);
    if (ids.isNotEmpty) {
      await _runner.attempt('会话消息删除失败', incomplete, () async {
        await db.deleteMessageRecordsAndIndex(ids, groupId: conversationId);
      });
    }
    await _runner.attempt('会话消息设置清理失败', incomplete, () async {
      await _settings.applyAppSettingsTargets(targets.appSettings);
    });
    return _finish(
      incomplete,
      hasDelivery
          ? await cleanupOrphanMedia()
          : await cleanupMediaPaths(targets.mediaPaths),
    );
  }

  Future<DataLifecycleResult> _runMessageDeletion(
    String messageId,
    String groupId,
    DeletionTargets targets,
  ) async {
    final incomplete = <String>[];
    final hasDelivery = db.messageBox.get(messageId)?.workDelivery != null;
    final mediaPaths = targets.mediaPaths.isNotEmpty
        ? targets.mediaPaths
        : db.messageBox
                .get(messageId)
                ?.managedMediaPaths
                .toList(growable: false) ??
            const <String>[];
    await _runner.attempt('消息删除失败', incomplete, () async {
      if (targets.keysFor(DeletionTargetNames.messages).isNotEmpty) {
        await db.deleteMessageRecordAndIndex(messageId, groupId: groupId);
        await _clearReplyReferences(
          targets.keysFor(DeletionTargetNames.replyReferences),
        );
      }
    });
    await _deleteTargetKeys(
      '群记忆失效失败',
      db.groupMemoryBox,
      targets.keysFor(DeletionTargetNames.groupMemories),
      incomplete,
    );
    await _applyMessageSettings(targets, incomplete);
    return _finish(
        incomplete,
        hasDelivery
            ? await cleanupOrphanMedia()
            : await cleanupMediaPaths(mediaPaths));
  }

  Future<DataLifecycleResult> _runGroupDeletion(
    String groupId, {
    required DeletionTargets targets,
    required bool deleteAssociatedPermanentData,
  }) async {
    final incomplete = <String>[];
    final messageKeys = targets.keysFor(DeletionTargetNames.messages);
    await _deleteTargetKeys(
      '群消息删除失败',
      db.messageBox,
      messageKeys,
      incomplete,
    );
    await _deleteTargetKeys(
      '群记忆删除失败',
      db.groupMemoryBox,
      targets.keysFor(DeletionTargetNames.groupMemories),
      incomplete,
    );
    await _deleteTargetKeys(
      '角色群记忆删除失败',
      db.characterMemoryBox,
      targets.keysFor(DeletionTargetNames.characterMemories),
      incomplete,
    );
    await _deleteTargetKeys(
      '群关系删除失败',
      db.relationshipStateBox,
      targets.keysFor(DeletionTargetNames.relationshipStates),
      incomplete,
    );
    await _deleteTargetKeys(
      '群任务删除失败',
      db.agentTaskBox,
      targets.keysFor(DeletionTargetNames.agentTasks),
      incomplete,
    );
    await _deleteTargetKeys(
      '群工作区记录删除失败',
      db.workModeWorkspaceBox,
      targets.keysFor(DeletionTargetNames.workspaces),
      incomplete,
    );
    if (deleteAssociatedPermanentData) {
      await _deleteTargetKeys(
        '群来源永久记忆删除失败',
        db.permanentMemoryBox,
        targets.keysFor(DeletionTargetNames.permanentMemories),
        incomplete,
      );
      await _deleteTargetKeys(
        '群来源关系事件删除失败',
        db.relationshipEventBox,
        targets.keysFor(DeletionTargetNames.relationshipEvents),
        incomplete,
      );
      await _rebuildRelationships(targets.relationshipIds, incomplete);
    }
    await _runner.attempt('群设置清理失败', incomplete, () async {
      await _settings.removeConversation(
        groupId,
        isGroup: true,
        targets: targets.appSettings,
      );
      await _clearReplyReferences(
        targets.keysFor(DeletionTargetNames.replyReferences),
      );
    });
    await _runner.attempt(
      '群聊删除失败',
      incomplete,
      () async {
        if (targets.keysFor(DeletionTargetNames.chatGroups).isNotEmpty) {
          await db.chatGroupBox.delete(groupId);
        }
      },
    );
    return _finish(incomplete, await cleanupOrphanMedia());
  }

  Future<DataLifecycleResult> _runConversationDeletion(
    String conversationId, {
    required DeletionTargets targets,
    required bool deleteAssociatedPermanentData,
  }) async {
    final incomplete = <String>[];
    await _deleteTargetKeys(
      '会话消息删除失败',
      db.messageBox,
      targets.keysFor(DeletionTargetNames.messages),
      incomplete,
    );
    await _deleteTargetKeys(
      '会话群记忆删除失败',
      db.groupMemoryBox,
      targets.keysFor(DeletionTargetNames.groupMemories),
      incomplete,
    );
    await _deleteTargetKeys(
      '会话角色记忆删除失败',
      db.characterMemoryBox,
      targets.keysFor(DeletionTargetNames.characterMemories),
      incomplete,
    );
    await _deleteTargetKeys(
      '会话关系删除失败',
      db.relationshipStateBox,
      targets.keysFor(DeletionTargetNames.relationshipStates),
      incomplete,
    );
    await _deleteTargetKeys(
      '会话任务删除失败',
      db.agentTaskBox,
      targets.keysFor(DeletionTargetNames.agentTasks),
      incomplete,
    );
    await _deleteTargetKeys(
      '会话工作区记录删除失败',
      db.workModeWorkspaceBox,
      targets.keysFor(DeletionTargetNames.workspaces),
      incomplete,
    );
    if (deleteAssociatedPermanentData) {
      await _deleteTargetKeys(
        '会话来源永久记忆删除失败',
        db.permanentMemoryBox,
        targets.keysFor(DeletionTargetNames.permanentMemories),
        incomplete,
      );
      await _deleteTargetKeys(
        '会话来源关系事件删除失败',
        db.relationshipEventBox,
        targets.keysFor(DeletionTargetNames.relationshipEvents),
        incomplete,
      );
      await _rebuildRelationships(targets.relationshipIds, incomplete);
    }
    await _runner.attempt('会话设置清理失败', incomplete, () async {
      await _settings.removeConversation(
        conversationId,
        isGroup: !DirectChatSession.isDirectConversationId(conversationId),
        targets: targets.appSettings,
      );
      await _clearReplyReferences(
        targets.keysFor(DeletionTargetNames.replyReferences),
      );
    });
    return _finish(incomplete, await cleanupOrphanMedia());
  }
}
