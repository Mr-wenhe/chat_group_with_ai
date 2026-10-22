part of 'chat_api_service.dart';

/// Protocol-specific request/response helpers kept outside the transport
/// class so the legacy OpenAI-compatible path stays small and easy to audit.
extension _ChatApiServiceProtocolSupport on ChatApiService {
  String _requestPath(String url) => Uri.tryParse(url)?.path ?? url;

  /// 本次请求实际生效的服务地址：**配置里存了地址就用它**，没存才用提供商的
  /// 规范地址。内置提供商过去只能用预设地址，表单里显示的地址因此是「改了也不
  /// 生效」的假字段；显示可编辑就必须认它，否则内置 + Anthropic 这类协议子路径
  /// 永远无法配置。
  String _configuredBaseUrl({
    required ApiProvider provider,
    String? customBaseUrl,
  }) {
    final stored = customBaseUrl?.trim() ?? '';
    if (stored.isNotEmpty) return stored;
    return provider.baseUrl.trim();
  }

  /// Custom endpoints own their model namespace. Never replace a custom
  /// model with one of the application's provider presets.
  String _resolveModelName({
    required ApiProvider provider,
    required String model,
  }) {
    final configuredModel = model.trim();
    if (configuredModel.isNotEmpty || provider == ApiProvider.custom) {
      return configuredModel;
    }
    return ApiProvider.defaultModels[provider.name] ?? '';
  }

  String? _safeProviderErrorDetail(Object? responseData) {
    final responseMap =
        responseData is Map ? Map<String, dynamic>.from(responseData) : null;
    final errorValue = responseMap?['error'];
    final errorMap =
        errorValue is Map ? Map<String, dynamic>.from(errorValue) : null;
    final message =
        (errorMap?['message'] ?? responseMap?['message'])?.toString().trim();
    final type = errorMap?['type']?.toString().trim();
    final code = errorMap?['code']?.toString().trim();
    if ((message == null || message.isEmpty) &&
        (type == null || type.isEmpty) &&
        (code == null || code.isEmpty)) {
      return null;
    }

    final parts = <String>[];
    if (message != null && message.isNotEmpty) {
      parts.add(_redactProviderText(message));
    }
    if (type != null && type.isNotEmpty) parts.add(type);
    if (code != null && code.isNotEmpty) parts.add('code=$code');
    return parts.join('；');
  }

  String _redactProviderText(String value) {
    final redacted = value
        .replaceAll(
          RegExp(
            r'(api[-_ ]?key|authorization|bearer)\s*[:=]\s*[^\s,;]+',
            caseSensitive: false,
          ),
          '[REDACTED]',
        )
        .replaceAll(RegExp(r'\bsk-[A-Za-z0-9._-]+\b'), '[REDACTED]');
    return redacted.length <= 180 ? redacted : '${redacted.substring(0, 180)}…';
  }

  String _appendProtocolPath({
    required String path,
    required ApiProtocol protocol,
    required String model,
    required bool streaming,
  }) {
    final clean = path.replaceAll(RegExp(r'/+$'), '');
    return switch (protocol) {
      ApiProtocol.anthropicMessages => '$clean/messages',
      ApiProtocol.openAiChatCompletions => '$clean/chat/completions',
      ApiProtocol.openAiResponses => '$clean/responses',
      ApiProtocol.geminiGenerateContent => clean.contains('/models/')
          ? '$clean:${streaming ? 'streamGenerateContent' : 'generateContent'}'
          : '$clean/models/${Uri.encodeComponent(model)}:'
              '${streaming ? 'streamGenerateContent' : 'generateContent'}',
    };
  }

  Map<String, String> _requestHeaders({
    required String apiKey,
    required ApiProtocol apiProtocol,
  }) {
    return switch (apiProtocol) {
      ApiProtocol.anthropicMessages => <String, String>{
          'Content-Type': 'application/json',
          'x-api-key': apiKey,
          'anthropic-version': '2023-06-01',
        },
      ApiProtocol.geminiGenerateContent => <String, String>{
          'Content-Type': 'application/json',
          'x-goog-api-key': apiKey,
        },
      ApiProtocol.openAiChatCompletions ||
      ApiProtocol.openAiResponses =>
        <String, String>{
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $apiKey',
        },
    };
  }

  Map<String, dynamic> _requestBody({
    required ApiProtocol apiProtocol,
    required String model,
    required List<Map<String, dynamic>> messages,
    required double temperature,
    required int maxTokens,
    required bool streaming,
    bool structuredJson = false,
    bool stepPlanLowReasoning = false,
    String? reasoningEffort,
    String? promptCacheKey,
  }) {
    final step5Effort = model.trim().toLowerCase() == 'step-5-preview' &&
            const {'low', 'medium', 'high'}.contains(reasoningEffort)
        ? reasoningEffort
        : null;
    return switch (apiProtocol) {
      ApiProtocol.anthropicMessages => _anthropicRequestBody(
          model: model,
          messages: messages,
          temperature: temperature,
          maxTokens: maxTokens,
          streaming: streaming,
          promptCacheKey: promptCacheKey,
          reasoningEffort: step5Effort,
        ),
      ApiProtocol.openAiChatCompletions => <String, dynamic>{
          'model': model,
          'messages': messages,
          if (promptCacheKey != null) 'prompt_cache_key': promptCacheKey,
          'temperature': temperature,
          if (step5Effort != null) 'reasoning_effort': step5Effort,
          if (maxTokens > 0) 'max_tokens': maxTokens,
          if (streaming) 'stream': true,
          if (streaming) 'stream_options': {'include_usage': true},
          // The currently supported StepFun reasoning models accept JSON mode
          // together with their reasoning envelope.  Keep it enabled for
          // structured work turns; prompt-only formatting is too fragile for
          // long multi-role discussions and can surface a natural-language
          // answer instead of the protocol object.
          if (structuredJson) 'response_format': {'type': 'json_object'},
          if ((stepPlanLowReasoning || _isStepFunReasoningModel(model)) &&
              _supportsStepPlanReasoningFormat(model))
            'reasoning_format': 'deepseek-style',
        },
      ApiProtocol.openAiResponses => <String, dynamic>{
          'model': model,
          'input': messages,
          if (promptCacheKey != null) 'prompt_cache_key': promptCacheKey,
          'temperature': temperature,
          if (maxTokens > 0) 'max_output_tokens': maxTokens,
          'stream': streaming,
        },
      ApiProtocol.geminiGenerateContent => _geminiRequestBody(
          model: model,
          messages: messages,
          temperature: temperature,
          maxTokens: maxTokens,
        ),
    };
  }

  bool _isStepPlanEndpoint({
    required ApiProvider provider,
    required String? customBaseUrl,
  }) {
    if (provider != ApiProvider.custom) return false;
    final path = Uri.tryParse(customBaseUrl?.trim() ?? '')?.path.toLowerCase();
    return path?.contains('/step_plan/') ?? false;
  }

  bool _supportsStepPlanReasoningFormat(String model) {
    final normalized = model.trim().toLowerCase();
    return const {
      'step-3.7-flash',
      'step-3.5-flash',
      'step-3.5-flash-2603',
      'step-3',
      'step-r1-v-mini',
      'step-router-v1',
    }.contains(normalized);
  }

  bool _isStepFunReasoningModel(String model) =>
      _supportsStepPlanReasoningFormat(model);

  Map<String, dynamic> _anthropicRequestBody({
    required String model,
    required List<Map<String, dynamic>> messages,
    required double temperature,
    required int maxTokens,
    required bool streaming,
    String? promptCacheKey,
    String? reasoningEffort,
  }) {
    final systemParts = <String>[];
    final conversation = <Map<String, dynamic>>[];
    for (final message in messages) {
      final role = message['role']?.toString().toLowerCase() ?? 'user';
      final content = message['content'];
      if (role == 'system') {
        final text = _messageText(content);
        if (text.isNotEmpty) systemParts.add(text);
        continue;
      }
      conversation.add({
        'role': role == 'assistant' ? 'assistant' : 'user',
        'content': content is String ? content : _messageText(content),
      });
    }
    return <String, dynamic>{
      'model': model,
      // Step 5 也可能被配成 Messages 协议走兼容中转：`output_config.effort`
      // 是 Messages 侧的推理档位字段，由中转翻译，不能只发给 OpenAI 通道。
      if (reasoningEffort != null) 'output_config': {'effort': reasoningEffort},
      'messages': conversation,
      if (systemParts.isNotEmpty)
        'system': promptCacheKey == null
            ? systemParts.join('\n\n')
            : _cachedSystemBlocks(systemParts),
      'temperature': temperature,
      'max_tokens': maxTokens > 0 ? maxTokens : 1024,
      'stream': streaming,
    };
  }

  List<Map<String, dynamic>> _cachedSystemBlocks(List<String> parts) {
    final first = parts.first;
    final boundary = first.indexOf(AgentPromptBuilder.dynamicContextMarker);
    // 动态边界就在最前面时没有稳定前缀；空 text block 会被上游判为无效请求，
    // 所以回退成不带 cache_control 的普通分段，而不是发一个空的缓存块。
    if (boundary == 0) {
      return [
        {'type': 'text', 'text': first},
        for (final text in parts.skip(1)) {'type': 'text', 'text': text},
      ];
    }
    // Only the stable first system prefix is cached; dynamic task data stays after it.
    final stable = boundary < 0 ? first : first.substring(0, boundary);
    return [
      {
        'type': 'text',
        'text': stable,
        'cache_control': {'type': 'ephemeral'}
      },
      if (boundary > 0) {'type': 'text', 'text': first.substring(boundary)},
      for (final text in parts.skip(1)) {'type': 'text', 'text': text},
    ];
  }

  Map<String, dynamic> _geminiRequestBody({
    required String model,
    required List<Map<String, dynamic>> messages,
    required double temperature,
    required int maxTokens,
  }) {
    final contents = <Map<String, dynamic>>[];
    final systemParts = <Map<String, String>>[];
    for (final message in messages) {
      final role = message['role']?.toString().toLowerCase() ?? 'user';
      final parts = _geminiParts(message['content']);
      if (parts.isEmpty) continue;
      if (role == 'system') {
        systemParts.addAll(parts);
      } else {
        contents.add({
          'role': role == 'assistant' ? 'model' : 'user',
          'parts': parts,
        });
      }
    }
    return <String, dynamic>{
      'contents': contents,
      if (systemParts.isNotEmpty) 'systemInstruction': {'parts': systemParts},
      'generationConfig': <String, dynamic>{
        'temperature': temperature,
        if (maxTokens > 0) 'maxOutputTokens': maxTokens,
      },
    };
  }

  Map<String, dynamic>? _asJsonMap(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return null;
  }

  String _responseText(
    Map<String, dynamic> data,
    ApiProtocol protocol, {
    bool allowReasoningContentFallback = false,
  }) {
    switch (protocol) {
      case ApiProtocol.anthropicMessages:
        final standard = _messageText(data['content']);
        if (standard.trim().isNotEmpty) return standard;
        return allowReasoningContentFallback
            ? _messageText(data['reasoning_content'])
            : '';
      case ApiProtocol.openAiChatCompletions:
        final choices = data['choices'];
        if (choices is List && choices.isNotEmpty && choices.first is Map) {
          final message = (choices.first as Map)['message'];
          if (message is Map) {
            final standard = _messageText(message['content']);
            if (standard.trim().isNotEmpty) return standard;
            // `reasoning_content` is private analysis for ordinary chat. Only
            // internal structured callers explicitly opt into this fallback.
            return allowReasoningContentFallback
                ? _messageText(message['reasoning_content'])
                : '';
          }
        }
        return '';
      case ApiProtocol.openAiResponses:
        final direct = data['output_text'];
        if (direct is String && direct.trim().isNotEmpty) return direct;
        return _messageText(data['output']);
      case ApiProtocol.geminiGenerateContent:
        final candidates = data['candidates'];
        if (candidates is List &&
            candidates.isNotEmpty &&
            candidates.first is Map) {
          return _messageText((candidates.first as Map)['content']);
        }
        return '';
    }
  }

  /// The upstream stop signal that accompanied an empty completion.
  ///
  /// It exists so work mode can record *why* a provider answered HTTP 200 with
  /// no content: an idle endpoint and a reasoning model that spent the whole
  /// output budget before writing anything look identical otherwise. It is
  /// protocol data, never shown as a reply.
  Map<String, dynamic> _emptyCompletionDetail(
    Map<String, dynamic> data,
    ApiProtocol protocol,
  ) {
    final usage = switch (protocol) {
      ApiProtocol.geminiGenerateContent => data['usageMetadata'],
      _ => data['usage'],
    };
    final usageMap = usage is Map ? usage : const <String, dynamic>{};
    final completionTokens = _intValue(
      protocol == ApiProtocol.geminiGenerateContent
          ? usageMap['candidatesTokenCount']
          : usageMap['output_tokens'] ?? usageMap['completion_tokens'],
    );
    final reasoningDetails = switch (protocol) {
      ApiProtocol.geminiGenerateContent => null,
      _ => usageMap['completion_tokens_details'] ??
          usageMap['output_tokens_details'],
    };
    final reasoningTokens = _intValue(
      protocol == ApiProtocol.geminiGenerateContent
          ? usageMap['thoughtsTokenCount']
          : reasoningDetails is Map
              ? reasoningDetails['reasoning_tokens']
              : null,
    );
    final stop = switch (protocol) {
      ApiProtocol.openAiChatCompletions =>
        _firstChoiceField(data, 'finish_reason'),
      ApiProtocol.anthropicMessages => data['stop_reason'],
      ApiProtocol.openAiResponses => data['incomplete_details'] is Map
          ? (data['incomplete_details'] as Map)['reason']
          : data['status'],
      ApiProtocol.geminiGenerateContent =>
        _firstCandidateField(data, 'finishReason'),
    };
    final stopText = stop?.toString().trim() ?? '';
    return <String, dynamic>{
      if (stopText.isNotEmpty) 'finishReason': stopText,
      if (completionTokens != null) 'completionTokens': completionTokens,
      if (reasoningTokens != null) 'reasoningTokens': reasoningTokens,
    };
  }

  Object? _firstChoiceField(Map<String, dynamic> data, String field) {
    final choices = data['choices'];
    if (choices is! List || choices.isEmpty || choices.first is! Map) {
      return null;
    }
    return (choices.first as Map)[field];
  }

  Object? _firstCandidateField(Map<String, dynamic> data, String field) {
    final candidates = data['candidates'];
    if (candidates is! List || candidates.isEmpty || candidates.first is! Map) {
      return null;
    }
    return (candidates.first as Map)[field];
  }

  Map<String, dynamic>? _usageFields(
    Map<String, dynamic> data,
    ApiProtocol protocol,
  ) {
    final usage = switch (protocol) {
      ApiProtocol.geminiGenerateContent => data['usageMetadata'],
      _ => data['usage'],
    };
    if (usage is! Map) return null;
    return ReportedTokenUsage.fromWire(usage, protocol).toMap();
  }

  String? _responseModel(Map<String, dynamic> data, ApiProtocol protocol) {
    final value = data['model'] ??
        (protocol == ApiProtocol.geminiGenerateContent
            ? data['modelVersion']
            : null);
    return value is String && value.trim().isNotEmpty ? value : null;
  }

  String _messageText(Object? value) {
    if (value is String) return value;
    if (value is List) {
      return value.map(_messageText).where((text) => text.isNotEmpty).join();
    }
    if (value is Map) {
      final partsText = _messageText(value['parts']);
      if (partsText.isNotEmpty) return partsText;
      for (final key in const ['text', 'value', 'output_text', 'content']) {
        final text = _messageText(value[key]);
        if (text.isNotEmpty) return text;
      }
    }
    return '';
  }

  List<Map<String, String>> _geminiParts(Object? content) {
    if (content is List) {
      return content
          .map((item) => _messageText(item))
          .where((text) => text.isNotEmpty)
          .map((text) => <String, String>{'text': text})
          .toList(growable: false);
    }
    final text = _messageText(content);
    return text.isEmpty
        ? const []
        : <Map<String, String>>[
            {'text': text}
          ];
  }

  int? _intValue(Object? value) =>
      value is num ? value.toInt() : int.tryParse('$value');
}

/// Small SSE decoder for native protocols whose event payloads do not follow
/// OpenAI's `choices[].delta` shape. It intentionally emits only safe text and
/// usage metadata; raw provider bodies never leave the transport boundary.
class _ProtocolStreamParser {
  final ApiProtocol protocol;
  final StringBuffer _content = StringBuffer();
  String? _eventName;
  String? _model;
  ReportedTokenUsage _usage = const ReportedTokenUsage();
  final Map<String, dynamic> _anthropicInputUsage = {};
  bool terminated = false;
  ReportedTokenUsage get usage => _usage;
  bool hasTerminalFrame = false;
  bool _truncated = false;

  final void Function()? onResponseActivity;
  final bool separateThoughts;
  _ProtocolStreamParser(this.protocol,
      {this.onResponseActivity, this.separateThoughts = false});

  ChatStreamEvent? ingestLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed.startsWith('event:')) {
      _eventName = trimmed.substring('event:'.length).trim();
      return null;
    }
    final data = trimmed.startsWith('data:')
        ? trimmed.substring('data:'.length).trim()
        : trimmed;
    if (data == '[DONE]') return doneEvent();
    final decoded = jsonDecode(data);
    if (decoded is! Map) return _error('流式响应格式无效');
    final payload = Map<String, dynamic>.from(decoded);
    if (payload['error'] != null || _eventName == 'error') {
      if (payload['usage'] is Map) {
        _usage = _usage.merge(
            ReportedTokenUsage.fromWire(payload['usage'] as Map, protocol));
      }
      return _error('上游模型返回错误');
    }
    return switch (protocol) {
      ApiProtocol.anthropicMessages => _anthropic(payload),
      ApiProtocol.openAiResponses => _responses(payload),
      ApiProtocol.geminiGenerateContent => _gemini(payload),
      ApiProtocol.openAiChatCompletions => null,
    };
  }

  ChatStreamEvent doneEvent() {
    terminated = true;
    return ChatStreamEvent(
      type: ChatStreamEventType.done,
      content: _content.toString(),
      model: _model,
      promptTokens: _usage.inputTokens,
      completionTokens: _usage.outputTokens,
      cachedTokens: _usage.cachedTokens,
      cacheWriteTokens: _usage.cacheWriteTokens,
      reasoningTokens: _usage.reasoningTokens,
      uncachedInputTokens: _usage.uncachedInputTokens,
      truncated: _truncated,
    );
  }

  ChatStreamEvent? _anthropic(Map<String, dynamic> payload) {
    final type = payload['type']?.toString() ?? _eventName;
    final message = payload['message'];
    final usage = payload['usage'] ??
        (message is Map<String, dynamic> ? message['usage'] : null);
    if (usage is Map) {
      final reported = Map<String, dynamic>.from(usage);
      // message_start.output_tokens is an initial snapshot, not the final billable output.
      if (type == 'message_start') reported.remove('output_tokens');
      _anthropicInputUsage.addAll(reported);
      _usage = _usage.merge(ReportedTokenUsage.fromWire(
          _anthropicInputUsage, ApiProtocol.anthropicMessages));
    }
    _model ??= _string(message is Map ? message['model'] : payload['model']);
    if (type == 'content_block_delta') {
      final delta = payload['delta'];
      if (delta is Map && _string(delta['thinking'])?.isNotEmpty == true) {
        onResponseActivity?.call();
      }
      final text = delta is Map ? _string(delta['text']) : null;
      return _token(text);
    }
    if (type == 'message_stop') return doneEvent();
    return _usage.hasValues
        ? ChatStreamEvent.token('').withUsage(_usage)
        : _clearEvent();
  }

  ChatStreamEvent? _responses(Map<String, dynamic> payload) {
    final type = payload['type']?.toString() ?? _eventName;
    if (const {
      'response.reasoning_text.delta',
      'response.reasoning_summary_text.delta'
    }.contains(type)) {
      if (_string(payload['delta'])?.isNotEmpty == true) {
        onResponseActivity?.call();
      }
      return _clearEvent();
    }
    if (type == 'response.output_text.delta') {
      return _token(_string(payload['delta']));
    }
    if (type == 'response.completed' || type == 'response.done') {
      final response = payload['response'];
      if (response is Map) {
        _model ??= _string(response['model']);
        final usage = response['usage'];
        if (usage is Map) {
          _usage = _usage.merge(ReportedTokenUsage.fromWire(usage, protocol));
        }
        if (_content.isEmpty) {
          final text = _messageText(response['output_text']).isNotEmpty
              ? _messageText(response['output_text'])
              : _messageText(response['output']);
          if (text.isNotEmpty) _content.write(text);
        }
      }
      return doneEvent();
    }
    if (type == 'response.failed' || type == 'response.incomplete') {
      final response = payload['response'];
      if (response is Map && response['usage'] is Map) {
        _usage = _usage.merge(
            ReportedTokenUsage.fromWire(response['usage'] as Map, protocol));
      }
      return _error('上游模型返回错误');
    }
    return _clearEvent();
  }

  ChatStreamEvent? _gemini(Map<String, dynamic> payload) {
    _model ??= _string(payload['modelVersion']);
    final usage = payload['usageMetadata'];
    if (usage is Map) {
      _usage = _usage.merge(ReportedTokenUsage.fromWire(usage, protocol));
    }
    final candidates = payload['candidates'];
    if (candidates is List &&
        candidates.isNotEmpty &&
        candidates.first is Map) {
      final candidate = candidates.first as Map;
      final finishReason = candidate['finishReason'];
      hasTerminalFrame = finishReason == 'STOP' || finishReason == 'MAX_TOKENS';
      _truncated = separateThoughts && finishReason == 'MAX_TOKENS';
      var content = candidate['content'];
      if (separateThoughts && content is Map && content['parts'] is List) {
        final parts = content['parts'] as List;
        if (parts.any((part) =>
            part is Map &&
            part['thought'] == true &&
            _string(part['text'])?.isNotEmpty == true)) {
          onResponseActivity?.call();
        }
        content = {
          ...content,
          'parts': parts
              .where((part) => part is! Map || part['thought'] != true)
              .toList()
        };
      }
      final text = _messageText(content);
      if (text.isNotEmpty) return _token(text);
    }
    return _clearEvent();
  }

  ChatStreamEvent? _token(String? text) {
    _eventName = null;
    if (text == null || text.isEmpty) return _clearEvent();
    onResponseActivity?.call();
    _content.write(text);
    return ChatStreamEvent.token(text);
  }

  ChatStreamEvent _error(String message) {
    terminated = true;
    return ChatStreamEvent.error(message).withUsage(_usage);
  }

  ChatStreamEvent? _clearEvent() {
    _eventName = null;
    return null;
  }

  String? _string(Object? value) => value is String ? value : null;

  String _messageText(Object? value) {
    if (value is String) return value;
    if (value is List) return value.map(_messageText).join();
    if (value is Map) {
      final partsText = _messageText(value['parts']);
      if (partsText.isNotEmpty) return partsText;
      for (final key in const ['text', 'value', 'output_text', 'content']) {
        final text = _messageText(value[key]);
        if (text.isNotEmpty) return text;
      }
    }
    return '';
  }
}
