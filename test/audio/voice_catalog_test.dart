import 'dart:io';

import 'package:chat_group/core/audio/voice_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('VoiceCatalog（与 voice.md 一致性）', () {
    test('voice.md 每两行成对且与 voicePresets 完全一致', () {
      final source = File('voice.md').readAsStringSync();
      final lines = source
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();

      expect(lines.length, voicePresets.length * 2,
          reason: 'voice.md 行数应为音色数的两倍（id/中文名成对）');

      for (var i = 0; i < voicePresets.length; i++) {
        expect(lines[i * 2], voicePresets[i].id,
            reason: '第 ${i + 1} 个音色 id 与 voice.md 不一致');
        expect(lines[i * 2 + 1], voicePresets[i].name,
            reason: '第 ${i + 1} 个音色中文名与 voice.md 不一致');
      }
    });

    test('id 无重复', () {
      final ids = voicePresets.map((v) => v.id).toSet();
      expect(ids.length, voicePresets.length, reason: '音色 id 应唯一');
    });

    test('voicePresetById 能反查存在的音色并返回 null 于未知 id', () {
      expect(voicePresetById('zh_female_meilinvyou_moon_bigtts')?.name,
          '魅力女友');
      expect(voicePresetById('not-a-real-voice'), isNull);
    });
  });
}
