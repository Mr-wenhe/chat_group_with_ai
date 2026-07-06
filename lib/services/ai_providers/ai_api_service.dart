import 'package:dio/dio.dart';
import 'package:chat_group/core/models/api_provider.dart';

class AiApiService {
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 15),
  ));

  Future<Map<String, dynamic>> testApiKey({
    required String apiKey,
    required ApiProvider provider,
    String? customBaseUrl,
    String? model,
  }) async {
    final baseUrl = provider == ApiProvider.custom
        ? (customBaseUrl ?? '').replaceAll(RegExp(r'/*$'), '')
        : provider.baseUrl;
    final modelName = provider == ApiProvider.custom
        ? (model ?? 'gpt-3.5-turbo')
        : (model ?? ApiProvider.defaultModels[provider.name] ?? '');

    if (baseUrl.isEmpty) {
      return {'success': false, 'message': 'Base URL 不能为空'};
    }
    if (modelName.isEmpty) {
      return {'success': false, 'message': '模型名称不能为空'};
    }

    final url = '$baseUrl/chat/completions';

    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $apiKey',
    };

    try {
      final response = await _dio.post(
        url,
        data: {
          'model': modelName,
          'messages': [
            {'role': 'user', 'content': 'Hi, reply with "OK" only.'}
          ],
          'max_tokens': 5,
        },
        options: Options(headers: headers, validateStatus: (s) => s != null && s < 500),
      );

      if (response.statusCode == 200) {
        final data = response.data as Map<String, dynamic>;
        final reply = data['choices']?[0]?['message']?['content']?.toString() ?? '(empty)';
        return {
          'success': true,
          'message': '连接成功',
          'reply': reply,
          'model': data['model'] ?? modelName,
        };
      } else {
        final err = response.data?.toString() ?? 'HTTP ${response.statusCode}';
        return {'success': false, 'message': 'HTTP ${response.statusCode}: $err\n请求: $url'};
      }
    } on DioException catch (e) {
      String friendlyMsg;
      if (e.type == DioExceptionType.connectionTimeout || e.type == DioExceptionType.sendTimeout || e.type == DioExceptionType.receiveTimeout) {
        friendlyMsg = '连接超时，请检查网络或 Base URL 是否正确';
      } else if (e.type == DioExceptionType.connectionError) {
        friendlyMsg = '网络连接失败：无法连接到服务器，请检查网络、Base URL 是否正确，或是否存在代理/VPN';
      } else if (e.response != null) {
        final err = e.response!.data?.toString() ?? e.message;
        return {'success': false, 'message': 'HTTP ${e.response!.statusCode}: $err'};
      } else {
        friendlyMsg = '网络请求失败: ${e.message}';
      }
      return {'success': false, 'message': friendlyMsg};
    } catch (e) {
      return {'success': false, 'message': '未知错误: $e'};
    }
  }
}
