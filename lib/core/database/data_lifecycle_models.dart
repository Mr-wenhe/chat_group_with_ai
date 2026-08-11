enum CharacterDeletionPolicy { keepMessageHistory, deleteRelatedData }

enum DataClearScope { chatContent, userContent, factoryReset }

class DeletionTargetNames {
  static const messages = 'messages';
  static const groupMemories = 'groupMemories';
  static const characterMemories = 'characterMemories';
  static const relationshipStates = 'relationshipStates';
  static const relationshipEvents = 'relationshipEvents';
  static const permanentMemories = 'permanentMemories';
  static const agentTasks = 'agentTasks';
  static const workspaces = 'workspaces';
  static const characterSkills = 'characterSkills';
  static const aiCharacters = 'aiCharacters';
  static const chatGroups = 'chatGroups';
  static const apiConfigs = 'apiConfigs';
  static const userProfiles = 'userProfiles';
  static const replyReferences = 'replyReferences';
  static const mentionReferences = 'mentionReferences';
  static const deletedSnapshots = 'deletedSnapshots';
  static const sessionIndexes = 'sessionIndexes';
  static const memoryPins = 'memoryPins';
  static const retryRecords = 'retryRecords';

  const DeletionTargetNames._();
}

/// Exact app-settings mutations resolved before a lifecycle operation starts.
///
/// Hive stores several indexes and queues as maps/lists inside one box. A
/// top-level key alone is not enough to keep a retry scoped, so map/list
/// entries carry the value that existed during planning. Retries remove an
/// entry only when that value is still unchanged.
class AppSettingsDeletionTargets {
  final Map<String, dynamic> exactValues;
  final Map<String, Map<String, dynamic>> mapEntries;
  final Map<String, List<dynamic>> listEntries;
  final Map<String, Map<String, Map<String, dynamic>>> nestedMapEntries;
  final Map<String, List<Map<String, dynamic>>> recordEntries;

  const AppSettingsDeletionTargets({
    this.exactValues = const {},
    this.mapEntries = const {},
    this.listEntries = const {},
    this.nestedMapEntries = const {},
    this.recordEntries = const {},
  });

  bool get isEmpty =>
      exactValues.isEmpty &&
      mapEntries.isEmpty &&
      listEntries.isEmpty &&
      nestedMapEntries.isEmpty &&
      recordEntries.isEmpty;

  Map<String, dynamic> toMap() => {
        'exactValues': Map<String, dynamic>.from(exactValues),
        'mapEntries': {
          for (final entry in mapEntries.entries)
            entry.key: Map<String, dynamic>.from(entry.value),
        },
        'listEntries': {
          for (final entry in listEntries.entries)
            entry.key: List<dynamic>.from(entry.value),
        },
        'nestedMapEntries': {
          for (final entry in nestedMapEntries.entries)
            entry.key: {
              for (final parent in entry.value.entries)
                parent.key: Map<String, dynamic>.from(parent.value),
            },
        },
        'recordEntries': {
          for (final entry in recordEntries.entries)
            entry.key: entry.value
                .map((record) => Map<String, dynamic>.from(record))
                .toList(growable: false),
        },
      };

  factory AppSettingsDeletionTargets.fromMap(dynamic raw) {
    if (raw is! Map) return const AppSettingsDeletionTargets();
    final exactValues = _stringDynamicMap(raw['exactValues']);
    final mapEntries = <String, Map<String, dynamic>>{};
    final rawMapEntries = raw['mapEntries'];
    if (rawMapEntries is Map) {
      for (final entry in rawMapEntries.entries) {
        if (entry.value is Map) {
          mapEntries[entry.key.toString()] = _stringDynamicMap(entry.value);
        }
      }
    }
    final listEntries = <String, List<dynamic>>{};
    final rawListEntries = raw['listEntries'];
    if (rawListEntries is Map) {
      for (final entry in rawListEntries.entries) {
        if (entry.value is List) {
          listEntries[entry.key.toString()] =
              List<dynamic>.from(entry.value as List);
        }
      }
    }
    final nestedMapEntries = <String, Map<String, Map<String, dynamic>>>{};
    final rawNested = raw['nestedMapEntries'];
    if (rawNested is Map) {
      for (final entry in rawNested.entries) {
        if (entry.value is! Map) continue;
        final parents = <String, Map<String, dynamic>>{};
        for (final parent in (entry.value as Map).entries) {
          if (parent.value is Map) {
            parents[parent.key.toString()] = _stringDynamicMap(parent.value);
          }
        }
        nestedMapEntries[entry.key.toString()] = parents;
      }
    }
    final recordEntries = <String, List<Map<String, dynamic>>>{};
    final rawRecords = raw['recordEntries'];
    if (rawRecords is Map) {
      for (final entry in rawRecords.entries) {
        if (entry.value is List) {
          recordEntries[entry.key.toString()] = (entry.value as List)
              .whereType<Map>()
              .map(_stringDynamicMap)
              .toList(growable: false);
        }
      }
    }
    return AppSettingsDeletionTargets(
      exactValues: exactValues,
      mapEntries: mapEntries,
      listEntries: listEntries,
      nestedMapEntries: nestedMapEntries,
      recordEntries: recordEntries,
    );
  }

  static Map<String, dynamic> _stringDynamicMap(dynamic raw) {
    if (raw is! Map) return <String, dynamic>{};
    return {
      for (final entry in raw.entries) entry.key.toString(): entry.value,
    };
  }
}

/// Keys resolved during the read-only planning phase.
///
/// The lifecycle runner stores these keys in the pending operation so a retry
/// continues the original scope instead of discovering newly-created records.
class DeletionTargets {
  final Map<String, List<dynamic>> boxKeys;
  final List<String> relationshipIds;
  final AppSettingsDeletionTargets appSettings;

  const DeletionTargets({
    this.boxKeys = const {},
    this.relationshipIds = const [],
    this.appSettings = const AppSettingsDeletionTargets(),
  });

  List<dynamic> keysFor(String box) =>
      List<dynamic>.from(boxKeys[box] ?? const <dynamic>[]);

  Map<String, dynamic> toMap() => {
        'boxKeys': {
          for (final entry in boxKeys.entries)
            entry.key: List<dynamic>.from(entry.value),
        },
        'relationshipIds': List<String>.from(relationshipIds),
        'appSettings': appSettings.toMap(),
      };

  factory DeletionTargets.fromMap(dynamic raw) {
    if (raw is! Map) return const DeletionTargets();
    final rawKeys = raw['boxKeys'];
    final boxKeys = <String, List<dynamic>>{};
    if (rawKeys is Map) {
      for (final entry in rawKeys.entries) {
        if (entry.value is List) {
          boxKeys[entry.key.toString()] =
              List<dynamic>.from(entry.value as List);
        }
      }
    }
    final relationshipIds = raw['relationshipIds'] is List
        ? (raw['relationshipIds'] as List)
            .map((value) => value.toString())
            .toList(growable: false)
        : const <String>[];
    return DeletionTargets(
      boxKeys: boxKeys,
      relationshipIds: relationshipIds,
      appSettings: AppSettingsDeletionTargets.fromMap(raw['appSettings']),
    );
  }
}

class DeletionPlan {
  final String title;

  /// Records deleted by the selected policy/scope by default.
  final Map<String, int> counts;

  /// Records that are only deleted when the optional associated-data switch is
  /// enabled, or when the more destructive character policy is selected.
  final Map<String, int> optionalCounts;

  /// Records deliberately retained by the selected operation.
  final Map<String, int> retainedCounts;
  final DeletionTargets targets;

  const DeletionPlan({
    required this.title,
    required this.counts,
    this.optionalCounts = const {},
    this.retainedCounts = const {},
    this.targets = const DeletionTargets(),
  });

  int count(String key) => counts[key] ?? 0;

  int optionalCount(String key) => optionalCounts[key] ?? 0;

  int retainedCount(String key) => retainedCounts[key] ?? 0;
}

class DataLifecycleResult {
  final List<String> incompleteItems;
  final int reclaimedFiles;
  final int reclaimedBytes;

  const DataLifecycleResult({
    this.incompleteItems = const [],
    this.reclaimedFiles = 0,
    this.reclaimedBytes = 0,
  });

  bool get isComplete => incompleteItems.isEmpty;
}

class MediaUsage {
  final int totalFiles;
  final int totalBytes;
  final int orphanFiles;
  final int orphanBytes;
  final List<String> orphanPaths;

  const MediaUsage({
    required this.totalFiles,
    required this.totalBytes,
    required this.orphanFiles,
    required this.orphanBytes,
    this.orphanPaths = const [],
  });

  static const empty = MediaUsage(
    totalFiles: 0,
    totalBytes: 0,
    orphanFiles: 0,
    orphanBytes: 0,
  );
}
