import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/streaming/chat_stream_event.dart';
import 'package:chat_group/services/chat_api_service.dart';
import 'package:dio/dio.dart';

/// Captures the immutable request payload that reaches the real API client boundary.
class CapturingChatApiService extends ChatApiService {
  CapturingChatApiService({this.responseText = '测试回复'});

  final String responseText;
  int sendCount = 0;
  int streamCount = 0;
  final List<List<Map<String, dynamic>>> messageCalls = [];

  @override
  Future<Map<String, dynamic>> sendChatMessage({
    required String apiKey,
    required ApiProvider provider,
    String? customBaseUrl,
    required String model,
    required List<Map<String, dynamic>> messages,
    double? temperature,
    int? maxTokens,
    Duration? receiveTimeout,
    int? maxRetries,
    CancelToken? cancelToken,
  }) async {
    sendCount++;
    _capture(messages);
    return {'success': true, 'message': responseText};
  }

  @override
  Stream<ChatStreamEvent> streamChatMessage({
    required String apiKey,
    required ApiProvider provider,
    String? customBaseUrl,
    required String model,
    required List<Map<String, dynamic>> messages,
    double temperature = 0.85,
    int maxTokens = 1024,
    Duration receiveTimeout = const Duration(seconds: 120),
    CancelToken? cancelToken,
  }) async* {
    streamCount++;
    _capture(messages);
    yield ChatStreamEvent.done(responseText);
  }

  void _capture(List<Map<String, dynamic>> messages) {
    messageCalls.add(
      messages
          .map((message) => Map<String, dynamic>.from(_copy(message) as Map))
          .toList(growable: false),
    );
  }

  dynamic _copy(dynamic value) {
    if (value is Map) {
      return {
        for (final entry in value.entries) entry.key: _copy(entry.value),
      };
    }
    if (value is List) return value.map(_copy).toList(growable: false);
    return value;
  }
}
