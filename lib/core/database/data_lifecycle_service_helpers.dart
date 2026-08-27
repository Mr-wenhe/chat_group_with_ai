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
  }) async {
    final messageKeys = await _runner.matchingKeys<Message>(
      db.messageBox,
      (message) => message.id == messageId && message.groupId == groupId,
    );
    final replyReferences = await _runner.matchingKeys<Message>(
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
          (message) =>
              message.media?.map((attachment) => attachment.localPath) ??
              const <String>[],
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
