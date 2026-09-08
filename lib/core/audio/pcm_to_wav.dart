/// 把裸 PCM 字节包上 44 字节 RIFF/WAVE 头，供播放器直接播放。
///
/// 火山引擎 TTS 返回 16bit / 单声道 / 24kHz 的裸 PCM（小端），ASR 麦克风
/// 采集的是 16bit / 单声道 / 16kHz。给头补齐即可喂给 audioplayers 等。
library;

import 'dart:typed_data';

/// 计算 WAV 文件总字节数（44 字节头 + PCM 数据），供文件长度上报使用。
int wavTotalBytes(int pcmByteLength) => 44 + pcmByteLength;

/// 将裸 PCM 字节包装为标准 WAV 文件字节。
///
/// [pcm] 为 16bit 小端单声道（或按 [numChannels]/[bitsPerSample] 交错）的
/// 采样序列；返回完整 RIFF 头 + 数据。
Uint8List pcmToWav(
  List<int> pcm, {
  int sampleRate = 24000,
  int numChannels = 1,
  int bitsPerSample = 16,
}) {
  final byteRate = sampleRate * numChannels * bitsPerSample ~/ 8;
  final blockAlign = numChannels * bitsPerSample ~/ 8;
  final dataLen = pcm.length;
  final out = BytesBuilder(copy: false);

  void writeAscii(String s) => out.add(s.codeUnits);
  void writeU32(int v) =>
      out.add(Uint8List.sublistView(ByteData(4)..setUint32(0, v, Endian.little)));
  void writeU16(int v) =>
      out.add(Uint8List.sublistView(ByteData(2)..setUint16(0, v, Endian.little)));

  writeAscii('RIFF');
  writeU32(36 + dataLen); // 文件长度 - 8。
  writeAscii('WAVE');
  writeAscii('fmt ');
  writeU32(16); // fmt 块长度。
  writeU16(1); // PCM 编码。
  writeU16(numChannels);
  writeU32(sampleRate);
  writeU32(byteRate);
  writeU16(blockAlign);
  writeU16(bitsPerSample);
  writeAscii('data');
  writeU32(dataLen);
  out.add(pcm);
  return out.toBytes();
}
