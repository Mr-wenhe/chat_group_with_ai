import 'dart:async';
import 'dart:io';
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
    } catch (e) {
      final retried = await _retryAfterCreatingMissingDir(
        player: player,
        wavBytes: wavBytes,
        error: e,
      );
      // 播放未能启动且修复重试失败：按“完成”处理，不阻塞串行队列。
      if (!retried) complete();
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

  Future<bool> _retryAfterCreatingMissingDir({
    required AudioPlayer player,
    required Uint8List wavBytes,
    required Object error,
  }) async {
    if (!Platform.isMacOS || error is! PathNotFoundException) return false;
    final missingPath = error.path;
    if (missingPath == null || missingPath.isEmpty) return false;
    final slashIndex = missingPath.lastIndexOf('/');
    if (slashIndex <= 0) return false;
    final parentDirPath = missingPath.substring(0, slashIndex);
    try {
      final parentDir = Directory(parentDirPath);
      if (!await parentDir.exists()) {
        await parentDir.create(recursive: true);
      }
      await player.play(BytesSource(wavBytes, mimeType: 'audio/wav'));
      return true;
    } catch (_) {
      return false;
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
