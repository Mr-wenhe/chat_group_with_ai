import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/models/api_protocol.dart';
import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/ai_governance/ai_request_gateway.dart';

class AiApiService {
  static const int _connectionTestMaxTokens = 128;

  final AiRequestGateway gateway;

  const AiApiService(this.gateway);

  Future<Map<String, dynamic>> testApiKey({
    required String apiKey,
    required ApiProvider provider,
    ApiProtocol apiProtocol = ApiProtocol.defaultValue,
    String? customBaseUrl,
    String? model,
  }) async {
    final configuredModel = model?.trim() ?? '';
    final modelName =
        configuredModel.isNotEmpty || provider == ApiProvider.custom
            ? configuredModel
            : ApiProvider.defaultModels[provider.name] ?? '';
    final result = await gateway.sendChatMessage(
      apiKey: apiKey,
      provider: provider,
      apiProtocol: apiProtocol,
      customBaseUrl: customBaseUrl,
      model: modelName,
      messages: const [
        {'role': 'user', 'content': 'Hi, reply with "OK" only.'},
      ],
      // Keep the probe short while still sending a valid chat request.
      maxTokens: _connectionTestMaxTokens,
      maxRetries: 0,
      purpose: AiRequestPurpose.connectionTest,
      conversationId: '',
      characterId: '',
      userInitiated: true,
    );
    if (result['success'] == true) {
      return {
        ...result,
        'message': '连接成功',
        'reply': result['message'],
      };
    }
    final providerError = result['providerError']?.toString().trim();
    final requestPath = result['requestPath']?.toString().trim();
    final requestModel = result['requestModel']?.toString().trim();
    final diagnostics = [
      if (providerError != null && providerError.isNotEmpty)
        '服务端：$providerError',
      if (requestPath != null && requestPath.isNotEmpty) '请求路径：$requestPath',
      if (requestModel != null && requestModel.isNotEmpty) '请求模型：$requestModel',
    ];
    return {
      ...result,
      if (diagnostics.isNotEmpty)
        'message': '${result['message'] ?? '连接测试失败'}；${diagnostics.join('；')}',
    };
  }
}
