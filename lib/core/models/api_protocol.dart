/// Wire protocols supported by an [ApiConfig].
///
/// Existing configurations default to OpenAI Chat Completions so adding this
/// field remains backwards compatible. The labels intentionally describe the
/// upstream contract, not the provider name: a custom gateway may expose any
/// of these protocols.
enum ApiProtocol {
  anthropicMessages('Anthropic Messages（原生）'),
  openAiChatCompletions('OpenAI Chat Completions'),
  openAiResponses('OpenAI Responses API'),
  geminiGenerateContent('Gemini Native generateContent');

  final String label;

  const ApiProtocol(this.label);

  static const ApiProtocol defaultValue = ApiProtocol.openAiChatCompletions;

  static ApiProtocol fromName(String? value) {
    for (final protocol in values) {
      if (protocol.name == value) return protocol;
    }
    return defaultValue;
  }

  String get baseUrlHint => switch (this) {
        ApiProtocol.anthropicMessages => 'https://api.anthropic.com/v1',
        ApiProtocol.openAiChatCompletions => 'https://your-api.com/v1',
        ApiProtocol.openAiResponses => 'https://api.openai.com/v1',
        ApiProtocol.geminiGenerateContent =>
          'https://generativelanguage.googleapis.com/v1beta',
      };

  String get description => switch (this) {
        ApiProtocol.anthropicMessages => '请求 /v1/messages；使用 x-api-key 鉴权',
        ApiProtocol.openAiChatCompletions =>
          '请求 /chat/completions；适用于 OpenAI 兼容接口',
        ApiProtocol.openAiResponses => '请求 /responses；适用于实现 Responses API 的接口',
        ApiProtocol.geminiGenerateContent =>
          '请求 :generateContent；适用于 Gemini Native 接口',
      };
}
