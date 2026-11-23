part of 'chat_api_sampling_compatibility_test.dart';

Dio _fixtureDio(
  List<RequestOptions> requests,
  List<Map<String, dynamic>> bodies, {
  ApiProtocol protocol = ApiProtocol.openAiChatCompletions,
  Map<String, dynamic> error = _fixedTemperatureError,
  int status = 400,
  bool alwaysReject = false,
  bool rejectWhenTemperaturePresent = false,
}) {
  return Dio()
    ..interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      requests.add(options);
      final body =
          jsonDecode(jsonEncode(options.data)) as Map<String, dynamic>;
      bodies.add(body);
      final rejected = alwaysReject ||
          (rejectWhenTemperaturePresent
              ? body.containsKey('temperature')
              : requests.length == 1);
      final streaming = protocol == ApiProtocol.geminiGenerateContent
          ? options.uri.path.endsWith(':streamGenerateContent')
          : (options.data as Map)['stream'] == true;
      final response = rejected ? error : _successBody(protocol);
      Object data = response;
      if (options.responseType == ResponseType.stream) {
        final text = rejected
            ? jsonEncode(error)
            : streaming
                ? _successStream(protocol)
                : jsonEncode(response);
        data = ResponseBody.fromString(text, rejected ? status : 200);
      }
      handler.resolve(Response(
          requestOptions: options,
          statusCode: rejected ? status : 200,
          data: data));
    }));
}

Map<String, dynamic> _successBody(ApiProtocol protocol) => switch (protocol) {
      ApiProtocol.openAiChatCompletions => {
          'choices': [
            {
              'message': {'content': 'OK'}
            }
          ],
          'usage': _usage
        },
      ApiProtocol.openAiResponses => {
          'output_text': 'OK',
          'usage': {'input_tokens': 12, 'output_tokens': 2}
        },
      ApiProtocol.anthropicMessages => {
          'content': [
            {'type': 'text', 'text': 'OK'}
          ],
          'usage': {'input_tokens': 12, 'output_tokens': 2}
        },
      ApiProtocol.geminiGenerateContent => {
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': 'OK'}
                ]
              },
              'finishReason': 'STOP'
            }
          ],
          'usageMetadata': {'promptTokenCount': 12, 'candidatesTokenCount': 2}
        },
    };

String _successStream(ApiProtocol protocol) => switch (protocol) {
      ApiProtocol.openAiChatCompletions =>
        'data: {"choices":[{"delta":{"content":"OK"},"finish_reason":"stop"}],"usage":{"prompt_tokens":12,"completion_tokens":2}}\n\ndata: [DONE]\n\n',
      ApiProtocol.openAiResponses =>
        'data: {"type":"response.completed","response":{"output_text":"OK","usage":{"input_tokens":12,"output_tokens":2}}}\n\n',
      ApiProtocol.anthropicMessages =>
        'data: {"type":"content_block_delta","delta":{"text":"OK"}}\n\ndata: {"type":"message_delta","usage":{"input_tokens":12,"output_tokens":2}}\n\ndata: {"type":"message_stop"}\n\n',
      ApiProtocol.geminiGenerateContent =>
        'data: ${jsonEncode(_successBody(protocol))}\n\n',
    };
