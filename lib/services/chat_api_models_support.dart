part of 'chat_api_service.dart';

/// 服务商返回的一条可选模型。
class ProviderModelInfo {
  final String id;
  final String? displayName;

  /// 上下文窗口；上游没给就是 null（不要拿猜的值去覆盖用户声明）。
  final int? contextWindow;

  /// 单次输出上限；同样允许缺失。
  final int? maxOutputTokens;

  /// 是否接受图片输入；`input_modalities` 缺失时为 null。
  final bool? supportsVision;

  const ProviderModelInfo({
    required this.id,
    this.displayName,
    this.contextWindow,
    this.maxOutputTokens,
    this.supportsVision,
  });
}

/// 取模型清单的结果。失败只描述原因，绝不回显上游正文。
class ProviderModelCatalog {
  final bool ok;
  final List<ProviderModelInfo> models;
  final String message;

  const ProviderModelCatalog._(this.ok, this.models, this.message);

  factory ProviderModelCatalog.success(List<ProviderModelInfo> models) =>
      ProviderModelCatalog._(true, models, '');

  factory ProviderModelCatalog.failure(String message) =>
      ProviderModelCatalog._(false, const <ProviderModelInfo>[], message);
}

extension _ChatApiServiceModels on ChatApiService {
  /// 列表接口很快，不需要跟补全请求一样的长超时。
  static const Duration _modelsRequestTimeout = Duration(seconds: 15);

  /// [ChatApiService.fetchModels] 的实现：主地址失败且不是鉴权问题时，按服务商规范
  /// 地址再试一次（**仅限同一来源**，见 [_canonicalBaseFor]）；两次都失败时汇报主地址
  /// 的原因——那才是用户在表单里看到、能改的那个地址。
  Future<ProviderModelCatalog> _fetchModelCatalog({
    required String apiKey,
    required ApiProvider provider,
    ApiProtocol apiProtocol = ApiProtocol.defaultValue,
    String? customBaseUrl,
  }) async {
    if (kIsWeb) {
      return ProviderModelCatalog.failure(
        ChatApiService._webNetworkUnsupportedMessage,
      );
    }
    final configuredBase = _configuredBaseUrl(
      provider: provider,
      customBaseUrl: customBaseUrl,
    );
    if (configuredBase.isEmpty) {
      return ProviderModelCatalog.failure('请先填写 Base URL');
    }

    final primaryUrl = _modelsUrl(configuredBase);
    final primary = await _fetchModelsOnce(
      apiKey: apiKey,
      url: primaryUrl,
      apiProtocol: apiProtocol,
    );
    if (primary.ok || primary.authRejected) return primary;

    final canonicalBase = _canonicalBaseFor(
      provider: provider,
      configuredBase: configuredBase,
    );
    if (canonicalBase == null) return primary;
    final fallbackUrl = _modelsUrl(canonicalBase);
    if (fallbackUrl == primaryUrl) return primary;
    final retried = await _fetchModelsOnce(
      apiKey: apiKey,
      url: fallbackUrl,
      apiProtocol: apiProtocol,
    );
    return retried.ok ? retried : primary;
  }

  Future<ProviderModelCatalog> _fetchModelsOnce({
    required String apiKey,
    required String url,
    required ApiProtocol apiProtocol,
  }) async {
    try {
      final response = await _dio.get<ResponseBody>(
        url,
        options: Options(
          headers: _requestHeaders(apiKey: apiKey, apiProtocol: apiProtocol),
          responseType: ResponseType.stream,
          receiveTimeout: _modelsRequestTimeout,
          // 不让底层客户端自动跟随重定向：跟随会把整个 headers map（含 API Key）
          // 原样发到 Location 指向的来源，跨来源 302 因此绕过了"凭据只发给用户配置
          // 的地址"这条边界。仓库里其它带凭据的客户端（搜索、图像、GitHub 技能）
          // 同样关掉它。
          followRedirects: false,
          validateStatus: (status) => status != null && status < 600,
        ),
      );
      final data = await _readBoundedResponseData(
        response.data,
        ChatApiService.defaultMaxResponseBytes,
      );
      if (response.statusCode != 200) {
        return ProviderModelCatalog.failure(
          _modelsFailureMessage(response.statusCode),
        );
      }
      return _parseModelCatalog(data, apiProtocol: apiProtocol);
    } on _ChatResponseTooLargeException {
      return ProviderModelCatalog.failure('模型列表响应超过安全大小限制');
    } on DioException catch (e) {
      return ProviderModelCatalog.failure(_dioErrorMessage(e));
    } catch (_) {
      return ProviderModelCatalog.failure('获取模型列表失败');
    }
  }

  /// 清单的字段拼写随协议不同：Gemini 原生用 `name`（`models/gemini-…` 资源路径）
  /// 当模型标识、能力字段是驼峰；OpenAI 兼容与 Anthropic 用 `id` 与下划线。
  ProviderModelCatalog _parseModelCatalog(
    Object? data, {
    required ApiProtocol apiProtocol,
  }) {
    if (data is! Map) {
      return ProviderModelCatalog.failure('模型列表响应格式无效');
    }
    final rawList = data['data'] ?? data['models'];
    if (rawList is! List) {
      return ProviderModelCatalog.failure('模型列表响应格式无效');
    }
    final gemini = apiProtocol == ApiProtocol.geminiGenerateContent;
    final seen = <String>{};
    final models = <ProviderModelInfo>[];
    for (final item in rawList) {
      if (item is! Map) continue;
      final id = _modelIdFrom(item, gemini: gemini);
      if (id.isEmpty || !seen.add(id)) continue;
      models.add(ProviderModelInfo(
        id: id,
        displayName: _firstNonEmptyString(
          item,
          gemini
              ? const ['displayName', 'display_name']
              : const ['name', 'display_name', 'displayName'],
        ),
        contextWindow: _firstPositiveInt(
          item,
          gemini
              ? const ['inputTokenLimit', 'input_token_limit', 'context_window']
              : const [
                  'context_window',
                  'context_length',
                  'input_token_limit',
                ],
        ),
        maxOutputTokens: _firstPositiveInt(
          item,
          gemini
              ? const [
                  'outputTokenLimit',
                  'output_token_limit',
                  'max_output_tokens',
                ]
              : const [
                  'max_output_tokens',
                  'max_output_length',
                  'output_token_limit',
                ],
        ),
        supportsVision: _supportsVision(item),
      ));
    }
    if (models.isEmpty) {
      return ProviderModelCatalog.failure('服务端未返回可用模型');
    }
    return ProviderModelCatalog.success(models);
  }

  /// Gemini 的 `name` 带 `models/` 资源前缀，而请求路径里的那段前缀由
  /// `_appendProtocolPath` 自己补上；原样留下会让路径变成 `models/models%2F…`。
  String _modelIdFrom(Map item, {required bool gemini}) {
    final raw =
        _nonEmptyString(item['id']) ?? _nonEmptyString(item['name']) ?? '';
    if (!gemini) return raw;
    const prefix = 'models/';
    return raw.startsWith(prefix) ? raw.substring(prefix.length) : raw;
  }

  String? _firstNonEmptyString(Map item, List<String> keys) {
    for (final key in keys) {
      final value = _nonEmptyString(item[key]);
      if (value != null) return value;
    }
    return null;
  }

  bool? _supportsVision(Map item) {
    final modalities = item['input_modalities'];
    if (modalities is List) {
      return modalities
          .any((value) => value.toString().toLowerCase() == 'image');
    }
    if (modalities is String && modalities.isNotEmpty) {
      return modalities
          .split(',')
          .any((v) => v.trim().toLowerCase() == 'image');
    }
    return null;
  }

  int? _firstPositiveInt(Map item, List<String> keys) {
    for (final key in keys) {
      final value = item[key];
      final parsed = value is num ? value.toInt() : int.tryParse('$value');
      if (parsed != null && parsed > 0) return parsed;
    }
    return null;
  }

  String? _nonEmptyString(Object? value) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? null : text;
  }

  String _modelsFailureMessage(int? statusCode) => switch (statusCode) {
        401 => 'API Key 无效或已过期（鉴权失败）',
        403 => 'API Key 没有访问该接口的权限（HTTP 403）',
        404 || 405 => '该服务地址没有模型列表接口，请手动填写模型名',
        final int code when _isRedirectStatus(code) =>
          _redirectBlockedMessage(code),
        null => '请求失败',
        _ => 'HTTP $statusCode 请求失败',
      };

  String _modelsUrl(String base) {
    final clean = base.replaceAll(RegExp(r'/+$'), '');
    return clean.endsWith('/models') ? clean : '$clean/models';
  }

  /// 服务商的规范地址：内置提供商就是它的预设地址；自定义地址则按主机名认出
  /// 它指向的是哪家内置服务（`…/anthropic` 这类协议子路径不会影响主机名）。
  ///
  /// **换了来源就不回落**：表单里的 Key 属于用户填的那个来源，把它转发到别的来源
  /// 就是把凭据交给用户没有配置过的一方。这里曾经只看提供商，于是私有代理返回 404
  /// 之后，同一把 Key 被发往内置提供商的官方地址；要换主机只能由用户自己改地址。
  String? _canonicalBaseFor({
    required ApiProvider provider,
    required String configuredBase,
  }) {
    final canonical = provider != ApiProvider.custom
        ? provider.baseUrl
        : _builtInBaseForHost(Uri.tryParse(configuredBase)?.host);
    if (canonical.isEmpty) return null;
    if (canonical == configuredBase) return null;
    if (!_sameOrigin(canonical, configuredBase)) return null;
    return canonical;
  }

  /// 路径变化仍落在同一来源；scheme、主机或有效端口不同都不能带 Key 回落。
  bool _sameOrigin(String first, String second) {
    final firstUri = Uri.tryParse(first);
    final secondUri = Uri.tryParse(second);
    return firstUri != null &&
        secondUri != null &&
        firstUri.hasAuthority &&
        secondUri.hasAuthority &&
        firstUri.host.isNotEmpty &&
        firstUri.scheme.toLowerCase() == secondUri.scheme.toLowerCase() &&
        firstUri.host.toLowerCase() == secondUri.host.toLowerCase() &&
        firstUri.port == secondUri.port;
  }

  String _builtInBaseForHost(String? host) {
    final target = host?.toLowerCase() ?? '';
    if (target.isEmpty) return '';
    for (final provider in ApiProvider.values) {
      if (provider == ApiProvider.custom) continue;
      final candidate = Uri.tryParse(provider.baseUrl)?.host.toLowerCase();
      if (candidate != null && candidate == target) return provider.baseUrl;
    }
    return '';
  }
}

extension on ProviderModelCatalog {
  /// 鉴权被拒时不该换地址重试：问题在 Key，不在路径。
  bool get authRejected => !ok && message.contains('API Key');
}
