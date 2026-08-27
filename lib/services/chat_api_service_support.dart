part of 'chat_api_service.dart';

extension _ChatApiServiceSupport on ChatApiService {
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
            // The stream parser may receive a provider-controlled error body.
            // Never promote that body into the result consumed by the chat UI.
            return {
              'success': false,
              'message': _safeStreamErrorMessage(event.message),
            };
        }
      }
    } on DioException catch (e) {
      return {'success': false, 'message': _dioErrorMessage(e)};
    } catch (e) {
      return {'success': false, 'message': '流式请求失败'};
    }
    if (content.trim().isEmpty) {
      // 部分 OpenAI 兼容服务的 SSE 通道只返回 [DONE]，但同一
      // 请求的非流式通道可正常返回内容；立即回退一次避免任务误报。
      return _sendChatMessageOnce(
        apiKey: apiKey,
        provider: provider,
        customBaseUrl: customBaseUrl,
        model: model,
        messages: messages,
        temperature: temperature,
        maxTokens: maxTokens,
        receiveTimeout: receiveTimeout,
        cancelToken: cancelToken,
        maxResponseBytes: ChatApiService.defaultMaxResponseBytes,
      );
    }
    return {
      'success': true,
      'message': content,
      if (promptTokens != null) 'promptTokens': promptTokens,
      if (completionTokens != null) 'completionTokens': completionTokens,
      if (cachedTokens != null) 'cachedTokens': cachedTokens,
    };
  }

  String _safeHttpErrorMessage(int? statusCode) =>
      statusCode == null ? '请求失败' : 'HTTP $statusCode 请求失败';

  String _safeStreamErrorMessage(String? message) {
    final status = RegExp(r'\bHTTP\s+(\d{3})\b', caseSensitive: false)
        .firstMatch(message ?? '')
        ?.group(1);
    return status == null ? '流式请求失败' : 'HTTP ${int.parse(status)} 请求失败';
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
      return _safeHttpErrorMessage(e.response!.statusCode);
    } else {
      return '请求失败';
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
