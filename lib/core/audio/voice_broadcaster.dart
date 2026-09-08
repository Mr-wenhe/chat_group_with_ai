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

/// 一句文本的准备结果：要么带可播音频，要么带失败原因，要么已被作废。
class _PreparedSpeech {
  const _PreparedSpeech.audio(this.pcm)
      : error = null,
        aborted = false;

  /// 合成返回空/空字节：成功但无可朗读内容，静默跳过。
  const _PreparedSpeech.empty()
      : pcm = null,
        error = null,
        aborted = false;

  const _PreparedSpeech.failed(this.error)
      : pcm = null,
        aborted = false;

  /// 合成期间被 [SpeechBroadcaster.stop]/[dispose] 作废。
  const _PreparedSpeech.aborted()
      : pcm = null,
        error = null,
        aborted = true;

  final Uint8List? pcm;
  final Object? error;
  final bool aborted;
}

/// 逐句语音播报队列：保证文本出现顺序与朗读顺序一致，同时用**流水线预取**
/// 消除句间停顿。
///
/// 流式回复按句切好后通过 [speak] 入队。若逐句“先合成完再播、播完再合成下一
/// 句”，句与句之间会插入下一句整段 TTS 合成延迟（几百 ms～1s 网络往返），听感
/// 上是明显的断句卡顿。这里改为：**播放当前句期间，后台预合成队首的下一句**
/// （单句前瞻槽位），当前句一结束，下一句音频已就绪、立即播放。仅第一句必须
/// 先合成（此时还没有可重叠的播放）。
///
/// 单句合成/播放失败只跳过该句（错误按批节流上报），不阻塞后续句子。
class SpeechBroadcaster {
  SpeechBroadcaster({
    required VoiceSynthesizer synthesize,
    required VoicePlaybackSink sink,
    this.onError,
  })  : _synthesize = synthesize,
        _sink = sink;

  final VoiceSynthesizer _synthesize;
  final VoicePlaybackSink _sink;

  /// 单批内的首个失败以该回调上报（见 [_reportFailure] 的节流逻辑）。
  final void Function(String message)? onError;

  final List<_VoiceSpeechItem> _queue = [];

  /// 前瞻槽位：预取结果与它对应的句子。只有队首（当前或紧邻下一句）会占槽，
  /// 保证同一句至多合成一次、且预取永远对应当前要播的下一句。
  _VoiceSpeechItem? _slotItem;
  Future<_PreparedSpeech>? _slotFuture;

  Future<void>? _drain;
  bool _disposed = false;

  /// 代际号：每次 [stop]/[dispose] 递增，让在途的预取合成作废。
  int _epoch = 0;

  /// 当前这一批是否已经上报过失败（成功后复位，避免一次回复里刷屏）。
  bool _errorReportedInBatch = false;

  /// 排队一句话。按调用顺序串行播放；播放间隙由预取隐藏。
  void speak({required String text, required String speaker}) {
    if (_disposed) return;
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    _queue.add(_VoiceSpeechItem(text: trimmed, speaker: speaker));
    _drain ??= _drainLoop();
    _prefetchHeadIfFree(); // 若正在播上句，让这句的合成与播放重叠。
  }

  /// 清空尚未开始/尚未播放的队列，作废在途预取并停止当前播放。
  /// 常用于关闭播报 / 页面失活。已预合成但未轮到播放的音频一并丢弃。
  Future<void> stop() async {
    _epoch++;
    _queue.clear();
    _slotItem = null;
    _slotFuture = null;
    await _sink.stop();
  }

  /// 释放底层资源并让进行中的队列尽快结束。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _epoch++;
    _queue.clear();
    _slotItem = null;
    _slotFuture = null;
    await _sink.dispose();
  }

  /// 当前队列是否已经播完（测试辅助）。
  Future<void> get idle => _drain ?? Future<void>.value();

  Future<void> _drainLoop() async {
    try {
      while (_queue.isNotEmpty) {
        final head = _queue.first;
        final prepared = await _preparedFor(head);
        if (identical(_slotItem, head)) {
          _slotItem = null;
          _slotFuture = null;
        }
        _queue.removeAt(0);
        if (prepared.aborted) continue; // stop/dispose：本句作废。
        _prefetchHeadIfFree(); // 为新的队首预取，与下方播放重叠。
        if (prepared.pcm != null) {
          await _playPcm(prepared.pcm!);
          _errorReportedInBatch = false;
        } else {
          final error = prepared.error;
          if (error != null) _reportFailure(error);
        }
        // pcm == null 且无 error：空音频，静默跳过。
      }
    } finally {
      _drain = null;
    }
  }

  /// 取队首的准备结果：已预取则复用槽位，否则现合成（首句/错过预取时）。
  Future<_PreparedSpeech> _preparedFor(_VoiceSpeechItem head) {
    if (identical(_slotItem, head) && _slotFuture != null) {
      return _slotFuture!;
    }
    _slotItem = head;
    final future = _startPrepare(head);
    _slotFuture = future;
    return future;
  }

  /// 空闲槽位时，为当前队首启动预合成（播放重叠的关键入口）。
  void _prefetchHeadIfFree() {
    if (_disposed || _queue.isEmpty) return;
    if (_slotFuture != null) return; // 已有在途预取（队首或紧邻下一句）。
    final head = _queue.first;
    _slotItem = head;
    _slotFuture = _startPrepare(head);
  }

  Future<_PreparedSpeech> _startPrepare(_VoiceSpeechItem item) async {
    final epoch = _epoch;
    final Uint8List? pcm;
    try {
      pcm = await _synthesize(item.text, item.speaker);
    } catch (error) {
      if (epoch != _epoch) return const _PreparedSpeech.aborted();
      return _PreparedSpeech.failed(error);
    }
    if (epoch != _epoch) return const _PreparedSpeech.aborted();
    if (pcm == null || pcm.isEmpty) return const _PreparedSpeech.empty();
    return _PreparedSpeech.audio(pcm);
  }

  Future<void> _playPcm(Uint8List pcm) async {
    final wav = pcmToWav(pcm);
    await _sink.playWav(wav);
  }

  void _reportFailure(Object error) {
    if (_errorReportedInBatch) return;
    _errorReportedInBatch = true;
    final callback = onError;
    if (callback != null) callback('$error');
  }
}
