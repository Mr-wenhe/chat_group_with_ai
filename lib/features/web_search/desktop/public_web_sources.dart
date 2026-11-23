import '../security/search_endpoint_validator.dart';

/// Stable per-task source IDs shared by model prompts and network execution.
class PublicWebSources {
  static final _trailingUrlPunctuation =
      RegExp(r'[.,!?;:，。！？；：、\]\}）】》」』]+$');
  final _sources = <String, Uri>{};

  Map<String, String> toMap() => {
        for (final entry in _sources.entries) entry.key: entry.value.toString(),
      };

  void restore(Object? raw) {
    if (raw == null || _sources.isNotEmpty) return;
    if (raw is! Map || raw.length > 100) {
      throw StateError('任务来源记录损坏。');
    }
    final restored = <String, Uri>{};
    for (var index = 1; index <= raw.length; index++) {
      final id = 's$index';
      final value = raw[id];
      if (value is! String) throw StateError('任务来源记录损坏。');
      final uri = SearchEndpointValidator.requireValid(value, isRelease: true);
      if (uri.hasPort && uri.port != 443) throw StateError('任务来源端口无效。');
      restored[id] = uri;
    }
    _sources.addAll(restored);
  }

  String register(String value) {
    final uri = SearchEndpointValidator.requireValid(value, isRelease: true);
    if (uri.hasPort && uri.port != 443) throw StateError('来源端口不受支持。');
    for (final entry in _sources.entries) {
      if (entry.value == uri) return entry.key;
    }
    if (_sources.length >= 100) throw StateError('本轮来源数量已达上限。');
    final id = 's${_sources.length + 1}';
    _sources[id] = uri;
    return id;
  }

  void registerUserText(String text) {
    for (final match in RegExp(r'https://[^\s<>"\)]+').allMatches(text)) {
      try {
        final candidate =
            match.group(0)!.replaceFirst(_trailingUrlPunctuation, '');
        if (candidate.isNotEmpty) register(candidate);
      } on Object {
        continue;
      }
    }
  }

  Uri source(String id) => _sources[id] ?? (throw StateError('来源编号无效。'));

}
