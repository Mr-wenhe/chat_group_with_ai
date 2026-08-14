import 'package:chat_group/core/database/database_service.dart';
import 'dart:math';

import 'package:chat_group/core/models/permanent_memory.dart';
import 'package:chat_group/core/models/relationship_event.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/core/models/user_profile.dart';
import 'package:uuid/uuid.dart';

part 'memory_migrator_legacy.dart';
part 'memory_migrator_relationships.dart';
part 'memory_migrator_storage.dart';

/// UUID v5 URL namespace constant (RFC 4122).
const _kUuidNamespaceUrl = '6ba7b811-9dad-11d1-80b4-00c04fd430c8';

/// 迁移 schema marker 版本；修复旧记忆主体元数据后递增，确保旧 marker 会重跑。
const _kMemoryMigratorSchemaVersion = 3;

/// app_settings 中存储迁移完成的 marker key。
const _kMemoryMigrationMarkerKey = 'memory_migration_marker_v1';

/// 迁移报告。
class MemoryMigrationReport {
  final bool alreadyMigrated;
  final int userProfileCreated;
  final int permanentMemoriesCreated;
  final int relationshipSnapshotsCreated;
  final int relationshipEventsCreated;
  final String? selectedOwnerName;
  final List<String> warnings;

  const MemoryMigrationReport({
    required this.alreadyMigrated,
    required this.userProfileCreated,
    required this.permanentMemoriesCreated,
    required this.relationshipSnapshotsCreated,
    required this.relationshipEventsCreated,
    this.selectedOwnerName,
    this.warnings = const [],
  });

  bool get hasChanges =>
      userProfileCreated > 0 ||
      permanentMemoriesCreated > 0 ||
      relationshipSnapshotsCreated > 0 ||
      relationshipEventsCreated > 0;
}

/// 幂等迁移：将旧数据结构迁移到全局永久记忆系统。
///
/// 可安全重复执行；已完成的迁移不会重复生成记录。
class MemoryMigrator {
  /// app_settings 中保存的安全迁移诊断摘要 key。
  static const diagnosticKey = 'memory_migration_v1_diagnostic';

  final DatabaseService _db;
  final Uuid _uuid;
  final int _schemaVersion;
  final Future<void> Function(PermanentMemory memory)? savePermanentMemory;

  MemoryMigrator(
    this._db, {
    Uuid? uuid,
    int? schemaVersion,
    this.savePermanentMemory,
  })  : _uuid = uuid ?? const Uuid(),
        _schemaVersion = schemaVersion ?? _kMemoryMigratorSchemaVersion;

  Future<MemoryMigrationReport> migrate({bool force = false}) async {
    final marker = _readMarker();
    if (!force && marker != null && _parseVersion(marker) == _schemaVersion) {
      return const MemoryMigrationReport(
        alreadyMigrated: true,
        userProfileCreated: 0,
        permanentMemoriesCreated: 0,
        relationshipSnapshotsCreated: 0,
        relationshipEventsCreated: 0,
      );
    }

    final warnings = <String>[];
    int userProfiles = 0;
    int memories = 0;
    int relSnapshots = 0;
    int relEvents = 0;
    String? selectedOwnerName;
    final reasonCodes = <String>{};

    try {
      final profileResult = await _migrateUserProfile();
      userProfiles = profileResult.created;
      selectedOwnerName = profileResult.selectedName;
      if (profileResult.warning != null) {
        warnings.add(profileResult.warning!);
        reasonCodes.add('owner_name_conflict');
      }

      memories += await _migrateCharacterMemories();
      final summaryResult = await _migrateMemorySummaries();
      memories += summaryResult.created;
      warnings.addAll(summaryResult.warnings);
      if (summaryResult.failedCharacterIds.isNotEmpty) {
        reasonCodes.add('summary_migration_failed');
      }

      final repairFailures = await _repairLegacyUserSubjects();
      if (repairFailures > 0) {
        warnings.add('旧版永久记忆主体修复失败，下次启动将重试。');
        reasonCodes.add('legacy_subject_repair_failed');
      }

      final relResult = await _migrateRelationshipStates();
      relSnapshots = relResult.snapshotsCreated;
      relEvents = relResult.eventsCreated;
      warnings.addAll(relResult.warnings);
      if (relResult.warnings.isNotEmpty) {
        reasonCodes.add('relationship_history_loss');
      }

      final migrationCompleted =
          summaryResult.failedCharacterIds.isEmpty && repairFailures == 0;
      if (migrationCompleted) {
        await _writeMarker({
          'version': _schemaVersion,
          'migratedAt': DateTime.now().toUtc().toIso8601String(),
          'stats': {
            'userProfiles': userProfiles,
            'permanentMemories': memories,
            'relationshipSnapshots': relSnapshots,
            'relationshipEvents': relEvents,
          },
        });
      }

      final report = MemoryMigrationReport(
        alreadyMigrated: false,
        userProfileCreated: userProfiles,
        permanentMemoriesCreated: memories,
        relationshipSnapshotsCreated: relSnapshots,
        relationshipEventsCreated: relEvents,
        selectedOwnerName: selectedOwnerName,
        warnings: warnings,
      );
      await _writeDiagnostic(
        status: migrationCompleted ? 'completed' : 'partial',
        warningCount: warnings.length,
        reasonCodes: reasonCodes,
        report: report,
      );
      return report;
    } on Object {
      await _writeDiagnostic(
        status: 'failed',
        warningCount: 1,
        reasonCodes: const {'storage_failure'},
        userProfileCreated: userProfiles,
        permanentMemoriesCreated: memories,
        relationshipSnapshotsCreated: relSnapshots,
        relationshipEventsCreated: relEvents,
      );
      rethrow;
    }
  }
}

class _ProfileResult {
  final int created;
  final String? selectedName;
  final String? warning;

  const _ProfileResult({
    required this.created,
    this.selectedName,
    this.warning,
  });
}

class _MemorySummaryMigrationResult {
  final int created;
  final List<String> failedCharacterIds;
  final List<String> warnings;

  const _MemorySummaryMigrationResult({
    required this.created,
    required this.failedCharacterIds,
    required this.warnings,
  });
}

class _RelationshipMigrationResult {
  final int snapshotsCreated;
  final int eventsCreated;
  final List<String> warnings;

  const _RelationshipMigrationResult({
    required this.snapshotsCreated,
    required this.eventsCreated,
    this.warnings = const [],
  });
}
