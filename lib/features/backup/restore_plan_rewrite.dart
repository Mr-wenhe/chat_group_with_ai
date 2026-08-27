part of 'restore_executor.dart';

List<Map<String, dynamic>> _rewriteUserProfiles(
  List<Map<String, dynamic>> records,
  DatabaseService db,
  Map<String, int> skipped,
) {
  final result = <Map<String, dynamic>>[];
  for (final record in records) {
    final key = BackupEntityCodec.key(record);
    if (db.userProfileBox.containsKey(key)) {
      skipped['userProfiles'] = (skipped['userProfiles'] ?? 0) + 1;
      continue;
    }
    final value = BackupEntityCodec.value(record);
    value['id'] = 'me';
    result.add(BackupEntityCodec.record('me', value));
  }
  return result;
}

Map<String, String> _mapping(
  List<Map<String, dynamic>> records,
  bool Function(Object key) contains,
  RestoreConflictStrategy strategy,
  String countKey,
  Map<String, int> skipped,
  Map<String, int> remapped,
) {
  final result = <String, String>{};
  for (final record in records) {
    final old = BackupEntityCodec.value(record)['id'].toString();
    if (!contains(BackupEntityCodec.key(record))) {
      result[old] = old;
    } else if (strategy == RestoreConflictStrategy.copyWithNewIds) {
      result[old] = const Uuid().v4();
      remapped[countKey] = (remapped[countKey] ?? 0) + 1;
    } else {
      result[old] = old;
      skipped[countKey] = (skipped[countKey] ?? 0) + 1;
    }
  }
  return result;
}

List<Map<String, dynamic>> _rewrite(
  List<Map<String, dynamic>> records,
  Map<String, String> mapping,
  bool Function(Object key) contains,
  RestoreConflictStrategy strategy,
  void Function(Map<String, dynamic> value) mutate,
) =>
    records
        .where((record) =>
            !contains(BackupEntityCodec.key(record)) ||
            strategy == RestoreConflictStrategy.copyWithNewIds)
        .map((record) {
      final value = BackupEntityCodec.value(record);
      final old = value['id'].toString();
      mutate(value);
      return BackupEntityCodec.record(mapping[old]!, value);
    }).toList();

List<Map<String, dynamic>> _rewriteStorage(
  List<Map<String, dynamic>> records,
  bool Function(Object key) contains,
  RestoreConflictStrategy strategy,
  String countKey,
  Map<String, int> skipped,
  Map<String, int> remapped,
  String Function(String key, Map<String, dynamic> value) mutate,
) {
  final result = <Map<String, dynamic>>[];
  for (final record in records) {
    final oldKey = BackupEntityCodec.key(record);
    if (contains(oldKey) &&
        strategy != RestoreConflictStrategy.copyWithNewIds) {
      skipped[countKey] = (skipped[countKey] ?? 0) + 1;
      continue;
    }
    final value = BackupEntityCodec.value(record);
    var newKey = mutate(oldKey, value);
    if (contains(newKey) ||
        result.any((item) => BackupEntityCodec.key(item) == newKey)) {
      newKey = '${newKey}_${const Uuid().v4()}';
    }
    if (newKey != oldKey) remapped[countKey] = (remapped[countKey] ?? 0) + 1;
    result.add(BackupEntityCodec.record(newKey, value));
  }
  return result;
}

Map<String, dynamic> _remapSettings(
  Map<String, dynamic> source,
  Map<String, String> characters,
  Map<String, String> groups,
  Map<String, String> memories,
  Map<String, String> relationships,
  String Function(String) conversation,
  DatabaseService db,
  RestoreConflictStrategy strategy,
  Map<String, int> skipped,
) {
  final result = <String, dynamic>{};
  final searchConfigIdRemap = strategy == RestoreConflictStrategy.copyWithNewIds
      ? _searchConfigIdRemap(source[SearchProviderConfigStore.configsKey])
      : const <String, String>{};
  for (final entry in source.entries) {
    var key = entry.key;
    dynamic value = entry.value;
    if (key == 'pinned_character_ids') value = _mapList(value, characters);
    if (key == 'pinned_group_ids') value = _mapList(value, groups);
    if (key == SearchProviderConfigStore.configsKey) {
      value = _restoreSearchConfigs(
        value,
        db.appSettingsBox.get(key),
        strategy,
        searchConfigIdRemap,
      );
    }
    if (key == SearchProviderConfigStore.defaultProviderKey &&
        strategy == RestoreConflictStrategy.copyWithNewIds) {
      final remapped = searchConfigIdRemap[value?.toString()];
      if (remapped == null) continue;
      value = remapped;
    }
    if (value is Map &&
        key == AiGovernanceStore.conversationSearchPoliciesKey) {
      value = _mapKeys(value, conversation);
    }
    if (key == 'memory_pinned_keys_v1') {
      value = _strings(value)
          .map((pin) => _mapMemoryPin(
                pin,
                characters,
                groups,
                memories,
                relationships,
              ))
          .toList(growable: false);
    }
    if (value is Map &&
        (key == 'direct_chat_read_at' || key == 'direct_chat_source')) {
      value = _mapKeys(value, conversation);
    }
    if (value is Map && key == 'direct_chat_last_proactive_at') {
      value = _mapKeys(value, (id) => characters[id] ?? id);
    }
    if (value is Map &&
        (key == 'group_chat_read_at' ||
            key == 'group_chat_last_proactive_at')) {
      value = _mapKeys(value, (id) => groups[id] ?? id);
    }
    if (value is Map && key == 'token_usage') {
      final usage = Map<String, dynamic>.from(value);
      if (usage['byCharacter'] is Map) {
        usage['byCharacter'] = _mapKeys(
          usage['byCharacter'] as Map,
          (id) => characters[id] ?? id,
        );
      }
      if (usage['byGroup'] is Map) {
        usage['byGroup'] = _mapKeys(
          usage['byGroup'] as Map,
          (id) => groups[id] ?? id,
        );
      }
      value = usage;
    }
    if (key.startsWith('work_mode_enabled:')) {
      key = 'work_mode_enabled:${conversation(key.substring(18))}';
    }
    const checkpointPrefix = 'context_compressed_through:';
    if (key.startsWith(checkpointPrefix)) {
      final payload = key.substring(checkpointPrefix.length);
      final separator = payload.lastIndexOf(':');
      if (separator > 0) {
        final oldConversation = payload.substring(0, separator);
        final oldCharacter = payload.substring(separator + 1);
        key = '$checkpointPrefix${conversation(oldConversation)}:'
            '${characters[oldCharacter] ?? oldCharacter}';
      }
    }
    if (key != SearchProviderConfigStore.configsKey &&
        db.appSettingsBox.containsKey(key) &&
        strategy != RestoreConflictStrategy.emptyOnly) {
      final existing = db.appSettingsBox.get(key);
      if (existing is List && value is List) {
        value = {...existing, ...value}.toList();
      } else if (existing is Map && value is Map) {
        final merged = Map<dynamic, dynamic>.from(existing);
        for (final imported in value.entries) {
          merged.putIfAbsent(imported.key, () => imported.value);
        }
        value = merged;
      } else {
        skipped['settings'] = (skipped['settings'] ?? 0) + 1;
        continue;
      }
    }
    result[key] = value;
  }
  return result;
}

List<Map<String, dynamic>> _restoreSearchConfigs(
  Object? raw,
  Object? existingRaw,
  RestoreConflictStrategy strategy,
  Map<String, String> idRemap,
) {
  final restored = SearchProviderConfigStore.restoreValue(raw);
  if (strategy == RestoreConflictStrategy.emptyOnly) return restored;

  final existing = _mapRecords(existingRaw);
  final existingIds = existing
      .map((item) => item['id']?.toString() ?? '')
      .where((id) => id.isNotEmpty)
      .toSet();
  if (strategy == RestoreConflictStrategy.skipExisting) {
    return [
      ...existing,
      ...restored.where(
        (item) => !existingIds.contains(item['id']?.toString()),
      ),
    ];
  }

  return [
    ...existing,
    ...restored.map(
      (item) => {
        ...item,
        'id': idRemap[item['id']?.toString()] ?? item['id'],
        // A copied configuration must not silently replace the current
        // default. The remapped default key below can still select it when
        // the destination has no existing default.
        'isDefault': false,
      },
    ),
  ];
}

Map<String, String> _searchConfigIdRemap(Object? raw) {
  final result = <String, String>{};
  if (raw is! List) return result;
  for (final item in raw.whereType<Map>()) {
    final id = item['id']?.toString() ?? '';
    if (id.isNotEmpty) result[id] = const Uuid().v4();
  }
  return result;
}

List<Map<String, dynamic>> _mapRecords(Object? raw) {
  return SearchProviderConfigStore.normalizeExistingValue(raw);
}

List<String> _mapList(Object? value, Map<String, String> mapping) =>
    _strings(value).map((id) => mapping[id] ?? id).toList();

String _mapMemoryPin(
  String pin,
  Map<String, String> characters,
  Map<String, String> groups,
  Map<String, String> memories,
  Map<String, String> relationships,
) {
  if (pin.startsWith('character:')) {
    final payload = pin.substring(10);
    final separator = payload.indexOf(':');
    final id = separator < 0 ? payload : payload.substring(0, separator);
    return 'character:${memories[id] ?? id}'
        '${separator < 0 ? '' : payload.substring(separator)}';
  }
  if (pin.startsWith('legacy:')) {
    final id = pin.substring(7);
    return 'legacy:${characters[id] ?? id}';
  }
  if (pin.startsWith('relationship:')) {
    final id = pin.substring(13);
    return 'relationship:${relationships[id] ?? id}';
  }
  if (pin.startsWith('group:')) {
    final payload = pin.substring(6);
    final separator = payload.indexOf(':');
    if (separator < 0) return pin;
    final oldGroup = payload.substring(0, separator);
    final newGroup = groups[oldGroup] ?? oldGroup;
    var memoryKey = payload.substring(separator + 1);
    if (memoryKey == oldGroup) {
      memoryKey = newGroup;
    } else if (memoryKey.startsWith('${oldGroup}_')) {
      memoryKey = '$newGroup${memoryKey.substring(oldGroup.length)}';
    }
    return 'group:$newGroup:$memoryKey';
  }
  return pin;
}

Map<String, dynamic> _mapKeys(
  Map source,
  String Function(String id) map,
) =>
    source.map((key, value) => MapEntry(map(key.toString()), value));

List<String> _strings(Object? value) =>
    (value as List? ?? const []).map((item) => item.toString()).toList();
