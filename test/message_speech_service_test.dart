import 'package:chat_group/services/message_speech_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('initialization selects Chinese voice and configures audible playback',
      () async {
    final engine = _FakeSpeechEngine(languages: ['en-US', 'zh-CN']);
    final service = MessageSpeechService(engine: engine);

    await service.initialize();

    expect(engine.awaitCompletion, isTrue);
    expect(engine.language, 'zh-CN');
    expect(engine.volume, 1.0);
    expect(engine.pitch, 1.0);
    expect(engine.rate, 0.5);
  });

  test('speaking state remains active until completion callback', () async {
    final engine = _FakeSpeechEngine(languages: ['zh-CN']);
    final service = MessageSpeechService(engine: engine);

    final started = await service.speak(
      messageId: 'm1',
      text: '你好，这是朗读测试。',
    );

    expect(started, isTrue);
    expect(service.state.isSpeaking, isTrue);
    expect(service.state.messageId, 'm1');

    engine.complete();
    expect(service.state.isSpeaking, isFalse);
    expect(service.state.messageId, isNull);
  });

  test('engine error clears speaking state and exposes a user-facing error',
      () async {
    final engine = _FakeSpeechEngine(languages: ['zh-CN']);
    final service = MessageSpeechService(engine: engine);
    await service.speak(messageId: 'm1', text: '测试');

    engine.fail('voice unavailable');

    expect(service.state.isSpeaking, isFalse);
    expect(service.state.error, contains('voice unavailable'));
  });

  test('falls back to an installed language instead of silently failing',
      () async {
    final engine = _FakeSpeechEngine(languages: ['en-GB']);
    final service = MessageSpeechService(engine: engine);

    await service.initialize();

    expect(engine.language, 'en-GB');
  });

  test('dispose stops active playback', () async {
    final engine = _FakeSpeechEngine(languages: ['zh-CN']);
    final service = MessageSpeechService(engine: engine);
    await service.speak(messageId: 'm1', text: '测试');

    service.dispose();
    await Future<void>.delayed(Duration.zero);

    expect(engine.stopCalls, 1);
    expect(service.state.isSpeaking, isFalse);
  });
}

class _FakeSpeechEngine implements SpeechEngine {
  _FakeSpeechEngine({required this.languages});

  final List<String> languages;
  bool? awaitCompletion;
  String? language;
  double? volume;
  double? pitch;
  double? rate;
  int stopCalls = 0;
  void Function()? _start;
  void Function()? _completion;
  void Function()? _cancel;
  void Function(String message)? _error;

  @override
  Future<void> configureAwaitCompletion(bool enabled) async {
    awaitCompletion = enabled;
  }

  @override
  Future<List<String>> availableLanguages() async => languages;

  @override
  Future<dynamic> setLanguage(String value) async => language = value;

  @override
  Future<dynamic> setPitch(double value) async => pitch = value;

  @override
  Future<dynamic> setSpeechRate(double value) async => rate = value;

  @override
  Future<dynamic> setVolume(double value) async => volume = value;

  @override
  Future<dynamic> speak(String text) async {
    _start?.call();
    return 1;
  }

  @override
  Future<dynamic> stop() async {
    stopCalls++;
    _cancel?.call();
    return 1;
  }

  @override
  void onStart(void Function() callback) => _start = callback;

  @override
  void onComplete(void Function() callback) => _completion = callback;

  @override
  void onCancel(void Function() callback) => _cancel = callback;

  @override
  void onError(void Function(String message) callback) => _error = callback;

  void complete() => _completion?.call();

  void fail(String message) => _error?.call(message);
}
