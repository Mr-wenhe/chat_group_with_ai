import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/features/backup/backup_setting_keys.dart';
import 'package:chat_group/features/settings/ai_speaker_picker_settings.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/lifecycle_hive.dart';

void main() {
  late Directory directory;
  late DatabaseService db;
  late AiSpeakerPickerSettings settings;

  ApiConfig config(String id, {bool hasCredential = true}) => ApiConfig(
        id: id,
        name: '配置$id',
        provider: 'deepseek',
        modelName: 'deepseek-chat',
        credentialId: hasCredential ? 'credential.$id' : '',
        hasCredential: hasCredential,
      );

  setUpAll(() async {
    directory = await openLifecycleHive();
    db = DatabaseService();
  });

  setUp(() async {
    await db.appSettingsBox.clear();
    await db.apiConfigBox.clear();
    settings = AiSpeakerPickerSettings(db);
  });

  tearDownAll(() async {
    await closeLifecycleHive(directory, db);
  });

  test('未设置时读出空引用，且不解析出任何配置', () {
    expect(settings.selectedConfigId(), isNull);
    expect(settings.resolveConfig(), isNull);
  });

  test('保存、读取与清除引用', () async {
    await db.apiConfigBox.put('cfg-1', config('cfg-1'));
    await settings.select('cfg-1');

    expect(settings.selectedConfigId(), 'cfg-1');
    expect(settings.resolveConfig()?.id, 'cfg-1');

    await settings.select(null);
    expect(settings.selectedConfigId(), isNull);
    // 清除走的是 delete：不留空串条目，避免导出/清理时看到一个"有值但为空"的键。
    expect(db.appSettingsBox.containsKey(AiSpeakerPickerSettings.storageKey),
        isFalse);
  });

  test('空白值按未设置处理，损坏类型不抛异常', () async {
    await settings.select('   ');
    expect(settings.selectedConfigId(), isNull);

    await db.appSettingsBox
        .put(AiSpeakerPickerSettings.storageKey, <String>['not-an-id']);
    expect(settings.selectedConfigId(), isNull);
    expect(settings.resolveConfig(), isNull);
  });

  test('引用指向已删除的配置时不解析、不报错', () async {
    await settings.select('cfg-gone');
    expect(settings.selectedConfigId(), 'cfg-gone');
    expect(settings.resolveConfig(), isNull);
  });

  test('配置没有凭据时不解析出配置', () async {
    await db.apiConfigBox.put('cfg-nocred', config('cfg-nocred', hasCredential: false));
    await settings.select('cfg-nocred');
    expect(settings.resolveConfig(), isNull);
  });

  test('删除被引用的配置时清掉悬空引用，删别的配置不受影响', () async {
    await settings.select('cfg-1');
    await settings.clearIfReferencing('cfg-2');
    expect(settings.selectedConfigId(), 'cfg-1');

    await settings.clearIfReferencing('cfg-1');
    expect(settings.selectedConfigId(), isNull);
  });

  test('恢复后的本机残留引用被 pruneDangling 收敛掉', () async {
    // 备份不含这个键，恢复后旧值原样留在本机，指向这台设备上不存在的配置。
    await settings.select('cfg-from-other-device');
    expect(await settings.pruneDangling(), isTrue);
    expect(settings.selectedConfigId(), isNull);
    expect(
      db.appSettingsBox.containsKey(AiSpeakerPickerSettings.storageKey),
      isFalse,
      reason: '清理必须删键，而不是留一个空值条目',
    );
  });

  test('pruneDangling 不动仍然存在的配置引用，包括暂时没有凭据的', () async {
    await db.apiConfigBox.put('cfg-1', config('cfg-1', hasCredential: false));
    await settings.select('cfg-1');
    // 缺少凭据是"暂时回落本地规则"的可修状态，不是悬空引用。
    expect(await settings.pruneDangling(), isFalse);
    expect(settings.selectedConfigId(), 'cfg-1');

    expect(await settings.pruneDangling(), isFalse);
    expect(settings.selectedConfigId(), 'cfg-1');
  });

  test('pruneDangling 在未设置引用时不写任何东西', () async {
    expect(await settings.pruneDangling(), isFalse);
    expect(
      db.appSettingsBox.containsKey(AiSpeakerPickerSettings.storageKey),
      isFalse,
    );
  });

  test('引用不进备份：键名不在任何清单里，也不含敏感词元', () {
    const key = AiSpeakerPickerSettings.storageKey;
    expect(backupCarriedSettingKeys.contains(key), isFalse);
    expect(backupConfigurationOnlySettingKeys.contains(key), isFalse);
    expect(isBackupCarriedSettingKey(key), isFalse);
    // 键名本身不能被导出侧的密钥扫描命中。
    expect(key.toLowerCase().contains('apikey'), isFalse);
    expect(key.toLowerCase().contains('credential'), isFalse);
  });
}
