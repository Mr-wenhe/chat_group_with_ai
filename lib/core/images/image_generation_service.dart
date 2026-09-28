import 'dart:convert';
import 'dart:typed_data';

import 'package:chat_group/features/web_search/security/search_endpoint_validator.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'image_service_config.dart';
import '../retry_handler.dart';

/// 生图失败的用户可读原因。message 直接面向用户展示，必须是中文。
class ImageGenerationException implements Exception {
  const ImageGenerationException(this.message);
  final String message;

  @override
  String toString() => 'ImageGenerationException: $message';
}

const Duration kImageConnectTimeout = Duration(seconds: 10);

/// 生图远慢于聊天补全（30–120s 常见），超时要放宽。
const Duration kImageReceiveTimeout = Duration(seconds: 120);

/// b64 解码前的响应体上限。超出即中断读取，避免坏服务撑爆内存。
const int kImageMaxResponseBytes = 20 * 1024 * 1024;

/// 解码/下载后的图片字节上限。
const int kImageMaxImageBytes = 12 * 1024 * 1024;

/// 仅超时/5xx 重试一次。生图按张计费，重试必须保守。
const int kImageMaxRetryCount = 1;

const String kImageResponseFormat = 'b64_json';

const String _kUnparsableImageMessage = '生图服务返回了无法解析的图片数据';
const String _kOversizedImageMessage = '生图结果超出大小限制';
const int _kProviderErrorDetailMaxChars = 120;

/// OpenAI Images 兼容生图客户端（`POST {baseUrl}/v1/images/generations`）。
///
/// 不复用 `ChatApiService`：那是 chat/completions 专用（messages 进、text/usage
/// 出），与本接口「单 prompt 进、图片字节出」形状完全不同，硬塞会污染聊天路径。
///
/// **仅限用户前台主动触发**，禁止后台或离线调用。
class ImageGenerationService {
  ImageGenerationService({
    required ImageServiceConfig config,
    required String apiKey,
    Dio? dio,
    Duration? connectTimeout,
    Duration? receiveTimeout,
    RetrySleep? retrySleep,
  })  : _config = config,
        _apiKey = apiKey,
        _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: connectTimeout ?? kImageConnectTimeout,
              receiveTimeout: receiveTimeout ?? kImageReceiveTimeout,
            )),
        _retrySleep = retrySleep ?? _defaultSleep;

  final ImageServiceConfig _config;
  final String _apiKey;
  final Dio _dio;
  final RetrySleep _retrySleep;

  static Future<void> _defaultSleep(Duration delay) =>
      Future<void>.delayed(delay);

  /// 生成一张 IP 形象，返回 PNG/JPEG 字节。
  Future<Uint8List> generate({required String prompt}) async {
    if (kIsWeb) {
      throw const ImageGenerationException('Web 端不支持图像生成。');
    }
    if (!_config.isConfigured) {
      throw const ImageGenerationException(
        '尚未配置图像服务（baseUrl / 模型 / Key），请到 设置 → 图像服务 完成配置',
      );
    }
    Object? lastError;
    for (var attempt = 0; attempt <= kImageMaxRetryCount; attempt++) {
      try {
        return await _generateOnce(prompt);
      } on ImageGenerationException {
        rethrow; // 业务失败（配置/解析/安全）不重试，重试只会重复计费。
      } on Object catch (error) {
        lastError = error;
        if (!_isRetryable(error) || attempt == kImageMaxRetryCount) {
          throw ImageGenerationException(await _mapTransportError(error));
        }
        await _retrySleep(const Duration(seconds: 1));
      }
    }
    throw ImageGenerationException(await _mapTransportError(lastError));
  }

  Future<Uint8List> _generateOnce(String prompt) async {
    // 泛型必须是 `Object?` 而不是 `ResponseBody`：Dio 的 `assureResponse<T>` 在
    // 响应不是 `Response<T>` 时会执行 `data as T`，把已解码 Map（测试注入形态）
    // 强转成 ResponseBody 会抛 TypeError，落进兜底文案里彻底盖掉真实错误。
    final response = await _dio.post<Object?>(
      generationsEndpoint(_config.baseUrl).toString(),
      data: _requestBody(prompt),
      options: Options(
        responseType: ResponseType.stream,
        headers: {'Authorization': 'Bearer $_apiKey'},
      ),
    );
    _ensureOk(response);
    return _extractImage(await _decodeResponseJson(response.data));
  }

  /// 非 2xx 统一在此报错。
  ///
  /// 生产路径 Dio 会因 `validateStatus` 先抛 [DioException]，这道检查主要兜住
  /// 测试拦截器 `handler.resolve` 注入的响应（那条路径会跳过 validateStatus），
  /// 也兜住自定义 adapter 直接回错误码的场景。
  ///
  /// 抛 [DioException] 而不是 [ImageGenerationException]：后者会被 [generate]
  /// 的重试循环当作业务失败直接 rethrow，5xx 就再也不会重试了。抛成
  /// `badResponse` 则统一落到 `_isRetryable` / `_mapTransportError`。
  void _ensureOk(Response<Object?> response) {
    final status = response.statusCode ?? 0;
    if (status >= 200 && status < 300) return;
    throw DioException(
      requestOptions: response.requestOptions,
      response: response,
      type: DioExceptionType.badResponse,
    );
  }

  /// 把响应体解成 JSON Map。
  ///
  /// 同时接受 [ResponseBody]（生产路径的有界流）与已解码的 [Map]
  /// （测试拦截器 `handler.resolve` 注入的形态），避免测试为流式响应单独造桩。
  Future<Map<String, dynamic>> _decodeResponseJson(Object? data) async {
    if (data is Map) return Map<String, dynamic>.from(data);
    if (data is ResponseBody) {
      return _decodeJsonMap(
        await _readStreamBounded(data.stream, kImageMaxResponseBytes),
      );
    }
    throw const ImageGenerationException(_kUnparsableImageMessage);
  }

  Map<String, dynamic> _requestBody(String prompt) => {
        'model': _config.model,
        'prompt': prompt,
        'n': kImageGenerationCount,
        // 尺寸的最后一道闸门：[ImageServiceConfig.fromMap] 已收过一次，但配置
        // 也可能被直接构造（测试、设置页草稿）。发一个构图装不下的尺寸，服务端
        // 不报错、照出图，只是出一张废图 —— 比 400 难查得多。
        'size': normalizeImageSize(_config.size, baseUrl: _config.baseUrl),
        // 恒请求 base64：避免二次网络请求，也就绕开了「客户端自选 URL」的红线。
        // 智谱等实现会无视该字段只回 `url`，那条路径由 [isTrustedImageUrl] 兜住。
        'response_format': kImageResponseFormat,
        // 仅当非空时才发送：通义/智谱等实现会拒绝未知字段。
        if (_config.quality.trim().isNotEmpty) 'quality': _config.quality,
        // 同上，默认不发。智谱默认打显式 AI 水印，用户在设置里开了去水印才发
        // `false`；OpenAI 不认这个字段，无条件发会把可用配置打成 400。
        if (_config.disableWatermark) 'watermark_enabled': false,
      };

  /// 从响应 `data[0]` 取图：优先 `b64_json`，没有才走可信域的 `url` 下载。
  Future<Uint8List> _extractImage(Map<String, dynamic> json) async {
    final data = json['data'];
    if (data is! List || data.isEmpty || data.first is! Map) {
      throw const ImageGenerationException(_kUnparsableImageMessage);
    }
    final item = Map<String, dynamic>.from(data.first as Map);
    final b64 = item['b64_json']?.toString();
    if (b64 != null && b64.isNotEmpty) return _decodeBase64Image(b64);
    final url = item['url']?.toString();
    if (url != null && url.isNotEmpty) return _downloadTrustedImage(url);
    throw const ImageGenerationException(_kUnparsableImageMessage);
  }

  Uint8List _decodeBase64Image(String b64) {
    final Uint8List bytes;
    try {
      bytes = base64Decode(b64);
    } on Object {
      throw const ImageGenerationException(_kUnparsableImageMessage);
    }
    if (bytes.length > kImageMaxImageBytes) {
      throw const ImageGenerationException(_kOversizedImageMessage);
    }
    if (bytes.isEmpty) {
      throw const ImageGenerationException(_kUnparsableImageMessage);
    }
    return bytes;
  }

  Future<Uint8List> _downloadTrustedImage(String rawUrl) async {
    final url = _normalizeDownloadUrl(rawUrl);
    if (!isTrustedImageUrl(url)) {
      // 带上 host：判定误伤时用户能直接报出域名，省一轮猜测。
      throw ImageGenerationException(
        '生图服务返回了不受信的图片地址（${_hostOrUnknown(url)}），已阻止下载',
      );
    }
    // 泛型同 `_generateOnce`：必须 `Object?`，否则 `assureResponse` 强转丢错误。
    final response = await _dio.get<Object?>(
      url,
      options: Options(
        responseType: ResponseType.stream,
        // 安全红线：绝不跟随重定向到新 host，否则白名单可被 302 绕过。
        followRedirects: false,
      ),
    );
    final raw = await _readBodyBytes(response.data, kImageMaxImageBytes);
    if (raw.isEmpty) {
      throw const ImageGenerationException(_kUnparsableImageMessage);
    }
    return raw;
  }
}

/// 读取响应体字节，同时接受流式 [ResponseBody] 与已缓冲的字节（测试注入形态）。
Future<Uint8List> _readBodyBytes(Object? data, int maxBytes) async {
  if (data is ResponseBody) return _readStreamBounded(data.stream, maxBytes);
  if (data is Uint8List) {
    if (data.length > maxBytes) {
      throw const ImageGenerationException(_kOversizedImageMessage);
    }
    return data;
  }
  if (data is List<int>) {
    if (data.length > maxBytes) {
      throw const ImageGenerationException(_kOversizedImageMessage);
    }
    return Uint8List.fromList(data);
  }
  throw const ImageGenerationException(_kUnparsableImageMessage);
}

/// 下载前的 URL 归一化：剥外层引号 + 把 `http://` 升级成 `https://`。
///
/// 升级 scheme 而不是直接拒：厂商文档/实现里偶见 http 示例地址，同一主机的
/// https 几乎总是可达，因写法误伤真实出图不值得。
String _normalizeDownloadUrl(String raw) {
  var value = raw.trim();
  if (value.length >= 2 &&
      ((value.startsWith('"') && value.endsWith('"')) ||
          (value.startsWith("'") && value.endsWith("'")))) {
    value = value.substring(1, value.length - 1).trim();
  }
  if (value.toLowerCase().startsWith('http://')) {
    value = 'https://${value.substring('http://'.length)}';
  }
  return value;
}

String _hostOrUnknown(String url) {
  final host = Uri.tryParse(url)?.host.trim();
  if (host == null || host.isEmpty) return '无法解析';
  return host;
}

/// 图片 URL 是否允许下载。
///
/// **安全边界，改动需安全评审。** 安全模型（2026-09 修订）：URL 来自**用户
/// 已配置的生图 API 的响应体**，不是客户端自选目标（CLAUDE.md「搜索与浏览器
/// 安全」禁止的是后者）。因此这里要挡的是 SSRF ——被劫持的 API 让本机去打
/// 内网 —— 而不是「必须命中厂商 CDN 白名单」。
///
/// 之所以撤掉静态 CDN 白名单：智谱 `glm-image` 等实现会无视 `response_format`
/// 只回 `url`，落图域名是各家对象存储，无法穷举；`.bigmodel.cn` 在白名单里
/// 仍被拒就是这么来的。白名单当门槛会稳定误伤真实出图。
///
/// 判定条件：
/// - 强制 `https`（`http://` 由 [_normalizeDownloadUrl] 升级后再进本函数）；
/// - host 必须是带点的 DNS 名，拒绝 IP 字面量与 `localhost`；
/// - host 不得命中私网/本机/云元数据地址（复用搜索侧
///   [SearchEndpointValidator.isPrivateOrLocalHost]，与 `validateSearchUrl`
///   对不可信结果链接的判定同源）；
/// - 下载时 `followRedirects: false`，判定不会被 302 绕过。
@visibleForTesting
bool isTrustedImageUrl(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !uri.hasAuthority) return false;
  if (uri.scheme != 'https') return false;
  // 去掉 FQDN 尾点，否则 `cdn.example.com.` 会被当成另一个名字。
  final host = uri.host.toLowerCase().replaceAll(RegExp(r'\.$'), '');
  if (host.isEmpty || !host.contains('.')) return false;
  return !SearchEndpointValidator.isPrivateOrLocalHost(host);
}

/// 生图端点的单点拼接：`{apiPrefix}/images/generations`。
///
/// [ImageServiceConfig.baseUrl] 是**含版本段的完整 API 前缀**（各家不同：
/// OpenAI `/v1`、智谱 `/api/paas/v4`、火山 `/api/v3`），预设见
/// `image_provider_presets.dart`。硬编码 `/v1` 会让智谱/火山必定 404，
/// 那是「配了却调不通」最难自查的一类故障。
///
/// 两条兜底，都是为了让用户少踩坑：
/// - 前缀若已带完整尾段 `…/images/generations`，原样使用（用户直接粘了文档里的
///   完整 URL 也能对）；
/// - 前缀若**只有域名没有路径**，自动补 `/v1`（OpenAI 默认形态，也兼容旧填法）。
@visibleForTesting
Uri generationsEndpoint(String baseUrl) {
  final normalized = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
  if (normalized.isEmpty) {
    throw const ImageGenerationException(
      '尚未配置图像服务（baseUrl / 模型 / Key），请到 设置 → 图像服务 完成配置',
    );
  }
  if (normalized.endsWith(_kGenerationsPath)) return Uri.parse(normalized);
  final uri = Uri.tryParse(normalized);
  final hasPath = uri != null && uri.path.isNotEmpty && uri.path != '/';
  // 只有域名时按 OpenAI 形态补 /v1；已有路径则尊重用户给的前缀，不再插入版本段。
  return Uri.parse(
    hasPath ? '$normalized$_kGenerationsPath' : '$normalized/v1$_kGenerationsPath',
  );
}

const String _kGenerationsPath = '/images/generations';

/// 有界读取字节流。超限抛 [ImageGenerationException]。
Future<Uint8List> _readStreamBounded(
  Stream<Uint8List> stream,
  int maxBytes,
) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    builder.add(chunk);
    if (builder.length > maxBytes) {
      throw const ImageGenerationException(_kOversizedImageMessage);
    }
  }
  return builder.takeBytes();
}

Map<String, dynamic> _decodeJsonMap(Uint8List raw) {
  try {
    final decoded = jsonDecode(utf8.decode(raw));
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
  } on Object {
    // 落到下面的统一错误。
  }
  throw const ImageGenerationException(_kUnparsableImageMessage);
}

bool _isRetryable(Object error) {
  if (error is! DioException) return false;
  return switch (error.type) {
    DioExceptionType.connectionTimeout ||
    DioExceptionType.sendTimeout ||
    DioExceptionType.receiveTimeout ||
    DioExceptionType.connectionError =>
      true,
    DioExceptionType.badResponse =>
      (error.response?.statusCode ?? 0) >= 500,
    _ => false,
  };
}

Future<String> _mapTransportError(Object? error) async {
  if (error is DioException) {
    if (error.type == DioExceptionType.badResponse) {
      return _mapStatusToMessage(
        error.response?.statusCode ?? 0,
        error.response?.data,
      );
    }
    return switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout =>
        '生图超时，请稍后重试',
      DioExceptionType.cancel => '请求已取消',
      _ => '图像服务暂时不可用，请检查网络后重试',
    };
  }
  return '图像服务暂时不可用，请检查网络后重试';
}

/// 状态码 → 用户可读中文文案。`body` 用于提取服务端 `error.message` 详情。
Future<String> _mapStatusToMessage(int statusCode, Object? body) async {
  return switch (statusCode) {
    401 || 403 => '图像服务 API Key 无效或已过期，请到 设置 → 图像服务 检查',
    404 => '图像服务地址或模型名不正确，请检查设置',
    429 => '请求过于频繁或额度不足，请稍后再试',
    0 || >= 500 => '图像服务暂时不可用，请检查网络后重试',
    _ => '图像服务拒绝了请求：${await _providerErrorDetail(body)}',
  };
}

/// 从服务端错误响应里提取 `error.message` / `message` / `error` 之一作为详情。
///
/// `ResponseType.stream` 下错误体也是 [ResponseBody]，必须先有界读出再解析；
/// 测试注入的假响应则是已解码的 Map，直接透传。
Future<String> _providerErrorDetail(Object? body) async {
  final detail = _extractProviderMessage(await _readErrorBody(body));
  if (detail == null || detail.trim().isEmpty) {
    return '请检查服务地址、模型名与配额';
  }
  return _truncateDetail(detail);
}

Future<Object?> _readErrorBody(Object? data) async {
  if (data is! ResponseBody) return data;
  try {
    // 错误详情只需几十字节；给 64KB 上限防止错误页撑爆内存。
    final raw = await _readStreamBounded(data.stream, 64 * 1024);
    return jsonDecode(utf8.decode(raw));
  } on Object {
    return null;
  }
}

String? _extractProviderMessage(Object? body) {
  if (body == null || body is! Map) return null;
  final map = Map<String, dynamic>.from(body);
  final nested = map['error'];
  if (nested is Map) return nested['message']?.toString();
  return (map['message'] ?? map['error'])?.toString();
}

String _truncateDetail(String detail) {
  final trimmed = detail.trim();
  if (trimmed.length <= _kProviderErrorDetailMaxChars) return trimmed;
  return '${trimmed.substring(0, _kProviderErrorDetailMaxChars)}…';
}
