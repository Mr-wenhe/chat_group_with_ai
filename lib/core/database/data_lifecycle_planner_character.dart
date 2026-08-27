part of 'data_lifecycle_planner.dart';

extension DataLifecyclePlannerCharacter on DataLifecyclePlanner {
  Future<DeletionPlan> previewCharacter(
    String characterId, {
    CharacterDeletionPolicy policy = CharacterDeletionPolicy.keepMessageHistory,
  }) async {
    final conversationId = DirectChatSession.conversationIdFor(characterId);
    final directMessages = await _keys<Message>(
      db.messageBox,
      (message) => message.groupId == conversationId,
    );
    final directIds = directMessages.whereType<String>().toSet();
    final mentionReferences = await _keys<Message>(
      db.messageBox,
      (message) => message.mentionedAiIds.contains(characterId),
    );
    final replyReferences = await _keys<Message>(
      db.messageBox,
      (message) =>
          message.replyToMessageId != null &&
          directIds.contains(message.replyToMessageId),
    );
    final groups = await _keys(
      db.chatGroupBox,
      (group) => group.aiCharacterIds.contains(characterId),
    );
    final skills = await _keys(
      db.characterSkillBox,
      (skill) => skill.characterId == characterId,
    );
    final tasks = await _keys(
      db.agentTaskBox,
      (task) => task.characterId == characterId,
    );
    final characterMemories = await _keys(
      db.characterMemoryBox,
      (memory) => memory.characterId == characterId,
    );
    final observerPermanentMemoryKeys = await _keys(
      db.permanentMemoryBox,
      (memory) => memory.observerCharacterId == characterId,
    );
    final subjectPermanentMemoryKeys = await _keys(
      db.permanentMemoryBox,
      (memory) => memory.subjectIds.contains(characterId),
    );
    final permanentMemories = await _keys(
      db.permanentMemoryBox,
      (memory) => policy == CharacterDeletionPolicy.deleteRelatedData
          ? memory.observerCharacterId == characterId ||
              memory.subjectIds.contains(characterId)
          : memory.observerCharacterId == characterId,
    );
    final relationshipStates = await _keys(
      db.relationshipStateBox,
      (relation) => _relationReferencesCharacter(relation, characterId,
          includeTarget: policy == CharacterDeletionPolicy.deleteRelatedData),
    );
    final sourceRelationshipStateKeys = await _keys(
      db.relationshipStateBox,
      (relation) => relation.sourceCharacterId == characterId,
    );
    final targetRelationshipStateKeys = await _keys(
      db.relationshipStateBox,
      (relation) =>
          relation.targetType == RelationshipTargetType.ai &&
          relation.targetId == characterId,
    );
    final relationshipEvents = await _keys(
      db.relationshipEventBox,
      (event) => _eventReferencesCharacter(event, characterId,
          includeTarget: policy == CharacterDeletionPolicy.deleteRelatedData),
    );
    final sourceRelationshipEventKeys = await _keys(
      db.relationshipEventBox,
      (event) => event.sourceCharacterId == characterId,
    );
    final targetRelationshipEventKeys = await _keys(
      db.relationshipEventBox,
      (event) =>
          event.targetType == RelationshipTargetType.ai &&
          event.targetId == characterId,
    );
    final eventValues = relationshipEvents
        .map(db.relationshipEventBox.get)
        .whereType<RelationshipEvent>()
        .toList(growable: false);
    final relationIds = <String>{
      ...relationshipStates
          .map(db.relationshipStateBox.get)
          .whereType<RelationshipState>()
          .map(RelationshipSnapshotRebuilderId.fromState),
      ...eventValues.map(RelationshipSnapshotRebuilderId.fromEvent),
    }..removeWhere((id) => id.isEmpty);
    final workspaceKeys = await _keys(
      db.workModeWorkspaceBox,
      (workspace) => workspace.conversationId == conversationId,
    );
    final usage = await media.usage(
      excludedMessageIds: policy == CharacterDeletionPolicy.deleteRelatedData
          ? directIds
          : const {},
    );
    final directSettings = settings.conversationSettingCount(
      conversationId,
      isGroup: false,
    );
    final sessionIndexCount = settings.conversationSessionIndexCount(
      conversationId,
      isGroup: false,
    );
    final rolePins = _countRelationshipPins(relationIds, characterId);
    final memoryPinCount = settings.characterMemoryPinCount(
      characterId,
      characterMemoryKeys: characterMemories,
      relationshipIds: relationIds,
    );
    final retryRecordCount =
        settings.characterRetryRecordCount(characterId, conversationId);
    final fullDelete = policy == CharacterDeletionPolicy.deleteRelatedData;
    final targets = DeletionTargets(
      boxKeys: {
        DeletionTargetNames.aiCharacters:
            db.aiCharacterBox.containsKey(characterId)
                ? [characterId]
                : const <dynamic>[],
        DeletionTargetNames.chatGroups: groups,
        DeletionTargetNames.messages: directMessages,
        DeletionTargetNames.characterMemories: characterMemories,
        DeletionTargetNames.characterSkills: skills,
        DeletionTargetNames.agentTasks: tasks,
        DeletionTargetNames.workspaces: workspaceKeys,
        DeletionTargetNames.permanentMemories: permanentMemories,
        DeletionTargetNames.relationshipStates: relationshipStates,
        DeletionTargetNames.relationshipEvents: relationshipEvents,
        DeletionTargetNames.mentionReferences: mentionReferences,
        DeletionTargetNames.replyReferences: replyReferences,
      },
      relationshipIds: relationIds.toList()..sort(),
      appSettings: settings.planCharacter(
        characterId,
        conversationId,
        removeConversation: fullDelete,
        characterMemoryKeys: characterMemories,
      ),
    );
    final counts = <String, int>{
      'characters': db.aiCharacterBox.containsKey(characterId) ? 1 : 0,
      'groups': groups.length,
      'directMessages': fullDelete ? directMessages.length : 0,
      'skills': skills.length,
      'tasks': tasks.length,
      'characterMemories': characterMemories.length,
      'memories': permanentMemories.length,
      'observerPermanentMemories': observerPermanentMemoryKeys.length,
      'subjectPermanentMemories': subjectPermanentMemoryKeys.length,
      'relationships': relationshipStates.length,
      'relationshipStates': relationshipStates.length,
      'relationshipEvents': relationshipEvents.length,
      'sourceRelationshipStates': sourceRelationshipStateKeys.length,
      'targetRelationshipStates': targetRelationshipStateKeys.length,
      'sourceRelationshipEvents': sourceRelationshipEventKeys.length,
      'targetRelationshipEvents': targetRelationshipEventKeys.length,
      'workspaces': workspaceKeys.length,
      'settings': fullDelete ? directSettings : 0,
      'sessionIndexes': fullDelete ? sessionIndexCount : 0,
      'memoryPins': memoryPinCount,
      'retryRecords': retryRecordCount,
      'pins': rolePins,
      'mentions': mentionReferences.length,
      'attachments': fullDelete ? usage.orphanFiles : 0,
    };
    final optionalCounts = fullDelete
        ? const <String, int>{}
        : {
            'directMessages': directMessages.length,
            'settings': directSettings,
            'attachments': usage.orphanFiles,
          };
    return DeletionPlan(
      title: '删除角色',
      counts: counts,
      optionalCounts: optionalCounts,
      retainedCounts: {
        'directMessages': fullDelete ? 0 : directMessages.length,
        'permanentMemories':
            db.permanentMemoryBox.length - permanentMemories.length,
        'relationshipEvents':
            db.relationshipEventBox.length - relationshipEvents.length,
        'groupMessages': db.messageBox.values
            .where((message) => message.groupId != conversationId)
            .length,
      },
      targets: targets,
    );
  }
}
