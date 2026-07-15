import 'dart:async';
import 'dart:convert';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/retry_handler.dart';
import 'package:chat_group/core/streaming/chat_stream_event.dart';
import 'package:chat_group/core/streaming/sse_parser.dart';
import 'package:dio/dio.dart';

class ChatApiService {
  final Dio _dio;
  final RetrySleep _retrySleep;

  ChatApiService({Dio? dio, RetrySleep? retrySleep})
      : _retrySleep = retrySleep ?? Future<void>.delayed,
        _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 30),
            ));

  /// 非流式请求：整段等待后返回结果，供「记忆摘要」等一次性调用复用。
  ///
  /// 注意：本方法保持原有行为不被破坏（架构要求），新增的流式能力见 [streamChatMessage]。
  Future<Map<String, dynamic>> sendChatMessage({
    required String apiKey,
    required ApiProvider provider,
    String? customBaseUrl,
    required String model,
    required List<Map<String, dynamic>> messages,
    double temperature = 0.85,
    int maxTokens = 1024,
    Duration? receiveTimeout,
    int maxRetries = RetryHandler.defaultMaxRetries,
    CancelToken? cancelToken,
  }) async {
    final result = await RetryHandler.executeWithRetry<Map<String, dynamic>>(
      operation: (attempt) => _sendChatMessageOnce(
        apiKey: apiKey,
        provider: provider,
        customBaseUrl: customBaseUrl,
        model: model,
        messages: messages,
        temperature: attempt.temperatureFor(temperature),
        maxTokens: maxTokens,
        receiveTimeout: receiveTimeout,
        cancelToken: cancelToken,
      ),
      shouldRetryResult: RetryHandler.isTransientResult,
      sleep: _retrySleep,
      maxRetries: maxRetries,
    );
    return _friendlyRetryFailure(result, maxRetries);
  }

  Future<Map<String, dynamic>> _sendChatMessageOnce({
    required String apiKey,
    required ApiProvider provider,
    String? customBaseUrl,
    required String model,
    required List<Map<String, dynamic>> messages,
    required double temperature,
    required int maxTokens,
    Duration? receiveTimeout,
    CancelToken? cancelToken,
  }) async {
    final baseUrl = provider == ApiProvider.custom
        ? (customBaseUrl ?? '').replaceAll(RegExp(r'/*$'), '')
        : provider.baseUrl;
    final modelName = model.isEmpty
        ? (ApiProvider.defaultModels[provider.name] ?? '')
        : model;

    if (baseUrl.isEmpty) {
      return {'success': false, 'message': 'Base URL 不能为空'};
    }
    if (modelName.isEmpty) {
      return {'success': false, 'message': '模型名称不能为空'};
    }

    final url = '$baseUrl${provider.apiPath}';
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $apiKey',
    };

    try {
      final response = await _dio.post(
        url,
        data: {
          'model': modelName,
          'messages': messages,
          'temperature': temperature,
          'max_tokens': maxTokens,
        },
        options: Options(
          headers: headers,
          receiveTimeout: receiveTimeout,
          validateStatus: (s) => s != null && s < 500,
        ),
        cancelToken: cancelToken,
      );

      if (response.statusCode == 200) {
        final data = response.data as Map<String, dynamic>;
        final reply = data['choices']?[0]?['message']?['content']?.toString() ??
            '(empty)';
        final usage = data['usage'];
        return {
          'success': true,
          'message': reply,
          'model': data['model'] ?? modelName,
          if (usage is Map<String, dynamic>) ...{
            'promptTokens': usage['prompt_tokens'] as int? ?? 0,
            'completionTokens': usage['completion_tokens'] as int? ?? 0,
            'cachedTokens': _extractCachedTokens(usage),
          }
        };
      } else {
        final err = response.data?.toString() ?? 'HTTP ${response.statusCode}';
        return {
          'success': false,
          'statusCode': response.statusCode,
          'message': 'HTTP ${response.statusCode}: $err'
        };
      }
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
        final err = e.response!.data?.toString() ?? e.message;
        return {
          'success': false,
          'statusCode': e.response!.statusCode,
          'message': 'HTTP ${e.response!.statusCode}: $err'
        };
      } else {
        return {'success': false, 'message': '请求失败: ${e.message}'};
      }
    } catch (e) {
      return {'success': false, 'message': '未知错误: $e'};
    }
  }

  /// 以 SSE 接收完整回复并汇总成与 [sendChatMessage] 相同的结果结构。
  ///
  /// Agent 文件任务可能生成数千 token；使用流式通道可以在模型持续输出时保持连接
  /// 活跃，避免非流式请求必须等整包完成而触发 receiveTimeout。
  Future<Map<String, dynamic>> sendChatMessageStreamed({
    required String apiKey,
    required ApiProvider provider,
    String? customBaseUrl,
    required String model,
    required List<Map<String, dynamic>> messages,
    double temperature = 0.85,
    int maxTokens = 1024,
    Duration receiveTimeout = const Duration(seconds: 120),
    int maxRetries = RetryHandler.defaultMaxRetries,
    CancelToken? cancelToken,
  }) async {
    final result = await RetryHandler.executeWithRetry<Map<String, dynamic>>(
      operation: (attempt) {
        final nextTemperature = attempt.temperatureFor(temperature);
        if (!attempt.useStreaming) {
          return _sendChatMessageOnce(
            apiKey: apiKey,
            provider: provider,
            customBaseUrl: customBaseUrl,
            model: model,
            messages: messages,
            temperature: nextTemperature,
            maxTokens: maxTokens,
            receiveTimeout: receiveTimeout,
            cancelToken: cancelToken,
          );
        }
        return _collectStreamedOnce(
          apiKey: apiKey,
          provider: provider,
          customBaseUrl: customBaseUrl,
          model: model,
          messages: messages,
          temperature: nextTemperature,
          maxTokens: maxTokens,
          receiveTimeout: receiveTimeout,
          cancelToken: cancelToken,
        );
      },
      shouldRetryResult: RetryHandler.isTransientResult,
      sleep: _retrySleep,
      maxRetries: maxRetries,
    );
    return _friendlyRetryFailure(result, maxRetries);
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

  Future<Map<String, dynamic>> _collectStreamedOnce({
    required String apiKey,
    required ApiProvider provider,
    String? customBaseUrl,
    required String model,
    required List<Map<String, dynamic>> messages,
    required double temperature,
    required int maxTokens,
    required Duration receiveTimeout,
    CancelToken? cancelToken,
  }) async {
    String content = '';
    int? promptTokens;
    int? completionTokens;
    int? cachedTokens;
    try {
      await for (final event in streamChatMessage(
        apiKey: apiKey,
        provider: provider,
        customBaseUrl: customBaseUrl,
        model: model,
        messages: messages,
        temperature: temperature,
        maxTokens: maxTokens,
        receiveTimeout: receiveTimeout,
        cancelToken: cancelToken,
      )) {
        switch (event.type) {
          case ChatStreamEventType.token:
            content += event.delta ?? '';
            break;
          case ChatStreamEventType.done:
            if ((event.content ?? '').isNotEmpty) content = event.content!;
            promptTokens = event.promptTokens;
            completionTokens = event.completionTokens;
            cachedTokens = event.cachedTokens;
            break;
          case ChatStreamEventType.error:
            return {'success': false, 'message': event.message ?? '流式请求失败'};
        }
      }
    } on DioException catch (e) {
      return {'success': false, 'message': _dioErrorMessage(e)};
    } catch (e) {
      return {'success': false, 'message': '流式请求失败: $e'};
    }
    if (content.trim().isEmpty) {
      return {'success': false, 'message': '模型返回了空内容'};
    }
    return {
      'success': true,
      'message': content,
      if (promptTokens != null) 'promptTokens': promptTokens,
      if (completionTokens != null) 'completionTokens': completionTokens,
      if (cachedTokens != null) 'cachedTokens': cachedTokens,
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
    String? customBaseUrl,
    required String model,
    required List<Map<String, dynamic>> messages,
    double temperature = 0.85,
    int maxTokens = 1024,
    Duration receiveTimeout = const Duration(seconds: 120),
    CancelToken? cancelToken,
  }) async* {
    // 与 sendChatMessage 保持一致的 URL / 模型解析
    final baseUrl = provider == ApiProvider.custom
        ? (customBaseUrl ?? '').replaceAll(RegExp(r'/*$'), '')
        : provider.baseUrl;
    final modelName = model.isEmpty
        ? (ApiProvider.defaultModels[provider.name] ?? '')
        : model;

    if (baseUrl.isEmpty) {
      yield ChatStreamEvent.error('Base URL 不能为空');
      return;
    }
    if (modelName.isEmpty) {
      yield ChatStreamEvent.error('模型名称不能为空');
      return;
    }

    final url = '$baseUrl${provider.apiPath}';
    final headers = <String, String>{
      'Content-Type': 'application/json; charset=utf-8',
      'Authorization': 'Bearer $apiKey',
      'Accept': 'text/event-stream',
    };
    final data = {
      'model': modelName,
      'messages': messages,
      'temperature': temperature,
      'max_tokens': maxTokens,
      'stream': true, // 开启 SSE 流式返回
      'stream_options': {'include_usage': true},
    };

    final parser = SseParser();
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
        yield ChatStreamEvent.error(
            'HTTP ${response.statusCode}: ${_extractErrorText(response.data)}');
        return;
      }

      // stream 模式下 response.data 为 ResponseBody，其 .stream 为 Stream<Uint8List>。
      // Uint8List 是 List<int> 的子类型，但 StreamTransformer 输入类型不协变，
      // 故先 cast 成 Stream<List<int>> 再交给 utf8.decoder。
      final stream = (response.data as ResponseBody)
          .stream
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter());

      // 逐行交给 SseParser，把产出的事件透传给调用方。
      await for (final line in stream) {
        if (RegExp(r'^data:\s*\[DONE\]\s*$').hasMatch(line.trim())) {
          yield parser.doneEvent();
          return;
        }
        final event = parser.ingestLine(line);
        if (event != null) {
          yield event;
        }
      }
      // 流正常结束，返回累计的完整内容。
      yield parser.doneEvent();
    } on DioException catch (e) {
      yield ChatStreamEvent.error(_dioErrorMessage(e));
    } catch (e) {
      yield ChatStreamEvent.error('未知错误: $e');
    }
  }

  /// 从流式响应体（可能尚未读取）中取出可读的错误摘要。
  String _extractErrorText(dynamic data) {
    if (data is ResponseBody) {
      // 流式错误体的内容不易同步读取，返回通用提示即可。
      return '请求失败';
    }
    return data?.toString() ?? '请求失败';
  }

  /// 把 DioException 转换为统一的人类可读错误信息。
  String _dioErrorMessage(DioException e) {
    if (CancelToken.isCancel(e)) return '请求已取消';
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.sendTimeout ||
        e.type == DioExceptionType.receiveTimeout) {
      return '连接超时';
    } else if (e.type == DioExceptionType.connectionError) {
      return '网络连接失败：无法连接到服务器';
    } else if (e.response != null) {
      final err = e.response!.data?.toString() ?? e.message;
      return 'HTTP ${e.response!.statusCode}: $err';
    } else {
      return '请求失败: ${e.message}';
    }
  }

  int _extractCachedTokens(Map<String, dynamic> usage) {
    var total = 0;
    final promptDetails = usage['prompt_tokens_details'];
    if (promptDetails is Map) {
      total += (promptDetails['cached_tokens'] as int? ?? 0);
    }
    final inputDetails = usage['input_tokens_details'];
    if (inputDetails is Map) {
      total += (inputDetails['cached_tokens'] as int? ?? 0);
      total += (inputDetails['cache_read'] as int? ?? 0);
    }
    total += (usage['cached_tokens'] as int? ?? 0);
    total += (usage['prompt_cache_hit_tokens'] as int? ?? 0);
    total += (usage['cache_read_input_tokens'] as int? ?? 0);
    return total;
  }
}
