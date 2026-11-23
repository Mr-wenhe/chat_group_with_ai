part of 'chat_api_service.dart';

final _samplingZoneKey = Object();

class _ChatSamplingState {
  bool useDefaultTemperature = false;
}

_ChatSamplingState? get _requestSamplingState =>
    Zone.current[_samplingZoneKey] as _ChatSamplingState?;

Future<T> _withRequestSampling<T>(Future<T> Function() operation) {
  if (_requestSamplingState != null) return operation();
  return runZoned(operation,
      zoneValues: {_samplingZoneKey: _ChatSamplingState()});
}

/// 已确认不接受 `temperature` 的模型身份（provider|protocol|baseUrl|model）。
///
/// 兼容重试原先只把「该模型不接受 temperature」记在**一次请求**里，于是每条回复
/// 都要先吃一次 400 再重发（现场：中转 14 秒失败 + 19 秒重试，用户看到的只是
/// 33 秒没有任何输出）。这条事实属于模型能力，进程内记住即可，重启后重新协商一次。
final Set<String> _temperatureIncompatibleModels = <String>{};

String _samplingIdentity({
  required ApiProvider provider,
  required ApiProtocol apiProtocol,
  String? customBaseUrl,
  required String model,
}) =>
    '${provider.name}|${apiProtocol.name}|${customBaseUrl ?? ''}|$model';

bool _isKnownTemperatureIncompatible({
  required ApiProvider provider,
  required ApiProtocol apiProtocol,
  String? customBaseUrl,
  required String model,
}) =>
    _temperatureIncompatibleModels.contains(_samplingIdentity(
      provider: provider,
      apiProtocol: apiProtocol,
      customBaseUrl: customBaseUrl,
      model: model,
    ));

void _rememberTemperatureIncompatible({
  required ApiProvider provider,
  required ApiProtocol apiProtocol,
  String? customBaseUrl,
  required String model,
}) {
  _temperatureIncompatibleModels.add(_samplingIdentity(
    provider: provider,
    apiProtocol: apiProtocol,
    customBaseUrl: customBaseUrl,
    model: model,
  ));
}

/// 仅测试使用：清掉进程内的模型能力记忆，避免用例之间互相影响。
@visibleForTesting
void forgetTemperatureCompatibility() => _temperatureIncompatibleModels.clear();

bool _isFixedTemperatureRejection(Object? data) {
  if (data is! Map || data['error'] is! Map) return false;
  final error = data['error'] as Map;
  final code = error['code'];
  if (code != 'unsupported_value' &&
      code != 'unsupported_parameter' &&
      error['type'] != 'invalid_request_error' &&
      !(code == 400 && error['status'] == 'INVALID_ARGUMENT')) {
    return false;
  }
  final message = error['message']?.toString().toLowerCase() ?? '';
  // 有的中转把「不适用」写成空串而不是省略 param（agentrouter 的
  // `Unsupported parameter: 'temperature' ...` 就是 `param: ""`）。把空串当
  // 未指定处理，否则这条兜底永远不会触发，用户只能看到一句 400。
  final rawParam = error['param']?.toString().trim() ?? '';
  final parameter = rawParam.isEmpty ? null : rawParam;
  if (parameter != null && parameter != 'temperature') return false;
  if (parameter == null && !RegExp(r'\btemperature\b').hasMatch(message)) {
    return false;
  }
  if (RegExp(r'only\s+(?:the\s+)?default\b.*\bsupported\b').hasMatch(message)) {
    return true;
  }
  // 这句话本身就是充分判据：`temperature` 不被该模型接受，去掉它重试是对的。
  // 不额外要求 `code` 与之配套——agentrouter 这类中转把 `code` 留成 null。
  return RegExp(r'''['"]?temperature['"]?\s+is not supported\b''').hasMatch(message);
}
