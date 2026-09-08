/// [record] 插件实现的麦克风 PCM 源。
///
/// 用 `pcm16bits` 流式编码，16kHz / 单声道，与火山流式 ASR 的输入格式一致。
/// `record` 在各平台（Android / iOS / macOS / Windows / Linux / web）都以
/// 配置的采样率输出裸 PCM，无需额外转码。
library;

import 'dart:typed_data';

import 'package:record/record.dart';

import 'voice_mic_source.dart';

class RecordVoiceMicSource implements VoiceMicSource {
  final AudioRecorder _recorder = AudioRecorder();
  Stream<Uint8List>? _stream;
  bool _recording = false;

  @override
  Future<bool> hasPermission() => _recorder.hasPermission();

  @override
  Future<Stream<Uint8List>> startStream({int sampleRate = 16000}) async {
    await stop();
    _stream = await _recorder.startStream(
      RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: 1,
      ),
    );
    _recording = true;
    return _stream!;
  }

  @override
  Future<void> stop() async {
    if (!_recording) return;
    _recording = false;
    try {
      await _recorder.stop();
    } catch (_) {
      // 停止采集失败（例如权限中途被收回）不需要向上抛——调用方要的是“已停止”。
    }
  }

  @override
  Future<void> dispose() => _recorder.dispose();
}
