import 'dart:convert';
import 'dart:io';

import 'package:chat_group/core/bundle/api_bundle.dart';
import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/database/database_service_image.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/storage/credential_repository.dart';
import 'package:chat_group/core/storage/debug_credential_cache.dart';
import 'package:chat_group/features/settings/ai_speaker_picker_settings.dart';
import 'package:chat_group/features/settings/api_bundle_import_models.dart';
import 'package:chat_group/features/settings/api_bundle_import_service.dart';
import 'package:chat_group/features/web_search/data/search_settings_store.dart';
import 'package:chat_group/features/web_search/data/zhipu_native_search_credential_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'helpers/lifecycle_hive.dart';

/// 每个字段用互不相同的哨兵值，任何一处把明文写错落点都能被下面的
/// 「密钥不落 app_settings」断言抓出来。
const String chatKey = 'sk-chat-SENTINEL-1a2b3c';
const String voiceKey = 'voice-SENTINEL-4d5e6f';
const String imageKey = 'image-SENTINEL-7g8h9i';
const String searchKey = 'tvly-SENTINEL-0j1k2l';

ApiBundle buildBundle({
  List<ApiBundleChatEntry>? chat,
  ApiBundleVoiceEntry? voice,
  ApiBundleImageEntry? image,
  List<ApiBundleSearchEntry>? search,
  ApiBundleZhipuNativeSearchEntry? zhipuNativeSearch,
  List<ApiBundleIssue> issues = const [],
}) =>
    ApiBundle(
      label: '测试包',
      issuedAt: '2026-10-15T00:00:00Z',
      chat: chat ?? const [],
      voice: voice,
      image: image,
      search: search ?? const [],
      zhipuNativeSearch: zhipuNativeSearch,
      issues: issues,
    );

ApiBundleChatEntry chatEntry({
  String id = '',
  String name = '主力对话',
  String provider = 'deepseek',
  String model = 'deepseek-chat',
  String baseUrl = '',
  String protocol = '',
  String apiKey = chatKey,
  bool setDefault = false,
  String? userAgent,
}) =>
    ApiBundleChatEntry(
      id: id,
      name: name,
      provider: provider,
      model: model,
      baseUrl: baseUrl,
      protocol: protocol,
      apiKey: apiKey,
      setDefault: setDefault,
      userAgent: userAgent,
    );

ApiBundle fullBundle() => buildBundle(
      chat: [chatEntry(setDefault: true)],
      voice: const ApiBundleVoiceEntry(
        apiKey: voiceKey,
        ttsResourceId: 'seed-tts-1.0',
        asrResourceId: 'volc.bigasr.sauc.duration',
        defaultVoiceId: '',
      ),
      image: const ApiBundleImageEntry(
        apiKey: imageKey,
        baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
        model: 'glm-image',
        size: '1280x1280',
        quality: '',
        disableWatermark: true,
      ),
      search: const [
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
    );

void main() {
  late Directory hiveDirectory;
  late DatabaseService db;
  late Box<dynamic> credentialBox;

  setUp(() async {
    hiveDirectory = await openLifecycleHive();
    db = DatabaseService();
    // 打开调试镜像 box，让非 release 下的凭据写入有一个真实落点。
    // 不开的话 `DebugCredentialCache` 无 box 可绑，写入会落到不可用的
    // flutter_secure_storage 上，测试就变成在验「无凭据环境」而不是正常路径。
    credentialBox = await Hive.openBox<dynamic>(DebugCredentialCache.boxName);
  });

  tearDown(() async {
    DebugCredentialCache.bind(null);
    CredentialRepository.clearCache();
    await closeLifecycleHive(hiveDirectory, db);
  });

  ApiBundleImportService service({
    bool secureStorageAvailable = true,
    DatabaseService? database,
  }) =>
      ApiBundleImportService(
        db: database ?? db,
        credentials: CredentialRepository(
          store: MemoryCredentialStore(),
          secureStorageAvailable: secureStorageAvailable,
        ),
      );

  /// `app_settings` 受 git 跟踪，明文密钥落进去等于提交进仓库。
  void expectNoPlaintextAnywhere() {
    final dump = db.appSettingsBox.values.map((v) => v.toString()).join('\n');
    for (final secret in [chatKey, voiceKey, imageKey, searchKey]) {
      expect(dump.contains(secret), isFalse, reason: 'app_settings 里出现了明文密钥');
    }
    final configDump = db.apiConfigBox.values
        .map((c) => c.legacyApiKeyForMigration ?? '')
        .join();
    expect(configDump.contains(chatKey), isFalse, reason: '聊天配置记录里留了明文密钥');
  }

  test('三类服务导入且旧搜索跳过，明文不进 app_settings', () async {
    final plan = service().plan(fullBundle());
    expect(plan.createCount, 3);
    expect(plan.overwriteCount, 0);

    final result = await service().apply(fullBundle());
    expect(result.failureCount, 0);
    expect(result.successCount, 3);

    // 聊天：元数据在 api_configs，密钥在凭据存储。
    final chatConfig = db.apiConfigBox.values.single;
    expect(chatConfig.provider, 'deepseek');
    expect(chatConfig.modelName, 'deepseek-chat');
    expect(chatConfig.hasCredential, isTrue);
    expect(
      chatConfig.credentialId,
      CredentialRepository().credentialIdFor(chatConfig.id),
    );
    expect(
      credentialBox
          .get('v:${CredentialRepository().credentialIdFor(chatConfig.id)}'),
      chatKey,
    );
    expect(AiSpeakerPickerSettings(db).selectedConfigId(), chatConfig.id);

    // 语音 / 图像：元数据在 app_settings 单 Map，密钥在凭据存储。
    expect(db.voiceServiceConfig.apiKeyBound, isTrue);
    expect(
      credentialBox.get(
          'v:${CredentialRepository().credentialIdFor('voice.volcengine')}'),
      voiceKey,
    );
    expect(db.imageServiceConfig.apiKeyBound, isTrue);
    expect(db.imageServiceConfig.model, 'glm-image');
    expect(db.imageServiceConfig.disableWatermark, isTrue);
    expect(
      credentialBox.get(
          'v:${CredentialRepository().credentialIdFor('image.openai-compatible')}'),
      imageKey,
    );

    expect(SearchProviderConfigStore(db: db).findById('tavily-main'), isNull);
    expect(credentialBox.get('v:credential.web-search.tavily-main'), isNull);
    expect(plan.skipCount, 1);

    expectNoPlaintextAnywhere();
  });

  test('覆盖聊天配置时沿用原 id 与 createdAt', () async {
    final created = DateTime(2020, 1, 2, 3, 4, 5);
    await db.saveApiConfig(ApiConfig(
      id: 'cfg-fixed',
      name: '旧名字',
      provider: 'deepseek',
      modelName: 'deepseek-chat',
      createdAt: created,
    ));

    final bundle = buildBundle(
      chat: [chatEntry(id: 'cfg-fixed', name: '新名字')],
    );
    final plan = service().plan(bundle);
    expect(plan.overwriteCount, 1);
    expect(plan.createCount, 0);

    await service().apply(bundle);

    expect(db.apiConfigBox.length, 1, reason: '覆盖不应新增第二条记录');
    final config = db.apiConfigBox.get('cfg-fixed')!;
    expect(config.name, '新名字');
    expect(config.createdAt, created, reason: 'createdAt 是 final，覆盖时必须透传');
  });

  test('匹配到多条现有配置时跳过而不是猜', () async {
    for (final id in ['dup-1', 'dup-2']) {
      await db.saveApiConfig(ApiConfig(
        id: id,
        name: '同名',
        provider: 'deepseek',
        modelName: 'deepseek-chat',
      ));
    }

    final plan = service().plan(buildBundle(chat: [chatEntry(id: '')]));
    expect(plan.createCount, 0);
    expect(plan.skipCount, 1);
    expect(plan.changes.single.detail, contains('无法确定覆盖哪一条'));

    await service().apply(buildBundle(chat: [chatEntry(id: '')]));
    expect(db.apiConfigBox.length, 2, reason: '跳过时不能改动任何一条');
  });

  test('非法条目被跳过，其余条目照常写入', () async {
    final bundle = buildBundle(chat: [
      chatEntry(name: '服务商写错', provider: 'not-a-provider'),
      chatEntry(name: '协议写错', protocol: 'not-a-protocol'),
      chatEntry(name: '没给密钥', apiKey: ''),
      chatEntry(name: '自定义没给 baseUrl', provider: 'custom', model: 'm'),
      chatEntry(name: '正常的', provider: 'moonshot', model: 'moonshot-v1-8k'),
    ]);

    final plan = service().plan(bundle);
    expect(plan.createCount, 1);
    expect(plan.skipCount, 4);

    final result = await service().apply(bundle);
    expect(result.successCount, 1);
    expect(db.apiConfigBox.length, 1);
    expect(db.apiConfigBox.values.single.name, '正常的');
    expectNoPlaintextAnywhere();
  });

  test('结构层被拒的条目也进入预览的跳过行', () {
    final plan = service().plan(buildBundle(
      issues: const [
        ApiBundleIssue(section: '搜索', title: '第 1 条', reason: 'apiKey 不能为空'),
      ],
    ));
    expect(plan.skipCount, 1);
    expect(plan.changes.single.service, BundleService.search);
    expect(plan.changes.single.detail, 'apiKey 不能为空');
  });

  test('搜索提供方要求令牌却缺令牌时跳过', () async {
    final bundle = buildBundle(search: const [
      ApiBundleSearchEntry(
        id: 'tavily-main',
        name: 'Tavily',
        provider: 'tavily',
        baseUrl: 'https://api.tavily.com',
        apiKey: '',
        enabled: true,
        isDefault: false,
      ),
    ]);
    final plan = service().plan(bundle);
    expect(plan.skipCount, 1);
    expect(plan.changes.single.detail, contains('已退役'));
    await service().apply(bundle);
    expect(SearchProviderConfigStore(db: db).configs, isEmpty);
  });

  test('安全存储不可用时整体拒绝，一个字节都不写', () async {
    final target = service(secureStorageAvailable: false);
    expect(target.ensureSupported, throwsA(isA<BundleImportRejected>()));

    final bundle = fullBundle();
    await expectLater(
      target.apply(bundle),
      throwsA(isA<BundleImportRejected>()),
    );
    expect(db.apiConfigBox, isEmpty);
    expect(db.voiceServiceConfig.apiKeyBound, isFalse);
    expect(db.imageServiceConfig.apiKeyBound, isFalse);
    expect(SearchProviderConfigStore(db: db).configs, isEmpty);
  });

  test('退役的搜索条目只跳过、不阻塞其余三类服务', () async {
    // 旧 Provider 的写入入口已删除，包里那一段只进预览的「跳过」行。这条用例
    // 只证明"跳过不阻塞"；它**不再**具备"搜索单条保存失败"的语义（那种失败
    // 路径已经不存在），真实的部分失败由下面那条用例覆盖。
    final result = await service().apply(fullBundle());

    expect(result.outcomes.where((o) => o.service == BundleService.search),
        isEmpty);
    expect(SearchProviderConfigStore(db: db).configs, isEmpty);
    expect(credentialBox.get('v:credential.web-search.tavily-main'), isNull);

    expect(result.failureCount, 0);
    expect(result.successCount, 3);
    expect(db.apiConfigBox.length, 1);
    expect(db.voiceServiceConfig.apiKeyBound, isTrue);
    expect(db.imageServiceConfig.apiKeyBound, isTrue);
  });

  test('聊天单条保存失败不影响其余服务，并如实报告该条失败', () async {
    // 真实失败路径：`saveApiConfig` 抛错（release 下凭据写不进去就抛 StateError，
    // 这里用子类把它稳定复现）。导入必须继续处理语音 / 图像，并把这一条记成
    // 失败而不是静默丢弃。
    final result = await service(database: _ChatSaveFailingDatabaseService())
        .apply(fullBundle());

    final chatOutcome = result.outcomes
        .singleWhere((o) => o.service == BundleService.chat);
    expect(chatOutcome.succeeded, isFalse);
    expect(chatOutcome.reason, isNotEmpty);
    expect(result.failureCount, 1);

    expect(result.successCount, 2);
    expect(db.apiConfigBox, isEmpty);
    expect(db.voiceServiceConfig.apiKeyBound, isTrue);
    expect(db.imageServiceConfig.apiKeyBound, isTrue);
  });

  test('智谱原生搜索凭据单独落地，且不进 app_settings 明文', () async {
    const zhipuKey = 'zhipu-SENTINEL-9x8y7z';
    final bundle = buildBundle(
      zhipuNativeSearch:
          const ApiBundleZhipuNativeSearchEntry(apiKey: zhipuKey),
    );

    final plan = service().plan(bundle);
    expect(plan.createCount, 1);
    expect(plan.skipCount, 0);
    expect(plan.changes.single.service, BundleService.search);
    expect(plan.changes.single.title, '智谱原生搜索');

    final result = await service().apply(bundle);
    expect(result.failureCount, 0);
    expect(result.successCount, 1);
    expect(
      ZhipuNativeSearchCredentialStore(db: db).hasConfiguredCredential,
      isTrue,
      reason: '导入没有写回智谱原生搜索的元数据绑定',
    );
    expect(
      credentialBox.get('v:credential.web-search.zhipu-native-search'),
      zhipuKey,
    );
    // 它和「独立 Provider」是两套存储：导入一类不该在另一类里留下任何痕迹。
    expect(SearchProviderConfigStore(db: db).configs, isEmpty);
    expectNoPlaintextAnywhere();
    expect(
      db.appSettingsBox.values
          .map((v) => v.toString())
          .join('\n')
          .contains(zhipuKey),
      isFalse,
      reason: 'app_settings 里出现了明文密钥',
    );
  });

  test('智谱原生搜索缺 apiKey 时跳过，不影响其余三类服务', () async {
    final bundle = buildBundle(
      chat: [chatEntry()],
      voice: const ApiBundleVoiceEntry(
        apiKey: voiceKey,
        ttsResourceId: '',
        asrResourceId: '',
        defaultVoiceId: '',
      ),
      zhipuNativeSearch: const ApiBundleZhipuNativeSearchEntry(apiKey: ''),
    );

    final plan = service().plan(bundle);
    expect(plan.skipCount, 1);
    expect(plan.changes.last.detail, 'apiKey 不能为空');
    expect(plan.createCount, 2);

    final result = await service().apply(bundle);
    expect(result.successCount, 2);
    expect(
      ZhipuNativeSearchCredentialStore(db: db).hasConfiguredCredential,
      isFalse,
    );
  });

  test('重复导入是幂等的：第二次全部呈覆盖，不产生重复记录', () async {
    await service().apply(fullBundle());
    final plan = service().plan(fullBundle());

    expect(plan.createCount, 0);
    // 聊天那条形状、名称、默认指向都没变，因此是「跳过」而不是「覆盖」；
    // 语音 / 图像 / 搜索比不了密钥，一律覆盖。
    expect(plan.skipCount, 2);
    expect(plan.overwriteCount, 2);

    final result = await service().apply(fullBundle());
    expect(result.failureCount, 0);
    expect(db.apiConfigBox.length, 1);
    expect(SearchProviderConfigStore(db: db).configs.length, 0);
  });

  test('未知音色不会覆盖现有默认音色', () async {
    await db.saveVoiceServiceConfig(
      db.voiceServiceConfig.copyWith(defaultVoiceId: () => 'existing-voice'),
    );

    await service().apply(buildBundle(
      voice: const ApiBundleVoiceEntry(
        apiKey: voiceKey,
        ttsResourceId: 'seed-tts-1.0',
        asrResourceId: 'volc.bigasr.sauc.duration',
        defaultVoiceId: 'not-a-real-voice',
      ),
    ));

    expect(db.voiceServiceConfig.defaultVoiceId, 'existing-voice');
    expect(db.voiceServiceConfig.apiKeyBound, isTrue);
  });

  group('User-Agent 三态往返', () {
    const targetId = 'cfg-relay';
    const oldUserAgent = 'claude-cli/2.0.0 (external, cli)';

    /// 预置一条已带自定义 UA 的配置，供「覆盖 / 保留」两种路径复用。
    Future<void> seedTarget() async {
      await db.apiConfigBox.put(
        targetId,
        ApiConfig(
          id: targetId,
          name: '主力对话',
          provider: 'deepseek',
          modelName: 'deepseek-chat',
          hasCredential: true,
          credentialId: CredentialRepository().credentialIdFor(targetId),
          userAgent: oldUserAgent,
        ),
      );
    }

    test('旧包不带该字段 → 保留目标配置原有 UA，且判为无变化', () async {
      await seedTarget();

      final plan = service().plan(buildBundle(chat: [chatEntry(id: targetId)]));
      expect(plan.skipCount, 1);
      expect(plan.changes.single.detail, contains('一致'));

      await service().apply(buildBundle(chat: [chatEntry(id: targetId)]));
      expect(db.apiConfigBox.get(targetId)!.userAgent, oldUserAgent);
    });

    test('显式空串 → 覆盖并清空 UA，回到客户端默认身份', () async {
      await seedTarget();

      final bundle =
          buildBundle(chat: [chatEntry(id: targetId, userAgent: '')]);
      final plan = service().plan(bundle);
      expect(plan.overwriteCount, 1);

      await service().apply(bundle);
      expect(db.apiConfigBox.get(targetId)!.userAgent, '');
    });

    test('非空值 → 覆盖为目标 UA', () async {
      await seedTarget();

      final bundle = buildBundle(
          chat: [chatEntry(id: targetId, userAgent: 'my-client/1.0')]);
      await service().apply(bundle);

      expect(db.apiConfigBox.get(targetId)!.userAgent, 'my-client/1.0');
    });

    test('程序化构造的超长 UA 被拒绝，不会静默换身份', () async {
      final long = 'x' * 300;
      final plan = service().plan(
          buildBundle(chat: [chatEntry(userAgent: long)]));

      expect(plan.createCount, 0);
      expect(plan.skipCount, 1);
      expect(plan.changes.single.detail, contains('过长'));
    });
  });

  test('预览里不出现密钥的任何字符，只给指纹', () {    final plan = service().plan(fullBundle());
    final text = jsonEncode([
      for (final change in plan.changes)
        [change.title, change.detail, change.keyFingerprint],
    ]);
    for (final secret in [chatKey, voiceKey, imageKey, searchKey]) {
      expect(text.contains(secret), isFalse);
    }
    // 指纹在位，用户仍可三方对照。
    expect(plan.changes.every((c) => c.keyFingerprint.length == 8), isTrue);
  });
}

/// 让聊天的单条保存稳定失败：release 下凭据写不进去时 `saveApiConfig` 抛
/// `StateError`，这里在测试里复现同一条异常出口，用来验证"部分失败"是真的
/// 被吞成单条失败而不是继续跑一遍成功路径。
class _ChatSaveFailingDatabaseService extends DatabaseService {
  @override
  Future<void> saveApiConfig(ApiConfig config) async {
    throw StateError('simulated credential write failure');
  }
}
