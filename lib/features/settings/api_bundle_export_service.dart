/// 把本机已经配好的四类服务打成授权码，交给另一个客户端导入。
///
/// 这是**读取**既有凭据并封装的唯一入口，和「API Key 连接测试红线」不冲突：
/// 那条红线禁止的是「为测一下而临时写入/回读/删除」，而这里是用户明确发起的
/// 导出，读的就是要导出的东西本身。
///
/// 与 [ApiBundleImportService] 严格对称：导出产出的载荷**先自己解析一遍**
/// （`ApiBundle.parse`）才交出去。生成一份导入侧不肯接受的配置包，用户拿到另一台
/// 机器上才发现「校验失败」，而那时已经没有办法回查是哪一项写坏了。
library;

import 'package:chat_group/core/bundle/api_bundle.dart';
import 'package:chat_group/core/bundle/api_bundle_codec.dart';
import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/database/database_service_image.dart';
import 'package:chat_group/core/storage/credential_repository.dart';
import 'package:chat_group/features/settings/ai_speaker_picker_settings.dart';
import 'package:chat_group/features/settings/api_bundle_import_models.dart';
import 'package:chat_group/features/web_search/data/search_settings_store.dart';
import 'package:chat_group/features/web_search/data/zhipu_native_search_credential_store.dart';

/// 导出清单里的一行（含被略过的那些）。
class ApiBundleExportEntry {
  const ApiBundleExportEntry({
    required this.service,
    required this.title,
    this.detail = '',
    this.fingerprint = '',
  });

  final BundleService service;
  final String title;
  final String detail;
  final String fingerprint;
}

class ApiBundleExportResult {
  const ApiBundleExportResult({
    required this.code,
    required this.included,
    required this.omitted,
  });

  /// 授权码。**等同于一整份密钥**，不要落盘、不要进日志、不要进备份。
  final String code;

  final List<ApiBundleExportEntry> included;

  /// 配了、但这次没能导出的项（多半是密钥读不出来），带原因。
  ///
  /// 必须单列而不是静默跳过：用户以为导全了、实际少了一条，等对方发现某个功能
  /// 用不了时，已经无从判断是导出漏了还是对方配错了。
  final List<ApiBundleExportEntry> omitted;

  bool get hasContent => included.isNotEmpty;
}

class ApiBundleExportService {
  ApiBundleExportService({
    required DatabaseService db,
    CredentialRepository? credentials,
  })  : _db = db,
        _credentials = credentials ?? CredentialRepository();

  final DatabaseService _db;
  final CredentialRepository _credentials;

  Future<ApiBundleExportResult> export({
    String secret = defaultBundleSecret,
  }) async {
    final included = <ApiBundleExportEntry>[];
    final omitted = <ApiBundleExportEntry>[];
    final payload = <String, dynamic>{
      'v': ApiBundle.supportedVersion,
      'label': '本机配置导出',
      'issuedAt': DateTime.now().toUtc().toIso8601String(),
    };

    final chat = await _collectChat(included, omitted);
    if (chat.isNotEmpty) payload['chat'] = chat;

    final voice = await _collectVoice(included, omitted);
    if (voice != null) payload['voice'] = voice;

    final image = await _collectImage(included, omitted);
    if (image != null) payload['image'] = image;

    for (final config in SearchProviderConfigStore(db: _db).configs) {
      omitted.add(ApiBundleExportEntry(
          service: BundleService.search,
          title: config.name,
          detail: '旧搜索提供商已退役，未读取或导出凭据'));
    }

    final zhipuSearch = await _collectZhipuNativeSearch(included, omitted);
    if (zhipuSearch != null) payload['zhipuNativeSearch'] = zhipuSearch;

    // 自检：导出侧拒绝生成一份导入侧不肯接受的包。
    final selfCheck = ApiBundle.parse(payload);
    // 自检只对整包级问题抛异常；条目级问题说明某个**字段**带不走（例如超过
    // 上限的 User-Agent：解析侧会保留目标机器上的原值并记一条 issue）。把它
    // 单列进「未导出」，导出结果才不会替用户宣称"这份包和本机一致"。
    for (final issue in selfCheck.issues) {
      omitted.add(ApiBundleExportEntry(
        service: _serviceForLabel(issue.section),
        title: issue.title,
        detail: '导出校验：${issue.reason}',
      ));
    }

    return ApiBundleExportResult(
      code: ApiBundleCodec.seal(payload, secret: secret),
      included: included,
      omitted: omitted,
    );
  }

  Future<List<Map<String, dynamic>>> _collectChat(
    List<ApiBundleExportEntry> included,
    List<ApiBundleExportEntry> omitted,
  ) async {
    const service = BundleService.chat;
    final defaultConfigId = AiSpeakerPickerSettings(_db).selectedConfigId();
    final result = <Map<String, dynamic>>[];

    for (final config in _db.apiConfigBox.values) {
      if (!config.hasCredential) continue;
      final read = await _credentials.read(config.id);
      final apiKey = read.value ?? '';
      if (!read.isAvailable || apiKey.isEmpty) {
        omitted.add(ApiBundleExportEntry(
          service: service,
          title: config.name,
          detail: '已绑定但密钥读不出来（系统安全存储不可用）',
        ));
        continue;
      }
      result.add(<String, dynamic>{
        // 带上 id：导入侧按 id 优先匹配，能精确覆盖同一台机器上的同一条配置，
        // 而不是在别处再造一条一模一样的。
        'id': config.id,
        'name': config.name,
        'provider': config.provider,
        'modelName': config.modelName,
        'customBaseUrl': config.customBaseUrl,
        'apiProtocol': config.apiProtocol,
        'enableWorkPromptCaching': config.enableWorkPromptCaching,
        'userAgent': config.userAgent,
        'apiKey': apiKey,
        if (config.id == defaultConfigId) 'makeDefault': true,
      });
      included.add(ApiBundleExportEntry(
        service: service,
        title: config.name,
        detail: '${config.provider} · ${config.modelName}',
        fingerprint: apiBundleKeyFingerprint(apiKey),
      ));
    }
    return result;
  }

  Future<Map<String, dynamic>?> _collectVoice(
    List<ApiBundleExportEntry> included,
    List<ApiBundleExportEntry> omitted,
  ) async {
    const service = BundleService.voice;
    final config = _db.voiceServiceConfig;
    if (!config.isConfigured) return null;

    final apiKey = await _db.readVoiceApiKey() ?? '';
    if (apiKey.isEmpty) {
      omitted.add(const ApiBundleExportEntry(
        service: service,
        title: '火山引擎语音服务',
        detail: '已绑定但密钥读不出来（系统安全存储不可用）',
      ));
      return null;
    }
    included.add(ApiBundleExportEntry(
      service: service,
      title: '火山引擎语音服务',
      detail: config.ttsResourceId,
      fingerprint: apiBundleKeyFingerprint(apiKey),
    ));
    return <String, dynamic>{
      'apiKey': apiKey,
      'ttsResourceId': config.ttsResourceId,
      'asrResourceId': config.asrResourceId,
      if (config.defaultVoiceId != null)
        'defaultVoiceId': config.defaultVoiceId,
    };
  }

  Future<Map<String, dynamic>?> _collectImage(
    List<ApiBundleExportEntry> included,
    List<ApiBundleExportEntry> omitted,
  ) async {
    const service = BundleService.image;
    final config = _db.imageServiceConfig;
    if (!config.isConfigured) return null;

    final apiKey = await _db.readImageApiKey() ?? '';
    if (apiKey.isEmpty) {
      omitted.add(const ApiBundleExportEntry(
        service: service,
        title: '图像服务',
        detail: '已绑定但密钥读不出来（系统安全存储不可用）',
      ));
      return null;
    }
    included.add(ApiBundleExportEntry(
      service: service,
      title: config.model,
      detail: config.baseUrl,
      fingerprint: apiBundleKeyFingerprint(apiKey),
    ));
    return <String, dynamic>{
      'apiKey': apiKey,
      'baseUrl': config.baseUrl,
      'model': config.model,
      'size': config.size,
      'quality': config.quality,
      'disableWatermark': config.disableWatermark,
    };
  }

  Future<Map<String, dynamic>?> _collectZhipuNativeSearch(
    List<ApiBundleExportEntry> included,
    List<ApiBundleExportEntry> omitted,
  ) async {
    const service = BundleService.search;
    const title = '智谱原生搜索';
    final store = ZhipuNativeSearchCredentialStore(db: _db);
    if (!store.hasConfiguredCredential) return null;

    final apiKey = await store.resolve() ?? '';
    if (apiKey.isEmpty) {
      omitted.add(const ApiBundleExportEntry(
        service: service,
        title: title,
        detail: '已绑定但密钥读不出来（系统安全存储不可用）',
      ));
      return null;
    }
    included.add(ApiBundleExportEntry(
      service: service,
      title: title,
      detail: '智谱 AI · 原生联网',
      fingerprint: apiBundleKeyFingerprint(apiKey),
    ));
    return <String, dynamic>{'apiKey': apiKey};
  }

  /// 把解析层的服务名映射回枚举。导入侧有同名实现，两边都只做一次全等匹配。
  static BundleService _serviceForLabel(String label) {
    for (final service in BundleService.values) {
      if (service.label == label) return service;
    }
    return BundleService.chat;
  }
}
