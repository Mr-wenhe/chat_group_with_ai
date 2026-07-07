import 'dart:async';
import 'dart:convert';

import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/streaming/chat_stream_event.dart';
import 'package:chat_group/core/streaming/sse_parser.dart';
import 'package:dio/dio.dart';

class ChatApiService {
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 30),
  ));

  /// 非流式请求：整段等待后返回结果，供「记忆摘要」等一次性调用复用。
  ///
  /// 注意：本方法保持原有行为不被破坏（架构要求），新增的流式能力见 [streamChatMessage]。
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
          'max_tokens': 1024,
        },
        options: Options(
            headers: headers, validateStatus: (s) => s != null && s < 500),
      );

      if (response.statusCode == 200) {
        final data = response.data as Map<String, dynamic>;
        final reply = data['choices']?[0]?['message']?['content']?.toString() ??
            '(empty)';
        return {
          'success': true,
          'message': reply,
          'model': data['model'] ?? modelName,
        };
      } else {
        final err = response.data?.toString() ?? 'HTTP ${response.statusCode}';
        return {
          'success': false,
          'message': 'HTTP ${response.statusCode}: $err'
        };
      }
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.sendTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        return {'success': false, 'message': '连接超时'};
      } else if (e.type == DioExceptionType.connectionError) {
        return {'success': false, 'message': '网络连接失败：无法连接到服务器'};
      } else if (e.response != null) {
        final err = e.response!.data?.toString() ?? e.message;
        return {
          'success': false,
          'message': 'HTTP ${e.response!.statusCode}: $err'
        };
      } else {
        return {'success': false, 'message': '请求失败: ${e.message}'};
      }
    } catch (e) {
      return {'success': false, 'message': '未知错误: $e'};
    }
  }

  /// 流式请求：以 `Stream<ChatStreamEvent>` 逐 token 产出回复（打字机效果）。
  ///
  /// 与 [sendChatMessage] 共用 URL / 模型解析逻辑；请求级使用
  /// `responseType: ResponseType.stream` 拿到 `ResponseBody.stream`，按行解析 SSE。
  /// 解析细节全部封装在 [SseParser] 中，本方法只负责网络与事件转发。
  ///
  /// 错误处理：非 200（4xx）或任何 DioException 都会 yield 一个 [ChatStreamEvent.error]
  /// 后结束，绝不抛出（保证 `await for` / `listen` 的调用方安全）。
  Stream<ChatStreamEvent> streamChatMessage({
    required String apiKey,
    required ApiProvider provider,
    String? customBaseUrl,
    required String model,
    required List<Map<String, dynamic>> messages,
    double temperature = 0.85,
  }) async* {
    // 与 sendChatMessage 保持一致的 URL / 模型解析
    final baseUrl = provider == ApiProvider.custom
        ? (customBaseUrl ?? '').replaceAll(RegExp(r'/*$'), '')
        : provider.baseUrl;
    final modelName = model.isEmpty
        ? (ApiProvider.defaultModels[provider.name] ?? '')
        : model;

    if (baseUrl.isEmpty) {
      yield ChatStreamEvent.error('Base URL 不能为空');
      return;
    }
    if (modelName.isEmpty) {
      yield ChatStreamEvent.error('模型名称不能为空');
      return;
    }

    final url = '$baseUrl${provider.apiPath}';
    final headers = <String, String>{
      'Content-Type': 'application/json; charset=utf-8',
      'Authorization': 'Bearer $apiKey',
      'Accept': 'text/event-stream',
    };
    final data = {
      'model': modelName,
      'messages': messages,
      'temperature': temperature,
      'max_tokens': 1024,
      'stream': true, // 开启 SSE 流式返回
    };

    final parser = SseParser();
    try {
      final response = await _dio.post<ResponseBody>(
        url,
        data: data,
        options: Options(
          headers: headers,
          // 流式模式下以字节流返回
          responseType: ResponseType.stream,
          // 4xx 不抛异常，交由我们产出 error 事件；>=500 仍抛 DioException。
          validateStatus: (s) => s != null && s < 500,
          receiveTimeout: const Duration(seconds: 120),
        ),
      );

      if (response.statusCode != 200) {
        yield ChatStreamEvent.error(
            'HTTP ${response.statusCode}: ${_extractErrorText(response.data)}');
        return;
      }

      // stream 模式下 response.data 为 ResponseBody，其 .stream 为 Stream<Uint8List>。
      // Uint8List 是 List<int> 的子类型，但 StreamTransformer 输入类型不协变，
      // 故先 cast 成 Stream<List<int>> 再交给 utf8.decoder。
      final stream = (response.data as ResponseBody)
          .stream
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter());

      // 逐行交给 SseParser，把产出的事件透传给调用方。
      await for (final line in stream) {
        for (final event in parser.ingest(line)) {
          yield event;
        }
      }
      // 流正常结束，返回累计的完整内容。
      yield parser.doneEvent();
    } on DioException catch (e) {
      yield ChatStreamEvent.error(_dioErrorMessage(e));
    } catch (e) {
      yield ChatStreamEvent.error('未知错误: $e');
    }
  }

  /// 从流式响应体（可能尚未读取）中取出可读的错误摘要。
  String _extractErrorText(dynamic data) {
    if (data is ResponseBody) {
      // 流式错误体的内容不易同步读取，返回通用提示即可。
      return '请求失败';
    }
    return data?.toString() ?? '请求失败';
  }

  /// 把 DioException 转换为统一的人类可读错误信息。
  String _dioErrorMessage(DioException e) {
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.sendTimeout ||
        e.type == DioExceptionType.receiveTimeout) {
      return '连接超时';
    } else if (e.type == DioExceptionType.connectionError) {
      return '网络连接失败：无法连接到服务器';
    } else if (e.response != null) {
      final err = e.response!.data?.toString() ?? e.message;
      return 'HTTP ${e.response!.statusCode}: $err';
    } else {
      return '请求失败: ${e.message}';
    }
  }
}
