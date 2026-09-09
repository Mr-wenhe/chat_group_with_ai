import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/models/api_protocol.dart';
import 'package:chat_group/core/retry_handler.dart';
import 'package:chat_group/core/streaming/chat_stream_event.dart';
import 'package:chat_group/core/streaming/sse_parser.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

part 'chat_api_service_support.dart';
part 'chat_api_protocol_support.dart';

class ChatApiService {
  static const String _emptyCompletionMessage = '模型返回了空内容';
  static const String _webNetworkUnsupportedMessage = 'Web 端暂不支持联网模型调用';
  static const int defaultMaxResponseBytes = 4 * 1024 * 1024;
  static const int maxSseLineBytes = 512 * 1024;
  static const int maxSseWireBytes = 8 * 1024 * 1024;

  final Dio _dio;
  final RetrySleep _retrySleep;

  ChatApiService({Dio? dio, RetrySleep? retrySleep})
      : _retrySleep = retrySleep ?? Future<void>.delayed,
        _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              // 部分推理模型需要先完成 thinking 过程，回复耗时可达 30-60s；
              // 30s 的默认值经常误杀正常请求。
              receiveTimeout: const Duration(seconds: 120),
            ));

  /// 非流式请求：整段等待后返回结果，供「记忆摘要」等一次性调用复用。
  ///
  /// 注意：本方法保持原有行为不被破坏（架构要求），新增的流式能力见 [streamChatMessage]。
  Future<Map<String, dynamic>> sendChatMessage({
    required String apiKey,
    required ApiProvider provider,
    ApiProtocol apiProtocol = ApiProtocol.defaultValue,
    String? customBaseUrl,
    required String model,
    required List<Map<String, dynamic>> messages,
    double temperature = 0.85,
    int maxTokens = 1024,
    Duration? receiveTimeout,
    int maxRetries = RetryHandler.defaultMaxRetries,
    CancelToken? cancelToken,
  }) async {
    if (kIsWeb) {
      return {
        'success': false,
        'message': _webNetworkUnsupportedMessage,
      };
    }
    final result = await RetryHandler.executeWithRetry<Map<String, dynamic>>(
      operation: (attempt) => _sendChatMessageOnce(
        apiKey: apiKey,
        provider: provider,
        apiProtocol: apiProtocol,
        customBaseUrl: customBaseUrl,
        model: model,
        messages: messages,
        temperature: attempt.temperatureFor(temperature),
        maxTokens: maxTokens,
        receiveTimeout: receiveTimeout,
        cancelToken: cancelToken,
        maxResponseBytes: defaultMaxResponseBytes,
      ),
      shouldRetryResult: RetryHandler.isTransientResult,
      sleep: _retrySleep,
      maxRetries: maxRetries,
    );
    return _friendlyRetryFailure(result, maxRetries);
  }

  /// Non-streaming request with a hard response-size boundary.
  ///
  /// Optional planners and other small-schema callers must not rely on a
  /// model's `max_tokens` hint as a transport limit. This path switches Dio to
  /// a stream response and rejects oversized bodies before JSON materialization.
  Future<Map<String, dynamic>> sendChatMessageWithResponseLimit({
    required String apiKey,
    required ApiProvider provider,
    ApiProtocol apiProtocol = ApiProtocol.defaultValue,
    String? customBaseUrl,
    required String model,
    required List<Map<String, dynamic>> messages,
    double temperature = 0.85,
    int maxTokens = 1024,
    Duration? receiveTimeout,
    int maxRetries = RetryHandler.defaultMaxRetries,
    CancelToken? cancelToken,
    required int maxResponseBytes,
  }) async {
    if (kIsWeb) {
      return {
        'success': false,
        'message': _webNetworkUnsupportedMessage,
      };
    }
    if (maxResponseBytes < 1) {
      return {'success': false, 'message': '响应大小限制无效'};
    }
    final result = await RetryHandler.executeWithRetry<Map<String, dynamic>>(
      operation: (attempt) => _sendChatMessageOnce(
        apiKey: apiKey,
        provider: provider,
        apiProtocol: apiProtocol,
        customBaseUrl: customBaseUrl,
        model: model,
        messages: messages,
        temperature: attempt.temperatureFor(temperature),
        maxTokens: maxTokens,
        receiveTimeout: receiveTimeout,
        cancelToken: cancelToken,
        maxResponseBytes: maxResponseBytes,
      ),
      shouldRetryResult: RetryHandler.isTransientResult,
      sleep: _retrySleep,
      maxRetries: maxRetries,
    );
    return _friendlyRetryFailure(result, maxRetries);
  }

  /// Resolves the one URL used by both streamed and non-streamed requests.
  ///
  /// A custom URL may be either a base URL or a complete OpenAI-compatible
  /// endpoint. Checking the parsed path suffix keeps non-standard endpoints
  /// such as `/v1/llm/completions` intact without mistaking a middle path
  /// segment for the endpoint.
  String _resolveCompletionUrl({
    required String? customBaseUrl,
    required ApiProvider provider,
    required ApiProtocol apiProtocol,
    required String model,
    bool streaming = false,
  }) {
    final raw =
        (provider == ApiProvider.custom ? customBaseUrl : provider.baseUrl)
                ?.trim() ??
            '';
    if (raw.isEmpty) return '';

    final parsed = Uri.tryParse(raw);
    if (parsed != null && parsed.isAbsolute && parsed.host.isNotEmpty) {
      var path = parsed.path.replaceAll(RegExp(r'/+$'), '');
      final isCompleteEndpoint = switch (apiProtocol) {
        ApiProtocol.anthropicMessages => path.endsWith('/messages'),
        ApiProtocol.openAiChatCompletions =>
          path.endsWith('/chat/completions') || path.endsWith('/completions'),
        ApiProtocol.openAiResponses => path.endsWith('/responses'),
        ApiProtocol.geminiGenerateContent =>
          path.endsWith(':generateContent') ||
              path.endsWith(':streamGenerateContent'),
      };
      final nextPath = isCompleteEndpoint
          ? (apiProtocol == ApiProtocol.geminiGenerateContent &&
                  streaming &&
                  path.endsWith(':generateContent')
              ? '${path.substring(0, path.length - ':generateContent'.length)}'
                  ':streamGenerateContent'
              : path)
          : _appendProtocolPath(
              path: path,
              protocol: apiProtocol,
              model: model,
              streaming: streaming,
            );
      var resolved = parsed.replace(path: nextPath);
      if (apiProtocol == ApiProtocol.geminiGenerateContent &&
          streaming &&
          !resolved.queryParameters.containsKey('alt')) {
        // Gemini's stream endpoint uses SSE only when explicitly requested.
        resolved = resolved.replace(
          queryParameters: {
            ...resolved.queryParameters,
            'alt': 'sse',
          },
        );
      }
      return resolved.toString();
    }

    final base = raw.replaceAll(RegExp(r'/*$'), '');
    final completeEndpoint = switch (apiProtocol) {
      ApiProtocol.anthropicMessages => base.endsWith('/messages'),
      ApiProtocol.openAiChatCompletions =>
        base.endsWith('/chat/completions') || base.endsWith('/completions'),
      ApiProtocol.openAiResponses => base.endsWith('/responses'),
      ApiProtocol.geminiGenerateContent => base.endsWith(':generateContent') ||
          base.endsWith(':streamGenerateContent'),
    };
    if (completeEndpoint) return base;
    return _appendProtocolPath(
      path: base,
      protocol: apiProtocol,
      model: model,
      streaming: streaming,
    );
  }

  Future<Map<String, dynamic>> _sendChatMessageOnce({
    required String apiKey,
    required ApiProvider provider,
    required ApiProtocol apiProtocol,
    String? customBaseUrl,
    required String model,
    required List<Map<String, dynamic>> messages,
    required double temperature,
    required int maxTokens,
    Duration? receiveTimeout,
    CancelToken? cancelToken,
    required int? maxResponseBytes,
  }) async {
    if (kIsWeb) {
      return {
        'success': false,
        'message': _webNetworkUnsupportedMessage,
      };
    }
    final url = _resolveCompletionUrl(
      customBaseUrl: customBaseUrl,
      provider: provider,
      apiProtocol: apiProtocol,
      model: model,
    );
    final modelName = _resolveModelName(provider: provider, model: model);

    if (url.isEmpty) {
      return {'success': false, 'message': 'Base URL 不能为空'};
    }
    if (modelName.isEmpty) {
      return {'success': false, 'message': '模型名称不能为空'};
    }

    final headers = _requestHeaders(apiKey: apiKey, apiProtocol: apiProtocol);

    try {
      final response = await _dio.post(
        url,
        data: _requestBody(
          apiProtocol: apiProtocol,
          model: modelName,
          messages: messages,
          temperature: temperature,
          maxTokens: maxTokens,
          streaming: false,
        ),
        options: Options(
          headers: headers,
          receiveTimeout: receiveTimeout,
          responseType: maxResponseBytes == null ? null : ResponseType.stream,
          // Keep even 5xx bodies on the bounded stream path so an upstream
          // error payload cannot bypass the response-size guard.
          validateStatus: (s) => s != null && s < 600,
        ),
        cancelToken: cancelToken,
      );

      final responseData = maxResponseBytes == null
          ? response.data
          : await _readBoundedResponseData(response.data, maxResponseBytes);

      if (response.statusCode == 200) {
        final data = _asJsonMap(responseData);
        if (data == null) {
          return {'success': false, 'message': '响应格式无效'};
        }
        final reply = _responseText(data, apiProtocol);
        if (reply.trim().isEmpty) {
          return {'success': false, 'message': _emptyCompletionMessage};
        }
        final usage = _usageFields(data, apiProtocol);
        return {
          'success': true,
          'message': reply,
          'model': _responseModel(data, apiProtocol) ?? modelName,
          if (usage != null) ...usage,
        };
      } else {
        final providerError = _safeProviderErrorDetail(responseData);
        return {
          'success': false,
          'statusCode': response.statusCode,
          'message': _safeHttpErrorMessage(response.statusCode),
          'requestPath': _requestPath(url),
          'requestModel': modelName,
          if (providerError != null) 'providerError': providerError,
        };
      }
    } on _ChatResponseTooLargeException {
      return {'success': false, 'message': '模型响应超过安全大小限制'};
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        return {'success': false, 'message': '请求已取消'};
      } else if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.sendTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        return {'success': false, 'message': '连接超时'};
      } else if (e.type == DioExceptionType.connectionError) {
        return {'success': false, 'message': '网络连接失败：无法连接到服务器'};
      } else if (e.response != null) {
        final providerError = _safeProviderErrorDetail(e.response!.data);
        return {
          'success': false,
          'statusCode': e.response!.statusCode,
          'message': _safeHttpErrorMessage(e.response!.statusCode),
          'requestPath': _requestPath(
            e.response!.requestOptions.uri.toString(),
          ),
          'requestModel': modelName,
          if (providerError != null) 'providerError': providerError,
        };
      } else {
        return {'success': false, 'message': '请求失败'};
      }
    } catch (e) {
      return {'success': false, 'message': '请求失败'};
    }
  }

  /// 以 SSE 接收完整回复并汇总成与 [sendChatMessage] 相同的结果结构。
  ///
  /// Agent 文件任务可能生成数千 token；使用流式通道可以在模型持续输出时保持连接
  /// 活跃，避免非流式请求必须等整包完成而触发 receiveTimeout。
  Future<Map<String, dynamic>> sendChatMessageStreamed({
    required String apiKey,
    required ApiProvider provider,
    ApiProtocol apiProtocol = ApiProtocol.defaultValue,
    String? customBaseUrl,
    required String model,
    required List<Map<String, dynamic>> messages,
    double temperature = 0.85,
    int maxTokens = 1024,
    Duration receiveTimeout = const Duration(seconds: 120),
    int maxRetries = RetryHandler.defaultMaxRetries,
    CancelToken? cancelToken,
    void Function(ChatStreamEvent event)? onEvent,
  }) async {
    if (kIsWeb) {
      return {
        'success': false,
        'message': _webNetworkUnsupportedMessage,
      };
    }
    final result = await RetryHandler.executeWithRetry<Map<String, dynamic>>(
      operation: (attempt) {
        final nextTemperature = attempt.temperatureFor(temperature);
        if (!attempt.useStreaming) {
          return _sendChatMessageOnce(
            apiKey: apiKey,
            provider: provider,
            apiProtocol: apiProtocol,
            customBaseUrl: customBaseUrl,
            model: model,
            messages: messages,
            temperature: nextTemperature,
            maxTokens: maxTokens,
            receiveTimeout: receiveTimeout,
            cancelToken: cancelToken,
            maxResponseBytes: defaultMaxResponseBytes,
          );
        }
        return _collectStreamedOnce(
          apiKey: apiKey,
          provider: provider,
          apiProtocol: apiProtocol,
          customBaseUrl: customBaseUrl,
          model: model,
          messages: messages,
          temperature: nextTemperature,
          maxTokens: maxTokens,
          receiveTimeout: receiveTimeout,
          cancelToken: cancelToken,
          onEvent: onEvent,
        );
      },
      shouldRetryResult: RetryHandler.isTransientResult,
      sleep: _retrySleep,
      maxRetries: maxRetries,
    );
    return _friendlyRetryFailure(result, maxRetries);
  }

  Future<dynamic> _readBoundedResponseData(
    dynamic responseData,
    int maxResponseBytes,
  ) async {
    if (responseData is! ResponseBody) {
      final text = responseData?.toString() ?? '';
      if (utf8.encode(text).length > maxResponseBytes) {
        throw const _ChatResponseTooLargeException();
      }
      return responseData;
    }

    final bytes = BytesBuilder(copy: false);
    var byteCount = 0;
    await for (final chunk in responseData.stream) {
      byteCount += chunk.length;
      if (byteCount > maxResponseBytes) {
        throw const _ChatResponseTooLargeException();
      }
      bytes.add(chunk);
    }
    final text = utf8.decode(bytes.takeBytes(), allowMalformed: true);
    return jsonDecode(text);
  }

  Map<String, dynamic> _friendlyRetryFailure(
    Map<String, dynamic> result,
    int maxRetries,
  ) {
    if (maxRetries <= 0 || !RetryHandler.isTransientResult(result)) {
      return result;
    }
    final reason = result['message']?.toString() ?? '未知瞬态错误';
    return {
      ...result,
      'message': '请求已重试 $maxRetries 次仍失败。原因：$reason。'
          '请检查网络和 API 配置、确认服务额度，或稍后再试。',
      'retryExhausted': true,
    };
  }

  /// 流式请求：以 `Stream<ChatStreamEvent>` 逐 token 产出回复（打字机效果）。
  ///
  /// 与 [sendChatMessage] 共用 URL / 模型解析逻辑；请求级使用
  /// `responseType: ResponseType.stream` 拿到 `ResponseBody.stream`，按行解析 SSE。
  /// 解析细节全部封装在 [SseParser] 中，本方法只负责网络与事件转发。
  ///
  /// 错误处理：非 200（4xx）或任何 DioException 都会 yield 一个 [ChatStreamEvent.error]
  /// 后结束，绝不抛出（保证 `await for` / `listen` 的调用方安全）。
  Stream<ChatStreamEvent> streamChatMessage({
    required String apiKey,
    required ApiProvider provider,
    ApiProtocol apiProtocol = ApiProtocol.defaultValue,
    String? customBaseUrl,
    required String model,
    required List<Map<String, dynamic>> messages,
    double temperature = 0.85,
    int maxTokens = 1024,
    Duration receiveTimeout = const Duration(seconds: 120),
    CancelToken? cancelToken,
  }) async* {
    if (kIsWeb) {
      yield ChatStreamEvent.error(_webNetworkUnsupportedMessage);
      return;
    }
    // 与 sendChatMessage 保持一致的 URL / 模型解析
    final url = _resolveCompletionUrl(
      customBaseUrl: customBaseUrl,
      provider: provider,
      apiProtocol: apiProtocol,
      model: model,
      streaming: true,
    );
    final modelName = _resolveModelName(provider: provider, model: model);

    if (url.isEmpty) {
      yield ChatStreamEvent.error('Base URL 不能为空');
      return;
    }
    if (modelName.isEmpty) {
      yield ChatStreamEvent.error('模型名称不能为空');
      return;
    }

    final headers = <String, String>{
      ..._requestHeaders(apiKey: apiKey, apiProtocol: apiProtocol),
      'Accept': 'text/event-stream',
    };
    final data = _requestBody(
      apiProtocol: apiProtocol,
      model: modelName,
      messages: messages,
      temperature: temperature,
      maxTokens: maxTokens,
      streaming: true,
    );

    final parser = SseParser();
    final protocolParser = apiProtocol == ApiProtocol.openAiChatCompletions
        ? null
        : _ProtocolStreamParser(apiProtocol);
    try {
      final response = await _dio.post<ResponseBody>(
        url,
        data: data,
        options: Options(
          headers: headers,
          // 流式模式下以字节流返回
          responseType: ResponseType.stream,
          // 4xx 不抛异常，交由我们产出 error 事件；>=500 仍抛 DioException。
          validateStatus: (s) => s != null && s < 500,
          receiveTimeout: receiveTimeout,
        ),
        cancelToken: cancelToken,
      );

      if (response.statusCode != 200) {
        yield ChatStreamEvent.error(_safeHttpErrorMessage(response.statusCode));
        return;
      }

      // stream 模式下 response.data 为 ResponseBody，其 .stream 为
      // Stream<Uint8List>；先在字节层限制帧/总量，再逐行解码，避免不完整
      // 的 SSE 帧在 UTF-8 解码器内部无限累积。
      final stream = (response.data as ResponseBody)
          .stream
          .cast<List<int>>()
          .transform(const BoundedSseLineTransformer(
            maxLineBytes: maxSseLineBytes,
            maxWireBytes: maxSseWireBytes,
          ))
          .map(utf8.decode);

      // 逐行交给 SseParser，把产出的事件透传给调用方。
      await for (final line in stream) {
        if (apiProtocol == ApiProtocol.openAiChatCompletions &&
            RegExp(r'^data:\s*\[DONE\]\s*$').hasMatch(line.trim())) {
          // 仅当解析器未被终止（错误/超限）时才产生 done 事件，
          // 避免错误后服务端仍然发送 [DONE] 导致误判为成功。
          if (!parser.terminated) {
            yield parser.doneEvent();
          }
          return;
        }
        final event = apiProtocol == ApiProtocol.openAiChatCompletions
            ? parser.ingestLine(line)
            : protocolParser!.ingestLine(line);
        if (event != null) {
          yield event.type == ChatStreamEventType.error
              ? ChatStreamEvent.error(_safeStreamErrorMessage(event.message))
              : event;
          if (parser.terminated || protocolParser?.terminated == true) return;
        }
      }
      // 流正常结束，仅当解析器未被终止（非 [DONE] 路径）时产出 done 事件，
      // 避免把 error/超限终止误报为成功。
      if (apiProtocol == ApiProtocol.openAiChatCompletions) {
        if (!parser.terminated) yield parser.doneEvent();
      } else if (!protocolParser!.terminated) {
        yield protocolParser.doneEvent();
      }
    } on SseInputLimitException {
      yield ChatStreamEvent.error('流式响应超过安全大小限制');
    } on DioException catch (e) {
      yield ChatStreamEvent.error(_dioErrorMessage(e));
    } catch (e) {
      yield ChatStreamEvent.error('请求失败');
    }
  }
}

class _ChatResponseTooLargeException implements Exception {
  const _ChatResponseTooLargeException();
}
