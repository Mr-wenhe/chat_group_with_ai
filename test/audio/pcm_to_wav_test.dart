import 'dart:convert';
import 'dart:typed_data';

import 'package:chat_group/core/audio/pcm_to_wav.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('pcmToWav', () {
    test('头 44 字节且 RIFF/WAVE/fmt/data 标记正确', () {
      final pcm = List<int>.filled(0, 0);
      final wav = pcmToWav(pcm, sampleRate: 24000);
      expect(wav, hasLength(44));
      expect(utf8.decode(wav.sublist(0, 4)), 'RIFF');
      expect(utf8.decode(wav.sublist(8, 12)), 'WAVE');
      expect(utf8.decode(wav.sublist(12, 16)), 'fmt ');
      expect(utf8.decode(wav.sublist(36, 40)), 'data');
    });

    test('PCM 数据原样拼接并携带数据长度', () {
      final pcm = Uint8List.fromList([1, 2, 3, 4]);
      final wav = pcmToWav(pcm, sampleRate: 16000, numChannels: 1);
      expect(wav, hasLength(44 + 4));
      final bd = ByteData.sublistView(wav);
      // RIFF 长度字段 = 36 + dataLen。
      expect(bd.getUint32(4, Endian.little), 40);
      expect(bd.getUint32(40, Endian.little), 4);
      // 音频格式字段（offset 20）为 1（PCM）。
      expect(bd.getUint16(20, Endian.little), 1);
      expect(wav.sublist(44), orderedEquals(pcm));
    });

    test('采样率/声道/位深写入字节率与块对齐', () {
      final wav = pcmToWav(
        Uint8List(0),
        sampleRate: 24000,
        numChannels: 2,
        bitsPerSample: 16,
      );
      final bd = ByteData.sublistView(wav);
      expect(bd.getUint32(24, Endian.little), 24000); // sampleRate。
      expect(bd.getUint32(28, Endian.little), 24000 * 4); // byteRate。
      expect(bd.getUint16(32, Endian.little), 4); // blockAlign。
      expect(bd.getUint16(34, Endian.little), 16); // bitsPerSample。
      expect(wavTotalBytes(100), 144);
    });
  });
}
