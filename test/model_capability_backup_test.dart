import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/ai_governance/ai_governance_store.dart';
import 'package:chat_group/features/backup/backup_models.dart';
import 'package:chat_group/features/backup/backup_restore_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/lifecycle_hive.dart';

/// 用户声明的模型能力必须随备份走。
///
/// 它决定工作模式能否启动（工具/流式）以及一次能写多长，而内置快照覆盖不到的
/// 模型只能靠这份声明；不携带的话，换设备恢复后用户要逐条重填，且重填之前工作
/// 模式会直接卡在能力拦截上。
void main() {
  const declaredKey = 'deepseek/deepseek-chat';
  const declared = CustomModelCapability(
    supportsStreaming: true,
    supportsTools: true,
    contextWindow: 2000000,
    maxOutput: 16384,
  );

  late Directory hiveDirectory;
  late Directory root;
  late Directory mediaDirectory;
  late DatabaseService db;

  setUp(() async {
    hiveDirectory = await openLifecycleHive();
    root = await Directory.systemTemp.createTemp('model_capability_backup_');
    mediaDirectory = Directory('${hiveDirectory.path}/media')
      ..createSync(recursive: true);
    db = DatabaseService();
  });

  tearDown(() async {
    await closeLifecycleHive(hiveDirectory);
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<Map> exportedSettings(File backup) async {
    final archive = ZipDecoder().decodeBytes(await backup.readAsBytes());
    final settingsFile = archive.findFile('data/settings.json')!;
    return jsonDecode(utf8.decode(settingsFile.content)) as Map;
  }

  test('能力声明随「仅配置」备份导出，并在恢复后可用', () async {
    await db.appSettingsBox.put(
      AiGovernanceStore.customCapabilitiesKey,
      {declaredKey: declared.toMap()},
    );

    final backup = File('${root.path}/capability.cgbak');
    final service = BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: root,
    );
    await service.createBackup(
      destination: backup,
      selection: const BackupSelection.configurationOnly(),
    );

    final settings = await exportedSettings(backup);
    final carried = Map<String, dynamic>.from(
        settings[AiGovernanceStore.customCapabilitiesKey] as Map);
    expect(carried[declaredKey]['maxOutput'], 16384);
    expect(carried[declaredKey]['contextWindow'], 2000000);
    expect(carried[declaredKey]['supportsTools'], isTrue);

    // 重新打开 Hive，模拟恢复到一台干净设备。
    await closeLifecycleHive(hiveDirectory);
    hiveDirectory = await openLifecycleHive();
    mediaDirectory = Directory('${hiveDirectory.path}/media')
      ..createSync(recursive: true);
    db = DatabaseService();

    final restoreService = BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: root,
    );
    final prepared = await restoreService.inspect(backup);
    addTearDown(prepared.dispose);
    await restoreService.restore(
      prepared,
      strategy: RestoreConflictStrategy.emptyOnly,
    );

    final restored = AiGovernanceStore.forDatabase(db)
        .customCapability('deepseek', 'deepseek-chat');
    expect(restored?.maxOutput, 16384);
    expect(restored?.contextWindow, 2000000);
    expect(restored?.supportsTools, isTrue);
  });

  test('能力声明不随「会话范围」备份走：它是配置，不是某个房间的状态', () async {
    await db.chatGroupBox.put(
      'group-1',
      ChatGroup(
        id: 'group-1',
        name: '测试群',
        theme: '测试',
        aiCharacterIds: const [],
      ),
    );
    await db.appSettingsBox.put(
      AiGovernanceStore.customCapabilitiesKey,
      {declaredKey: declared.toMap()},
    );
    // 对照组：同一份备份里确实会带走的会话状态。
    await db.appSettingsBox.put('work_mode_enabled:group-1', true);

    final backup = File('${root.path}/conversation.cgbak');
    final service = BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: root,
    );
    await service.createBackup(
      destination: backup,
      selection: const BackupSelection.conversation('group-1'),
    );

    final settings = await exportedSettings(backup);
    expect(
      settings.containsKey(AiGovernanceStore.customCapabilitiesKey),
      isFalse,
      reason: '能力声明按 provider/model 存，会话范围备份不该带上它',
    );
    expect(settings['work_mode_enabled:group-1'], isTrue);
  });
}
