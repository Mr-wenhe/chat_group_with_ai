import 'package:hive/hive.dart';

import 'package:chat_group/core/database/data_lifecycle_models.dart';
import 'package:chat_group/core/database/data_lifecycle_settings.dart';
import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/database/hive_deletion_runner.dart';
import 'package:chat_group/core/database/managed_media_store.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/relationship_event.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/features/direct_chat/direct_chat_session.dart';

/// Resolves destructive targets before any write begins.
///
/// The plan is also used as the persisted pending-operation target set. This
/// keeps retries bounded to the original operation even if new records appear
/// while a partial delete is waiting for user retry.
part 'data_lifecycle_planner_character.dart';
part 'data_lifecycle_planner_clear.dart';

class DataLifecyclePlanner {
  final DatabaseService db;
  final DataLifecycleSettings settings;
  final ManagedMediaStore media;
  final HiveDeletionRunner runner;

  const DataLifecyclePlanner({
    required this.db,
    required this.settings,
    required this.media,
    required this.runner,
  });

  Future<DeletionPlan> previewGroup(
    String groupId, {
    bool deleteAssociatedPermanentData = false,
  }) async {
    final messages = await _keys<Message>(
      db.messageBox,
      (message) => message.groupId == groupId,
    );
    final messageIds = messages.whereType<String>().toSet();
    final groupMemories = await _keys(
      db.groupMemoryBox,
      (item) => item.groupId == groupId,
    );
    final characterMemories = await _keys(
      db.characterMemoryBox,
      (item) => item.groupId == groupId,
    );
    final legacyRelationships = await _keys(
      db.relationshipStateBox,
      (item) => item.groupId == groupId,
    );
    final tasks = await _keys(
      db.agentTaskBox,
      (item) => item.groupId == groupId,
    );
    final workspaces = await _keys(
      db.workModeWorkspaceBox,
      (item) => item.conversationId == groupId,
    );
    final permanentMemories = await _keys(
      db.permanentMemoryBox,
      (item) => item.originConversationId == groupId,
    );
    final relationshipEvents = await _keys(
      db.relationshipEventBox,
      (item) => item.originConversationId == groupId,
    );
    final eventValues = relationshipEvents
        .map(db.relationshipEventBox.get)
        .whereType<RelationshipEvent>()
        .toList(growable: false);
    final replyReferences = await _keys<Message>(
      db.messageBox,
      (message) =>
          message.replyToMessageId != null &&
          messageIds.contains(message.replyToMessageId),
    );
    final usage = await media.usage(excludedMessageIds: messageIds);
    final legacyCount = legacyRelationships.length;
    final sessionIndexCount = settings.conversationSessionIndexCount(
      groupId,
      isGroup: true,
    );
    final memoryPinCount = settings.conversationMemoryPinCount(
      groupId,
      isGroup: true,
      characterMemoryKeys: characterMemories,
    );
    final retryRecordCount = settings.conversationRetryRecordCount(groupId);
    final targets = DeletionTargets(
      boxKeys: {
        DeletionTargetNames.chatGroups: db.chatGroupBox.containsKey(groupId)
            ? [groupId]
            : const <dynamic>[],
        DeletionTargetNames.messages: messages,
        DeletionTargetNames.groupMemories: groupMemories,
        DeletionTargetNames.characterMemories: characterMemories,
        DeletionTargetNames.relationshipStates: legacyRelationships,
        DeletionTargetNames.agentTasks: tasks,
        DeletionTargetNames.workspaces: workspaces,
        DeletionTargetNames.permanentMemories: permanentMemories,
        DeletionTargetNames.relationshipEvents: relationshipEvents,
        DeletionTargetNames.replyReferences: replyReferences,
      },
      relationshipIds: eventValues
          .map(RelationshipSnapshotRebuilderId.fromEvent)
          .toSet()
          .toList()
        ..sort(),
      appSettings: settings.planConversation(
        groupId,
        isGroup: true,
        characterMemoryKeys: characterMemories,
      ),
    );
    return DeletionPlan(
      title: '删除群聊',
      counts: {
        'groups': db.chatGroupBox.containsKey(groupId) ? 1 : 0,
        'messages': messages.length,
        'groupMemories': groupMemories.length,
        'characterMemories': characterMemories.length,
        'legacyRelationshipStates': legacyCount,
        'relationshipStates': legacyCount,
        'relationships': legacyCount,
        'tasks': tasks.length,
        'workspaces': workspaces.length,
        'settings': settings.conversationSettingCount(groupId, isGroup: true),
        'sessionIndexes': sessionIndexCount,
        'memoryPins': memoryPinCount,
        'retryRecords': retryRecordCount,
        'attachments': usage.orphanFiles,
        if (deleteAssociatedPermanentData) ...{
          'permanentMemories': permanentMemories.length,
          'relationshipEvents': relationshipEvents.length,
        },
      },
      optionalCounts: deleteAssociatedPermanentData
          ? const {}
          : {
              'permanentMemories': permanentMemories.length,
              'relationshipEvents': relationshipEvents.length,
            },
      retainedCounts: {
        'permanentMemories': db.permanentMemoryBox.length -
            (deleteAssociatedPermanentData ? permanentMemories.length : 0),
        'relationshipEvents': db.relationshipEventBox.length -
            (deleteAssociatedPermanentData ? relationshipEvents.length : 0),
        'globalRelationshipStates': db.relationshipStateBox.values
            .where((state) => state.groupId == 'global')
            .length,
      },
      targets: targets,
    );
  }

  Future<DeletionPlan> previewConversation(
    String conversationId, {
    bool deleteAssociatedPermanentData = false,
  }) async {
    final isGroup = !DirectChatSession.isDirectConversationId(conversationId);
    final messages = await _keys<Message>(
      db.messageBox,
      (message) => message.groupId == conversationId,
    );
    final messageIds = messages.whereType<String>().toSet();
    final groupMemories = await _keys(
      db.groupMemoryBox,
      (item) => item.groupId == conversationId,
    );
    final characterMemories = await _keys(
      db.characterMemoryBox,
      (item) => item.groupId == conversationId,
    );
    final legacyRelationships = await _keys(
      db.relationshipStateBox,
      (item) => item.groupId == conversationId,
    );
    final tasks = await _keys(
      db.agentTaskBox,
      (item) => item.groupId == conversationId,
    );
    final workspaces = await _keys(
      db.workModeWorkspaceBox,
      (item) => item.conversationId == conversationId,
    );
    final permanentMemories = await _keys(
      db.permanentMemoryBox,
      (item) => item.originConversationId == conversationId,
    );
    final relationshipEvents = await _keys(
      db.relationshipEventBox,
      (item) => item.originConversationId == conversationId,
    );
    final eventValues = relationshipEvents
        .map(db.relationshipEventBox.get)
        .whereType<RelationshipEvent>()
        .toList(growable: false);
    final replyReferences = await _keys<Message>(
      db.messageBox,
      (message) =>
          message.replyToMessageId != null &&
          messageIds.contains(message.replyToMessageId),
    );
    final usage = await media.usage(excludedMessageIds: messageIds.toSet());
    final legacyCount = legacyRelationships.length;
    final sessionIndexCount = settings.conversationSessionIndexCount(
      conversationId,
      isGroup: isGroup,
    );
    final memoryPinCount = settings.conversationMemoryPinCount(
      conversationId,
      isGroup: isGroup,
      characterMemoryKeys: characterMemories,
    );
    final retryRecordCount =
        settings.conversationRetryRecordCount(conversationId);
    final targets = DeletionTargets(
      boxKeys: {
        DeletionTargetNames.messages: messages,
        DeletionTargetNames.groupMemories: groupMemories,
        DeletionTargetNames.characterMemories: characterMemories,
        DeletionTargetNames.relationshipStates: legacyRelationships,
        DeletionTargetNames.agentTasks: tasks,
        DeletionTargetNames.workspaces: workspaces,
        DeletionTargetNames.permanentMemories: permanentMemories,
        DeletionTargetNames.relationshipEvents: relationshipEvents,
        DeletionTargetNames.replyReferences: replyReferences,
      },
      relationshipIds: eventValues
          .map(RelationshipSnapshotRebuilderId.fromEvent)
          .toSet()
          .toList()
        ..sort(),
      appSettings: settings.planConversation(
        conversationId,
        isGroup: isGroup,
        characterMemoryKeys: characterMemories,
      ),
    );
    final defaultCounts = <String, int>{
      'groups': isGroup && db.chatGroupBox.containsKey(conversationId) ? 1 : 0,
      'messages': messages.length,
      'groupMemories': groupMemories.length,
      'characterMemories': characterMemories.length,
      'legacyRelationshipStates': legacyCount,
      'relationshipStates': legacyCount,
      'relationships': legacyCount,
      'tasks': tasks.length,
      'workspaces': workspaces.length,
      'settings': settings.conversationSettingCount(
        conversationId,
        isGroup: isGroup,
      ),
      'sessionIndexes': sessionIndexCount,
      'memoryPins': memoryPinCount,
      'retryRecords': retryRecordCount,
      'attachments': usage.orphanFiles,
    };
    if (deleteAssociatedPermanentData) {
      defaultCounts['permanentMemories'] = permanentMemories.length;
      defaultCounts['relationshipEvents'] = relationshipEvents.length;
    }
    return DeletionPlan(
      title: isGroup ? '清空群聊' : '清空私聊',
      counts: defaultCounts,
      optionalCounts: deleteAssociatedPermanentData
          ? const {}
          : {
              'permanentMemories': permanentMemories.length,
              'relationshipEvents': relationshipEvents.length,
            },
      retainedCounts: {
        'permanentMemories': db.permanentMemoryBox.length -
            (deleteAssociatedPermanentData ? permanentMemories.length : 0),
        'relationshipEvents': db.relationshipEventBox.length -
            (deleteAssociatedPermanentData ? relationshipEvents.length : 0),
        'globalRelationshipStates': db.relationshipStateBox.values
            .where((state) => state.groupId == 'global')
            .length,
      },
      targets: targets,
    );
  }
}
