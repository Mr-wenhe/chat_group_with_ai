part of 'backup_exporter.dart';

class _Snapshot {
  final List<MapEntry<Object, dynamic>> apiConfigs;
  final List<MapEntry<Object, dynamic>> characters;
  final List<MapEntry<Object, dynamic>> groups;
  final List<MapEntry<Object, dynamic>> messages;
  final List<MapEntry<Object, dynamic>> groupMemories;
  final List<MapEntry<Object, dynamic>> characterMemories;
  final List<MapEntry<Object, dynamic>> relationships;
  final List<MapEntry<Object, dynamic>> skills;
  final List<MapEntry<Object, dynamic>> tasks;
  final List<MapEntry<Object, dynamic>> workspaces;
  final Map<String, dynamic> settings;

  const _Snapshot({
    required this.apiConfigs,
    required this.characters,
    required this.groups,
    required this.messages,
    required this.groupMemories,
    required this.characterMemories,
    required this.relationships,
    required this.skills,
    required this.tasks,
    required this.workspaces,
    required this.settings,
  });

  factory _Snapshot.capture(DatabaseService db, BackupSelection selection) {
    final conversationId = selection.conversationId;
    final group =
        conversationId == null ? null : db.chatGroupBox.get(conversationId);
    final directCharacterId = conversationId?.startsWith('dm:') == true
        ? conversationId!.substring(3)
        : null;
    if (selection.scope == BackupScope.conversation &&
        group == null &&
        (directCharacterId == null ||
            !db.aiCharacterBox.containsKey(directCharacterId))) {
      throw const BackupException('指定会话不存在');
    }
    final configurationOnly = selection.scope == BackupScope.configurationOnly;
    final characterIds = selection.scope == BackupScope.all || configurationOnly
        ? db.aiCharacterBox.keys.map((key) => key.toString()).toSet()
        : {
            ...?group?.aiCharacterIds,
            if (directCharacterId != null) directCharacterId,
          };
    final apiConfigIds = db.aiCharacterBox.values
        .where((item) => characterIds.contains(item.id))
        .map((item) => item.apiConfigId)
        .where((id) => id.isNotEmpty)
        .toSet();
    final all = selection.scope == BackupScope.all;
    bool inConversation(String id) => all || id == conversationId;

    return _Snapshot(
      apiConfigs: _entries(db.apiConfigBox.toMap(),
          (item) => all || configurationOnly || apiConfigIds.contains(item.id)),
      characters: _entries(db.aiCharacterBox.toMap(),
          (item) => all || characterIds.contains(item.id)),
      groups: _entries(db.chatGroupBox.toMap(),
          (item) => all || configurationOnly || item.id == conversationId),
      messages: configurationOnly
          ? const []
          : _entries(
              db.messageBox.toMap(), (item) => inConversation(item.groupId)),
      groupMemories: configurationOnly
          ? const []
          : _entries(db.groupMemoryBox.toMap(),
              (item) => inConversation(item.groupId)),
      characterMemories: configurationOnly
          ? const []
          : _entries(db.characterMemoryBox.toMap(),
              (item) => inConversation(item.groupId)),
      relationships: configurationOnly
          ? const []
          : _entries(db.relationshipStateBox.toMap(),
              (item) => inConversation(item.groupId)),
      skills: _entries(
          db.characterSkillBox.toMap(),
          (item) =>
              item.isGlobal || all || characterIds.contains(item.characterId)),
      tasks: configurationOnly
          ? const []
          : _entries(
              db.agentTaskBox.toMap(), (item) => inConversation(item.groupId)),
      workspaces: configurationOnly
          ? const []
          : _entries(db.workModeWorkspaceBox.toMap(),
              (item) => inConversation(item.conversationId)),
      settings: _selectedSettings(db, selection),
    );
  }

  static List<MapEntry<Object, T>> _entries<T>(
    Map<dynamic, T> source,
    bool Function(T value) include,
  ) =>
      source.entries
          .where((entry) => include(entry.value))
          .map((entry) => MapEntry<Object, T>(entry.key, entry.value))
          .toList(growable: false);

  static Map<String, dynamic> _safeSettings(DatabaseService db) {
    const keys = {
      'theme_mode',
      'app_skin_mode',
      'tts_enabled',
      'direct_chat_read_at',
      'direct_chat_source',
      'direct_chat_last_proactive_at',
      'group_chat_read_at',
      'group_chat_last_proactive_at',
      'pinned_character_ids',
      'pinned_group_ids',
      'memory_pinned_keys_v1',
      'token_usage',
    };
    final result = <String, dynamic>{};
    for (final key in db.appSettingsBox.keys.whereType<String>()) {
      if (keys.contains(key) ||
          key.startsWith('work_mode_enabled:') ||
          key.startsWith('context_compressed_through:')) {
        result[key] = db.appSettingsBox.get(key);
      }
    }
    return result;
  }

  static Map<String, dynamic> _selectedSettings(
    DatabaseService db,
    BackupSelection selection,
  ) {
    final safe = _safeSettings(db);
    if (selection.scope == BackupScope.all) return safe;
    if (selection.scope == BackupScope.configurationOnly) {
      const configurationKeys = {
        'theme_mode',
        'app_skin_mode',
        'tts_enabled',
        'pinned_character_ids',
        'pinned_group_ids',
      };
      return Map.fromEntries(
        safe.entries.where((entry) => configurationKeys.contains(entry.key)),
      );
    }

    final conversationId = selection.conversationId!;
    final directCharacterId =
        conversationId.startsWith('dm:') ? conversationId.substring(3) : null;
    final result = <String, dynamic>{};
    for (final entry in safe.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key == 'pinned_character_ids' && directCharacterId != null) {
        if (value is List && value.contains(directCharacterId)) {
          result[key] = [directCharacterId];
        }
      } else if (key == 'pinned_group_ids' && directCharacterId == null) {
        if (value is List && value.contains(conversationId)) {
          result[key] = [conversationId];
        }
      } else if (key == 'memory_pinned_keys_v1' && value is List) {
        final pins = value
            .whereType<String>()
            .where((pin) => _memoryPinBelongsToConversation(
                  db,
                  pin,
                  conversationId,
                  directCharacterId,
                ))
            .toList(growable: false);
        if (pins.isNotEmpty) result[key] = pins;
      } else if (value is Map &&
          (key == 'direct_chat_read_at' || key == 'direct_chat_source')) {
        if (value.containsKey(conversationId)) {
          result[key] = {conversationId: value[conversationId]};
        }
      } else if (value is Map &&
          key == 'direct_chat_last_proactive_at' &&
          directCharacterId != null) {
        if (value.containsKey(directCharacterId)) {
          result[key] = {directCharacterId: value[directCharacterId]};
        }
      } else if (value is Map &&
          (key == 'group_chat_read_at' ||
              key == 'group_chat_last_proactive_at') &&
          directCharacterId == null) {
        if (value.containsKey(conversationId)) {
          result[key] = {conversationId: value[conversationId]};
        }
      } else if (key == 'work_mode_enabled:$conversationId' ||
          key.startsWith('context_compressed_through:$conversationId:')) {
        result[key] = value;
      }
    }
    return result;
  }

  static bool _memoryPinBelongsToConversation(
    DatabaseService db,
    String pin,
    String conversationId,
    String? directCharacterId,
  ) {
    if (pin.startsWith('group:$conversationId:')) return true;
    if (pin.startsWith('character:')) {
      final id = pin.substring(10).split(':').first;
      return db.characterMemoryBox.get(id)?.groupId == conversationId;
    }
    if (pin.startsWith('relationship:')) {
      return db.relationshipStateBox.get(pin.substring(13))?.groupId ==
          conversationId;
    }
    if (pin.startsWith('legacy:')) {
      final characterId = pin.substring(7);
      return characterId == directCharacterId ||
          (db.chatGroupBox
                  .get(conversationId)
                  ?.aiCharacterIds
                  .contains(characterId) ??
              false);
    }
    return false;
  }
}
