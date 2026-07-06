import 'package:dio/dio.dart';
import 'package:chat_group/core/models/api_provider.dart';

class ChatApiService {
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 30),
  ));

  Future<Map<String, dynamic>> sendChatMessage({
    required String apiKey,
    required ApiProvider provider,
    String? customBaseUrl,
    required String model,
    required List<Map<String, dynamic>> messages,
    double temperature = 0.85,
  }) async {
    final baseUrl = provider == ApiProvider.custom
        ? (customBaseUrl ?? '').replaceAll(RegExp(r'/*$'), '')
        : provider.baseUrl;
    final modelName = model.isEmpty
        ? (ApiProvider.defaultModels[provider.name] ?? '')
        : model;

    if (baseUrl.isEmpty) {
      return {'success': false, 'message': 'Base URL 不能为空'};
    }
    if (modelName.isEmpty) {
      return {'success': false, 'message': '模型名称不能为空'};
    }

    final url = '$baseUrl${provider.apiPath}';
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $apiKey',
    };

    try {
      final response = await _dio.post(
        url,
        data: {
          'model': modelName,
          'messages': messages,
          'temperature': temperature,
          'max_tokens': 500,
        },
        options: Options(headers: headers, validateStatus: (s) => s != null && s < 500),
      );

      if (response.statusCode == 200) {
        final data = response.data as Map<String, dynamic>;
        final reply = data['choices']?[0]?['message']?['content']?.toString() ?? '(empty)';
        return {
          'success': true,
          'message': reply,
          'model': data['model'] ?? modelName,
        };
      } else {
        final err = response.data?.toString() ?? 'HTTP ${response.statusCode}';
        return {'success': false, 'message': 'HTTP ${response.statusCode}: $err'};
      }
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionTimeout || e.type == DioExceptionType.sendTimeout || e.type == DioExceptionType.receiveTimeout) {
        return {'success': false, 'message': '连接超时'};
      } else if (e.type == DioExceptionType.connectionError) {
        return {'success': false, 'message': '网络连接失败：无法连接到服务器'};
      } else if (e.response != null) {
        final err = e.response!.data?.toString() ?? e.message;
        return {'success': false, 'message': 'HTTP ${e.response!.statusCode}: $err'};
      } else {
        return {'success': false, 'message': '请求失败: ${e.message}'};
      }
    } catch (e) {
      return {'success': false, 'message': '未知错误: $e'};
    }
  }
}
