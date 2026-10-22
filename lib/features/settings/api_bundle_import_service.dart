/// 把配置包写进四类服务。
///
/// 核心约定：**不新造任何凭据写入通道**，四类服务各自复用既有的绑定路径——
/// 聊天走 `DatabaseService.saveApiConfig`，语音走 `bindVoiceApiKey`，图像走
/// `bindImageApiKey`，搜索走 `SearchProviderConfigStore.save`。这样「明文 Key
/// 不许进 `app_settings`」「非 macOS 的 release 严禁写 Hive 明文 Key」这些既有
/// 红线自动继续生效，不需要为导入功能再实现一遍平台分流。
///
/// 预览与执行共用 [_resolve]：两套判据各写一份，迟早会出现「预览说新增、执行却
/// 覆盖」这种对不上的情况。
library;

import 'package:flutter/foundation.dart';

import 'package:chat_group/core/audio/voice_catalog.dart';
import 'package:chat_group/core/bundle/api_bundle.dart';
import 'package:chat_group/core/bundle/api_bundle_codec.dart';
import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/database/database_service_image.dart';
import 'package:chat_group/core/images/image_service_config.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_protocol.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/storage/credential_repository.dart';
import 'package:chat_group/features/settings/ai_speaker_picker_settings.dart';
import 'package:chat_group/features/settings/api_bundle_import_models.dart';
import 'package:chat_group/features/web_search/data/search_settings_store.dart';
import 'package:chat_group/features/web_search/data/zhipu_native_search_credential_store.dart';
import 'package:chat_group/features/web_search/models/search_models.dart';
import 'package:chat_group/features/web_search/models/search_provider_config.dart';
import 'package:chat_group/features/web_search/security/search_endpoint_validator.dart';

class ApiBundleImportService {
  ApiBundleImportService({
    required DatabaseService db,
    CredentialRepository? credentials,
    SearchProviderConfigStore? searchStore,
    bool? isRelease,
  })  : _db = db,
        _credentials = credentials ?? CredentialRepository(),
        _isRelease = isRelease ?? kReleaseMode,
        _searchStore = searchStore ??
            SearchProviderConfigStore(
              db: db,
              isRelease: isRelease ?? kReleaseMode,
            ),
        // `isRelease` 必须透传：release 下 macOS 的开发回退被禁用，用 `kReleaseMode`
        // 的默认值在注入 `isRelease: false` 的测试里会得到不一致的平台分流。
        _zhipuSearchStore = ZhipuNativeSearchCredentialStore(
          db: db,
          isRelease: isRelease ?? kReleaseMode,
        );

  final DatabaseService _db;
  final CredentialRepository _credentials;
  final SearchProviderConfigStore _searchStore;
  final ZhipuNativeSearchCredentialStore _zhipuSearchStore;
  final bool _isRelease;

  static const String _zhipuNativeSearchTitle = '智谱原生搜索';

  /// 写前唯一硬闸。不通过就**一个字节都不写**。
  ///
  /// 与「逐条失败」严格区分：环境不具备写入凭据的能力时，部分写入只会留下
  /// 半配置状态——`hasCredential` 打上了勾、密钥却没落地，比什么都没做强不了。
  void ensureSupported() {
    if (kIsWeb) {
      throw const BundleImportRejected(
        'Web 端不支持导入授权码：浏览器环境没有可供凭据安全落地的边界。',
      );
    }
    if (!_credentials.secureStorageAvailable) {
      throw const BundleImportRejected('当前环境没有可用的系统安全存储，无法导入密钥。');
    }
  }

  /// 只读预览。不碰安全存储，不写任何 box。
  BundleImportPlan plan(ApiBundle bundle) {
    final resolution = _resolve(bundle);
    return BundleImportPlan(label: bundle.label, changes: resolution.changes);
  }

  /// 执行导入。
  ///
  /// **不做跨服务回滚**：三套存储（`api_configs` Hive、各 `app_settings` 单 Map、
  /// 安全存储）彼此独立，且都已具备单条粒度的回滚。外层补偿会去删已经写好的
  /// 密钥——那不只是回滚失败，还会顺手删掉用户原本可用的旧 Key，把「导入失败」
  /// 升级成「原来能用现在不能用了」。宁可如实报告部分成功。
  Future<BundleImportResult> apply(ApiBundle bundle) async {
    ensureSupported();
    final resolution = _resolve(bundle);
    final outcomes = <BundleImportOutcome>[];

    // 聊天最先：没有可用的对话配置，App 等于不可用，失败要最早暴露。
    final appliedChat = <ApiConfig>[];
    for (final write in resolution.chatWrites) {
      outcomes.add(await _applyChat(write, appliedChat));
    }
    // 默认指针在全部聊天配置写完之后才设：只有目标确实存在且带凭据才指过去，
    // 否则会留下一个指向不存在配置的引用。
    await _applyDefaultPointer(resolution, appliedChat);

    if (resolution.voiceWrite != null) {
      outcomes.add(await _applyVoice(resolution.voiceWrite!));
    }
    if (resolution.imageWrite != null) {
      outcomes.add(await _applyImage(resolution.imageWrite!));
    }
    for (final write in resolution.searchWrites) {
      outcomes.add(await _applySearch(write));
    }
    if (resolution.zhipuSearchWrite != null) {
      outcomes.add(await _applyZhipuNativeSearch(resolution.zhipuSearchWrite!));
    }

    return BundleImportResult(outcomes);
  }

  // ---------------------------------------------------------------- 解析

  _Resolution _resolve(ApiBundle bundle) {
    final changes = <BundleChange>[
      // 结构层被拒的条目先列出来。它们不是致命错误：一条坏的搜索配置不该挡住
      // 其余三类服务。
      for (final issue in bundle.issues)
        BundleChange(
          service: _serviceForLabel(issue.section),
          action: BundleChangeAction.skip,
          title: issue.title,
          detail: issue.reason,
        ),
    ];

    final existingConfigs = _db.apiConfigBox.values.toList(growable: false);
    final chatWrites = <_ChatWrite>[];
    for (final entry in bundle.chat) {
      final id = _resolveChat(entry, existingConfigs, changes);
      if (id != null) chatWrites.add(id);
    }

    final voiceWrite = _resolveVoice(bundle.voice, changes);
    final imageWrite = _resolveImage(bundle.image, changes);
    final searchWrites = <_SearchWrite>[];
    for (final entry in bundle.search) {
      final write = _resolveSearch(entry, changes);
      if (write != null) searchWrites.add(write);
    }
    final zhipuSearchWrite =
        _resolveZhipuNativeSearch(bundle.zhipuNativeSearch, changes);

    return _Resolution(
      changes: changes,
      chatWrites: chatWrites,
      voiceWrite: voiceWrite,
      imageWrite: imageWrite,
      searchWrites: searchWrites,
      zhipuSearchWrite: zhipuSearchWrite,
    );
  }

  /// 返回非 null 表示这条要写；返回 null 表示已作为「跳过」记录进 [changes]。
  _ChatWrite? _resolveChat(
    ApiBundleChatEntry entry,
    List<ApiConfig> existing,
    List<BundleChange> changes,
  ) {
    final fingerprint = _fingerprint(entry.apiKey);
    void skip(String reason) => changes.add(BundleChange(
          service: BundleService.chat,
          action: BundleChangeAction.skip,
          title: entry.name,
          detail: reason,
          keyFingerprint: fingerprint,
        ));

    final provider = _providerByName(entry.provider);
    if (provider == null) {
      skip('未知的服务商「${entry.provider}」');
      return null;
    }
    if (entry.id.isNotEmpty && entry.id.trim() != entry.id) {
      skip('配置 id 首尾不能有空格');
      return null;
    }
    // 解析层已经拦过空密钥，这里再拦一次：`ApiBundle` 可以被直接构造出来
    // （生成工具、测试、将来的其它入口），服务才是语义上的权威。
    if (entry.apiKey.isEmpty) {
      skip('apiKey 不能为空');
      return null;
    }
    final protocol = entry.protocol.isEmpty
        ? provider.defaultProtocol
        : _protocolByName(entry.protocol);
    if (protocol == null) {
      skip('未知的协议「${entry.protocol}」');
      return null;
    }
    if (provider == ApiProvider.custom && entry.baseUrl.isEmpty) {
      skip('自定义服务商必须提供 baseUrl');
      return null;
    }

    final model = entry.model.isEmpty
        ? (ApiProvider.defaultModels[provider.name] ?? '')
        : entry.model;
    final matches = _matchChatConfigs(entry, provider, model, existing);
    if (matches.length > 1) {
      // 绝不猜。猜错的代价是把用户的另一套配置改掉，而用户看不出来是被谁改的。
      skip('匹配到 ${matches.length} 条现有配置，无法确定覆盖哪一条；请改用带 id 的配置包');
      return null;
    }

    final target = matches.isEmpty ? null : matches.single;
    // 「无变化」还要看默认指向是否已经到位：条目声明了 makeDefault，但本机的
    // 选人器已经指着它，那这次导入在这条上确实什么都没改。只看形状会把
    // 「导出后再导回同一台机器」显示成一堆「覆盖」，让用户以为有东西被动过。
    final pointerSatisfied = target != null &&
        target.id == AiSpeakerPickerSettings(_db).selectedConfigId();
    if (target != null &&
        (!entry.setDefault || pointerSatisfied) &&
        _sameChatShape(
          target: target,
          provider: provider,
          model: model,
          baseUrl: entry.baseUrl,
          protocol: protocol,
          name: entry.name,
          enableWorkPromptCaching: entry.enableWorkPromptCaching,
        )) {
      skip('与现有配置一致，保持不变');
      return null;
    }

    changes.add(BundleChange(
      service: BundleService.chat,
      action: target == null
          ? BundleChangeAction.create
          : BundleChangeAction.overwrite,
      title: entry.name,
      detail: target == null
          ? '${provider.label} · ${model.isEmpty ? '默认模型' : model}'
          : '更新为 ${provider.label} · ${model.isEmpty ? '默认模型' : model} 并替换密钥',
      keyFingerprint: fingerprint,
    ));
    return _ChatWrite(
        entry: entry,
        target: target,
        provider: provider,
        protocol: protocol,
        model: model);
  }

  _VoiceWrite? _resolveVoice(
    ApiBundleVoiceEntry? entry,
    List<BundleChange> changes,
  ) {
    if (entry == null) return null;
    if (entry.apiKey.isEmpty) {
      changes.add(const BundleChange(
        service: BundleService.voice,
        action: BundleChangeAction.skip,
        title: '火山引擎语音服务',
        detail: 'apiKey 不能为空',
      ));
      return null;
    }
    final current = _db.voiceServiceConfig;
    // 语音 / 图像都不做「内容一致就跳过」：判定一致必须比对密钥，而比对密钥
    // 要么读安全存储（没必要），要么比指纹（指纹相同也只说明钥匙相同，元数据
    // 仍可能不同）。已配置即覆盖，语义确定，且重复导入是幂等的。
    changes.add(BundleChange(
      service: BundleService.voice,
      action: current.isConfigured
          ? BundleChangeAction.overwrite
          : BundleChangeAction.create,
      title: '火山引擎语音服务',
      detail: current.isConfigured ? '替换语音 API Key' : '写入语音 API Key',
      keyFingerprint: _fingerprint(entry.apiKey),
    ));
    return _VoiceWrite(entry);
  }

  _ImageWrite? _resolveImage(
    ApiBundleImageEntry? entry,
    List<BundleChange> changes,
  ) {
    if (entry == null) return null;
    final fingerprint = _fingerprint(entry.apiKey);
    void skip(String reason) => changes.add(BundleChange(
          service: BundleService.image,
          action: BundleChangeAction.skip,
          title: '图像服务',
          detail: reason,
          keyFingerprint: fingerprint,
        ));

    if (entry.apiKey.isEmpty) {
      skip('apiKey 不能为空');
      return null;
    }
    final uri = Uri.tryParse(entry.baseUrl);
    if (uri == null ||
        !uri.isAbsolute ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      // 这里不套用 SearchEndpointValidator：那个校验器带的是搜索域的
      // 「release 必须 HTTPS / 禁本地网关」策略，把它套到生图端点上会拒掉
      // 用户本来能用的内网部署。只做「是不是一个绝对 http(s) 地址」的形状校验。
      skip('baseUrl 必须是绝对的 http/https 地址');
      return null;
    }

    final current = _db.imageServiceConfig;
    changes.add(BundleChange(
      service: BundleService.image,
      action: current.isConfigured
          ? BundleChangeAction.overwrite
          : BundleChangeAction.create,
      title: '${entry.model} · ${entry.baseUrl}',
      detail: current.isConfigured ? '替换图像 API Key' : '写入图像 API Key',
      keyFingerprint: fingerprint,
    ));
    return _ImageWrite(entry);
  }

  _SearchWrite? _resolveSearch(
    ApiBundleSearchEntry entry,
    List<BundleChange> changes,
  ) {
    final fingerprint = _fingerprint(entry.apiKey);
    void skip(String reason) => changes.add(BundleChange(
          service: BundleService.search,
          action: BundleChangeAction.skip,
          title: entry.name,
          detail: reason,
          keyFingerprint: fingerprint,
        ));

    final id = SearchProviderConfig.canonicalizeId(entry.id);
    if (id == null) {
      skip('id 为空、含首尾空格/控制字符，或超过长度上限');
      return null;
    }
    final kind = _searchKindByName(entry.provider);
    if (kind == null) {
      skip('未知的搜索提供方「${entry.provider}」');
      return null;
    }
    final requiresCredential =
        searchProviderRequiresCredential(kind, isRelease: _isRelease);
    if (requiresCredential && entry.apiKey.isEmpty) {
      skip('该搜索提供方必须配置访问令牌');
      return null;
    }
    if (!searchProviderUsesFixedEndpoint(kind)) {
      if (entry.baseUrl.isEmpty) {
        skip('Base URL 不能为空');
        return null;
      }
      final validation = SearchEndpointValidator.validate(
        entry.baseUrl,
        isRelease: _isRelease,
        allowLocalDevelopmentGateway: _searchStore.allowLocalDevelopmentGateway,
      );
      if (!validation.isValid) {
        skip(validation.message);
        return null;
      }
    }

    final existing = _searchStore.findById(id);
    changes.add(BundleChange(
      service: BundleService.search,
      action: existing == null
          ? BundleChangeAction.create
          : BundleChangeAction.overwrite,
      title: '${entry.name}（${kind.name}）',
      detail: existing == null ? '新增搜索提供方' : '更新搜索提供方并替换令牌',
      keyFingerprint: fingerprint,
    ));
    return _SearchWrite(entry: entry, id: id, kind: kind, existing: existing);
  }

  /// 智谱原生搜索是**另一类**搜索凭据，落点与上面那条 Provider 路径完全不同
  /// （`ZhipuNativeSearchCredentialStore`，不是 `SearchProviderConfigStore`）。
  /// 它不需要 id / provider / baseUrl 这些字段，因此单独走一条解析与写入。
  _ZhipuNativeSearchWrite? _resolveZhipuNativeSearch(
    ApiBundleZhipuNativeSearchEntry? entry,
    List<BundleChange> changes,
  ) {
    if (entry == null) return null;
    if (entry.apiKey.isEmpty) {
      changes.add(const BundleChange(
        service: BundleService.search,
        action: BundleChangeAction.skip,
        title: _zhipuNativeSearchTitle,
        detail: 'apiKey 不能为空',
      ));
      return null;
    }
    // 与语音 / 图像同一口径：不再比对密钥内容。判定一致势必要读一次安全存储，
    // 而「已配置即覆盖」语义确定，且重复导入本来就是幂等的。
    final configured = _zhipuSearchStore.hasConfiguredCredential;
    changes.add(BundleChange(
      service: BundleService.search,
      action:
          configured ? BundleChangeAction.overwrite : BundleChangeAction.create,
      title: _zhipuNativeSearchTitle,
      detail: configured ? '替换智谱原生搜索 API Key' : '写入智谱原生搜索 API Key',
      keyFingerprint: _fingerprint(entry.apiKey),
    ));
    return _ZhipuNativeSearchWrite(entry);
  }

  // ---------------------------------------------------------------- 执行

  Future<BundleImportOutcome> _applyChat(
    _ChatWrite write,
    List<ApiConfig> applied,
  ) async {
    final target = write.target;
    final config = ApiConfig(
      // 覆盖时**必须沿用原 id**：`AICharacter.apiConfigId` 指着它，换 id 会造出
      // 「角色指向一个不存在的配置」。
      id: target?.id ?? (write.entry.id.isEmpty ? null : write.entry.id),
      name: write.entry.name,
      provider: write.provider.name,
      modelName: write.model,
      apiKey: write.entry.apiKey,
      customBaseUrl: write.entry.baseUrl,
      // createdAt 是 final；覆盖时透传旧值，否则每次导入都会把「创建时间」刷新。
      createdAt: target?.createdAt,
      apiProtocol: write.protocol.name,
      enableWorkPromptCaching: write.entry.enableWorkPromptCaching ??
          target?.enableWorkPromptCaching ??
          false,
    );
    try {
      await _db.saveApiConfig(config);
      applied.add(config);
      return BundleImportOutcome(
        service: BundleService.chat,
        title: write.entry.name,
        succeeded: true,
      );
    } on Object catch (error) {
      // release 下凭据写不进去时 `saveApiConfig` 会直接抛 StateError。单条失败
      // 不能掀翻整包——其余三类服务与其余配置仍有价值。
      return BundleImportOutcome(
        service: BundleService.chat,
        title: write.entry.name,
        succeeded: false,
        reason: _chatFailureReason(error),
      );
    }
  }

  Future<void> _applyDefaultPointer(
    _Resolution resolution,
    List<ApiConfig> applied,
  ) async {
    final wanted = resolution.chatWrites
        .where((write) => write.entry.setDefault)
        .map((write) => write.entry.name)
        .toSet();
    if (wanted.isEmpty) return;
    for (final config in applied) {
      if (!wanted.contains(config.name)) continue;
      await AiSpeakerPickerSettings(_db).select(config.id);
      return;
    }
  }

  Future<BundleImportOutcome> _applyVoice(_VoiceWrite write) async {
    const title = '火山引擎语音服务';
    final entry = write.entry;
    // 既有绑定器自带平台分流与回退，这里只负责把结果翻译成展示文案。
    final failure = await _db.bindVoiceApiKey(entry.apiKey);
    if (failure != null) {
      return BundleImportOutcome(
        service: BundleService.voice,
        title: title,
        succeeded: false,
        reason: failure,
      );
    }
    final current = _db.voiceServiceConfig;
    await _db.saveVoiceServiceConfig(current.copyWith(
      ttsResourceId: entry.ttsResourceId.isEmpty ? null : entry.ttsResourceId,
      asrResourceId: entry.asrResourceId.isEmpty ? null : entry.asrResourceId,
      // 未知音色不写入：`resolveVoiceId` 对未知 id 返回 null，写了等于没写，
      // 还会把用户原来的默认音色冲掉。
      defaultVoiceId: voicePresetById(entry.defaultVoiceId) == null
          ? null
          : () => entry.defaultVoiceId,
    ));
    return const BundleImportOutcome(
      service: BundleService.voice,
      title: title,
      succeeded: true,
    );
  }

  Future<BundleImportOutcome> _applyImage(_ImageWrite write) async {
    final entry = write.entry;
    final title = entry.model;
    final failure = await _db.bindImageApiKey(entry.apiKey);
    if (failure != null) {
      return BundleImportOutcome(
        service: BundleService.image,
        title: title,
        succeeded: false,
        reason: failure,
      );
    }
    final current = _db.imageServiceConfig;
    await _db.saveImageServiceConfig(current.copyWith(
      baseUrl: entry.baseUrl,
      model: entry.model,
      size: entry.size.isEmpty
          ? null
          : normalizeImageSize(entry.size, baseUrl: entry.baseUrl),
      quality: entry.quality,
      disableWatermark: entry.disableWatermark,
    ));
    return BundleImportOutcome(
      service: BundleService.image,
      title: title,
      succeeded: true,
    );
  }

  Future<BundleImportOutcome> _applySearch(_SearchWrite write) async {
    final entry = write.entry;
    final existing = write.existing;
    final config = SearchProviderConfig(
      id: write.id,
      name: entry.name,
      provider: write.kind,
      baseUrl: entry.baseUrl,
      enabled: entry.enabled,
      // 包里没点名要设为默认时，保留现有默认标记——否则覆盖一条本来就是默认的
      // 配置会顺手把它降级，而用户没要求这么做。
      isDefault: entry.isDefault || (existing?.isDefault ?? false),
    );
    // 失败是返回值而不是异常；其内部自带 repair intent 与单条回滚，
    // 外层不要再包事务。
    final result = await _searchStore.save(
      config,
      enteredCredential: entry.apiKey,
    );
    return BundleImportOutcome(
      service: BundleService.search,
      title: entry.name,
      succeeded: result.isSuccess,
      reason: result.isSuccess ? '' : (result.errorMessage ?? '搜索配置保存失败'),
    );
  }

  Future<BundleImportOutcome> _applyZhipuNativeSearch(
    _ZhipuNativeSearchWrite write,
  ) async {
    // 与设置页那张卡片走同一个调用：平台分流、release 边界与 macOS 的 Hive
    // 回退都由它自己处理。失败是返回值不是异常，取 message 记为单条失败原因，
    // 其余服务继续。
    final result = await _zhipuSearchStore.save(write.entry.apiKey);
    return BundleImportOutcome(
      service: BundleService.search,
      title: _zhipuNativeSearchTitle,
      succeeded: result.isSuccess,
      reason: result.isSuccess ? '' : (result.message ?? '智谱原生搜索凭据写入失败'),
    );
  }

  // ---------------------------------------------------------------- 工具

  /// 按 [entry] 的 id（优先）或「服务商 + 模型 + Base URL」匹配现有聊天配置。
  static List<ApiConfig> _matchChatConfigs(
    ApiBundleChatEntry entry,
    ApiProvider provider,
    String model,
    List<ApiConfig> existing,
  ) {
    if (entry.id.isNotEmpty) {
      return existing.where((c) => c.id == entry.id).toList(growable: false);
    }
    return existing
        .where((config) =>
            config.provider == provider.name &&
            config.modelName == model &&
            _normalizeUrl(config.customBaseUrl) == _normalizeUrl(entry.baseUrl))
        .toList(growable: false);
  }

  static bool _sameChatShape({
    required ApiConfig target,
    required ApiProvider provider,
    required String model,
    required String baseUrl,
    required ApiProtocol protocol,
    required String name,
    bool? enableWorkPromptCaching,
  }) =>
      // 名称也算「元数据」：只改名也是一次真实变更，判成「无变化」会让用户
      // 反复导入却看不到任何效果，而且没有任何提示。
      target.name == name &&
      target.provider == provider.name &&
      target.modelName == model &&
      _normalizeUrl(target.customBaseUrl) == _normalizeUrl(baseUrl) &&
      target.apiProtocol == protocol.name &&
      (enableWorkPromptCaching == null ||
          target.enableWorkPromptCaching == enableWorkPromptCaching);

  static String _normalizeUrl(String raw) {
    var value = raw.trim();
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }

  static ApiProvider? _providerByName(String name) {
    for (final provider in ApiProvider.values) {
      if (provider.name == name) return provider;
    }
    return null;
  }

  static ApiProtocol? _protocolByName(String name) {
    for (final protocol in ApiProtocol.values) {
      if (protocol.name == name) return protocol;
    }
    return null;
  }

  static SearchProviderKind? _searchKindByName(String name) {
    for (final kind in SearchProviderKind.values) {
      if (kind.name == name) return kind;
    }
    return null;
  }

  static BundleService _serviceForLabel(String label) {
    for (final service in BundleService.values) {
      if (service.label == label) return service;
    }
    return BundleService.chat;
  }

  /// 指纹实现由 [apiBundleKeyFingerprint] 统一提供，导出侧与生成脚本共用同一份。
  static String _fingerprint(String secret) => apiBundleKeyFingerprint(secret);

  /// 按环境区分文案，因为**两种环境下的真相不同**。
  ///
  /// 非 release 下凭据写不进安全存储时，明文会留在该记录自己的 Hive 字段里
  /// （既有行为，不是本特性引入）。此时对外说「密钥保存失败」是不准确的，
  /// 说「绝无明文」更是错的——两种情况都要如实说。
  static String _chatFailureReason(Object error) {
    if (kReleaseMode) {
      return '密钥无法写入系统安全存储，配置未保存';
    }
    return '密钥未能写入安全存储（开发模式下可能已留存在本地配置记录中）';
  }
}

/// [_resolve] 的产物：预览行 + 待执行动作。
class _Resolution {
  const _Resolution({
    required this.changes,
    required this.chatWrites,
    required this.voiceWrite,
    required this.imageWrite,
    required this.searchWrites,
    required this.zhipuSearchWrite,
  });

  final List<BundleChange> changes;
  final List<_ChatWrite> chatWrites;
  final _VoiceWrite? voiceWrite;
  final _ImageWrite? imageWrite;
  final List<_SearchWrite> searchWrites;
  final _ZhipuNativeSearchWrite? zhipuSearchWrite;
}

class _ChatWrite {
  const _ChatWrite({
    required this.entry,
    required this.target,
    required this.provider,
    required this.protocol,
    required this.model,
  });

  final ApiBundleChatEntry entry;
  final ApiConfig? target;
  final ApiProvider provider;
  final ApiProtocol protocol;
  final String model;
}

class _VoiceWrite {
  const _VoiceWrite(this.entry);

  final ApiBundleVoiceEntry entry;
}

class _ImageWrite {
  const _ImageWrite(this.entry);

  final ApiBundleImageEntry entry;
}

class _SearchWrite {
  const _SearchWrite({
    required this.entry,
    required this.id,
    required this.kind,
    required this.existing,
  });

  final ApiBundleSearchEntry entry;
  final String id;
  final SearchProviderKind kind;
  final SearchProviderConfig? existing;
}

class _ZhipuNativeSearchWrite {
  const _ZhipuNativeSearchWrite(this.entry);

  final ApiBundleZhipuNativeSearchEntry entry;
}
