part of 'data_lifecycle_settings.dart';

class _AppSettingsTargetBuilder {
  final DataLifecycleSettings owner;
  final exactValues = <String, dynamic>{};
  final mapEntries = <String, Map<String, dynamic>>{};
  final listEntries = <String, List<dynamic>>{};
  final nestedMapEntries = <String, Map<String, Map<String, dynamic>>>{};
  final recordEntries = <String, List<Map<String, dynamic>>>{};

  _AppSettingsTargetBuilder(this.owner);

  void exactKey(String key) {
    if (!owner.db.appSettingsBox.containsKey(key)) return;
    exactValues[key] = owner._cloneSettingValue(
      owner.db.appSettingsBox.get(key),
    );
  }

  void exactKeysWithPrefix(String prefix) {
    for (final key in owner.db.appSettingsBox.keys.whereType<String>()) {
      if (key.startsWith(prefix)) exactKey(key);
    }
  }

  void mapEntry(String settingKey, String entryKey) {
    final raw = owner.db.appSettingsBox.get(settingKey);
    if (raw is! Map || !raw.containsKey(entryKey)) return;
    mapEntries.putIfAbsent(settingKey, () => <String, dynamic>{})[entryKey] =
        owner._cloneSettingValue(raw[entryKey]);
  }

  void allMapEntries(String settingKey) {
    final raw = owner.db.appSettingsBox.get(settingKey);
    if (raw is! Map) return;
    for (final key in raw.keys) {
      mapEntry(settingKey, key.toString());
    }
  }

  void nestedMapEntry(
    String settingKey,
    String parentKey,
    String entryKey,
  ) {
    final raw = owner.db.appSettingsBox.get(settingKey);
    if (raw is! Map || raw[parentKey] is! Map) return;
    final parent = raw[parentKey] as Map;
    if (!parent.containsKey(entryKey)) return;
    nestedMapEntries
            .putIfAbsent(
              settingKey,
              () => <String, Map<String, dynamic>>{},
            )
            .putIfAbsent(parentKey, () => <String, dynamic>{})[entryKey] =
        owner._cloneSettingValue(parent[entryKey]);
  }

  void allNestedMapEntries(String settingKey) {
    final raw = owner.db.appSettingsBox.get(settingKey);
    if (raw is! Map) return;
    for (final parentEntry in raw.entries) {
      if (parentEntry.value is! Map) continue;
      for (final entryKey in (parentEntry.value as Map).keys) {
        nestedMapEntry(
          settingKey,
          parentEntry.key.toString(),
          entryKey.toString(),
        );
      }
    }
  }

  void listValue(String settingKey, dynamic value) {
    final raw = owner.db.appSettingsBox.get(settingKey);
    if (raw is! List ||
        !raw.any((item) => owner._sameSettingValue(item, value))) {
      return;
    }
    listEntries
        .putIfAbsent(settingKey, () => <dynamic>[])
        .add(owner._cloneSettingValue(value));
  }

  void recordValue(
    String settingKey,
    dynamic value, {
    required List<String> identityKeys,
  }) {
    if (value is! Map) return;
    final match = <String, dynamic>{};
    for (final key in identityKeys) {
      if (value.containsKey(key)) {
        match[key] = owner._cloneSettingValue(value[key]);
      }
    }
    if (match.isEmpty) return;
    recordEntries.putIfAbsent(settingKey, () => <Map<String, dynamic>>[]).add({
      'match': match,
      'value': owner._cloneSettingValue(value),
    });
  }

  void merge(AppSettingsDeletionTargets targets) {
    exactValues.addAll(targets.exactValues);
    for (final entry in targets.mapEntries.entries) {
      final destination =
          mapEntries.putIfAbsent(entry.key, () => <String, dynamic>{});
      destination.addAll(entry.value);
    }
    for (final entry in targets.listEntries.entries) {
      final destination = listEntries.putIfAbsent(entry.key, () => <dynamic>[]);
      destination.addAll(entry.value);
    }
    for (final entry in targets.nestedMapEntries.entries) {
      final parents = nestedMapEntries.putIfAbsent(
        entry.key,
        () => <String, Map<String, dynamic>>{},
      );
      for (final parent in entry.value.entries) {
        final destination =
            parents.putIfAbsent(parent.key, () => <String, dynamic>{});
        destination.addAll(parent.value);
      }
    }
    for (final entry in targets.recordEntries.entries) {
      final destination =
          recordEntries.putIfAbsent(entry.key, () => <Map<String, dynamic>>[]);
      destination.addAll(entry.value);
    }
  }

  AppSettingsDeletionTargets build() => AppSettingsDeletionTargets(
        exactValues: exactValues,
        mapEntries: mapEntries,
        listEntries: listEntries,
        nestedMapEntries: nestedMapEntries,
        recordEntries: recordEntries,
      );
}
