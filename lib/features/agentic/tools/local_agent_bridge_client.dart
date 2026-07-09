import 'package:dio/dio.dart';
import 'package:chat_group/features/agentic/tools/local_agent_bridge_config.dart';

class LocalAgentBridgeClient {
  final String baseUrl;
  late final Dio _dio;

  LocalAgentBridgeClient({
    this.baseUrl = kLocalAgentBridgeDefaultBaseUrl,
    Dio? dio,
  }) {
    final uri = Uri.parse(baseUrl);
    final local = uri.host == '127.0.0.1' || uri.host == 'localhost';
    if (!local || (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw ArgumentError('Local agent bridge must use localhost.');
    }
    _dio = dio ?? Dio(BaseOptions(baseUrl: baseUrl));
  }

  Future<Map<String, dynamic>> getHealth() async {
    final response = await _dio.get<Map<String, dynamic>>('/health');
    return response.data ?? const {};
  }

  Future<Map<String, dynamic>> postJson(
    String path,
    Map<String, dynamic> body,
  ) async {
    final response = await _dio.post<Map<String, dynamic>>(path, data: body);
    return response.data ?? const {};
  }
}
