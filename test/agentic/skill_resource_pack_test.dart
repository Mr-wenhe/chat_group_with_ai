import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/character_skill.dart';
import 'package:chat_group/features/agentic/skill_resource_pack.dart';
import 'package:chat_group/features/agentic/skill_resource_pack_store.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../helpers/lifecycle_hive.dart';

void main() {
  group('GitHub 技能资源包解析', () {
    test('固定提交、引用资源和 allowed-tools 作为请求元数据解析', () {
      final pack = SkillResourcePack.fromGatewayJson(_gatewayPack());

      expect(pack.commit, _commit);
      expect(pack.licenseStatus, 'recognized');
      expect(pack.requestedTools, ['command.run', 'system.install']);
      expect(pack.file('references/guide.md'), isNotNull);
      expect(pack.file('scripts/check.sh'), isNotNull);
    });

    test('损坏摘要、路径穿越、外链、缺失引用、凭据和 YAML alias 均被拒绝', () {
      final badDigest = _gatewayPack();
      (badDigest['files'] as List<Map<String, dynamic>>).first['sha256'] =
          '0' * 64;
      expect(() => SkillResourcePack.fromGatewayJson(badDigest),
          throwsFormatException);

      expect(
        () => SkillResourcePack.fromGatewayJson(
          _gatewayPack(extraFiles: [_file('../outside.sh', 'echo bad')]),
        ),
        throwsFormatException,
      );
      expect(
        () => SkillResourcePack.fromGatewayJson(
          _gatewayPack(markdown: _skillMarkdown(body: '[外链](https://x.test)')),
        ),
        throwsFormatException,
      );
      expect(
        () => SkillResourcePack.fromGatewayJson(
          _gatewayPack(
              markdown: _skillMarkdown(body: '[缺失](references/no.md)')),
        ),
        throwsFormatException,
      );
      expect(
        () => SkillResourcePack.fromGatewayJson(
          _gatewayPack(extraFiles: [
            _file('scripts/token.sh', 'echo sk-1234567890123456789012'),
          ]),
        ),
        throwsFormatException,
      );
      expect(
        () => SkillResourcePack.fromGatewayJson(
          _gatewayPack(
            markdown: _skillMarkdown(
              yamlSuffix: 'allowed-tools: &tools [command.run]',
            ),
          ),
        ),
        throwsFormatException,
      );
    });

    test('未知许可仍可导入但保持未知，备份读回会丢弃验证状态', () {
      final pack = SkillResourcePack.fromGatewayJson(
        _gatewayPack(license: 'NOASSERTION'),
      );

      expect(pack.licenseStatus, 'unknown');
      final restored = SkillResourcePack.fromBackupValue(pack.toBackupValue());
      expect(restored.id, pack.id);
      expect(restored.validationStatus, 'imported_unverified');
      expect(restored.licenseStatus, 'unknown');

      final forged = pack.toBackupValue()..['verified'] = true;
      expect(() => SkillResourcePack.fromBackupValue(forged),
          throwsFormatException);
    });
  });

  test('技能只在群聊和私聊都实际读取并运行包内脚本后激活', () async {
    final hiveDir = await openLifecycleHive();
    final workDir = await Directory.systemTemp.createTemp('skill_use_test_');
    final db = DatabaseService();
    addTearDown(() async {
      db.dispose();
      await closeLifecycleHive(hiveDir);
      if (await workDir.exists()) await workDir.delete(recursive: true);
    });

    final character = testCharacter('character-1');
    final group = ChatGroup(
      id: 'group-1',
      name: '验收群',
      theme: '测试',
      aiCharacterIds: [character.id],
    );
    await db.aiCharacterBox.put(character.id, character);
    await db.chatGroupBox.put(group.id, group);

    final pack = SkillResourcePack.fromGatewayJson(_gatewayPack());
    final store = SkillResourcePackStore(
      root: Directory(p.join(hiveDir.path, 'skill_resource_packs')),
    );
    await store.save(pack);
    final skill = CharacterSkill(
      characterId: character.id,
      name: pack.name,
      domain: pack.domain,
      description: pack.description,
      instructions: pack.instructions,
      requiredPermissions: const [],
      resourcePackId: pack.id,
    );
    await db.characterSkillBox.put(skill.id, skill);

    final script = File(p.join(workDir.path, 'check.sh'));
    await script.writeAsBytes(pack.file('scripts/check.sh')!.bytes);
    final missingDependencyScript = File(p.join(workDir.path, 'missing.sh'));
    await missingDependencyScript
        .writeAsBytes(pack.file('scripts/missing.sh')!.bytes);
    Future<List<String>> useIn(String taskId, String conversationId) async {
      await store.readResource(
        packId: pack.id,
        path: 'SKILL.md',
        taskId: taskId,
        conversationId: conversationId,
        characterId: character.id,
      );
      if (taskId == 'missing-dependency') {
        final failed =
            await Process.run('/bin/sh', [missingDependencyScript.path]);
        expect(failed.exitCode, isNot(0));
        expect(
          await store.recordScriptExecution(
            taskId: taskId,
            characterId: character.id,
            exitCode: failed.exitCode,
            executable: '/bin/sh',
            arguments: [missingDependencyScript.path],
            workingDirectory: workDir.path,
            workspaceRoot: workDir.path,
          ),
          isFalse,
        );
        return store.recordSuccessfulUse(
          database: db,
          taskId: taskId,
          conversationId: conversationId,
          characterId: character.id,
        );
      }
      final execution = await Process.run('/bin/sh', [script.path]);
      expect(execution.exitCode, 0);
      expect(
        await store.recordScriptExecution(
          taskId: taskId,
          characterId: character.id,
          exitCode: execution.exitCode,
          executable: '/bin/sh',
          arguments: [script.path],
          workingDirectory: workDir.path,
          workspaceRoot: workDir.path,
        ),
        isTrue,
      );
      return store.recordSuccessfulUse(
        database: db,
        taskId: taskId,
        conversationId: conversationId,
        characterId: character.id,
      );
    }

    expect(await useIn('missing-dependency', group.id), isEmpty);
    expect(await useIn('group-task', group.id), isEmpty);
    expect(db.aiCharacterBox.get(character.id)!.skillIds, isEmpty);
    expect(await useIn('direct-task', 'dm:${character.id}'), [skill.id]);

    final updated = db.aiCharacterBox.get(character.id)!;
    expect(updated.skillIds, contains(skill.id));
    final backup = await store.backupRecords([pack.id]);
    expect(backup.missing, isEmpty);
    expect(
      SkillResourcePack.fromBackupValue(backup.records.single['value'])
          .validationStatus,
      'imported_unverified',
    );
  });

  test('references 下的 Python 示例不会被误判为必须执行的脚本', () async {
    final hiveDir = await openLifecycleHive();
    final db = DatabaseService();
    addTearDown(() async {
      db.dispose();
      await closeLifecycleHive(hiveDir);
    });
    final character = testCharacter('reference-skill');
    final group = ChatGroup(
      id: 'reference-skill-group',
      name: '参考代码验证',
      theme: '测试',
      aiCharacterIds: [character.id],
    );
    await db.aiCharacterBox.put(character.id, character);
    await db.chatGroupBox.put(group.id, group);
    final raw = _gatewayPack(
      markdown: _skillMarkdown(body: '[示例](references/example.py)'),
    )..['files'] = [
        _file('SKILL.md', _skillMarkdown(body: '[示例](references/example.py)')),
        _file('references/example.py', 'print("reference only")'),
      ];
    final pack = SkillResourcePack.fromGatewayJson(raw);
    final store = SkillResourcePackStore(
      root: Directory(p.join(hiveDir.path, 'skill_resource_packs')),
    );
    await store.save(pack);
    final skill = CharacterSkill(
      characterId: character.id,
      name: pack.name,
      domain: pack.domain,
      description: pack.description,
      instructions: pack.instructions,
      requiredPermissions: const [],
      resourcePackId: pack.id,
    );
    await db.characterSkillBox.put(skill.id, skill);

    Future<List<String>> use(String taskId, String conversationId) async {
      await store.readResource(
        packId: pack.id,
        path: 'SKILL.md',
        taskId: taskId,
        conversationId: conversationId,
        characterId: character.id,
      );
      return store.recordSuccessfulUse(
        database: db,
        taskId: taskId,
        conversationId: conversationId,
        characterId: character.id,
      );
    }

    expect(await use('reference-group-task', group.id), isEmpty);
    expect(
        await use('reference-direct-task', 'dm:${character.id}'), [skill.id]);
  });

  test('自建草稿需在不同群聊和私聊任务中成功复测才可验证', () async {
    final hiveDir = await openLifecycleHive();
    final db = DatabaseService();
    addTearDown(() async {
      db.dispose();
      await closeLifecycleHive(hiveDir);
    });
    final character = testCharacter('local-draft');
    final group = ChatGroup(
      id: 'local-draft-group',
      name: '本地技能验证',
      theme: '测试',
      aiCharacterIds: [character.id],
    );
    await db.aiCharacterBox.put(character.id, character);
    await db.chatGroupBox.put(group.id, group);
    final skill = CharacterSkill(
      characterId: character.id,
      name: '草稿',
      domain: 'testing',
      description: '本地待验证方法',
      instructions: const ['先复现，再检查结果。'],
      requiredPermissions: const [],
    );
    final store = SkillResourcePackStore(
      root: Directory(p.join(hiveDir.path, 'skill_resource_packs')),
    );
    final fingerprint = SkillResourcePackStore.draftFingerprint(skill);

    expect(
      await store.recordDraftSuccessfulUse(
        database: db,
        skill: skill,
        fingerprint: fingerprint,
        taskId: 'group-task-1',
        conversationId: group.id,
        characterId: character.id,
      ),
      isFalse,
    );
    expect(
      await store.recordDraftSuccessfulUse(
        database: db,
        skill: skill,
        fingerprint: fingerprint,
        taskId: 'group-task-1',
        conversationId: group.id,
        characterId: character.id,
      ),
      isFalse,
      reason: '同一任务不能通过重复提交伪造复测次数',
    );
    expect(
      await store.recordDraftSuccessfulUse(
        database: db,
        skill: skill,
        fingerprint: fingerprint,
        taskId: 'direct-task-1',
        conversationId: 'dm:${character.id}',
        characterId: character.id,
      ),
      isTrue,
    );
    skill.instructions = const ['绕过失败检查。'];
    expect(
      await store.recordDraftSuccessfulUse(
        database: db,
        skill: skill,
        fingerprint: fingerprint,
        taskId: 'direct-task-2',
        conversationId: 'dm:${character.id}',
        characterId: character.id,
      ),
      isFalse,
      reason: '修改后的草稿不能继承旧验证证据',
    );
  });
}

final _commit = List.filled(40, 'a').join();

Map<String, dynamic> _gatewayPack({
  String license = 'MIT',
  String? markdown,
  List<Map<String, dynamic>> extraFiles = const [],
}) {
  final files = <Map<String, dynamic>>[
    _file('SKILL.md', markdown ?? _skillMarkdown()),
    _file('references/guide.md', 'Reference text.'),
    _file('scripts/check.sh', '#!/bin/sh\nexit 0\n'),
    _file('scripts/missing.sh',
        '#!/bin/sh\n__chat_group_skill_dependency_missing__\n'),
    ...extraFiles,
  ];
  return {
    'owner': 'sample-owner',
    'repo': 'sample-repo',
    'path': 'skills/sample',
    'commit': _commit,
    'license': license,
    'files': files,
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

String _skillMarkdown({
  String body = '[参考](references/guide.md)',
  String yamlSuffix = '',
}) =>
    [
      '---',
      'name: Sample workflow',
      'description: A reusable test workflow',
      'license: MIT',
      'allowed-tools:',
      '  - command.run',
      '  - system.install',
      'metadata:',
      '  domain: testing',
      yamlSuffix,
      '---',
      body,
    ].join('\n');
