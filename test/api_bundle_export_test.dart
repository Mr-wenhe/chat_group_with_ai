import 'dart:io';

import 'package:chat_group/core/bundle/api_bundle.dart';
import 'package:chat_group/core/bundle/api_bundle_codec.dart';
import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/storage/credential_repository.dart';
import 'package:chat_group/core/storage/debug_credential_cache.dart';
import 'package:chat_group/features/settings/api_bundle_export_service.dart';
import 'package:chat_group/features/settings/api_bundle_import_models.dart';
import 'package:chat_group/features/settings/api_bundle_import_service.dart';
import 'package:chat_group/features/web_search/data/search_credential_repository.dart';
import 'package:chat_group/features/web_search/data/zhipu_native_search_credential_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'helpers/lifecycle_hive.dart';

const String chatKey = 'sk-export-SENTINEL-aa';
const String voiceKey = 'voice-export-SENTINEL-bb';
const String imageKey = 'image-export-SENTINEL-cc';
const String searchKey = 'tvly-export-SENTINEL-dd';

ApiBundle seededBundle() => const ApiBundle(
      label: '源机器',
      issuedAt: '2026-10-15T00:00:00Z',
      chat: [
        ApiBundleChatEntry(
          id: 'cfg-1',
          name: '主力对话',
          provider: 'deepseek',
          model: 'deepseek-chat',
          baseUrl: '',
          protocol: 'openAiChatCompletions',
          apiKey: chatKey,
          setDefault: true,
          enableWorkPromptCaching: true,
        ),
      ],
      voice: ApiBundleVoiceEntry(
        apiKey: voiceKey,
        ttsResourceId: 'seed-tts-1.0',
        asrResourceId: 'volc.bigasr.sauc.duration',
        defaultVoiceId: '',
      ),
      image: ApiBundleImageEntry(
        apiKey: imageKey,
        baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
        model: 'glm-image',
        size: '1280x1280',
        quality: '',
        disableWatermark: true,
      ),
      search: [
        ApiBundleSearchEntry(
          id: 'tavily-main',
          name: 'Tavily',
          provider: 'tavily',
          baseUrl: 'https://api.tavily.com',
          apiKey: searchKey,
          enabled: true,
          isDefault: true,
        ),
      ],
      issues: [],
    );

void main() {
  late Directory hiveDirectory;
  late DatabaseService db;

  setUp(() async {
    hiveDirectory = await openLifecycleHive();
    db = DatabaseService();
    await Hive.openBox<dynamic>(DebugCredentialCache.boxName);
  });

  tearDown(() async {
    DebugCredentialCache.bind(null);
    CredentialRepository.clearCache();
    await closeLifecycleHive(hiveDirectory, db);
  });

  ApiBundleExportService exporter() => ApiBundleExportService(db: db);
  ApiBundleImportService importer() => ApiBundleImportService(db: db);

  /// 把四类服务配好，作为导出的输入。
  Future<void> seed() => importer().apply(seededBundle());

  test('本机什么都没配时不导出内容，但仍给出可解析的空包', () async {
    final result = await exporter().export();

    expect(result.hasContent, isFalse);
    expect(result.included, isEmpty);

    // 即便没有内容，产出的码也必须能被解析——否则用户会拿到一串「校验失败」。
    final parsed = ApiBundle.parse(ApiBundleCodec.open(result.code));
    expect(parsed.hasNoEntries, isTrue);
  });

  test('四类服务都能导出，且解码后密钥与原值逐一对应', () async {
    await seed();
    final result = await exporter().export();

    expect(result.included.length, 4);
    expect(result.omitted, isEmpty);

    final payload = ApiBundleCodec.open(result.code);
    final parsed = ApiBundle.parse(payload);

    final chat = parsed.chat.single;
    expect(chat.id, 'cfg-1', reason: '带上 id，导入侧才能精确覆盖同一条配置');
    expect(chat.apiKey, chatKey);
    expect(chat.provider, 'deepseek');
    expect(chat.model, 'deepseek-chat');
    expect(chat.setDefault, isTrue, reason: '默认聊天配置的指向也要一起带走');

    expect(parsed.voice!.apiKey, voiceKey);
    expect(parsed.voice!.ttsResourceId, 'seed-tts-1.0');

    expect(parsed.image!.apiKey, imageKey);
    expect(parsed.image!.baseUrl, 'https://open.bigmodel.cn/api/paas/v4');
    expect(parsed.image!.model, 'glm-image');
    expect(parsed.image!.disableWatermark, isTrue);

    expect(parsed.search.single.apiKey, searchKey);
    expect(parsed.search.single.isDefault, isTrue);
  });

  test('导出的码是「导入侧肯接受」的：解析零跳过、语义与原状态一致', () async {
    await seed();
    final result = await exporter().export();
    final plan = importer().plan(ApiBundle.parse(
      ApiBundleCodec.open(result.code),
    ));

    // 同一台机器上导了再导：聊天配置形状与名称都没变、默认指向也已到位，判为
    // 「无变化」；语音 / 图像 / 搜索的密钥无法在预览阶段比对，一律走「覆盖」。
    expect(plan.createCount, 0);
    expect(plan.overwriteCount, 3);
    expect(plan.skipCount, 1);

    // 导出侧自己先跑过一遍 ApiBundle.parse，因此这里不该出现任何**结构性**跳过
    // （缺字段、超长、枚举未知……）。唯一该出现的是上面那条「无变化」。
    expect(
      plan.changes
          .where((change) => change.action == BundleChangeAction.skip)
          .every((change) => change.detail == '与现有配置一致，保持不变'),
      isTrue,
      reason: '导出侧生成了导入侧不接受的条目',
    );
  });

  test('把码贴到「另一台机器」上能完整重建', () async {
    await seed();
    final code = (await exporter().export()).code;

    // 模拟换机：清掉聊天配置与它对应的凭据。
    await db.apiConfigBox.clear();
    await CredentialRepository().delete('cfg-1');

    final imported = await importer().apply(ApiBundle.parse(
      ApiBundleCodec.open(code),
    ));

    expect(imported.failureCount, 0);
    final restored = db.apiConfigBox.get('cfg-1');
    expect(restored, isNotNull);
    expect(restored!.hasCredential, isTrue);
    expect(restored.enableWorkPromptCaching, isTrue);
    expect((await CredentialRepository().read('cfg-1')).value, chatKey);
  });

  test('展示清单里不含密钥明文，只给指纹', () async {
    await seed();
    final result = await exporter().export();

    final shown = [
      for (final entry in [...result.included, ...result.omitted])
        '${entry.service.label}|${entry.title}|${entry.detail}|${entry.fingerprint}',
    ].join('\n');

    for (final secret in [chatKey, voiceKey, imageKey, searchKey]) {
      expect(shown.contains(secret), isFalse);
    }
    expect(
      result.included.every((e) => e.fingerprint.length == 8),
      isTrue,
    );
  });

  test('只配了智谱原生搜索时，它也会进包（此前整类被遗漏）', () async {
    const zhipuKey = 'zhipu-export-SENTINEL-ee';
    await ZhipuNativeSearchCredentialStore(db: db).save(zhipuKey);

    final result = await exporter().export();
    expect(result.hasContent, isTrue);
    expect(result.included.map((e) => e.title), contains('智谱原生搜索'));
    expect(result.omitted, isEmpty);

    final parsed = ApiBundle.parse(ApiBundleCodec.open(result.code));
    expect(parsed.zhipuNativeSearch!.apiKey, zhipuKey);
    // 独立 Provider 一条都没配，`search` 段就该是空的——智谱原生走的是它自己的段，
    // 不能被混进那张会被当成 `SearchProviderConfig` 写入的列表里。
    expect(parsed.search, isEmpty);
  });

  test('智谱原生搜索凭据能导到另一台机器并重建绑定', () async {
    const zhipuKey = 'zhipu-export-SENTINEL-ff';
    await ZhipuNativeSearchCredentialStore(db: db).save(zhipuKey);
    final code = (await exporter().export()).code;

    // 模拟换机：元数据与凭据一并抹掉。
    await db.appSettingsBox
        .delete(ZhipuNativeSearchCredentialStore.settingsKey);
    await SearchCredentialRepository()
        .delete(ZhipuNativeSearchCredentialStore.credentialConfigId);
    expect(
      ZhipuNativeSearchCredentialStore(db: db).hasConfiguredCredential,
      isFalse,
    );

    final imported = await importer().apply(
      ApiBundle.parse(ApiBundleCodec.open(code)),
    );
    expect(imported.failureCount, 0);

    final restored = ZhipuNativeSearchCredentialStore(db: db);
    expect(restored.hasConfiguredCredential, isTrue);
    expect(await restored.resolve(), zhipuKey);
  });

  test('导出清单里不含智谱原生搜索的明文', () async {
    const zhipuKey = 'zhipu-export-SENTINEL-gg';
    await ZhipuNativeSearchCredentialStore(db: db).save(zhipuKey);

    final result = await exporter().export();
    final shown = [
      for (final entry in [...result.included, ...result.omitted])
        '${entry.service.label}|${entry.title}|${entry.detail}|${entry.fingerprint}',
    ].join('\n');

    expect(shown.contains(zhipuKey), isFalse);
    expect(
      result.included.firstWhere((e) => e.title == '智谱原生搜索').fingerprint.length,
      8,
    );
  });

  test('未配过的服务不会凭空出现在导出清单里', () async {
    // 只配聊天。
    await importer().apply(const ApiBundle(
      label: '',
      issuedAt: '',
      chat: [
        ApiBundleChatEntry(
          id: '',
          name: '只有聊天',
          provider: 'deepseek',
          model: 'deepseek-chat',
          baseUrl: '',
          protocol: '',
          apiKey: chatKey,
          setDefault: true,
        ),
      ],
      voice: null,
      image: null,
      search: [],
      issues: [],
    ));

    final result = await exporter().export();

    expect(result.included.length, 1);
    expect(result.included.single.service, BundleService.chat);

    final parsed = ApiBundle.parse(ApiBundleCodec.open(result.code));
    expect(parsed.voice, isNull);
    expect(parsed.image, isNull);
    expect(parsed.search, isEmpty);
  });
}
