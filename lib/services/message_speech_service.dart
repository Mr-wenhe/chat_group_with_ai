import 'package:flutter_tts/flutter_tts.dart';

abstract interface class SpeechEngine {
  Future<void> configureAwaitCompletion(bool enabled);
  Future<List<String>> availableLanguages();
  Future<dynamic> setLanguage(String value);
  Future<dynamic> setPitch(double value);
  Future<dynamic> setSpeechRate(double value);
  Future<dynamic> setVolume(double value);
  Future<dynamic> speak(String text);
  Future<dynamic> stop();
  void onStart(void Function() callback);
  void onComplete(void Function() callback);
  void onCancel(void Function() callback);
  void onError(void Function(String message) callback);
}

class FlutterTtsSpeechEngine implements SpeechEngine {
  FlutterTtsSpeechEngine([FlutterTts? tts]) : _tts = tts ?? FlutterTts();

  final FlutterTts _tts;

  @override
  Future<void> configureAwaitCompletion(bool enabled) async {
    await _tts.awaitSpeakCompletion(enabled);
  }

  @override
  Future<List<String>> availableLanguages() async {
    final raw = await _tts.getLanguages;
    if (raw is! Iterable) return const [];
    return raw
        .map((value) => value.toString().trim())
        .where((value) => value.isNotEmpty)
        .toList();
  }

  @override
  Future<dynamic> setLanguage(String value) => _tts.setLanguage(value);

  @override
  Future<dynamic> setPitch(double value) => _tts.setPitch(value);

  @override
  Future<dynamic> setSpeechRate(double value) => _tts.setSpeechRate(value);

  @override
  Future<dynamic> setVolume(double value) => _tts.setVolume(value);

  @override
  Future<dynamic> speak(String text) => _tts.speak(text);

  @override
  Future<dynamic> stop() => _tts.stop();

  @override
  void onStart(void Function() callback) => _tts.setStartHandler(callback);

  @override
  void onComplete(void Function() callback) =>
      _tts.setCompletionHandler(callback);

  @override
  void onCancel(void Function() callback) => _tts.setCancelHandler(callback);

  @override
  void onError(void Function(String message) callback) {
    _tts.setErrorHandler((message) => callback(message.toString()));
  }
}

class SpeechPlaybackState {
  const SpeechPlaybackState({
    this.isSpeaking = false,
    this.messageId,
    this.error,
  });

  final bool isSpeaking;
  final String? messageId;
  final String? error;
}

class MessageSpeechService {
  MessageSpeechService({
    required this.engine,
    this.onStateChanged,
  });

  final SpeechEngine engine;
  final void Function(SpeechPlaybackState state)? onStateChanged;

  SpeechPlaybackState state = const SpeechPlaybackState();
  bool _initialized = false;
  bool _disposed = false;

  Future<void> initialize() async {
    if (_initialized || _disposed) return;
    engine.onStart(() {
      if (_disposed) return;
      _emit(SpeechPlaybackState(
        isSpeaking: true,
        messageId: state.messageId,
      ));
    });
    engine.onComplete(_finish);
    engine.onCancel(_finish);
    engine.onError((message) {
      if (_disposed) return;
      _emit(SpeechPlaybackState(error: '语音朗读失败：$message'));
    });

    await engine.configureAwaitCompletion(true);
    await engine.setVolume(1.0);
    await engine.setPitch(1.0);
    await engine.setSpeechRate(0.5);

    final languages = await engine.availableLanguages();
    if (languages.isNotEmpty) {
      await engine.setLanguage(_preferredLanguage(languages));
    }
    _initialized = true;
  }

  Future<bool> speak({
    required String messageId,
    required String text,
  }) async {
    final content = text.trim();
    if (_disposed || content.isEmpty) return false;
    try {
      await initialize();
      _emit(SpeechPlaybackState(isSpeaking: true, messageId: messageId));
      final result = await engine.speak(content);
      if (result == 0 || result == false) {
        _emit(const SpeechPlaybackState(error: '语音朗读启动失败，请检查系统语音设置。'));
        return false;
      }
      return true;
    } catch (error) {
      _emit(SpeechPlaybackState(error: '语音朗读失败：$error'));
      return false;
    }
  }

  Future<void> stop() async {
    if (_disposed) return;
    try {
      await engine.stop();
    } finally {
      _finish();
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    try {
      await engine.stop();
    } finally {
      _disposed = true;
      state = const SpeechPlaybackState();
    }
  }

  void _finish() {
    if (_disposed) return;
    _emit(const SpeechPlaybackState());
  }

  void _emit(SpeechPlaybackState next) {
    state = next;
    onStateChanged?.call(next);
  }

  String _preferredLanguage(List<String> languages) {
    String normalized(String value) => value.replaceAll('_', '-').toLowerCase();

    for (final preferred in const ['zh-cn', 'zh-hans-cn', 'zh-tw', 'zh-hk']) {
      for (final language in languages) {
        if (normalized(language) == preferred) return language;
      }
    }
    for (final language in languages) {
      if (normalized(language).startsWith('zh-') ||
          normalized(language) == 'zh') {
        return language;
      }
    }
    return languages.first;
  }
}
