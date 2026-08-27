part of 'data_lifecycle_settings.dart';

extension _DataLifecycleSettingsOperations on DataLifecycleSettings {
  Future<void> _deleteExactValues(Map<String, dynamic> values) async {
    for (final entry in values.entries) {
      final current = db.appSettingsBox.get(entry.key);
      if (_sameSettingValue(current, entry.value)) {
        await db.appSettingsBox.delete(entry.key);
        continue;
      }
      if (current is Map && entry.value is Map) {
        final map = Map<dynamic, dynamic>.from(current);
        var changed = false;
        for (final expected in (entry.value as Map).entries) {
          if (map.containsKey(expected.key) &&
              _sameSettingValue(map[expected.key], expected.value)) {
            map.remove(expected.key);
            changed = true;
          }
        }
        if (changed) {
          if (map.isEmpty) {
            await db.appSettingsBox.delete(entry.key);
          } else {
            await db.appSettingsBox.put(entry.key, map);
          }
        }
        continue;
      }
      if (current is List && entry.value is List) {
        final list = List<dynamic>.from(current);
        for (final expected in entry.value as List) {
          final index = list.indexWhere(
            (value) => _sameSettingValue(value, expected),
          );
          if (index >= 0) list.removeAt(index);
        }
        if (list.length != current.length) {
          if (list.isEmpty) {
            await db.appSettingsBox.delete(entry.key);
          } else {
            await db.appSettingsBox.put(entry.key, list);
          }
        }
      }
    }
  }

  Future<void> _removeMapEntries(
    Map<String, Map<String, dynamic>> entries,
  ) async {
    for (final target in entries.entries) {
      final raw = db.appSettingsBox.get(target.key);
      if (raw is! Map) continue;
      final map = Map<dynamic, dynamic>.from(raw);
      var changed = false;
      for (final entry in target.value.entries) {
        if (map.containsKey(entry.key) &&
            _sameSettingValue(map[entry.key], entry.value)) {
          map.remove(entry.key);
          changed = true;
        }
      }
      if (!changed) continue;
      if (map.isEmpty) {
        await db.appSettingsBox.delete(target.key);
      } else {
        await db.appSettingsBox.put(target.key, map);
      }
    }
  }

  Future<void> _removeNestedMapEntries(
    Map<String, Map<String, Map<String, dynamic>>> entries,
  ) async {
    for (final target in entries.entries) {
      final raw = db.appSettingsBox.get(target.key);
      if (raw is! Map) continue;
      final outer = Map<dynamic, dynamic>.from(raw);
      var changed = false;
      for (final parent in target.value.entries) {
        final rawInner = outer[parent.key];
        if (rawInner is! Map) continue;
        final inner = Map<dynamic, dynamic>.from(rawInner);
        for (final entry in parent.value.entries) {
          if (inner.containsKey(entry.key) &&
              _sameSettingValue(inner[entry.key], entry.value)) {
            inner.remove(entry.key);
            changed = true;
          }
        }
        if (inner.isEmpty) {
          outer.remove(parent.key);
        } else if (changed) {
          outer[parent.key] = inner;
        }
      }
      if (!changed) continue;
      if (outer.isEmpty) {
        await db.appSettingsBox.delete(target.key);
      } else {
        await db.appSettingsBox.put(target.key, outer);
      }
    }
  }

  Future<void> _removeListEntries(
    Map<String, List<dynamic>> entries,
  ) async {
    for (final target in entries.entries) {
      final raw = db.appSettingsBox.get(target.key);
      if (raw is! List) continue;
      final list = List<dynamic>.from(raw);
      for (final expected in target.value) {
        final index = list.indexWhere(
          (value) => _sameSettingValue(value, expected),
        );
        if (index >= 0) list.removeAt(index);
      }
      if (list.isEmpty &&
          target.key == DataLifecycleSettings.memoryRetryQueueKey) {
        await db.appSettingsBox.delete(target.key);
      } else if (list.length != raw.length) {
        await db.appSettingsBox.put(target.key, list);
      }
    }
  }

  Future<void> _removeRecordEntries(
    Map<String, List<Map<String, dynamic>>> entries,
  ) async {
    for (final target in entries.entries) {
      final raw = db.appSettingsBox.get(target.key);
      if (raw is! List) continue;
      final list = List<dynamic>.from(raw);
      for (final selector in target.value) {
        final match = selector['match'];
        final index = list.indexWhere(
          (value) => _recordMatches(value, match),
        );
        if (index >= 0) list.removeAt(index);
      }
      if (list.isEmpty) {
        await db.appSettingsBox.delete(target.key);
      } else if (list.length != raw.length) {
        await db.appSettingsBox.put(target.key, list);
      }
    }
  }

  bool _recordMatches(dynamic value, dynamic rawMatch) {
    if (value is! Map || rawMatch is! Map || rawMatch.isEmpty) return false;
    for (final entry in rawMatch.entries) {
      if (!value.containsKey(entry.key) ||
          !_sameSettingValue(value[entry.key], entry.value)) {
        return false;
      }
    }
    return true;
  }

  Future<void> _removeMemoryPins(bool Function(String pin) remove) async {
    final raw = db.appSettingsBox.get(DataLifecycleSettings._memoryPinnedKey);
    if (raw is! List) return;
    await db.appSettingsBox.put(
      DataLifecycleSettings._memoryPinnedKey,
      raw.whereType<String>().where((pin) => !remove(pin)).toList(),
    );
  }

  List<Map<String, dynamic>> _retryItems() {
    final raw =
        db.appSettingsBox.get(DataLifecycleSettings.memoryRetryQueueKey);
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList(growable: false);
  }

  List<String> _memoryPins() {
    final raw = db.appSettingsBox.get(DataLifecycleSettings._memoryPinnedKey);
    return raw is List
        ? raw.whereType<String>().toList(growable: false)
        : const [];
  }

  String _retryKey(dynamic messageId, dynamic observerId) =>
      '${DataLifecycleSettings._retryPrefix}$messageId:$observerId';

  bool _memoryPinExists(String pin) {
    if (pin.startsWith('character:')) {
      return db.characterMemoryBox.containsKey(
        pin.substring(10).split(':').first,
      );
    }
    if (pin.startsWith('legacy:')) {
      return db.aiCharacterBox.containsKey(pin.substring(7));
    }
    if (pin.startsWith('relationship:')) {
      final stableId = pin.substring(13);
      return db.relationshipStateBox.values.any(
        (state) =>
            state.id == stableId ||
            state.sourceCharacterId.isNotEmpty &&
                RelationshipState.stableGlobalId(
                      state.sourceCharacterId,
                      state.targetType,
                      state.targetId,
                    ) ==
                    stableId,
      );
    }
    if (pin.startsWith('group:')) {
      final payload = pin.substring(6);
      final separator = payload.indexOf(':');
      return separator > 0 &&
          db.chatGroupBox.containsKey(payload.substring(0, separator));
    }
    return false;
  }

  Map<String, dynamic> _snapshots() {
    final raw = db.appSettingsBox
        .get(DataLifecycleSettings.deletedCharacterSnapshotsKey);
    return raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
  }

  AICharacter? _characterFromSnapshot(String id, dynamic raw) {
    if (raw is! Map) return null;
    final genderName = raw['gender']?.toString();
    final gender = switch (genderName) {
      'male' => CharacterGender.male,
      'female' => CharacterGender.female,
      _ => CharacterGender.female,
    };
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
      gender: gender,
      hasKnownGender: genderName == 'male' || genderName == 'female',
    );
  }
}
