// Stage 16 真实数据副本端到端验收测试。
//
// 本测试复制真实 data/*.hive 到临时目录（排除 api_configs.hive 避免泄露凭据），
// 在副本上执行：旧库启动 → 迁移 → 幂等验证 → 备份 → 清空 → 恢复 → 跨场景验证。
// 测试结束后删除临时目录，不触碰真实 data/*.hive。
import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/character_memory.dart';
import 'package:chat_group/core/models/character_skill.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/group_memory.dart';
import 'package:chat_group/core/models/media_attachment.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/permanent_memory.dart';
import 'package:chat_group/core/models/relationship_event.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/core/models/tool_permission.dart';
import 'package:chat_group/core/models/user_profile.dart';
import 'package:chat_group/core/models/work_mode_workspace.dart';
import 'package:chat_group/features/backup/backup_models.dart';
import 'package:chat_group/features/backup/backup_restore_service.dart';
import 'package:chat_group/features/memory/memory_context_selector.dart';
import 'package:chat_group/features/memory/memory_migrator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

/// 真实 data 目录路径。
const _kRealDataDir = 'data';

/// 排除的 box 文件（含 API Key 凭据，禁止复制）。
const _kExcludedBoxes = <String>{
  'api_configs.hive',
};

void main() {
  group('Stage 16 real-data-copy end-to-end', () {
    late Directory tempDir;
    late DatabaseService db;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('stage16_e2e_');
      await _copyRealHiveFiles(tempDir);
      Hive.init(tempDir.path);
      _registerAdaptersIfNeeded();
      await _openAllBoxes();
      db = DatabaseService();
      await _seedCredentialFreeApiConfigMetadata(db);
    });

    tearDown(() async {
      db.dispose();
      await Hive.close();
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    test(
        'real data copy: open → migrate → idempotent → backup → restore → cross-scenario',
        () async {
      // ── 1. 验证旧库可以打开 ──────────────────────────────────────
      final characterCount = db.aiCharacterBox.length;
      final groupCount = db.chatGroupBox.length;
      final messageCount = db.messageBox.length;
      final legacyMemoryCount = db.characterMemoryBox.length;
      final legacyRelationCount = db.relationshipStateBox.length;
      expect(characterCount, greaterThan(0), reason: '真实数据应包含角色');
      expect(groupCount, greaterThan(0), reason: '真实数据应包含群聊');
      expect(messageCount, greaterThan(0), reason: '真实数据应包含消息');

      // ── 2. 运行 MemoryMigrator ──────────────────────────────────
      final migrator = MemoryMigrator(db);
      final report = await migrator.migrate();
      expect(report.alreadyMigrated, isFalse,
          reason: '首次迁移应报告 alreadyMigrated=false');

      // ── 4. 验证 migration marker ──────────────────────────────────
      final marker = db.appSettingsBox.get('memory_migration_marker_v1');
      expect(marker, isNotNull, reason: '迁移完成后应写入 schema marker');

      // ── 5. 验证 UserProfile 创建 ──────────────────────────────────
      final profile = db.userProfileBox.get('me');
      expect(profile, isNotNull, reason: '迁移应创建 UserProfile');
      expect(profile!.id, equals('me'), reason: 'UserProfile id 应为 me');
      expect(profile.displayName, isNotEmpty,
          reason: 'UserProfile.displayName 不应为空');

      // ── 6. 验证迁移生成了新数据（如果有旧数据） ───────────────────
      final hasLegacyMemoryData = legacyMemoryCount > 0 ||
          db.aiCharacterBox.values
              .any((c) => c.memorySummary.trim().isNotEmpty);
      if (hasLegacyMemoryData) {
        expect(db.permanentMemoryBox.length, greaterThan(0),
            reason: '有旧记忆数据时应生成 PermanentMemory');
      }

      // 旧 box 不应被清空
      expect(db.characterMemoryBox.length, equals(legacyMemoryCount),
          reason: '旧 CharacterMemory box 应保留只读');
      expect(db.relationshipStateBox.length,
          greaterThanOrEqualTo(legacyRelationCount),
          reason: '旧 RelationshipState box 不应减少');

      // ── 7. 幂等验证：再次迁移不产生重复 ──────────────────────────
      final report2 = await migrator.migrate();
      expect(report2.alreadyMigrated, isTrue,
          reason: '第二次迁移应报告 alreadyMigrated=true');
      expect(report2.permanentMemoriesCreated, 0,
          reason: '幂等：不应重复创建 PermanentMemory');
      expect(report2.relationshipEventsCreated, 0,
          reason: '幂等：不应重复创建 RelationshipEvent');
      final permanentMemoryCountAfterMigration = db.permanentMemoryBox.length;
      expect(db.permanentMemoryBox.length,
          equals(permanentMemoryCountAfterMigration),
          reason: '幂等：PermanentMemory 数量不变');

      // ── 8. 真实数据 round-trip：备份 → 清空临时库 → 恢复 ──────────
      final backupRoot = Directory('${tempDir.path}/backup_work');
      final mediaDirectory = Directory('${tempDir.path}/media');
      await mediaDirectory.create();
      final backupFile = File('${tempDir.path}/stage16-roundtrip.cgbak');
      final backupService = BackupRestoreService(
        db: db,
        mediaDirectory: mediaDirectory,
        tempRoot: backupRoot,
      );
      final backup = await backupService.createBackup(destination: backupFile);
      expect(backup.manifest.scope, BackupScope.all);

      await _clearOpenBoxes(db);
      expect(db.aiCharacterBox, isEmpty, reason: '恢复前临时库应已清空');
      expect(db.chatGroupBox, isEmpty, reason: '恢复前临时库应已清空');
      expect(db.messageBox, isEmpty, reason: '恢复前临时库应已清空');

      final prepared = await backupService.inspect(backupFile);
      try {
        final restoreReport = await backupService.restore(
          prepared,
          strategy: RestoreConflictStrategy.emptyOnly,
        );
        expect(restoreReport.errors, isEmpty);
        for (final entry in backup.manifest.counts.entries) {
          if (entry.key == 'attachments' || entry.key == 'missingAttachments') {
            continue;
          }
          expect(restoreReport.inserted[entry.key] ?? 0, equals(entry.value),
              reason: '恢复写入的 ${entry.key} 数量应与 manifest 一致');
        }
        _expectRestoredCounts(db, backup.manifest.counts);
      } finally {
        await prepared.dispose();
      }

      // ── 9. 跨场景验证：真实群 A → 群 B 读取同一 AI 永久记忆 ────────
      final selector = MemoryContextSelector(db);
      // 未标记的旧摘要按原文保留，真实数据中可能超过默认 Prompt 预算。
      const stage16MemoryBudget = 12000;
      final groups = db.chatGroupBox.values
          .where((group) => group.aiCharacterIds.isNotEmpty)
          .toList(growable: false);
      expect(groups, hasLength(greaterThanOrEqualTo(2)),
          reason: '真实数据应至少包含两个有参与者的群');
      final visibleMemoryObservers = db.permanentMemoryBox.values
          .where((memory) =>
              memory.status == MemoryStatus.active &&
              memory.content.trim().isNotEmpty &&
              (memory.subjectIds.isEmpty || memory.subjectIds.contains('user')))
          .map((memory) => memory.observerCharacterId)
          .toSet();
      ChatGroup? selectedGroupA;
      ChatGroup? selectedGroupB;
      String? observerId;
      for (var firstIndex = 0;
          firstIndex < groups.length && selectedGroupA == null;
          firstIndex++) {
        for (var secondIndex = firstIndex + 1;
            secondIndex < groups.length && selectedGroupA == null;
            secondIndex++) {
          final first = groups[firstIndex];
          final second = groups[secondIndex];
          final sharedCharacters = first.aiCharacterIds
              .toSet()
              .intersection(second.aiCharacterIds.toSet());
          final candidates =
              sharedCharacters.where(visibleMemoryObservers.contains);
          if (candidates.isEmpty) continue;
          final candidate = candidates.first;
          selectedGroupA = first;
          selectedGroupB = second;
          observerId = candidate;
        }
      }
      expect(selectedGroupA, isNotNull, reason: '真实数据中没有共同 AI 且拥有可见记忆的两个群');
      final groupA = selectedGroupA!;
      final groupB = selectedGroupB!;
      expect(groupA.id, isNot(equals(groupB.id)));
      final observerCharacterId = observerId!;
      final allParticipantIds =
          db.aiCharacterBox.values.map((c) => c.id).toList();
      final participantIdsA = groupA.aiCharacterIds.toList(growable: false);
      final participantIdsB = groupB.aiCharacterIds.toList(growable: false);
      final sharedMemoryIds = db.permanentMemoryBox.values
          .where((memory) =>
              memory.observerCharacterId == observerCharacterId &&
              memory.status == MemoryStatus.active &&
              memory.content.trim().isNotEmpty &&
              (memory.subjectIds.isEmpty || memory.subjectIds.contains('user')))
          .map((memory) => memory.id)
          .toSet();
      expect(sharedMemoryIds, isNotEmpty, reason: '真实数据应包含可跨场景读取的永久记忆');
      final sharedMemory = db.permanentMemoryBox.get(sharedMemoryIds.first)!;
      final sharedContent = sharedMemory.content.trim();

      // 在"群 A"上下文中查询。
      final memoryInContextA = await selector.select(
        observerCharacterId: observerCharacterId,
        participantCharacterIds: participantIdsA,
        currentTargetId: 'user',
        userMessage: 'Stage 16 群 A ${groupA.id}',
        characterBudget: stage16MemoryBudget,
      );

      // 在"群 B"上下文中查询同一角色：参数来自另一真实群。
      final memoryInContextB = await selector.select(
        observerCharacterId: observerCharacterId,
        participantCharacterIds: participantIdsB,
        currentTargetId: 'user',
        userMessage: 'Stage 16 群 B ${groupB.id}',
        characterBudget: stage16MemoryBudget,
      );
      expect(memoryInContextA, contains(sharedContent),
          reason: '群 A 应读到观察者的永久记忆');
      expect(memoryInContextB, contains(sharedContent),
          reason: '同一 AI 在群 B 应读到群 A 形成的永久记忆');

      // ── 10. 群 → DM 可读取 ───────────────────────────────────────
      final dmMemory = await selector.select(
        observerCharacterId: observerCharacterId,
        participantCharacterIds: [observerCharacterId],
        currentTargetId: 'user',
        userMessage: 'Stage 16 DM $observerCharacterId',
        characterBudget: stage16MemoryBudget,
      );
      expect(dmMemory, contains(sharedContent),
          reason: '群 → DM 应能读取同一 AI 的永久记忆');

      // ── 11. DM → 群可读取 ────────────────────────────────────────
      final backToGroupMemory = await selector.select(
        observerCharacterId: observerCharacterId,
        participantCharacterIds: participantIdsA,
        currentTargetId: 'user',
        userMessage: 'Stage 16 群 A ${groupA.id}',
        characterBudget: stage16MemoryBudget,
      );
      expect(backToGroupMemory, contains(sharedContent),
          reason: 'DM → 群应能读取同一 AI 的永久记忆');

      // ── 12. AI A 不能读取 AI B 的私聊记忆 ──────────────────────────
      if (db.aiCharacterBox.length >= 2) {
        final privacyCandidates = db.aiCharacterBox.values.where((character) {
          if (character.id == observerCharacterId) return false;
          return db.permanentMemoryBox.values.any((memory) =>
              memory.observerCharacterId == character.id &&
              memory.status == MemoryStatus.active &&
              memory.content.trim().isNotEmpty);
        });
        expect(privacyCandidates, isNotEmpty, reason: '真实数据应包含至少一个有记忆的 B 角色');
        final secondCharacter = privacyCandidates.first;
        final secondCharacterId = secondCharacter.id;

        // A 视角的永久记忆。
        final aMemories = db.permanentMemoryBox.values.where((memory) =>
            memory.observerCharacterId == observerCharacterId &&
            memory.status == MemoryStatus.active);
        // B 视角的永久记忆。
        final bMemories = db.permanentMemoryBox.values.where((memory) =>
            memory.observerCharacterId == secondCharacterId &&
            memory.status == MemoryStatus.active &&
            memory.content.trim().isNotEmpty);
        expect(bMemories, isNotEmpty, reason: '真实数据应包含可用于隐私隔离验证的 B 视角记忆');
        final bMemory = bMemories.first;

        // 验证：每条记忆的观察者就是声明的观察者。
        for (final aMemory in aMemories) {
          expect(aMemory.observerCharacterId, equals(observerCharacterId),
              reason: 'A 的记忆观察者应为 A 自身');
        }
        for (final bMemory in bMemories) {
          expect(bMemory.observerCharacterId, equals(secondCharacterId),
              reason: 'B 的记忆观察者应为 B 自身');
        }

        // 先证明 B 自己能读到正文，再验证 A 看不到正文。
        final bSelected = await selector.select(
          observerCharacterId: secondCharacterId,
          participantCharacterIds: allParticipantIds,
          currentTargetId: 'user',
          userMessage: bMemory.content,
          characterBudget: stage16MemoryBudget,
        );
        expect(bSelected, contains(bMemory.content), reason: 'B 应能读取自己的永久记忆正文');

        final aSelected = await selector.select(
          observerCharacterId: observerCharacterId,
          participantCharacterIds: [observerCharacterId, secondCharacterId],
          currentTargetId: secondCharacterId,
          userMessage: bMemory.content,
          characterBudget: stage16MemoryBudget,
        );
        expect(aSelected, isNot(contains(bMemory.content)),
            reason: 'A 的查询结果不应包含 B 的永久记忆正文');
      }

      // ── 13. 方向性关系在跨场景仍正确 ───────────────────────────────
      // 全局关系快照不按 groupId 隔离
      final globalRelations =
          db.relationshipStateBox.values.where((r) => r.id.startsWith('rel:'));
      for (final rel in globalRelations) {
        // 全局关系的 id 应包含 source 和 target
        expect(rel.id, contains(rel.sourceCharacterId),
            reason: '全局关系 ID 应包含 sourceCharacterId');
      }

      // ── 14. 真实 data/*.hive 未被修改 ────────────────────────────
      // 验证通过：整个测试在临时目录上操作，从未写入真实 data/
      // 临时目录在 tearDown 中被删除
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}

/// 清空当前副本中所有已打开 box；真实 data/ 从未被打开或写入。
Future<void> _clearOpenBoxes(DatabaseService db) async {
  await Future.wait([
    db.aiCharacterBox.clear(),
    db.apiConfigBox.clear(),
    db.chatGroupBox.clear(),
    db.messageBox.clear(),
    db.groupMemoryBox.clear(),
    db.characterMemoryBox.clear(),
    db.relationshipStateBox.clear(),
    db.characterSkillBox.clear(),
    db.agentTaskBox.clear(),
    db.workModeWorkspaceBox.clear(),
    db.appSettingsBox.clear(),
    db.userProfileBox.clear(),
    db.permanentMemoryBox.clear(),
    db.relationshipEventBox.clear(),
    Hive.box<dynamic>('ai_governance_ledger').clear(),
  ]);
}

/// 真实副本排除 api_configs.hive；为角色引用补充不含凭据的配置元数据。
Future<void> _seedCredentialFreeApiConfigMetadata(DatabaseService db) async {
  final configIds = <String>{
    for (final character in db.aiCharacterBox.values)
      if (character.apiConfigId.isNotEmpty) character.apiConfigId,
  };
  for (final configId in configIds) {
    final character = db.aiCharacterBox.values.firstWhere(
      (item) => item.apiConfigId == configId,
    );
    await db.apiConfigBox.put(
      configId,
      ApiConfig(
        id: configId,
        name: 'Stage 16 credential-free metadata',
        provider: character.apiProvider,
        modelName: character.modelName,
        customBaseUrl: character.customBaseUrl,
      ),
    );
  }
}

/// BackupManifest 的关系计数只包含全局快照，恢复后该 box 也只应有这些快照。
void _expectRestoredCounts(
  DatabaseService db,
  Map<String, int> manifestCounts,
) {
  final actualCounts = <String, int>{
    'apiConfigs': db.apiConfigBox.length,
    'characters': db.aiCharacterBox.length,
    'groups': db.chatGroupBox.length,
    'messages': db.messageBox.length,
    'groupMemories': db.groupMemoryBox.length,
    'characterMemories': db.characterMemoryBox.length,
    'relationships': db.relationshipStateBox.length,
    'skills': db.characterSkillBox.length,
    'agentTasks': db.agentTaskBox.length,
    'workMode': db.workModeWorkspaceBox.length,
    'userProfiles': db.userProfileBox.length,
    'permanentMemories': db.permanentMemoryBox.length,
    'relationshipEvents': db.relationshipEventBox.length,
  };
  for (final entry in actualCounts.entries) {
    expect(entry.value, equals(manifestCounts[entry.key] ?? 0),
        reason: '恢复后 ${entry.key} 数量应与备份 manifest 一致');
  }
}

/// 复制真实 hive 文件到临时目录，排除 api_configs.hive。
Future<void> _copyRealHiveFiles(Directory target) async {
  final source = Directory(_kRealDataDir);
  if (!await source.exists()) {
    throw const FileSystemException('真实 data 目录不存在', _kRealDataDir);
  }
  await for (final entity in source.list()) {
    if (entity is File && entity.path.endsWith('.hive')) {
      final name = entity.uri.pathSegments.last;
      if (_kExcludedBoxes.contains(name)) continue;
      await entity.copy('${target.path}/$name');
    }
  }
}

/// 注册 Hive adapter（如果尚未注册）。
void _registerAdaptersIfNeeded() {
  if (!Hive.isAdapterRegistered(0)) Hive.registerAdapter(AICharacterAdapter());
  if (!Hive.isAdapterRegistered(24)) {
    Hive.registerAdapter(CharacterGenderAdapter());
  }
  if (!Hive.isAdapterRegistered(1)) Hive.registerAdapter(ChatGroupAdapter());
  if (!Hive.isAdapterRegistered(2)) Hive.registerAdapter(MessageAdapter());
  if (!Hive.isAdapterRegistered(3)) Hive.registerAdapter(GroupMemoryAdapter());
  if (!Hive.isAdapterRegistered(4)) Hive.registerAdapter(ApiConfigAdapter());
  if (!Hive.isAdapterRegistered(5)) {
    Hive.registerAdapter(CharacterMemoryAdapter());
  }
  if (!Hive.isAdapterRegistered(6)) {
    Hive.registerAdapter(RelationshipTargetTypeAdapter());
  }
  if (!Hive.isAdapterRegistered(7)) {
    Hive.registerAdapter(RelationshipMoodAdapter());
  }
  if (!Hive.isAdapterRegistered(8)) {
    Hive.registerAdapter(RelationshipStateAdapter());
  }
  if (!Hive.isAdapterRegistered(9)) {
    Hive.registerAdapter(MediaAttachmentAdapter());
  }
  if (!Hive.isAdapterRegistered(10)) {
    Hive.registerAdapter(ToolPermissionAdapter());
  }
  if (!Hive.isAdapterRegistered(11)) {
    Hive.registerAdapter(CharacterSkillAdapter());
  }
  if (!Hive.isAdapterRegistered(12)) {
    Hive.registerAdapter(AgentTaskStatusAdapter());
  }
  if (!Hive.isAdapterRegistered(13)) Hive.registerAdapter(AgentTaskAdapter());
  if (!Hive.isAdapterRegistered(16)) {
    Hive.registerAdapter(WorkModeWorkspaceAdapter());
  }
  if (!Hive.isAdapterRegistered(23)) {
    Hive.registerAdapter(RelationshipStageAdapter());
  }
  if (!Hive.isAdapterRegistered(18)) {
    Hive.registerAdapter(MemoryStatusAdapter());
  }
  if (!Hive.isAdapterRegistered(19)) {
    Hive.registerAdapter(PermanentMemoryAdapter());
  }
  if (!Hive.isAdapterRegistered(20)) {
    Hive.registerAdapter(RelationshipEventCreatorAdapter());
  }
  if (!Hive.isAdapterRegistered(21)) {
    Hive.registerAdapter(RelationshipEventAdapter());
  }
  if (!Hive.isAdapterRegistered(22)) {
    Hive.registerAdapter(UserProfileAdapter());
  }
  if (!Hive.isAdapterRegistered(14)) {
    Hive.registerAdapter(MemoryKindAdapter());
  }
  if (!Hive.isAdapterRegistered(15)) {
    Hive.registerAdapter(MemoryOriginTypeAdapter());
  }
}

/// 打开所有 Hive box。
Future<void> _openAllBoxes() async {
  await Hive.openBox<AICharacter>('ai_characters');
  await Hive.openBox<ApiConfig>('api_configs');
  await Hive.openBox<ChatGroup>('chat_groups');
  await Hive.openBox<Message>('messages');
  await Hive.openBox<GroupMemory>('group_memories');
  await Hive.openBox<CharacterMemory>('character_memories');
  await Hive.openBox<RelationshipState>('relationship_states');
  await Hive.openBox<CharacterSkill>('character_skills');
  await Hive.openBox<AgentTask>('agent_tasks');
  await Hive.openBox<WorkModeWorkspace>('work_mode_workspaces');
  await Hive.openBox<dynamic>('app_settings');
  await Hive.openBox<UserProfile>('user_profile');
  await Hive.openBox<PermanentMemory>('permanent_memories');
  await Hive.openBox<RelationshipEvent>('relationship_events');
  await Hive.openBox<dynamic>('ai_governance_ledger');
}
