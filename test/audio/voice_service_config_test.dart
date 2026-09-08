import 'package:chat_group/core/audio/voice_service_config.dart';
import 'package:chat_group/core/audio/voice_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('VoiceServiceConfig', () {
    test('默认值：标准火山资源、无默认音色、未绑定 Key', () {
      const c = VoiceServiceConfig.empty;
      expect(c.ttsResourceId, volcTtsDefaultResourceId);
      expect(c.asrResourceId, volcAsrDefaultResourceId);
      expect(c.defaultVoiceId, isNull);
      expect(c.apiKeyBound, isFalse);
      expect(c.isConfigured, isFalse);
    });

    test('toMap/fromMap 往返保留全部字段', () {
      const c = VoiceServiceConfig(
        ttsResourceId: 'seed-tts-2.0',
        asrResourceId: 'volc.bigasr.free',
        defaultVoiceId: 'zh_male_guozhoudege_moon_bigtts',
        apiKeyBound: true,
      );
      final restored = VoiceServiceConfig.fromMap(c.toMap());
      expect(restored.ttsResourceId, 'seed-tts-2.0');
      expect(restored.asrResourceId, 'volc.bigasr.free');
      expect(restored.defaultVoiceId, 'zh_male_guozhoudege_moon_bigtts');
      expect(restored.apiKeyBound, isTrue);
      expect(restored.isConfigured, isTrue);
    });

    test('fromMap 处理空值/缺失与仅留一个 Key 字段的旧数据', () {
      final empty = VoiceServiceConfig.fromMap(null);
      expect(empty.ttsResourceId, volcTtsDefaultResourceId);
      expect(empty.apiKeyBound, isFalse);

      final partial =
          VoiceServiceConfig.fromMap(const {'apiKeyBound': true});
      expect(partial.ttsResourceId, volcTtsDefaultResourceId);
      expect(partial.apiKeyBound, isTrue);

      final blankVoice = VoiceServiceConfig.fromMap(
          const {'defaultVoiceId': ''});
      expect(blankVoice.defaultVoiceId, isNull);
    });

    test('copyWith 可清空 defaultVoiceId 与切换绑定状态', () {
      const base = VoiceServiceConfig(defaultVoiceId: 'x');
      final cleared = base.copyWith(defaultVoiceId: () => null);
      expect(cleared.defaultVoiceId, isNull);
      final bound = base.copyWith(apiKeyBound: true);
      expect(bound.apiKeyBound, isTrue);
      expect(base.apiKeyBound, isFalse, reason: 'copyWith 不修改原对象');
    });
  });

  group('VoiceServiceConfig.resolveVoiceId', () {
    const config = VoiceServiceConfig(
      defaultVoiceId: 'zh_male_guozhoudege_moon_bigtts',
      apiKeyBound: true,
    );

    test('优先角色音色，其次全局默认音色', () {
      expect(
        VoiceServiceConfig.resolveVoiceId(
            'zh_female_meilinvyou_moon_bigtts', config),
        'zh_female_meilinvyou_moon_bigtts',
      );
      expect(
        VoiceServiceConfig.resolveVoiceId(null, config),
        'zh_male_guozhoudege_moon_bigtts',
      );
      expect(
        VoiceServiceConfig.resolveVoiceId('', config),
        'zh_male_guozhoudege_moon_bigtts',
      );
    });

    test('目录外的非法 id 不通过（返回 null，避免把脏值发给接口）', () {
      expect(VoiceServiceConfig.resolveVoiceId('not-a-voice', config), isNull);
      expect(
        VoiceServiceConfig.resolveVoiceId(
            null, const VoiceServiceConfig(defaultVoiceId: 'ghost')),
        isNull,
      );
    });

    test('目录自身能反查每个条目', () {
      for (final preset in voicePresets) {
        expect(voicePresetById(preset.id), isNotNull);
      }
    });
  });
}
