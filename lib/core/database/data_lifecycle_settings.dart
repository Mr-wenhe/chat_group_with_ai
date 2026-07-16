import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/features/direct_chat/direct_chat_session.dart';

class DataLifecycleSettings {
  static const pendingOperationKey = 'data_lifecycle_pending_operation';
  static const deletedCharacterSnapshotsKey = 'deleted_character_snapshots';

  static const _messageIndexKey = 'message_ids_by_group';
  static const _directReadKey = 'direct_chat_read_at';
  static const _directSourceKey = 'direct_chat_source';
  static const _directProactiveKey = 'direct_chat_last_proactive_at';
  static const _groupReadKey = 'group_chat_read_at';
  static const _groupProactiveKey = 'group_chat_last_proactive_at';
  static const _pinnedCharacterKey = 'pinned_character_ids';
  static const _pinnedGroupKey = 'pinned_group_ids';
  static const _tokenUsageKey = 'token_usage';
  static const _workModePrefix = 'work_mode_enabled:';
  static const _checkpointPrefix = 'context_compressed_through:';

  final DatabaseService db;

  const DataLifecycleSettings(this.db);

  int conversationSettingCount(String id, {required bool isGroup}) {
    var count = 0;
    for (final key in [
      _messageIndexKey,
      isGroup ? _groupReadKey : _directReadKey,
      isGroup ? _groupProactiveKey : _directSourceKey,
    ]) {
      final raw = db.appSettingsBox.get(key);
      if (raw is Map && raw.containsKey(id)) count++;
    }
    final pins =
        db.appSettingsBox.get(isGroup ? _pinnedGroupKey : _pinnedCharacterKey);
    if (pins is List && pins.contains(id)) count++;
    if (db.appSettingsBox.containsKey('$_workModePrefix$id')) count++;
    count += db.appSettingsBox.keys
        .whereType<String>()
        .where((key) => key.startsWith('$_checkpointPrefix$id:'))
        .length;
    return count;
  }

  Future<void> removeConversation(
    String conversationId, {
    required bool isGroup,
  }) async {
    await _removeMapEntry(_messageIndexKey, conversationId);
    await _removeMapEntry(
      isGroup ? _groupReadKey : _directReadKey,
      conversationId,
    );
    await _removeMapEntry(
      isGroup ? _groupProactiveKey : _directSourceKey,
      conversationId,
    );
    await _removeListValue(
      isGroup ? _pinnedGroupKey : _pinnedCharacterKey,
      isGroup
          ? conversationId
          : DirectChatSession.characterIdFrom(conversationId) ?? conversationId,
    );
    await db.appSettingsBox.delete('$_workModePrefix$conversationId');
    await _deleteKeysWithPrefix('$_checkpointPrefix$conversationId:');
    await _removeTokenUsage(
      isGroup ? 'byGroup' : 'byCharacter',
      conversationId,
    );
    db.resetLifecycleCaches();
  }

  Future<void> removeCharacter(
    String characterId,
    String conversationId, {
    required bool removeConversation,
  }) async {
    await _removeListValue(_pinnedCharacterKey, characterId);
    await _removeMapEntry(_directProactiveKey, characterId);
    await _removeTokenUsage('byCharacter', characterId);
    await db.appSettingsBox.delete('$_workModePrefix$conversationId');
    await _deleteKeysWithPrefix('$_checkpointPrefix$conversationId:');
    if (removeConversation) {
      await this.removeConversation(conversationId, isGroup: false);
    }
    db.resetLifecycleCaches();
  }

  Future<void> clearConversationSettings() async {
    const keys = [
      _messageIndexKey,
      _directReadKey,
      _directSourceKey,
      _directProactiveKey,
      _groupReadKey,
      _groupProactiveKey,
      _tokenUsageKey,
      deletedCharacterSnapshotsKey,
    ];
    await db.appSettingsBox.deleteAll(keys);
    await _deleteKeysWithPrefix(_workModePrefix);
    await _deleteKeysWithPrefix(_checkpointPrefix);
  }

  Future<void> clearExceptPreferences() async {
    const preferences = {
      'theme_mode',
      DatabaseService.appSkinModeKey,
      'tts_enabled',
      'ai_processing_dir',
      pendingOperationKey,
    };
    await db.appSettingsBox.deleteAll(
      db.appSettingsBox.keys
          .where((key) => !preferences.contains(key))
          .toList(),
    );
  }

  Future<void> clearExceptPendingOperation() => db.appSettingsBox.deleteAll(
        db.appSettingsBox.keys
            .where((key) => key != pendingOperationKey)
            .toList(),
      );

  Future<void> saveDeletedCharacter(AICharacter character) async {
    final snapshots = _snapshots();
    snapshots[character.id] = {
      'name': character.name,
      'avatar': character.avatar,
      'age': character.age,
      'role': character.role,
    };
    await db.appSettingsBox.put(deletedCharacterSnapshotsKey, snapshots);
  }

  Future<void> removeDeletedCharacter(String characterId) async {
    final snapshots = _snapshots();
    if (snapshots.remove(characterId) == null) return;
    await db.appSettingsBox.put(deletedCharacterSnapshotsKey, snapshots);
  }

  List<AICharacter> deletedCharacters() => _snapshots()
      .entries
      .where((entry) => !db.aiCharacterBox.containsKey(entry.key))
      .map((entry) => _characterFromSnapshot(entry.key, entry.value))
      .whereType<AICharacter>()
      .toList(growable: false);

  AICharacter? deletedCharacter(String characterId) {
    final raw = _snapshots()[characterId];
    return raw == null ? null : _characterFromSnapshot(characterId, raw);
  }

  Future<void> _removeMapEntry(String key, String entryKey) async {
    final raw = db.appSettingsBox.get(key);
    if (raw is! Map || !raw.containsKey(entryKey)) return;
    final map = Map<String, dynamic>.from(raw)..remove(entryKey);
    await db.appSettingsBox.put(key, map);
  }

  Future<void> _removeListValue(String key, String value) async {
    final raw = db.appSettingsBox.get(key);
    if (raw is! List || !raw.contains(value)) return;
    await db.appSettingsBox.put(
      key,
      raw.where((item) => item != value).toList(growable: false),
    );
  }

  Future<void> _removeTokenUsage(String dimension, String id) async {
    final raw = db.appSettingsBox.get(_tokenUsageKey);
    if (raw is! Map) return;
    final usage = Map<String, dynamic>.from(raw);
    final dimensionValue = usage[dimension];
    if (dimensionValue is! Map || !dimensionValue.containsKey(id)) return;
    usage[dimension] = Map<String, dynamic>.from(dimensionValue)..remove(id);
    await db.appSettingsBox.put(_tokenUsageKey, usage);
  }

  Future<void> _deleteKeysWithPrefix(String prefix) =>
      db.appSettingsBox.deleteAll(
        db.appSettingsBox.keys
            .whereType<String>()
            .where((key) => key.startsWith(prefix))
            .toList(),
      );

  Map<String, dynamic> _snapshots() {
    final raw = db.appSettingsBox.get(deletedCharacterSnapshotsKey);
    return raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
  }

  AICharacter? _characterFromSnapshot(String id, dynamic raw) {
    if (raw is! Map) return null;
    return AICharacter(
      id: id,
      name: raw['name']?.toString() ?? '已删除角色',
      avatar: raw['avatar']?.toString() ?? '?',
      age: raw['age'] is int ? raw['age'] as int : 0,
      role: raw['role']?.toString() ?? '已删除角色',
      personalityTags: const [],
      systemPrompt: '',
      apiKey: '',
      apiProvider: '',
      apiConfigId: '',
      isActive: false,
      agenticEnabled: false,
    );
  }
}
