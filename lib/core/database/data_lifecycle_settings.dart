import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/database/data_lifecycle_models.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/features/direct_chat/direct_chat_session.dart';

class DataLifecycleSettings {
  static const pendingOperationKey = 'data_lifecycle_pending_operation';
  static const deletedCharacterSnapshotsKey = 'deleted_character_snapshots';
  static const memoryPinnedKey = 'memory_pinned_keys_v1';
  static const memoryRetryQueueKey = 'memory_retry_queue_v1';

  static const _messageIndexKey = 'message_ids_by_group';
  static const _messageIndexCountKey = 'message_index_count';
  static const _conversationSummariesKey = 'conversation_summaries';
  static const _directReadKey = 'direct_chat_read_at';
  static const _directSourceKey = 'direct_chat_source';
  static const _directProactiveKey = 'direct_chat_last_proactive_at';
  static const _groupReadKey = 'group_chat_read_at';
  static const _groupProactiveKey = 'group_chat_last_proactive_at';
  static const _pinnedCharacterKey = 'pinned_character_ids';
  static const _pinnedGroupKey = 'pinned_group_ids';
  static const _memoryPinnedKey = memoryPinnedKey;
  static const _tokenUsageKey = 'token_usage';
  static const _workModePrefix = 'work_mode_enabled:';
  static const _checkpointPrefix = 'context_compressed_through:';
  static const _retryPrefix = 'retry:';

  final DatabaseService db;

  const DataLifecycleSettings(this.db);

  AppSettingsDeletionTargets planConversation(
    String conversationId, {
    required bool isGroup,
    Iterable<dynamic> characterMemoryKeys = const [],
  }) {
    final builder = _AppSettingsTargetBuilder(this);
    builder.mapEntry(_messageIndexKey, conversationId);
    builder.mapEntry(_conversationSummariesKey, conversationId);
    builder.mapEntry(
      isGroup ? _groupReadKey : _directReadKey,
      conversationId,
    );
    builder.mapEntry(
      isGroup ? _groupProactiveKey : _directSourceKey,
      conversationId,
    );
    final characterId = DirectChatSession.characterIdFrom(conversationId);
    if (!isGroup && characterId != null) {
      builder.mapEntry(_directProactiveKey, characterId);
      builder.listValue(_pinnedCharacterKey, characterId);
    } else if (isGroup) {
      builder.listValue(_pinnedGroupKey, conversationId);
    }
    builder.exactKey('$_workModePrefix$conversationId');
    builder.exactKeysWithPrefix('$_checkpointPrefix$conversationId:');
    builder.nestedMapEntry(
      _tokenUsageKey,
      isGroup ? 'byGroup' : 'byCharacter',
      conversationId,
    );
    final characterKeys = characterMemoryKeys.map((key) => key.toString());
    for (final pin in _memoryPins()) {
      final remove = isGroup
          ? pin.startsWith('group:$conversationId:') || !_memoryPinExists(pin)
          : (characterId != null && pin == 'legacy:$characterId') ||
              !_memoryPinExists(pin);
      if (remove) builder.listValue(_memoryPinnedKey, pin);
      if (pin.startsWith('character:')) {
        final payload = pin.substring('character:'.length);
        final separator = payload.indexOf(':');
        if (separator > 0 &&
            characterKeys.contains(payload.substring(0, separator))) {
          builder.listValue(_memoryPinnedKey, pin);
        }
      }
    }
    for (final item in _retryItems()) {
      if (item['conversationId']?.toString() != conversationId) continue;
      builder.recordValue(
        memoryRetryQueueKey,
        item,
        identityKeys: const ['messageId', 'observerId', 'conversationId'],
      );
      builder.exactKey(_retryKey(item['messageId'], item['observerId']));
    }
    return builder.build();
  }

  AppSettingsDeletionTargets planCharacter(
    String characterId,
    String conversationId, {
    required bool removeConversation,
    Iterable<dynamic> characterMemoryKeys = const [],
  }) {
    final builder = _AppSettingsTargetBuilder(this);
    builder.listValue(_pinnedCharacterKey, characterId);
    builder.mapEntry(_directProactiveKey, characterId);
    builder.nestedMapEntry(_tokenUsageKey, 'byCharacter', characterId);
    builder.exactKey('$_workModePrefix$conversationId');
    builder.exactKeysWithPrefix('$_checkpointPrefix$conversationId:');
    for (final pin in _memoryPins()) {
      if (pin == 'legacy:$characterId' || !_memoryPinExists(pin)) {
        builder.listValue(_memoryPinnedKey, pin);
      }
      if (pin.startsWith('character:')) {
        final payload = pin.substring('character:'.length);
        final separator = payload.indexOf(':');
        if (separator > 0 &&
            characterMemoryKeys
                .map((key) => key.toString())
                .contains(payload.substring(0, separator))) {
          builder.listValue(_memoryPinnedKey, pin);
        }
      }
    }
    for (final item in _retryItems()) {
      if (item['observerId']?.toString() != characterId) continue;
      builder.recordValue(
        memoryRetryQueueKey,
        item,
        identityKeys: const ['messageId', 'observerId', 'conversationId'],
      );
      builder.exactKey(_retryKey(item['messageId'], item['observerId']));
    }
    if (removeConversation) {
      builder.merge(
        planConversation(conversationId, isGroup: false),
      );
      builder.mapEntry(deletedCharacterSnapshotsKey, characterId);
    }
    return builder.build();
  }

  AppSettingsDeletionTargets planClear(DataClearScope scope) {
    final builder = _AppSettingsTargetBuilder(this);
    if (scope == DataClearScope.chatContent) {
      for (final key in const [
        _messageIndexKey,
        _conversationSummariesKey,
        _directReadKey,
        _directSourceKey,
        _directProactiveKey,
        _groupReadKey,
        _groupProactiveKey,
      ]) {
        builder.allMapEntries(key);
      }
      builder.allNestedMapEntries(_tokenUsageKey);
      builder.exactKey(_messageIndexCountKey);
      builder.exactKeysWithPrefix(_workModePrefix);
      builder.exactKeysWithPrefix(_checkpointPrefix);
      builder.exactKeysWithPrefix(_retryPrefix);
      for (final item in _retryItems()) {
        builder.recordValue(
          memoryRetryQueueKey,
          item,
          identityKeys: const ['messageId', 'observerId', 'conversationId'],
        );
      }
      final rawQueue = db.appSettingsBox.get(memoryRetryQueueKey);
      if (rawQueue is List) {
        for (final item in rawQueue.where((item) => item is! Map)) {
          builder.listValue(memoryRetryQueueKey, item);
        }
      }
      for (final pin in _memoryPins()) {
        if (pin.startsWith('group:') ||
            pin.startsWith('character:') ||
            pin.startsWith('legacy:') ||
            !_memoryPinExists(pin)) {
          builder.listValue(_memoryPinnedKey, pin);
        }
      }
      return builder.build();
    }

    final preservePending = scope == DataClearScope.userContent;
    for (final key in db.appSettingsBox.keys.whereType<String>()) {
      if (key == pendingOperationKey) continue;
      if (preservePending && _isPreferenceKey(key)) continue;
      builder.exactKey(key);
    }
    return builder.build();
  }

  int conversationSettingCount(String id, {required bool isGroup}) {
    var count = 0;
    for (final key in [
      _messageIndexKey,
      _conversationSummariesKey,
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
    final characterId = DirectChatSession.characterIdFrom(id);
    final proactiveId = isGroup ? id : characterId ?? id;
    final proactive = db.appSettingsBox.get(_directProactiveKey);
    if (!isGroup && proactive is Map && proactive.containsKey(proactiveId)) {
      count++;
    }
    final usage = db.appSettingsBox.get(_tokenUsageKey);
    final dimension =
        usage is Map ? usage[isGroup ? 'byGroup' : 'byCharacter'] : null;
    if (dimension is Map && dimension.containsKey(id)) count++;
    return count;
  }

  int conversationSessionIndexCount(String id, {required bool isGroup}) {
    var count = 0;
    for (final key in [
      _messageIndexKey,
      _conversationSummariesKey,
      isGroup ? _groupReadKey : _directReadKey,
      isGroup ? _groupProactiveKey : _directSourceKey,
    ]) {
      final raw = db.appSettingsBox.get(key);
      if (raw is Map && raw.containsKey(id)) count++;
    }
    if (!isGroup) {
      final characterId = DirectChatSession.characterIdFrom(id);
      final raw = db.appSettingsBox.get(_directProactiveKey);
      if (characterId != null && raw is Map && raw.containsKey(characterId)) {
        count++;
      }
    }
    return count;
  }

  int allSessionIndexCount() {
    var count = 0;
    for (final key in [
      _messageIndexKey,
      _conversationSummariesKey,
      _directReadKey,
      _directSourceKey,
      _directProactiveKey,
      _groupReadKey,
      _groupProactiveKey,
    ]) {
      final raw = db.appSettingsBox.get(key);
      if (raw is Map) count += raw.length;
    }
    return count;
  }

  int conversationRetryRecordCount(String conversationId) => _retryItems()
      .where((item) => item['conversationId'] == conversationId)
      .length;

  int characterRetryRecordCount(String characterId, String conversationId) =>
      _retryItems()
          .where((item) =>
              item['conversationId'] == conversationId ||
              item['observerId'] == characterId)
          .length;

  int allRetryRecordCount() => _retryItems().length;

  int conversationMemoryPinCount(
    String conversationId, {
    required bool isGroup,
    Iterable<dynamic> characterMemoryKeys = const [],
  }) {
    final characterKeys =
        characterMemoryKeys.map((key) => key.toString()).toSet();
    final characterId = DirectChatSession.characterIdFrom(conversationId);
    return _memoryPins().where((pin) {
      if (isGroup && pin.startsWith('group:$conversationId:')) return true;
      if (!isGroup && characterId != null && pin == 'legacy:$characterId') {
        return true;
      }
      if (pin.startsWith('character:')) {
        final payload = pin.substring('character:'.length);
        final separator = payload.indexOf(':');
        if (separator > 0 &&
            characterKeys.contains(payload.substring(0, separator))) {
          return true;
        }
      }
      return !_memoryPinExists(pin);
    }).length;
  }

  int characterMemoryPinCount(
    String characterId, {
    Iterable<dynamic> characterMemoryKeys = const [],
    Iterable<String> relationshipIds = const [],
  }) {
    final characterKeys =
        characterMemoryKeys.map((key) => key.toString()).toSet();
    final relationIds = relationshipIds.toSet();
    return _memoryPins().where((pin) {
      if (pin == 'legacy:$characterId') return true;
      if (pin.startsWith('character:')) {
        final payload = pin.substring('character:'.length);
        final separator = payload.indexOf(':');
        if (separator > 0 &&
            characterKeys.contains(payload.substring(0, separator))) {
          return true;
        }
      }
      if (pin.startsWith('relationship:') &&
          relationIds.contains(pin.substring('relationship:'.length))) {
        return true;
      }
      return !_memoryPinExists(pin);
    }).length;
  }

  int clearMemoryPinCount({required bool preserveGlobalRelationshipPins}) =>
      _memoryPins().where((pin) {
        if (preserveGlobalRelationshipPins && pin.startsWith('relationship:')) {
          return !_memoryPinExists(pin);
        }
        return true;
      }).length;

  Future<void> removeConversation(
    String conversationId, {
    required bool isGroup,
    AppSettingsDeletionTargets? targets,
  }) async {
    await applyAppSettingsTargets(
      targets ?? planConversation(conversationId, isGroup: isGroup),
    );
    db.resetLifecycleCaches();
  }

  Future<void> removeCharacter(
    String characterId,
    String conversationId, {
    required bool removeConversation,
    AppSettingsDeletionTargets? targets,
  }) async {
    await applyAppSettingsTargets(
      targets ??
          planCharacter(
            characterId,
            conversationId,
            removeConversation: removeConversation,
          ),
    );
    db.resetLifecycleCaches();
  }

  Future<void> clearConversationSettings({
    bool removeDeletedCharacterSnapshots = false,
    AppSettingsDeletionTargets? targets,
  }) async {
    final resolved = targets ?? planClear(DataClearScope.chatContent);
    await applyAppSettingsTargets(resolved);
    if (removeDeletedCharacterSnapshots && targets == null) {
      await db.appSettingsBox.delete(deletedCharacterSnapshotsKey);
    }
  }

  Future<void> clearExceptPreferences({
    AppSettingsDeletionTargets? targets,
  }) async =>
      applyAppSettingsTargets(
        targets ?? planClear(DataClearScope.userContent),
      );

  Future<void> clearExceptPendingOperation({
    AppSettingsDeletionTargets? targets,
  }) async =>
      applyAppSettingsTargets(
        targets ?? planClear(DataClearScope.factoryReset),
      );

  Future<void> applyAppSettingsTargets(
    AppSettingsDeletionTargets targets,
  ) async {
    await _deleteExactValues(targets.exactValues);
    await _removeMapEntries(targets.mapEntries);
    await _removeNestedMapEntries(targets.nestedMapEntries);
    await _removeListEntries(targets.listEntries);
    await _removeRecordEntries(targets.recordEntries);
  }

  Future<void> saveDeletedCharacter(AICharacter character) async {
    final snapshots = _snapshots();
    final snapshot = <String, dynamic>{
      'name': character.name,
      'avatar': character.avatar,
      'age': character.age,
      'role': character.role,
    };
    if (character.hasKnownGender) snapshot['gender'] = character.gender.name;
    snapshots[character.id] = snapshot;
    await db.appSettingsBox.put(deletedCharacterSnapshotsKey, snapshots);
  }

  Future<void> removeDeletedCharacter(String characterId) async {
    final snapshots = _snapshots();
    if (snapshots.remove(characterId) == null) return;
    await db.appSettingsBox.put(deletedCharacterSnapshotsKey, snapshots);
  }

  Future<void> removeRelationshipPin(String stableRelationshipId) async {
    await _removeMemoryPins(
      (pin) => pin == 'relationship:$stableRelationshipId',
    );
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

  bool _isPreferenceKey(String key) => {
        'theme_mode',
        DatabaseService.appSkinModeKey,
        'tts_enabled',
        'ai_processing_dir',
      }.contains(key);

  dynamic _cloneSettingValue(dynamic value) {
    if (value is Map) {
      return {
        for (final entry in value.entries)
          entry.key.toString(): _cloneSettingValue(entry.value),
      };
    }
    if (value is List) {
      return value.map(_cloneSettingValue).toList(growable: false);
    }
    return value;
  }

  bool _sameSettingValue(dynamic left, dynamic right) {
    if (identical(left, right)) return true;
    if (left is Map && right is Map) {
      if (left.length != right.length) return false;
      for (final entry in left.entries) {
        if (!right.containsKey(entry.key) ||
            !_sameSettingValue(entry.value, right[entry.key])) {
          return false;
        }
      }
      return true;
    }
    if (left is List && right is List) {
      if (left.length != right.length) return false;
      for (var index = 0; index < left.length; index++) {
        if (!_sameSettingValue(left[index], right[index])) return false;
      }
      return true;
    }
    return left == right;
  }

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
      if (list.isEmpty && target.key == memoryRetryQueueKey) {
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
    final raw = db.appSettingsBox.get(_memoryPinnedKey);
    if (raw is! List) return;
    await db.appSettingsBox.put(
      _memoryPinnedKey,
      raw.whereType<String>().where((pin) => !remove(pin)).toList(),
    );
  }

  List<Map<String, dynamic>> _retryItems() {
    final raw = db.appSettingsBox.get(memoryRetryQueueKey);
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList(growable: false);
  }

  List<String> _memoryPins() {
    final raw = db.appSettingsBox.get(_memoryPinnedKey);
    return raw is List
        ? raw.whereType<String>().toList(growable: false)
        : const [];
  }

  String _retryKey(dynamic messageId, dynamic observerId) =>
      '$_retryPrefix$messageId:$observerId';

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
    final raw = db.appSettingsBox.get(deletedCharacterSnapshotsKey);
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
