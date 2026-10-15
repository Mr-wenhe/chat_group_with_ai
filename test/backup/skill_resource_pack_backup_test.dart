import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/character_skill.dart';
import 'package:chat_group/features/agentic/skill_resource_pack.dart';
import 'package:chat_group/features/agentic/skill_resource_pack_store.dart';
import 'package:chat_group/features/backup/backup_models.dart';
import 'package:chat_group/features/backup/backup_restore_service.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import '../helpers/lifecycle_hive.dart';

class _TestDatabaseService extends DatabaseService {
  final String testDataPath;

  _TestDatabaseService(this.testDataPath);

  @override
  String? get dataDirPath => testDataPath;
}

void main() {
  test('资源包随完整、配置、会话备份往返，恢复后不继承验证和权限', () async {
    final sourceHive = await openLifecycleHive();
    final tempRoot =
        await Directory.systemTemp.createTemp('skill_backup_staging_');
    Directory? targetHive;
    PreparedBackup? prepared;
    _TestDatabaseService? sourceDb;
    _TestDatabaseService? targetDb;
    addTearDown(() async {
      await prepared?.dispose();
      if (targetHive != null) {
        await closeLifecycleHive(targetHive, targetDb);
      } else {
        await closeLifecycleHive(sourceHive, sourceDb);
      }
      if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
    });

    sourceDb = _TestDatabaseService(sourceHive.path);
    final sourceMedia = Directory('${sourceDb.dataDirPath}/media');
    await sourceMedia.create(recursive: true);
    final character = testCharacter('skill-backup-character');
    final group = ChatGroup(
      id: 'skill-backup-group',
      name: '测试群',
      theme: '备份',
      aiCharacterIds: [character.id],
    );
    await sourceDb.aiCharacterBox.put(character.id, character);
    await sourceDb.chatGroupBox.put(group.id, group);
    final pack = SkillResourcePack.fromGatewayJson(_gatewayPack());
    await SkillResourcePackStore.forDatabase(sourceDb).save(pack);
    final skill = CharacterSkill(
      characterId: character.id,
      name: pack.name,
      domain: pack.domain,
      description: pack.description,
      instructions: pack.instructions,
      requiredPermissions: const [],
      resourcePackId: pack.id,
    );
    character.skillIds = [skill.id];
    await sourceDb.characterSkillBox.put(skill.id, skill);
    await sourceDb.aiCharacterBox.put(character.id, character);

    final sourceService = BackupRestoreService(
      db: sourceDb,
      mediaDirectory: sourceMedia,
      tempRoot: tempRoot,
    );
    final conversationBackup = File('${tempRoot.path}/conversation.cgbak');
    for (final selection in [
      const BackupSelection.all(),
      const BackupSelection.configurationOnly(),
      BackupSelection.conversation(group.id),
    ]) {
      final destination = selection.scope == BackupScope.conversation
          ? conversationBackup
          : File('${tempRoot.path}/${selection.scope.name}.cgbak');
      await sourceService.createBackup(
        destination: destination,
        selection: selection,
      );
      final inspection = await sourceService.inspect(destination);
      addTearDown(inspection.dispose);
      expect(
        inspection.manifest.files,
        contains('data/skill_resource_packs.json'),
      );
      final records = (jsonDecode(await File(
        '${inspection.stagingDirectory.path}/data/skill_resource_packs.json',
      ).readAsString()) as List)
          .cast<Map>();
      expect(records, hasLength(1));
      expect(records.single['value']['verified'], isFalse);
    }

    prepared = await sourceService.inspect(conversationBackup);
    sourceDb.dispose();
    sourceDb = null;
    await closeLifecycleHive(sourceHive);

    targetHive = await openLifecycleHive();
    targetDb = _TestDatabaseService(targetHive.path);
    final targetMedia = Directory('${targetDb.dataDirPath}/media');
    await targetMedia.create(recursive: true);
    final restore = BackupRestoreService(
      db: targetDb,
      mediaDirectory: targetMedia,
      tempRoot: tempRoot,
    );
    await restore.restore(prepared,
        strategy: RestoreConflictStrategy.emptyOnly);

    final restoredSkill = targetDb.characterSkillBox.values.single;
    final restoredCharacter = targetDb.aiCharacterBox.get(character.id)!;
    expect(restoredSkill.resourcePackId, pack.id);
    expect(restoredSkill.requiredPermissions, isEmpty);
    expect(restoredCharacter.skillIds, isNot(contains(restoredSkill.id)));
    final restoredPacks = await SkillResourcePackStore.forDatabase(targetDb)
        .backupRecords([pack.id]);
    expect(restoredPacks.missing, isEmpty);
    expect(restoredPacks.records.single['value']['verified'], isFalse);
    final reference =
        await SkillResourcePackStore.forDatabase(targetDb).readResource(
      packId: pack.id,
      path: 'references/guide.md',
      taskId: 'restore-read',
      conversationId: 'dm:${character.id}',
      characterId: character.id,
    );
    expect(reference.content, 'Reference text.');
  });
}

Map<String, dynamic> _gatewayPack() {
  final skill = [
    '---',
    'name: Backup skill',
    'description: Referenced script and documentation',
    'license: MIT',
    'metadata:',
    '  domain: testing',
    '---',
    'Read [the guide](references/guide.md) and run [the script](scripts/check.sh).',
  ].join('\n');
  const script = '#!/bin/sh\nexit 0\n';
  const reference = 'Reference text.';
  return {
    'owner': 'sample-owner',
    'repo': 'sample-repo',
    'path': 'skills/backup',
    'commit': List.filled(40, 'b').join(),
    'license': 'MIT',
    'files': [
      _file('SKILL.md', skill),
      _file('references/guide.md', reference),
      _file('scripts/check.sh', script),
    ],
  };
}

Map<String, dynamic> _file(String path, String content) {
  final bytes = Uint8List.fromList(utf8.encode(content));
  return {
    'path': path,
    'encoding': 'utf8',
    'content': content,
    'sha256': sha256.convert(bytes).toString(),
  };
}
