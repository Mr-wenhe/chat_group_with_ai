import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/ai_governance/ai_request_gateway.dart';

class AiApiService {
  final AiRequestGateway gateway;

  const AiApiService(this.gateway);

  Future<Map<String, dynamic>> testApiKey({
    required String apiKey,
    required ApiProvider provider,
    String? customBaseUrl,
    String? model,
  }) async {
    final modelName = model ?? ApiProvider.defaultModels[provider.name] ?? '';
    final result = await gateway.sendChatMessage(
      apiKey: apiKey,
      provider: provider,
      customBaseUrl: customBaseUrl,
      model: modelName,
      messages: const [
        {'role': 'user', 'content': 'Hi, reply with "OK" only.'},
      ],
      maxTokens: 0,
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
    return result;
  }
}
