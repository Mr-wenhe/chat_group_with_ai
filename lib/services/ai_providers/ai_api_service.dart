import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/models/api_protocol.dart';
import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/ai_governance/ai_request_gateway.dart';
import 'package:chat_group/services/chat_api_service.dart';

class AiApiService {
  static const int _connectionTestMaxTokens = 128;

  final AiRequestGateway gateway;

  const AiApiService(this.gateway);

  /// 取该配置可用的模型清单（表单里的「获取模型」按钮）。
  ///
  /// 刻意不经治理网关：它不是一次模型调用，没有用途、预算与用量可言，也不该写进
  /// 请求诊断。失败原因由返回的 message 给出，已经是安全文案。
  Future<ProviderModelCatalog> fetchModels({
    required String apiKey,
    required ApiProvider provider,
    ApiProtocol apiProtocol = ApiProtocol.defaultValue,
    String? customBaseUrl,
  }) =>
      gateway.client.fetchModels(
        apiKey: apiKey,
        provider: provider,
        apiProtocol: apiProtocol,
        customBaseUrl: customBaseUrl,
      );

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
