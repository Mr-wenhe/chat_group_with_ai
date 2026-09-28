import 'package:chat_group/core/images/image_provider_presets.dart';
import 'package:chat_group/core/images/image_service_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('服务商预设表', () {
    test('每家 apiPrefix 都是含版本段的完整前缀且不带尾段', () {
      for (final preset in kImageProviderPresets) {
        expect(preset.id, isNotEmpty, reason: '预设必须有 id');
        expect(preset.label, isNotEmpty, reason: '预设必须有显示名');
        expect(
          preset.apiPrefix.startsWith('https://'),
          isTrue,
          reason: '${preset.label} 的前缀必须是 https',
        );
        expect(
          preset.apiPrefix.endsWith('/images/generations'),
          isFalse,
          reason: '${preset.label} 的前缀不应自带尾段，尾段由端点拼接统一加',
        );
        expect(
          preset.apiPrefix.replaceAll(RegExp(r'/+$'), ''),
          preset.apiPrefix,
          reason: '${preset.label} 的前缀不应以斜杠结尾',
        );
        // 模型名宁缺毋滥：编造的型号表现为 404，比留空更难自查。
        expect(
          preset.sampleModels.every((model) => model.trim().isNotEmpty),
          isTrue,
          reason: '${preset.label} 的建议模型名不得为空串',
        );
      }
    });

    test('OpenAI / 智谱 / 火山的前缀版本段各不相同（硬编码 /v1 的回归锁）', () {
      final openai = imageProviderPresetById('openai')!;
      final zhipu = imageProviderPresetById('zhipu')!;
      final ark = imageProviderPresetById('ark')!;
      expect(openai.apiPrefix, endsWith('/v1'));
      expect(zhipu.apiPrefix, endsWith('/api/paas/v4'));
      expect(ark.apiPrefix, endsWith('/api/v3'));
    });

    test('建议尺寸/质量必须落在全局可选枚举内，否则下拉带出会丢值', () {
      for (final preset in kImageProviderPresets) {
        if (preset.recommendedSize.isNotEmpty) {
          expect(
            kImageSizeOptions.contains(preset.recommendedSize),
            isTrue,
            reason: '${preset.label} 的建议尺寸 ${preset.recommendedSize} 不在 kImageSizeOptions 里',
          );
        }
        if (preset.recommendedQuality.isNotEmpty) {
          expect(
            kImageQualityOptions.contains(preset.recommendedQuality),
            isTrue,
            reason: '${preset.label} 的建议质量不在 kImageQualityOptions 里',
          );
        }
      }
    });

    test('glm-image 的尺寸是 32 对齐值，quality 固定 hd', () {
      // 智谱文档：glm-image 尺寸枚举是 1280x1280 等 32 对齐值，quality 只支持 hd。
      // 之前默认 1024x1024 / 空 quality 对它是不匹配的，这里是回归锁。
      final zhipu = imageProviderPresetById('zhipu')!;
      expect(zhipu.sampleModels, contains('glm-image'));
      expect(zhipu.recommendedSize, '1280x1280');
      expect(zhipu.recommendedQuality, 'hd');
    });

    test('imageProviderPresetById 命中与未命中', () {
      expect(imageProviderPresetById('zhipu')?.label, contains('智谱'));
      expect(imageProviderPresetById(kImageProviderPresetCustomId), isNull);
      expect(imageProviderPresetById('nope'), isNull);
    });

    test('imageProviderPresetIdForPrefix 反推选中项，可还原下拉状态', () {
      for (final preset in kImageProviderPresets) {
        expect(imageProviderPresetIdForPrefix(preset.apiPrefix), preset.id);
        // 尾斜杠与空白不应影响反推，否则重进设置页会掉回「自定义」。
        expect(
          imageProviderPresetIdForPrefix('${preset.apiPrefix}/ '),
          preset.id,
        );
      }
    });

    test('反推不出的一律落到自定义，绝不静默改写用户地址', () {
      expect(
        imageProviderPresetIdForPrefix('https://my-proxy.internal/openai/v1'),
        kImageProviderPresetCustomId,
      );
      expect(imageProviderPresetIdForPrefix(''), kImageProviderPresetCustomId);
    });
  });
}
