part of 'chat_api_service.dart';

/// Protocol-specific request/response helpers kept outside the transport
/// class so the legacy OpenAI-compatible path stays small and easy to audit.
extension _ChatApiServiceProtocolSupport on ChatApiService {
  String _requestPath(String url) => Uri.tryParse(url)?.path ?? url;

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
  }) {
    return switch (apiProtocol) {
      ApiProtocol.anthropicMessages => _anthropicRequestBody(
          model: model,
          messages: messages,
          temperature: temperature,
          maxTokens: maxTokens,
          streaming: streaming,
        ),
      ApiProtocol.openAiChatCompletions => <String, dynamic>{
          'model': model,
          'messages': messages,
          'temperature': temperature,
          if (maxTokens > 0) 'max_tokens': maxTokens,
          if (streaming) 'stream': true,
          if (streaming) 'stream_options': {'include_usage': true},
          if (structuredJson) 'response_format': {'type': 'json_object'},
        },
      ApiProtocol.openAiResponses => <String, dynamic>{
          'model': model,
          'input': messages,
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

  Map<String, dynamic> _anthropicRequestBody({
    required String model,
    required List<Map<String, dynamic>> messages,
    required double temperature,
    required int maxTokens,
    required bool streaming,
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
      'messages': conversation,
      if (systemParts.isNotEmpty) 'system': systemParts.join('\n\n'),
      'temperature': temperature,
      'max_tokens': maxTokens > 0 ? maxTokens : 1024,
      'stream': streaming,
    };
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

  String _responseText(Map<String, dynamic> data, ApiProtocol protocol) {
    switch (protocol) {
      case ApiProtocol.anthropicMessages:
        return _messageText(data['content']);
      case ApiProtocol.openAiChatCompletions:
        final choices = data['choices'];
        if (choices is List && choices.isNotEmpty && choices.first is Map) {
          final message = (choices.first as Map)['message'];
          if (message is Map) {
            final standard = _messageText(message['content']);
            if (standard.trim().isNotEmpty) return standard;
            return _messageText(message['reasoning_content']);
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

  Map<String, dynamic>? _usageFields(
    Map<String, dynamic> data,
    ApiProtocol protocol,
  ) {
    final usage = switch (protocol) {
      ApiProtocol.geminiGenerateContent => data['usageMetadata'],
      _ => data['usage'],
    };
    if (usage is! Map) return null;
    final prompt = _intValue(
      protocol == ApiProtocol.geminiGenerateContent
          ? usage['promptTokenCount']
          : usage['input_tokens'] ?? usage['prompt_tokens'],
    );
    final completion = _intValue(
      protocol == ApiProtocol.geminiGenerateContent
          ? usage['candidatesTokenCount']
          : usage['output_tokens'] ?? usage['completion_tokens'],
    );
    final cached = _intValue(
      protocol == ApiProtocol.geminiGenerateContent
          ? usage['cachedContentTokenCount']
          : usage['cache_read_input_tokens'] ??
              usage['cached_tokens'] ??
              (usage['prompt_tokens_details'] is Map
                  ? (usage['prompt_tokens_details'] as Map)['cached_tokens']
                  : null),
    );
    return <String, dynamic>{
      if (prompt != null) 'promptTokens': prompt,
      if (completion != null) 'completionTokens': completion,
      if (cached != null) 'cachedTokens': cached,
    };
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

  int? _intValue(Object? value) {
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }
}

/// Small SSE decoder for native protocols whose event payloads do not follow
/// OpenAI's `choices[].delta` shape. It intentionally emits only safe text and
/// usage metadata; raw provider bodies never leave the transport boundary.
class _ProtocolStreamParser {
  final ApiProtocol protocol;
  final StringBuffer _content = StringBuffer();
  String? _eventName;
  String? _model;
  int? _promptTokens;
  int? _completionTokens;
  int? _cachedTokens;
  bool terminated = false;

  _ProtocolStreamParser(this.protocol);

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
    return ChatStreamEvent.done(
      _content.toString(),
      _model,
      _promptTokens,
      _completionTokens,
      _cachedTokens,
    );
  }

  ChatStreamEvent? _anthropic(Map<String, dynamic> payload) {
    final type = payload['type']?.toString() ?? _eventName;
    final message = payload['message'];
    final usage = payload['usage'] ??
        (message is Map<String, dynamic> ? message['usage'] : null);
    if (usage is Map) {
      _promptTokens ??= _intValue(usage['input_tokens']);
      _completionTokens ??= _intValue(usage['output_tokens']);
      _cachedTokens ??= _intValue(usage['cache_read_input_tokens']);
    }
    _model ??= _string(message is Map ? message['model'] : payload['model']);
    if (type == 'content_block_delta') {
      final delta = payload['delta'];
      final text = delta is Map ? _string(delta['text']) : null;
      return _token(text);
    }
    if (type == 'message_stop') return doneEvent();
    return _clearEvent();
  }

  ChatStreamEvent? _responses(Map<String, dynamic> payload) {
    final type = payload['type']?.toString() ?? _eventName;
    if (type == 'response.output_text.delta') {
      return _token(_string(payload['delta']));
    }
    if (type == 'response.completed' || type == 'response.done') {
      final response = payload['response'];
      if (response is Map) {
        _model ??= _string(response['model']);
        final usage = response['usage'];
        if (usage is Map) {
          _promptTokens ??= _intValue(usage['input_tokens']);
          _completionTokens ??= _intValue(usage['output_tokens']);
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
      return _error('上游模型返回错误');
    }
    return _clearEvent();
  }

  ChatStreamEvent? _gemini(Map<String, dynamic> payload) {
    _model ??= _string(payload['modelVersion']);
    final usage = payload['usageMetadata'];
    if (usage is Map) {
      _promptTokens ??= _intValue(usage['promptTokenCount']);
      _completionTokens ??= _intValue(usage['candidatesTokenCount']);
      _cachedTokens ??= _intValue(usage['cachedContentTokenCount']);
    }
    final candidates = payload['candidates'];
    if (candidates is List &&
        candidates.isNotEmpty &&
        candidates.first is Map) {
      final text = _messageText((candidates.first as Map)['content']);
      if (text.isNotEmpty) return _token(text);
    }
    return _clearEvent();
  }

  ChatStreamEvent? _token(String? text) {
    _eventName = null;
    if (text == null || text.isEmpty) return _clearEvent();
    _content.write(text);
    return ChatStreamEvent.token(text);
  }

  ChatStreamEvent _error(String message) {
    terminated = true;
    return ChatStreamEvent.error(message);
  }

  ChatStreamEvent? _clearEvent() {
    _eventName = null;
    return null;
  }

  int? _intValue(Object? value) {
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
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
