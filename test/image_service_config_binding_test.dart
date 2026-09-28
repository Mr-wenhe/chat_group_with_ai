import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/database/database_service_image.dart';
import 'package:chat_group/core/images/image_service_config.dart';
import 'package:chat_group/core/storage/credential_repository.dart';
import 'package:chat_group/features/backup/backup_setting_keys.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/lifecycle_hive.dart';

void main() {
  late Directory hiveDirectory;
  late DatabaseService db;
  late MemoryCredentialStore store;

  setUp(() async {
    hiveDirectory = await openLifecycleHive();
    db = DatabaseService();
    store = MemoryCredentialStore();
  });

  tearDown(() async {
    await closeLifecycleHive(hiveDirectory, db);
  });

  test('fromMap / toMap 往返保留全部字段', () {
    const config = ImageServiceConfig(
      baseUrl: 'https://api.openai.com',
      model: 'dall-e-3',
      size: '1024x1792',
      quality: 'hd',
      disableWatermark: true,
      apiKeyBound: true,
    );

    final restored = ImageServiceConfig.fromMap(config.toMap());

    expect(restored.baseUrl, config.baseUrl);
    expect(restored.model, config.model);
    expect(restored.size, config.size);
    expect(restored.quality, config.quality);
    expect(restored.disableWatermark, isTrue);
    expect(restored.apiKeyBound, isTrue);
  });

  test('fromMap 对缺失/非法输入回落默认值', () {
    final empty = ImageServiceConfig.fromMap(null);
    expect(empty.baseUrl, '');
    expect(empty.model, '');
    expect(empty.size, kDefaultImageSize);
    expect(empty.quality, '');
    // 旧配置缺该键时读作 false（不发送 watermark_enabled），行为不变。
    expect(empty.disableWatermark, isFalse);
    expect(empty.apiKeyBound, isFalse);

    final trimmed = ImageServiceConfig.fromMap({
      'baseUrl': 'https://api.openai.com///',
      'model': '  m  ',
    });
    // 尾部斜杠统一去掉，避免拼出 //v1/...。
    expect(trimmed.baseUrl, 'https://api.openai.com');
    expect(trimmed.model, 'm');
  });

  test('isConfigured 要求 Key 已绑定且 baseUrl / 模型非空', () {
    const base = ImageServiceConfig(
      baseUrl: 'https://api.openai.com',
      model: 'dall-e-3',
    );
    expect(base.isConfigured, isFalse); // 未绑定 Key
    expect(base.copyWith(apiKeyBound: true).isConfigured, isTrue);
    expect(base.copyWith(apiKeyBound: true, model: '').isConfigured, isFalse);
    expect(
      base.copyWith(apiKeyBound: true, baseUrl: '  ').isConfigured,
      isFalse,
    );
  });

  test('绑定后可读回同一明文，且 apiKeyBound 翻转为 true', () async {
    final credentials = testCredentials(store);
    final error = await db.bindImageApiKey(
      'sk-test-secret',
      credentials: credentials,
    );

    expect(error, isNull);
    expect(db.imageServiceConfig.apiKeyBound, isTrue);
    expect(
        await db.readImageApiKey(credentials: credentials), 'sk-test-secret');
  });

  test('解除绑定后读不到密钥，且 apiKeyBound 翻回 false', () async {
    final credentials = testCredentials(store);
    await db.bindImageApiKey('sk-temp', credentials: credentials);
    await db.unbindImageApiKey(credentials: credentials);

    expect(await db.readImageApiKey(credentials: credentials), isNull);
    expect(db.imageServiceConfig.apiKeyBound, isFalse);
  });

  test('安全存储不可用时仅非 Release 回退到本地，解绑后清除', () async {
    final unavailable = CredentialRepository(
      store: store,
      legacyStorage: MemoryLegacyCredentialStore(),
      secureStorageAvailable: false,
    );

    final error =
        await db.bindImageApiKey('  sk-x  ', credentials: unavailable);

    if (kReleaseMode) {
      expect(error, contains('安全存储'));
      expect(db.imageServiceConfig.apiKeyBound, isFalse);
      expect(db.appSettingsBox.get('image_api_key_debug_only'), isNull);
    } else {
      expect(error, isNull);
      expect(db.imageServiceConfig.apiKeyBound, isTrue);
      expect(db.appSettingsBox.get('image_api_key_debug_only'), 'sk-x');
      expect(await db.readImageApiKey(credentials: unavailable), 'sk-x');
      // 安全存储恢复前不谎报解绑成功，也不遗留未绑定但可读的凭据。
      expect(await db.unbindImageApiKey(credentials: unavailable), isNotNull);
      expect(db.imageServiceConfig.apiKeyBound, isTrue);
      final credentials = testCredentials(store);
      expect(await db.unbindImageApiKey(credentials: credentials), isNull);
      expect(db.appSettingsBox.get('image_api_key_debug_only'), isNull);
      expect(await db.readImageApiKey(credentials: credentials), isNull);
      expect(db.imageServiceConfig.apiKeyBound, isFalse);
    }
  });

  test('安全存储优先于调试回退；成功保存后清理过期回退', () async {
    final credentials = testCredentials(store);
    if (!kReleaseMode) {
      await db.appSettingsBox.put('image_api_key_debug_only', 'sk-old');
    }
    expect(
        await db.bindImageApiKey('sk-new', credentials: credentials), isNull);
    expect(db.appSettingsBox.get('image_api_key_debug_only'), isNull);
    expect(await db.readImageApiKey(credentials: credentials), 'sk-new');
    if (!kReleaseMode) {
      await db.appSettingsBox.put('image_api_key_debug_only', 'sk-stale');
      expect(await db.readImageApiKey(credentials: credentials), 'sk-new');
    }
    expect(await db.unbindImageApiKey(credentials: credentials), isNull);
    expect(db.appSettingsBox.get('image_api_key_debug_only'), isNull);
    expect(await db.readImageApiKey(credentials: credentials), isNull);
  });

  test('安全存储删除失败时不清理回退或解除绑定', () async {
    final credentials = testCredentials(store);
    expect(
        await db.bindImageApiKey('sk-live', credentials: credentials), isNull);
    if (!kReleaseMode) {
      await db.appSettingsBox.put('image_api_key_debug_only', 'sk-fallback');
    }
    store.failNextDelete = true;

    expect(
        await db.unbindImageApiKey(credentials: credentials), contains('删除失败'));
    expect(db.imageServiceConfig.apiKeyBound, isTrue);
    expect(await db.readImageApiKey(credentials: credentials), 'sk-live');
    if (!kReleaseMode) {
      expect(db.appSettingsBox.get('image_api_key_debug_only'), 'sk-fallback');
    }
  });

  test('空白 Key 不应保存或标记绑定', () async {
    final credentials = testCredentials(store);
    expect(await db.bindImageApiKey('  ', credentials: credentials),
        contains('不能为空'));
    expect(db.imageServiceConfig.apiKeyBound, isFalse);
    expect(store.values, isEmpty);
  });

  test('调试回退凭据不得被备份携带', () {
    expect(isBackupCarriedSettingKey('image_api_key_debug_only'), isFalse);
  });

  test('配置读写落 app_settings，可用 saveImageServiceConfig 覆盖', () async {
    await db.saveImageServiceConfig(const ImageServiceConfig(
      baseUrl: 'https://api.example.com',
      model: 'wanx-v1',
      size: '1024x1792',
    ));

    final loaded = db.imageServiceConfig;
    expect(loaded.baseUrl, 'https://api.example.com');
    expect(loaded.model, 'wanx-v1');
    expect(loaded.size, '1024x1792');
  });

  test('已存的构图装不下的尺寸，读回即自愈成服务商建议值', () async {
    // 实测 512x512 下出图只有一片发丝：头涨出画框、脸被挤到画面外，而 prompt 里
    // 脸部词量是头发的六倍。该值曾作为下拉选项提供过，用户选中并保存；读回必须
    // 自动换成该家建议值 —— 否则他会反复重新生成，然后归因到 prompt（实际发生）。
    await db.saveImageServiceConfig(const ImageServiceConfig(
      baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
      model: 'glm-image',
      size: '512x512',
    ));

    // 智谱预设的建议值是 1280x1280，也就是人工验证能正常出图的那个尺寸。
    expect(db.imageServiceConfig.size, '1280x1280');
  });

  test('normalizeImageSize 只守地板，不改写合法的自定义尺寸', () {
    // 合法但不在下拉里的自定义值（glm-image 的 32 对齐枚举）必须原样保留，
    // 否则「用户填了对的值却被改成默认」和「填了错的值」一样难查。
    expect(normalizeImageSize('1472x1088'), '1472x1088');
    expect(normalizeImageSize('2048x2048'), '2048x2048');
  });

  test('normalizeImageSize 把非法尺寸送到服务商建议值，查不出预设才用默认', () {
    expect(
      normalizeImageSize('512x512',
          baseUrl: 'https://open.bigmodel.cn/api/paas/v4'),
      '1280x1280',
    );
    expect(normalizeImageSize('512x512'), kDefaultImageSize);
    expect(normalizeImageSize('abc'), kDefaultImageSize);
    expect(normalizeImageSize(''), kDefaultImageSize);
    // 形状对但有一条边在地板下，同样不许发出去。
    expect(normalizeImageSize('1024x512'), kDefaultImageSize);
    expect(normalizeImageSize('512x1024'), kDefaultImageSize);
  });
}
