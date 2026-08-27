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
  final List<MapEntry<Object, dynamic>> userProfiles;
  final List<MapEntry<Object, Map<String, dynamic>>> permanentMemories;
  final List<MapEntry<Object, Map<String, dynamic>>> relationshipEvents;
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
    required this.userProfiles,
    required this.permanentMemories,
    required this.relationshipEvents,
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
    final messages = configurationOnly
        ? const <MapEntry<Object, dynamic>>[]
        : _entriesFromBox(db.messageBox.keys, db.messageBox.get,
            (item) => inConversation(item.groupId));
    final messageIds = messages.map((entry) => entry.value.id).toSet();
    final visibleCharacterIds = characterIds;
    final visibleIds = {'user', ...visibleCharacterIds};
    List<String> sourceMessages(Iterable<String> ids) => all
        ? ids.toList(growable: false)
        : ids.where(messageIds.contains).toList(growable: false);
    final selectedPermanentMemories = configurationOnly
        ? const <MapEntry<Object, PermanentMemory>>[]
        : _entriesFromBox(db.permanentMemoryBox.keys, db.permanentMemoryBox.get,
            (item) {
            if (all) return true;
            return item.originConversationId == conversationId &&
                visibleCharacterIds.contains(item.observerCharacterId);
          });
    final permanentMemoryIds =
        selectedPermanentMemories.map((entry) => entry.value.id).toSet();
    final globalRelationships = all
        ? RelationshipState.selectStableSnapshots(db.relationshipStateBox.values
            .where((item) => item.groupId == 'global'))
        : const <RelationshipState>[];

    return _Snapshot(
      apiConfigs: _entriesFromBox(db.apiConfigBox.keys, db.apiConfigBox.get,
          (item) => all || configurationOnly || apiConfigIds.contains(item.id)),
      characters: _entriesFromBox(db.aiCharacterBox.keys, db.aiCharacterBox.get,
          (item) => all || characterIds.contains(item.id)),
      groups: _entriesFromBox(db.chatGroupBox.keys, db.chatGroupBox.get,
          (item) => all || configurationOnly || item.id == conversationId),
      messages: messages,
      groupMemories: configurationOnly
          ? const []
          : _entriesFromBox(db.groupMemoryBox.keys, db.groupMemoryBox.get,
              (item) => inConversation(item.groupId)),
      characterMemories: configurationOnly
          ? const []
          : _entriesFromBox(
              db.characterMemoryBox.keys,
              db.characterMemoryBox.get,
              (item) => inConversation(item.groupId)),
      relationships: configurationOnly
          ? const []
          : _entriesByValues(db.relationshipStateBox.keys,
              db.relationshipStateBox.get, globalRelationships),
      skills: _entriesFromBox(
          db.characterSkillBox.keys,
          db.characterSkillBox.get,
          (item) =>
              item.isGlobal || all || characterIds.contains(item.characterId)),
      tasks: configurationOnly
          ? const []
          : _entriesFromBox(db.agentTaskBox.keys, db.agentTaskBox.get,
              (item) => inConversation(item.groupId)),
      workspaces: configurationOnly
          ? const []
          : _entriesFromBox(
              db.workModeWorkspaceBox.keys,
              db.workModeWorkspaceBox.get,
              (item) => inConversation(item.conversationId)),
      userProfiles: all
          ? _entriesFromBox(
              db.userProfileBox.keys, db.userProfileBox.get, (_) => true)
          : const [],
      permanentMemories: configurationOnly
          ? const []
          : selectedPermanentMemories.map((entry) {
              final item = entry.value;
              return MapEntry<Object, Map<String, dynamic>>(
                // Migrated memories use a stable Hive key that differs from
                // the entity id; the backup format is keyed by canonical id.
                item.id,
                BackupEntityCodec.permanentMemory(
                  item,
                  sourceMessageIds: sourceMessages(item.sourceMessageIds),
                  subjectIds: all
                      ? item.subjectIds
                      : item.subjectIds.where(visibleIds.contains).toList(),
                  participantIds: all
                      ? item.participantIds
                      : item.participantIds.where(visibleIds.contains).toList(),
                  supersedesIds: all
                      ? item.supersedesIds
                      : item.supersedesIds
                          .where(permanentMemoryIds.contains)
                          .toList(),
                ),
              );
            }).toList(growable: false),
      relationshipEvents: configurationOnly
          ? const []
          : _entriesFromBox(
              db.relationshipEventBox.keys, db.relationshipEventBox.get,
              (item) {
              if (all) return true;
              final sourceVisible =
                  visibleCharacterIds.contains(item.sourceCharacterId);
              final targetVisible =
                  item.targetType == RelationshipTargetType.user
                      ? true
                      : visibleCharacterIds.contains(item.targetId);
              return item.originConversationId == conversationId &&
                  sourceVisible &&
                  targetVisible;
            }).map((entry) {
              final item = entry.value;
              return MapEntry<Object, Map<String, dynamic>>(
                // Migrated events have the same stable-key/id split as memories.
                item.id,
                BackupEntityCodec.relationshipEvent(
                  item,
                  sourceMessageIds: sourceMessages(item.sourceMessageIds),
                ),
              );
            }).toList(growable: false),
      settings: _selectedSettings(db, selection),
    );
  }

  static List<MapEntry<Object, T>> _entriesFromBox<T>(
    Iterable<dynamic> keys,
    T? Function(dynamic key) read,
    bool Function(T value) include,
  ) {
    final selected = <MapEntry<Object, T>>[];
    for (final key in keys) {
      final value = read(key);
      if (value != null && include(value)) {
        selected.add(MapEntry<Object, T>(key, value));
      }
    }
    selected.sort((a, b) => a.key.toString().compareTo(b.key.toString()));
    return selected;
  }

  static List<MapEntry<Object, T>> _entriesByValues<T>(
    Iterable<dynamic> keys,
    T? Function(dynamic key) read,
    Iterable<T> values,
  ) {
    final selected = values.toSet();
    return _entriesFromBox(keys, read, selected.contains);
  }

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
      SearchProviderConfigStore.configsKey,
      SearchProviderConfigStore.defaultProviderKey,
      SearchProviderConfigStore.runtimeSettingsKey,
      AiGovernanceStore.globalSearchPolicyKey,
      AiGovernanceStore.conversationSearchPoliciesKey,
    };
    final result = <String, dynamic>{};
    for (final key in db.appSettingsBox.keys.whereType<String>()) {
      if (keys.contains(key) ||
          key.startsWith('work_mode_enabled:') ||
          key.startsWith('context_compressed_through:')) {
        final raw = db.appSettingsBox.get(key);
        final safe = switch (key) {
          SearchProviderConfigStore.configsKey =>
            SearchProviderConfigStore.backupValue(raw),
          SearchProviderConfigStore.runtimeSettingsKey =>
            SearchRuntimeSettings.fromMap(raw).toMap(),
          AiGovernanceStore.globalSearchPolicyKey => _safeSearchPolicy(raw),
          AiGovernanceStore.conversationSearchPoliciesKey =>
            _safeConversationSearchPolicies(raw),
          _ => raw,
        };
        if (safe != null) result[key] = safe;
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
        SearchProviderConfigStore.configsKey,
        SearchProviderConfigStore.defaultProviderKey,
        SearchProviderConfigStore.runtimeSettingsKey,
        AiGovernanceStore.globalSearchPolicyKey,
        AiGovernanceStore.conversationSearchPoliciesKey,
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

  static String _safeSearchPolicy(Object? raw) {
    const allowed = {'off', 'ask', 'auto'};
    final value = raw?.toString() ?? '';
    return allowed.contains(value) ? value : 'off';
  }

  static Map<String, dynamic> _safeConversationSearchPolicies(Object? raw) {
    const allowed = {'off', 'ask', 'auto'};
    if (raw is! Map) return const {};
    final result = <String, dynamic>{};
    const scanner = SearchSecretScanner();
    for (final entry in raw.entries) {
      final id = entry.key.toString().trim();
      final policy = entry.value?.toString() ?? '';
      if (id.isEmpty || id.length > 240 || scanner.containsSensitiveData(id)) {
        continue;
      }
      if (allowed.contains(policy)) result[id] = policy;
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
