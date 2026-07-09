import 'package:flutter_test/flutter_test.dart';

import 'package:chat_group/core/models/api_provider.dart';

void main() {
  group('ApiProvider.supportsVision', () {
    test('不支持视觉的 provider', () {
      expect(ApiProvider.deepseek.supportsVision, isFalse);
      expect(ApiProvider.baidu.supportsVision, isFalse);
      expect(ApiProvider.xfyun.supportsVision, isFalse);
    });

    test('支持视觉的 provider', () {
      expect(ApiProvider.qwen.supportsVision, isTrue);
      expect(ApiProvider.zhipu.supportsVision, isTrue);
      expect(ApiProvider.moonshot.supportsVision, isTrue);
      expect(ApiProvider.custom.supportsVision, isTrue);
    });

    test('覆盖所有枚举值，无遗漏', () {
      for (final provider in ApiProvider.values) {
        final expected = provider == ApiProvider.qwen ||
            provider == ApiProvider.zhipu ||
            provider == ApiProvider.moonshot ||
            provider == ApiProvider.custom;
        expect(provider.supportsVision, expected,
            reason: '${provider.name}.supportsVision 应为 $expected');
      }
    });
  });
}
