import 'dart:typed_data';

/// 麦克风 PCM 源抽象。
///
/// [startStream] 返回 16bit / 单声道 PCM 字节流——这正是火山流式 ASR
/// （[VolcengineAsrSession]）要求的输入格式。录制侧统一按 16kHz 采样。
///
/// 测试中用假实现注入受控的 PCM 流；真机实现见 [RecordVoiceMicSource]。
abstract interface class VoiceMicSource {
  /// 请求麦克风权限（首次会弹系统授权框）；已授权返回 `true`。
  Future<bool> hasPermission();

  /// 开始采集并返回 PCM 字节流；再次调用会先停止上一次采集。
  Future<Stream<Uint8List>> startStream({int sampleRate = 16000});

  /// 停止采集（不关闭底层资源，后续可再次 [startStream]）。
  Future<void> stop();

  /// 释放底层资源（页面销毁时调用）。
  Future<void> dispose();
}
