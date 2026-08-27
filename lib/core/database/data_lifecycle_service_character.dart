part of 'data_lifecycle_service.dart';

extension _DataLifecycleServiceCharacter on DataLifecycleService {
  Future<DataLifecycleResult> _runCharacterDeletion(
    String characterId,
    CharacterDeletionPolicy policy, {
    required DeletionTargets targets,
  }) async {
    final incomplete = <String>[];
    final character = db.aiCharacterBox.get(characterId);
    if (character != null &&
        policy == CharacterDeletionPolicy.keepMessageHistory) {
      final saved = await _runner.attempt(
        '历史身份快照保存失败',
        incomplete,
        () => _settings.saveDeletedCharacter(character),
      );
      if (!saved) return _finish(incomplete);
    }
    final conversationId = DirectChatSession.conversationIdFor(characterId);
    final deleteMessages = policy == CharacterDeletionPolicy.deleteRelatedData;
    final deletedMessageKeys = deleteMessages
        ? targets.keysFor(DeletionTargetNames.messages)
        : const <dynamic>[];

    await _runner.attempt('群成员引用清理失败', incomplete, () async {
      for (final key in targets.keysFor(DeletionTargetNames.chatGroups)) {
        final group = db.chatGroupBox.get(key);
        if (group == null) continue;
        if (group.aiCharacterIds.contains(characterId)) {
          group.aiCharacterIds = group.aiCharacterIds
              .where((id) => id != characterId)
              .toList(growable: false);
          await db.chatGroupBox.put(group.id, group);
        }
      }
    });
    await _runner.attempt('消息提及引用清理失败', incomplete, () async {
      for (final key
          in targets.keysFor(DeletionTargetNames.mentionReferences)) {
        final message = db.messageBox.get(key);
        if (message == null) continue;
        if (message.mentionedAiIds.contains(characterId)) {
          message.mentionedAiIds = message.mentionedAiIds
              .where((id) => id != characterId)
              .toList(growable: false);
          await db.messageBox.put(message.id, message);
        }
      }
    });
    await _deleteTargetKeys(
      '角色记忆删除失败',
      db.characterMemoryBox,
      targets.keysFor(DeletionTargetNames.characterMemories),
      incomplete,
    );
    await _deleteTargetKeys(
      '角色关系删除失败',
      db.relationshipStateBox,
      targets.keysFor(DeletionTargetNames.relationshipStates),
      incomplete,
    );
    await _deleteTargetKeys(
      '角色关系事件删除失败',
      db.relationshipEventBox,
      targets.keysFor(DeletionTargetNames.relationshipEvents),
      incomplete,
    );
    await _deleteTargetKeys(
      '角色永久记忆删除失败',
      db.permanentMemoryBox,
      targets.keysFor(DeletionTargetNames.permanentMemories),
      incomplete,
    );
    await _deleteTargetKeys(
      '角色技能删除失败',
      db.characterSkillBox,
      targets.keysFor(DeletionTargetNames.characterSkills),
      incomplete,
    );
    await _deleteTargetKeys(
      '角色任务删除失败',
      db.agentTaskBox,
      targets.keysFor(DeletionTargetNames.agentTasks),
      incomplete,
    );
    await _deleteTargetKeys(
      '私聊工作区记录删除失败',
      db.workModeWorkspaceBox,
      targets.keysFor(DeletionTargetNames.workspaces),
      incomplete,
    );
    if (deleteMessages) {
      await _runner.deleteKeys(
        '私聊消息删除失败',
        db.messageBox,
        deletedMessageKeys,
        incomplete,
      );
      await _runner.attempt('私聊回复引用清理失败', incomplete, () {
        return _clearReplyReferences(
          targets.keysFor(DeletionTargetNames.replyReferences),
        );
      });
    }
    await _rebuildRelationships(targets.relationshipIds, incomplete);
    await _cleanupRelationshipPins(targets.relationshipIds, incomplete);
    await _runner.attempt('角色设置清理失败', incomplete, () async {
      await _settings.removeCharacter(
        characterId,
        conversationId,
        removeConversation: deleteMessages,
        targets: targets.appSettings,
      );
      if (deleteMessages) await _settings.removeDeletedCharacter(characterId);
    });
    await _runner.attempt(
      '角色删除失败',
      incomplete,
      () async {
        if (targets.keysFor(DeletionTargetNames.aiCharacters).isNotEmpty) {
          await db.aiCharacterBox.delete(characterId);
        }
      },
    );
    return _finish(incomplete, await cleanupOrphanMedia());
  }

  Future<DataLifecycleResult> _runApiConfigDeletion(
    String configId,
    String? replacementConfigId, {
    required DeletionTargets targets,
  }) async {
    final incomplete = <String>[];
    final credentialDeleted = await _runner.attempt(
      'API 凭据删除失败',
      incomplete,
      () => _deleteSecureCredential(configId),
    );
    if (!credentialDeleted) return _finish(incomplete);
    final replacement = replacementConfigId == null
        ? null
        : db.apiConfigBox.get(replacementConfigId);
    await _runner.attempt('角色配置解绑失败', incomplete, () async {
      for (final key in targets.keysFor(DeletionTargetNames.aiCharacters)) {
        final character = db.aiCharacterBox.get(key);
        if (character == null) continue;
        if (character.apiConfigId == configId) {
          _applyApiConfig(character, replacement);
          await db.aiCharacterBox.put(character.id, character);
        }
      }
    });
    await _runner.attempt(
      'API 配置删除失败',
      incomplete,
      () async {
        if (targets.keysFor(DeletionTargetNames.apiConfigs).isNotEmpty) {
          await db.apiConfigBox.delete(configId);
        }
      },
    );
    return _finish(incomplete);
  }
}
