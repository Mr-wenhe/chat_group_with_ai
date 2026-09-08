import 'dart:typed_data';

import 'pcm_to_wav.dart';

/// 合成一句文本为音频的抽象。
///
/// 返回 16bit/单声道 PCM（通常 24000Hz）；返回 null 或空字节表示“本句
/// 无可合成音频”，播放器应跳过该句且不中断队列。
typedef VoiceSynthesizer = Future<Uint8List?> Function(
  String text,
  String speaker,
);

/// 播放一段完整 WAV 音频的抽象。实现侧保证 `playWav` 在整段播放结束后
/// 才 resolve，被 [stop] 打断时也应尽快返回，避免串行队列卡死。
abstract interface class VoicePlaybackSink {
  /// 播放 [wavBytes]（完整 WAV 容器），播放结束后 Future 完成。
  Future<void> playWav(Uint8List wavBytes);

  /// 停止当前播放。正在等待的 [playWav] 应尽快返回。
  Future<void> stop();

  /// 释放底层音频资源。
  Future<void> dispose();
}

/// 一个待播报条目。
class _VoiceSpeechItem {
  const _VoiceSpeechItem({required this.text, required this.speaker});
  final String text;
  final String speaker;
}

/// 逐句串行语音播报队列：保证文本出现顺序与朗读顺序一致。
///
/// 流式回复按句切好后通过 [speak] 入队，这里一次只做一件事——合成一句
/// → 转 WAV → 交给 [VoicePlaybackSink] 播放 → 再处理下一句。单句合成/
/// 播放失败只跳过该句（错误按批节流上报），不阻塞后续句子。
class SpeechBroadcaster {
  SpeechBroadcaster({
    required VoiceSynthesizer synthesize,
    required VoicePlaybackSink sink,
    this.onError,
  })  : _synthesize = synthesize,
        _sink = sink;

  final VoiceSynthesizer _synthesize;
  final VoicePlaybackSink _sink;

  /// 单批内的首个失败以该回调上报（见 [_VoiceSpeechItem] 处理后的节流逻辑）。
  final void Function(String message)? onError;

  final List<_VoiceSpeechItem> _queue = [];
  Future<void>? _drain;
  bool _disposed = false;

  /// 代际号：每次 [stop]/[dispose] 递增，让“正在合成的那一句”作废。
  int _epoch = 0;

  /// 当前这一批是否已经上报过失败（成功后复位，避免一次回复里刷屏）。
  bool _errorReportedInBatch = false;

  /// 排队一句话。按调用顺序串行合成并播放。
  void speak({required String text, required String speaker}) {
    if (_disposed) return;
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    _queue.add(_VoiceSpeechItem(text: trimmed, speaker: speaker));
    _drain ??= _drainLoop();
  }

  /// 清空尚未开始的队列、作废正在合成的一句并停止当前播放。
  /// 常用于关闭播报 / 页面失活。
  Future<void> stop() async {
    _epoch++;
    _queue.clear();
    await _sink.stop();
  }

  /// 释放底层资源并让进行中的队列尽快结束。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _epoch++;
    _queue.clear();
    await _sink.dispose();
  }

  /// 当前队列是否已经播完（测试辅助）。
  Future<void> get idle => _drain ?? Future<void>.value();

  Future<void> _drainLoop() async {
    try {
      while (_queue.isNotEmpty) {
        final item = _queue.removeAt(0);
        await _speakOne(item);
      }
    } finally {
      _drain = null;
    }
  }

  Future<void> _speakOne(_VoiceSpeechItem item) async {
    final epoch = _epoch;
    Uint8List? pcm;
    try {
      pcm = await _synthesize(item.text, item.speaker);
    } catch (error) {
      _reportFailure(error);
      return;
    }
    if (epoch != _epoch) return; // 合成期间被 stop/dispose，丢弃这句。
    if (pcm == null || pcm.isEmpty) {
      // 无音频：视为“成功跳过”，继续后续句子。
      return;
    }
    try {
      final wav = pcmToWav(pcm);
      await _sink.playWav(wav);
      _errorReportedInBatch = false;
    } catch (error) {
      _reportFailure(error);
    }
  }

  void _reportFailure(Object error) {
    if (_errorReportedInBatch) return;
    _errorReportedInBatch = true;
    final callback = onError;
    if (callback != null) callback('$error');
  }
}
