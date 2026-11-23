part of 'chat_api_service.dart';

extension _ChatApiServiceSupport on ChatApiService {
  Future<Map<String, dynamic>> _collectStreamedOnce({
    required String apiKey,
    required ApiProvider provider,
    required ApiProtocol apiProtocol,
    String? customBaseUrl,
    String? userAgent,
    required String model,
    required List<Map<String, dynamic>> messages,
    required double temperature,
    required int maxTokens,
    required Duration receiveTimeout,
    required bool structuredJson,
    CancelToken? cancelToken,
    bool finishOnTerminalFrame = false,
    String? reasoningEffort,
    void Function()? onResponseActivity,
    void Function(ChatStreamEvent event)? onEvent,
    String? promptCacheKey,
  }) async {
    final transportFailures = <Map<String, dynamic>>[];
    Map<String, dynamic> withAttempts(Map<String, dynamic> result) =>
        transportFailures.isEmpty
            ? result
            : {
                ...result,
                'usageAttempts': [...transportFailures, result],
              };
    String content = '';
    var useDefaultTemperature = false;
    var truncated = false;
    var usage = const ReportedTokenUsage();

    /// 空完成时改走非流式通道再问一次。
    ///
    /// 部分 OpenAI 兼容服务的 SSE 通道只返回 `[DONE]`、或被推理模型把输出预算
    /// 全花在思考上，但同一请求的非流式通道可正常返回内容。这条回退必须在
    /// 「error 事件」和「流结束仍无正文」两处都生效：上层网关会把空完成转成
    /// 带 `emptyCompletion` 标记的 error，只在函数末尾判断就会漏掉。
    Future<Map<String, dynamic>> fallbackToNonStreaming(
      ReportedTokenUsage streamedUsage,
    ) async {
      final fallback = await _sendChatMessageOnce(
        apiKey: apiKey,
        provider: provider,
        apiProtocol: apiProtocol,
        promptCacheKey: promptCacheKey,
        customBaseUrl: customBaseUrl,
        userAgent: userAgent,
        model: model,
        messages: messages,
        temperature: temperature,
        maxTokens: maxTokens,
        receiveTimeout: receiveTimeout,
        cancelToken: cancelToken,
        structuredJson: structuredJson,
        useDefaultTemperature: useDefaultTemperature,
        reasoningEffort: reasoningEffort,
        stepPlanLowReasoning: _isStepPlanEndpoint(
          provider: provider,
          customBaseUrl: customBaseUrl,
        ),
        maxResponseBytes: ChatApiService.defaultMaxResponseBytes,
      );
      return withAttempts({
        ...fallback,
        'usageAttempts': [
          {...streamedUsage.toMap(), 'success': false, 'message': '模型返回了空内容'},
          fallback,
        ]
      });
    }
    try {
      // Keep the legacy public stream as the extension point for existing
      // clients/tests. The internal path is used only for structured agent
      // requests because it carries the extra JSON-mode flag.
      final responseStream = structuredJson
          ? _streamChatMessageInternal(
              apiKey: apiKey,
              provider: provider,
              apiProtocol: apiProtocol,
              promptCacheKey: promptCacheKey,
              customBaseUrl: customBaseUrl,
              userAgent: userAgent,
              model: model,
              messages: messages,
              temperature: temperature,
              maxTokens: maxTokens,
              receiveTimeout: receiveTimeout,
              structuredJson: true,
              cancelToken: cancelToken,
              finishOnTerminalFrame: finishOnTerminalFrame,
              reasoningEffort: reasoningEffort,
              onResponseActivity: onResponseActivity,
            )
          : streamChatMessage(
              apiKey: apiKey,
              provider: provider,
              apiProtocol: apiProtocol,
              promptCacheKey: promptCacheKey,
              customBaseUrl: customBaseUrl,
              userAgent: userAgent,
              model: model,
              messages: messages,
              temperature: temperature,
              maxTokens: maxTokens,
              receiveTimeout: receiveTimeout,
              cancelToken: cancelToken,
              finishOnTerminalFrame: finishOnTerminalFrame,
              reasoningEffort: reasoningEffort,
              onResponseActivity: onResponseActivity,
            );
      completionLoop:
      await for (final event in responseStream) {
        final failure = event.transportFailure;
        if (failure != null) {
          useDefaultTemperature = true;
          transportFailures.add({
            ...failure.usage.toMap(),
            'success': false,
            'message': failure.message,
            'statusCode': _streamStatusCode(failure.message),
            if (failure.failureDetail != null)
              'failureDetail': failure.failureDetail,
          });
          continue;
        }
        usage = usage.merge(event.usage);
        onEvent?.call(event);
        switch (event.type) {
          case ChatStreamEventType.token:
            content += event.delta ?? '';
            break;
          case ChatStreamEventType.done:
            if ((event.content ?? '').isNotEmpty) content = event.content!;
            if (event.truncated) truncated = true;
            if (finishOnTerminalFrame) break completionLoop;
            break;
          case ChatStreamEventType.error:
            // 空完成不是普通失败：先给非流式通道一次机会，别把可重试的协议
            // 偶发直接报成任务失败（群讨论的空完成重发也靠这条回退之外的上层
            // 判断，两处都必须能看到 emptyCompletion 标记）。
            if (event.emptyCompletion) {
              return fallbackToNonStreaming(usage);
            }
            // 已由 ChatApiService 分类/脱敏的消息原样透传，否则「连接超时」
            // 会被再洗成「流式请求失败」，isTransientResult 与 WorkFailure
            // 就再也看不出这次失败能否重试。未标记的消息可能仍含供应商正文
            // （自定义 streamChatMessage 实现直接 yield 的情况），保留一次脱敏。
            final statusCode = _streamStatusCode(event.message);
            final retryAfter = event.retryAfter;
            return withAttempts({
              ...usage.toMap(),
              'success': false,
              'message': event.sanitized
                  ? (event.message ?? '流式请求失败')
                  : _safeStreamErrorMessage(event.message),
              if (statusCode != null) 'statusCode': statusCode,
              if (retryAfter != null) 'retryAfterMs': retryAfter.inMilliseconds,
              if (event.failureDetail != null)
                'failureDetail': event.failureDetail,
            });
        }
      }
    } on DioException catch (e) {
      final statusCode = e.response?.statusCode;
      final retryAfter = _retryAfterFromHeaders(e.response?.headers);
      return withAttempts({
        ...usage.toMap(),
        'success': false,
        'message': _dioErrorMessage(e),
        'failureDetail': _failureDetail(e),
        if (statusCode != null) 'statusCode': statusCode,
        if (retryAfter != null) 'retryAfterMs': retryAfter.inMilliseconds,
      });
    } catch (e) {
      return withAttempts({
        ...usage.toMap(),
        'success': false,
        'message': '流式请求失败',
        'failureDetail': _failureDetail(e),
      });
    }
    if (content.trim().isEmpty) {
      // 流走完了却没有正文字符（有的通道连 [DONE] 的 content 都空）：与非流式
      // 通道的回退共用同一条路径，避免两处各写一份「空内容」话术。
      return fallbackToNonStreaming(usage);
    }
    return withAttempts({
      'success': true,
      'message': content,
      if (truncated) 'truncated': true,
      // 请求时给出的输出上限。`truncated` 只有 OpenAI 兼容解析器会产出（看
      // finish_reason），带上这个值，调用方就能跨协议判断"输出是否被用尽"。
      if (maxTokens > 0) 'requestedMaxTokens': maxTokens,
      ...usage.toMap(),
    });
  }

  String _safeHttpErrorMessage(int? statusCode, {String? providerError}) =>
      switch (statusCode) {
        401
            when providerError
                    ?.toLowerCase()
                    .contains('unauthorized client detected') ??
                false =>
          'HTTP 401：服务端拒绝当前客户端；请向服务商确认此 Key 是否允许第三方客户端调用当前接口。',
        null => '请求失败',
        final int code when _isRedirectStatus(code) =>
          _redirectBlockedMessage(code),
        _ => 'HTTP $statusCode 请求失败',
      };

  /// Preserve explicit caller size limits while bounding error-body read time.
  Future<Map<String, dynamic>?> _readStreamErrorBody(ResponseBody? body,
      {int? maxResponseBytes}) async {
    if (body == null) return null;
    final chunks = StreamIterator<Uint8List>(body.stream);
    final stopwatch = Stopwatch()..start();
    try {
      final bytes = BytesBuilder(copy: false);
      while (true) {
        final remaining =
            ChatApiService._httpErrorReadTimeout - stopwatch.elapsed;
        if (remaining <= Duration.zero) return null;
        if (!await chunks.moveNext().timeout(remaining)) break;
        final chunk = chunks.current;
        if (bytes.length + chunk.length >
            (maxResponseBytes ?? ChatApiService._maxHttpErrorBytes)) {
          if (maxResponseBytes != null) {
            throw const _ChatResponseTooLargeException();
          }
          return null;
        }
        bytes.add(chunk);
      }
      return _asJsonMap(
          jsonDecode(utf8.decode(bytes.takeBytes(), allowMalformed: true)));
    } on _ChatResponseTooLargeException {
      rethrow;
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) rethrow;
      return null;
    } on Object {
      return null;
    } finally {
      // Cancelling a stalled socket must not extend the read deadline.
      unawaited(chunks.cancel());
    }
  }

  /// 把异常折成「异常类型 + 脱敏后有界的正文摘要」，只供诊断归因使用。
  ///
  /// 用户可见文案已经把这些成因折叠成同一句（「请求失败」「流式请求失败」），
  /// 事后无法区分响应体不是 JSON、TLS 证书被拒还是连接被丢包；审计里必须留下
  /// 类型与开头。dio 的 `toString()` 会带出整个请求上下文，这里显式只取类型、
  /// 内层异常与 message，避免把无关上下文写进诊断。
  String _failureDetail(Object error) {
    final parts = <String>[];
    if (error is DioException) {
      parts.add('DioException/${error.type.name}');
      final inner = error.error;
      if (inner != null) parts.add('${inner.runtimeType}: $inner');
      final message = error.message;
      if (message != null && message.trim().isNotEmpty) parts.add(message);
    } else {
      parts.add(error.runtimeType.toString());
      parts.add('$error');
    }
    final redacted =
        const SearchSecretScanner().redact(parts.join(' | ')).trim();
    return redacted.length <= ChatApiService.failureDetailMaxLength
        ? redacted
        : '${redacted.substring(0, ChatApiService.failureDetailMaxLength)}…';
  }

  String _safeStreamErrorMessage(String? message) {
    final statusCode = _streamStatusCode(message);
    return statusCode == null ? '流式请求失败' : 'HTTP $statusCode 请求失败';
  }

  int? _streamStatusCode(String? message) {
    final status = RegExp(r'\bHTTP\s+(\d{3})\b', caseSensitive: false)
        .firstMatch(message ?? '')
        ?.group(1);
    return status == null ? null : int.tryParse(status);
  }

  Duration? _retryAfterFromHeaders(Headers? headers) {
    if (headers == null) return null;
    String? raw;
    for (final entry in headers.map.entries) {
      if (entry.key.toLowerCase() != 'retry-after' || entry.value.isEmpty) {
        continue;
      }
      raw = entry.value.first.trim();
      break;
    }
    if (raw == null || raw.isEmpty) return null;
    final seconds = int.tryParse(raw);
    if (seconds != null && seconds >= 0) {
      return _boundRetryAfter(Duration(seconds: seconds));
    }
    final date = _parseRetryAfterDate(raw);
    if (date == null) return null;
    final remaining = date.difference(DateTime.now());
    return _boundRetryAfter(remaining.isNegative ? Duration.zero : remaining);
  }

  Duration _boundRetryAfter(Duration value) {
    const maximum = Duration(minutes: 2);
    return value.compareTo(maximum) > 0 ? maximum : value;
  }

  DateTime? _parseRetryAfterDate(String raw) {
    final parsed = DateTime.tryParse(raw);
    if (parsed != null) return parsed;
    final match = RegExp(
      r'^[A-Za-z]{3},\s+(\d{2})\s+([A-Za-z]{3})\s+(\d{4})\s+'
      r'(\d{2}):(\d{2}):(\d{2})\s+GMT$',
      caseSensitive: false,
    ).firstMatch(raw);
    if (match == null) return null;
    const months = <String, int>{
      'jan': 1,
      'feb': 2,
      'mar': 3,
      'apr': 4,
      'may': 5,
      'jun': 6,
      'jul': 7,
      'aug': 8,
      'sep': 9,
      'oct': 10,
      'nov': 11,
      'dec': 12,
    };
    final month = months[match.group(2)!.toLowerCase()];
    if (month == null) return null;
    return DateTime.utc(
      int.parse(match.group(3)!),
      month,
      int.parse(match.group(1)!),
      int.parse(match.group(4)!),
      int.parse(match.group(5)!),
      int.parse(match.group(6)!),
    );
  }

  /// 把 DioException 转换为统一的人类可读错误信息。
  String _dioErrorMessage(DioException e) {
    if (CancelToken.isCancel(e)) return ChatApiService.cancelledResultMessage;
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
}

bool _isRedirectStatus(int statusCode) => statusCode >= 300 && statusCode < 400;

/// 带凭据的请求一律不自动跟随重定向，3xx 因此原样回到调用方。文案要说清这是
/// 「不让 Key 跟着跳」而不是网络故障，并给出用户自己能做的动作——把 Base URL
/// 直接改成最终地址。目标地址不回显：它来自上游的 Location，属于不可信正文。
String _redirectBlockedMessage(int statusCode) =>
    'HTTP $statusCode：服务地址要求跳转，已停止请求（API Key 只发给配置里的地址）；'
    '请把 Base URL 改成最终地址';
