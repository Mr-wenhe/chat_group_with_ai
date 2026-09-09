import 'dart:async';
import 'dart:typed_data';

import 'package:chat_group/core/audio/voice_broadcaster.dart';
import 'package:flutter_test/flutter_test.dart';

/// 可控放行的伪播放器：
/// - [holdPlayback]=true 时 playWav 挂起等待手动 [releaseAll]；
/// - [autoReleaseAfterManual]=true 时首次 [releaseAll] 之后的播放自动放行，
///   便于验证“播放中入队保序”而不必逐句手动放行。
class _FakeSink implements VoicePlaybackSink {
  _FakeSink({this.holdPlayback = false, this.autoReleaseAfterManual = false});

  final bool holdPlayback;
  final bool autoReleaseAfterManual;
  final List<Uint8List> played = [];
  final List<Completer<void>> _gates = [];
  bool _manualReleased = false;
  bool _disposed = false;

  bool get isDisposed => _disposed;

  @override
  Future<void> playWav(Uint8List wavBytes) async {
    played.add(wavBytes);
    if (!holdPlayback || (autoReleaseAfterManual && _manualReleased)) return;
    final gate = Completer<void>();
    _gates.add(gate);
    await gate.future;
  }

  void releaseAll() {
    _manualReleased = true;
    for (final gate in _gates) {
      if (!gate.isCompleted) gate.complete();
    }
    _gates.clear();
  }

  @override
  Future<void> stop() async => releaseAll();

  @override
  Future<void> dispose() async {
    _disposed = true;
    releaseAll();
  }
}

class _FakeSynth {
  final List<(String text, String speaker)> calls = [];

  /// 每次合成返回的 PCM；为空时使用 [defaultResult]。
  Uint8List? defaultResult = Uint8List.fromList([0x01, 0x02]);

  /// 按调用序号返回的结果（越界用 defaultResult）。
  final List<Uint8List?> overrideResults = [];
  Object? error;

  Future<Uint8List?> call(String text, String speaker) async {
    calls.add((text, speaker));
    final thrown = error;
    if (thrown != null) throw thrown;
    final index = calls.length - 1;
    if (index < overrideResults.length) return overrideResults[index];
    return defaultResult;
  }
}

Uint8List _pcm(int byteLength) => Uint8List(byteLength);

void main() {
  const riifMagic = 'RIFF';

  Future<void> settle(SpeechBroadcaster broadcaster) =>
      broadcaster.idle.timeout(const Duration(seconds: 5));

  test('按入队顺序逐句合成并播放为合法 WAV', () async {
    final sink = _FakeSink();
    final synth = _FakeSynth();
    synth.defaultResult = _pcm(100);
    final broadcaster = SpeechBroadcaster(
      synthesize: synth.call,
      sink: sink,
    );

    broadcaster.speak(text: '第一句。', speaker: 'v1');
    broadcaster.speak(text: '第二句！', speaker: 'v1');
    await settle(broadcaster);

    expect(synth.calls, hasLength(2));
    expect(synth.calls[0].$1, '第一句。');
    expect(synth.calls[0].$2, 'v1');
    expect(synth.calls[1].$1, '第二句！');
    expect(sink.played, hasLength(2));
    // 每段都是“44 字节 RIFF 头 + PCM 长度”。
    for (final wav in sink.played) {
      expect(String.fromCharCodes(wav.sublist(0, 4)), riifMagic);
      expect(wav.length, 44 + 100);
    }
  });

  test('空文本不进入队列（无合成、无播放）', () async {
    final sink = _FakeSink();
    final synth = _FakeSynth();
    final broadcaster = SpeechBroadcaster(
      synthesize: synth.call,
      sink: sink,
    );

    broadcaster.speak(text: '   ', speaker: 'v1');
    broadcaster.speak(text: '', speaker: 'v1');
    await settle(broadcaster);

    expect(synth.calls, isEmpty);
    expect(sink.played, isEmpty);
  });

  test('合成返回空字节时跳过该句但仍继续后续', () async {
    final sink = _FakeSink();
    final synth = _FakeSynth();
    synth.overrideResults.addAll([Uint8List(0), _pcm(8)]);
    final broadcaster = SpeechBroadcaster(
      synthesize: synth.call,
      sink: sink,
    );

    broadcaster.speak(text: '无可合成。', speaker: 'v1');
    broadcaster.speak(text: '能合成。', speaker: 'v1');
    await settle(broadcaster);

    expect(synth.calls, hasLength(2));
    expect(sink.played, hasLength(1));
  });

  test('合成失败上报一次（节流）且不中断后续句子', () async {
    final sink = _FakeSink();
    final synth = _FakeSynth();
    synth.defaultResult = _pcm(4);
    final errors = <String>[];
    final broadcaster = SpeechBroadcaster(
      synthesize: synth.call,
      sink: sink,
      onError: errors.add,
    );

    synth.error = Exception('网络抖动');
    broadcaster.speak(text: '第一句（失败）。', speaker: 'v1');
    broadcaster.speak(text: '第二句（失败）。', speaker: 'v1');
    await settle(broadcaster);

    // 同一批内两个失败只上报一次。
    expect(errors, hasLength(1));
    expect(errors.single, contains('网络抖动'));
    expect(sink.played, isEmpty);

    // 成功后下一批失败可再次上报（节流复位）。
    synth.error = null;
    broadcaster.speak(text: '成功句。', speaker: 'v1');
    await settle(broadcaster);
    expect(sink.played, hasLength(1));

    synth.error = Exception('再次失败');
    broadcaster.speak(text: '又失败。', speaker: 'v1');
    await settle(broadcaster);
    expect(errors, hasLength(2));
  });

  test('相邻两句：前一句播放期间后一句已预合成（消除句间串行延迟）', () async {
    final sink = _FakeSink(holdPlayback: true, autoReleaseAfterManual: true);
    final synth = _FakeSynth();
    synth.defaultResult = _pcm(8);
    final broadcaster = SpeechBroadcaster(
      synthesize: synth.call,
      sink: sink,
    );

    broadcaster.speak(text: '第一句。', speaker: 'v1');
    broadcaster.speak(text: '第二句。', speaker: 'v1');
    // 首句仍被播放器 gate 挡住，但第二句已在第一句播放期间完成合成——
    // 这样第一句结束即可立即开播第二句，无需再等一段网络合成往返。
    await _waitFor(
      () => sink.played.length == 1 && synth.calls.length == 2,
      reason: '播放第一句期间应已开始合成第二句',
    );
    expect(sink.played, hasLength(1));
    expect(synth.calls, hasLength(2), reason: '播放第一句期间应已开始合成第二句');
    expect(synth.calls.map((c) => c.$1), ['第一句。', '第二句。']);

    sink.releaseAll();
    await settle(broadcaster);

    expect(sink.played, hasLength(2));
    expect(synth.calls.map((c) => c.$1), ['第一句。', '第二句。']);
  });

  test('播放中继续入队仍按原顺序串行（新句立即进入预取，不重排）', () async {
    // 仅首句手动放行；首次放行后其余自动放行，避免逐个 gate。
    final sink = _FakeSink(holdPlayback: true, autoReleaseAfterManual: true);
    final synth = _FakeSynth();
    synth.defaultResult = _pcm(8);
    final broadcaster = SpeechBroadcaster(
      synthesize: synth.call,
      sink: sink,
    );

    broadcaster.speak(text: '甲。', speaker: 'v1');
    await _waitFor(
      () => sink.played.length == 1,
      reason: '甲应已进入播放状态',
    );
    // 甲 正在播放（gate 未放行），此刻入队乙：乙立即开始预合成，但不抢先播放。
    broadcaster.speak(text: '乙。', speaker: 'v1');
    await _waitFor(
      () => sink.played.length == 1 && synth.calls.length == 2,
      reason: '甲播放期间乙应已被预合成',
    );
    expect(synth.calls, hasLength(2), reason: '甲播放期间乙已被预合成');
    expect(sink.played, hasLength(1), reason: '乙只合成、未播放，保持顺序');

    sink.releaseAll(); // 放行甲的播放
    await settle(broadcaster);

    expect(synth.calls.map((c) => c.$1), ['甲。', '乙。']);
    expect(sink.played, hasLength(2));
  });

  test('stop 清空未开始队列并中断当前播放', () async {
    final sink = _FakeSink(holdPlayback: true);
    final synth = _FakeSynth();
    synth.defaultResult = _pcm(8);
    final broadcaster = SpeechBroadcaster(
      synthesize: synth.call,
      sink: sink,
    );

    broadcaster.speak(text: '甲。', speaker: 'v1');
    broadcaster.speak(text: '乙。', speaker: 'v1');
    // 乙虽已被预合成（在途合成与甲的播放重叠），但还未轮到播放。
    await _waitFor(
      () => sink.played.length == 1 && synth.calls.length == 2,
      reason: '乙在甲播放期间应已被预合成',
    );
    expect(synth.calls, hasLength(2), reason: '乙在甲播放期间已被预合成');

    await broadcaster.stop(); // 丢弃乙、打断甲

    expect(synth.calls, hasLength(2), reason: '乙确实被预合成了');
    expect(sink.played, hasLength(1), reason: '乙仅被合成、未播放，stop 丢弃了未轮到播放的音频');
    // 被打断后队列已空，idle 可正常完成。
    await settle(broadcaster);
  });

  test('dispose 后新入队被忽略', () async {
    final sink = _FakeSink();
    final synth = _FakeSynth();
    final broadcaster = SpeechBroadcaster(
      synthesize: synth.call,
      sink: sink,
    );

    await broadcaster.dispose();
    broadcaster.speak(text: '不应播放。', speaker: 'v1');
    await _flushMicrotasks();

    expect(sink.isDisposed, isTrue);
    expect(synth.calls, isEmpty);
    expect(sink.played, isEmpty);
  });
}

Future<void> _flushMicrotasks() => Future<void>.delayed(Duration.zero);

Future<void> _waitFor(
  bool Function() condition, {
  required String reason,
  Duration timeout = const Duration(seconds: 5),
}) async {
  final stopwatch = Stopwatch()..start();
  while (stopwatch.elapsed < timeout) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Timed out waiting for $reason');
}
