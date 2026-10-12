part of 'data_lifecycle_service.dart';

extension _DataLifecycleServiceHelpers on DataLifecycleService {
  Future<void> _clearReplyReferences(Iterable<dynamic> messageKeys) async {
    for (final key in messageKeys) {
      final message = db.messageBox.get(key);
      if (message != null && message.replyToMessageId != null) {
        message.replyToMessageId = null;
        await db.messageBox.put(message.id, message);
      }
    }
  }

  Future<void> _deleteTargetKeys<T>(
    String failure,
    Box<T> box,
    List<dynamic> keys,
    List<String> incomplete,
  ) =>
      _runner.deleteKeys(failure, box, keys, incomplete);

  Future<void> _rebuildRelationships(
    Iterable<String> relationshipIds,
    List<String> incomplete,
  ) async {
    if (relationshipIds.isEmpty) return;
    await _runner.attempt(
      '关系快照重建失败',
      incomplete,
      () => _relationshipRebuilder.rebuildFor(relationshipIds),
    );
  }

  Future<void> _cleanupRelationshipPins(
    Iterable<String> relationshipIds,
    List<String> incomplete,
  ) async {
    await _runner.attempt('关系 pin 清理失败', incomplete, () async {
      for (final relationshipId in relationshipIds) {
        final stillExists = db.relationshipStateBox.values.any((state) {
          final stableId = RelationshipState.stableGlobalId(
            state.sourceCharacterId,
            state.targetType,
            state.targetId,
          );
          return stableId == relationshipId;
        });
        if (!stillExists) {
          await _settings.removeRelationshipPin(relationshipId);
        }
      }
    });
  }

  Future<DeletionTargets> _planMessage(
    String messageId,
    String groupId, {
    bool invalidateGroupMemory = true,
    bool keepReplyReferences = false,
  }) async {
    final messageKeys = await _runner.matchingKeys<Message>(
      db.messageBox,
      (message) => message.id == messageId && message.groupId == groupId,
    );
    // 保留引用时不碰引用方：它的 replyToMessageId 会悬空，渲染层据此显示
    // 「原消息已删除」，比把引用整条抹掉更能说明这里曾经有内容。
    final replyReferences = keepReplyReferences
        ? const <dynamic>[]
        : await _runner.matchingKeys<Message>(
            db.messageBox,
            (message) => message.replyToMessageId == messageId,
          );
    final groupMemories = invalidateGroupMemory
        ? await _runner.matchingKeys<GroupMemory>(
            db.groupMemoryBox,
            (memory) => memory.groupId == groupId,
          )
        : const <dynamic>[];
    final mediaPaths = db.messageBox.values
        .where(
            (message) => message.id == messageId && message.groupId == groupId)
        .expand(
          (message) => message.managedMediaPaths,
        )
        .toList(growable: false);
    return DeletionTargets(
      boxKeys: {
        DeletionTargetNames.messages: messageKeys,
        DeletionTargetNames.replyReferences: replyReferences,
        if (groupMemories.isNotEmpty)
          DeletionTargetNames.groupMemories: groupMemories,
      },
      mediaPaths: mediaPaths,
      appSettings: _settings.planMessageRetryRecords([messageId]),
    );
  }

  /// 把只指向消息的设置清理应用到盘上。
  ///
  /// 单条与批量删除共用：两处各写一遍时，新加的清理项只会落在其中一边。
  Future<void> _applyMessageSettings(
    DeletionTargets targets,
    List<String> incomplete,
  ) async {
    if (targets.appSettings.isEmpty) return;
    await _runner.attempt(
      '消息重试记录清理失败',
      incomplete,
      () => _settings.applyAppSettingsTargets(targets.appSettings),
    );
  }

  /// 批量计划：只认属于 [groupId] 且确实存在的 id。
  ///
  /// 引用指针一律保留（与单条删除同一承诺），所以计划里根本不出现
  /// replyReferences —— 被引用方会显示「原消息已删除」，而不是凭空少一截引用条。
  Future<DeletionTargets> _planMessages(
    Iterable<String> messageIds,
    String groupId,
  ) async {
    final requested = messageIds.toSet();
    return _targetsForMessages(
      db.messageBox.values
          .where((message) =>
              message.groupId == groupId && requested.contains(message.id))
          .toList(growable: false),
    );
  }

  /// 一个会话的全部消息，外加只指向消息的那部分设置。
  Future<DeletionTargets> _planConversationMessages(
    String conversationId,
  ) async {
    // 按会话的重试记录计划是消息粒度版本的超集（它还覆盖已经不在 box 里的消息），
    // 所以这里不要那份按消息算出来的：它会被整份丢掉，纯属多扫一遍队列。
    final targets = _targetsForMessages(
      db.messageBox.values
          .where((message) => message.groupId == conversationId)
          .toList(growable: false),
      includeRetryRecords: false,
    );
    return DeletionTargets(
      boxKeys: targets.boxKeys,
      mediaPaths: targets.mediaPaths,
      appSettings: _settings.planConversationMessages(
        conversationId,
        isGroup: !DirectChatSession.isDirectConversationId(conversationId),
      ),
    );
  }

  DeletionTargets _targetsForMessages(
    List<Message> messages, {
    bool includeRetryRecords = true,
  }) {
    if (messages.isEmpty) return const DeletionTargets();
    return DeletionTargets(
      boxKeys: {
        DeletionTargetNames.messages:
            messages.map((message) => message.id).toList(growable: false),
      },
      mediaPaths: messages
          .expand((message) => message.managedMediaPaths)
          .toList(growable: false),
      appSettings: includeRetryRecords
          ? _settings.planMessageRetryRecords(
              messages.map((message) => message.id),
            )
          : const AppSettingsDeletionTargets(),
    );
  }

  Future<DeletionTargets> _targetsForRetry(Map<String, dynamic> job) async {
    if (job.containsKey('targets')) {
      return DeletionTargets.fromMap(job['targets']);
    }
    final id = job['id']?.toString() ?? '';
    switch (job['kind']) {
      case 'message':
        return _planMessage(id, job['groupId']?.toString() ?? '');
      case 'group':
        return (await _planner.previewGroup(
          id,
          deleteAssociatedPermanentData:
              job['deleteAssociatedPermanentData'] == true,
        ))
            .targets;
      case 'conversation':
        return (await _planner.previewConversation(
          id,
          deleteAssociatedPermanentData:
              job['deleteAssociatedPermanentData'] == true,
        ))
            .targets;
      case 'character':
        final policy = CharacterDeletionPolicy.values.firstWhere(
          (value) => value.name == job['policy'],
          orElse: () => CharacterDeletionPolicy.keepMessageHistory,
        );
        return (await _planner.previewCharacter(id, policy: policy)).targets;
      case 'apiConfig':
        return (await _planner.previewApiConfig(id)).targets;
      case 'clear':
        final scope = DataClearScope.values.firstWhere(
          (value) => value.name == job['scope'],
          orElse: () => DataClearScope.userContent,
        );
        return (await _planner.previewClear(scope)).targets;
      default:
        return const DeletionTargets();
    }
  }

  void _applyApiConfig(AICharacter character, ApiConfig? replacement) {
    character.apiConfigId = replacement?.id ?? '';
    character.apiKey = '';
    character.apiProvider = replacement?.provider ?? '';
    character.modelName = replacement?.modelName ?? '';
    character.customBaseUrl = replacement?.customBaseUrl ?? '';
  }

  Future<bool> _begin(Map<String, dynamic> operation) async {
    if (hasPendingOperation) return false;
    await db.appSettingsBox
        .put(DataLifecycleService.pendingOperationKey, operation);
    return true;
  }

  DataLifecycleResult _pendingOperationConflict() =>
      const DataLifecycleResult(incompleteItems: ['请先在设置中重试未完成删除']);

  Future<DataLifecycleResult> _finish(
    List<String> incomplete, [
    DataLifecycleResult media = const DataLifecycleResult(),
  ]) async {
    incomplete.addAll(media.incompleteItems);
    if (incomplete.isEmpty) {
      try {
        await db.appSettingsBox
            .delete(DataLifecycleService.pendingOperationKey);
      } on Object {
        incomplete.add('删除完成状态保存失败');
      }
    }
    return DataLifecycleResult(
      incompleteItems: incomplete,
      reclaimedFiles: media.reclaimedFiles,
      reclaimedBytes: media.reclaimedBytes,
    );
  }
}
