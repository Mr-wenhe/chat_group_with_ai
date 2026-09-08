import 'dart:async';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';

import 'voice_broadcaster.dart';

/// 基于 audioplayers 的 [VoicePlaybackSink]：逐句播放 WAV 字节。
///
/// 每一句使用独立的 [AudioPlayer]，句末/被打断时即销毁。这样完成事件天然
/// 只属于当前这一句，不会与上一句的“stopped”状态事件互相串扰；audioplayers
/// 6 会把 `BytesSource` 在各平台正确解码（Windows 走 Media Foundation 字节流、
/// iOS/macOS/Linux 先落临时文件、移动端/Web 直接解码），无需自行管理临时文件。
class AudioplayersVoiceSink implements VoicePlaybackSink {
  /// 正在播放的播放器与其完成信号（仅一句在播；供 [stop] 打断）。
  AudioPlayer? _activePlayer;
  Completer<void>? _activeCompleter;

  @override
  Future<void> playWav(Uint8List wavBytes) async {
    final player = AudioPlayer();
    final completer = Completer<void>();
    _activePlayer = player;
    _activeCompleter = completer;

    late final StreamSubscription<void> doneSub;
    late final StreamSubscription<PlayerState> stateSub;
    void complete() {
      if (!completer.isCompleted) completer.complete();
    }

    stateSub = player.onPlayerStateChanged.listen((state) {
      if (state == PlayerState.completed || state == PlayerState.disposed) {
        complete();
      }
    });
    doneSub = player.onPlayerComplete.listen((_) => complete());

    try {
      await player.play(BytesSource(wavBytes, mimeType: 'audio/wav'));
    } catch (_) {
      // 播放未能启动：按“完成”处理，不阻塞串行队列。
      complete();
    }
    await completer.future;

    await doneSub.cancel();
    await stateSub.cancel();
    if (identical(_activePlayer, player)) {
      _activePlayer = null;
      _activeCompleter = null;
    }
    try {
      await player.dispose();
    } catch (_) {
      // 忽略平台侧销毁异常。
    }
  }

  @override
  Future<void> stop() async {
    final player = _activePlayer;
    final completer = _activeCompleter;
    _activePlayer = null;
    _activeCompleter = null;
    if (player != null) {
      try {
        await player.stop();
      } catch (_) {
        // 忽略。
      }
    }
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  @override
  Future<void> dispose() => stop();
}
