import 'package:flutter_test/flutter_test.dart';

import 'package:chat_group/core/audio/voice_service_config.dart';
import 'package:chat_group/core/images/image_service_config.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/features/settings/api_key_settings_status.dart';
import 'package:chat_group/features/web_search/models/search_models.dart';
import 'package:chat_group/features/web_search/models/search_provider_config.dart';

ApiConfig _config(
  String name, {
  bool bound = false,
  String model = 'deepseek-chat',
}) {
  return ApiConfig(
    name: name,
    provider: 'deepseek',
    modelName: model,
    hasCredential: bound,
  );
}

SearchProviderConfig _provider(
  String name, {
  bool bound = false,
  bool attention = false,
}) {
  return SearchProviderConfig(
    id: name,
    name: name,
    provider: SearchProviderKind.gateway,
    baseUrl: 'https://search.example.com',
    hasCredential: bound,
    requiresAttention: attention,
  );
}

void main() {
  group('chatStatus', () {
    test('没有配置时给出可执行的引导', () {
      final entry = chatStatus(const <ApiConfig>[]);
      expect(entry.id, ApiKeyCategory.chat);
      expect(entry.configured, isFalse);
      expect(entry.summary, '尚未配置 · 角色无法回复消息');
    });

    test('全部绑定 Key 时计入已配置', () {
      final entry =
          chatStatus([_config('a', bound: true), _config('b', bound: true)]);
      expect(entry.configured, isTrue);
      expect(entry.summary, '2 个配置 · 全部已绑定 Key');
    });

    test('部分绑定 Key 时计入已配置并报出数量', () {
      final entry = chatStatus([
        _config('a', bound: true),
        _config('b'),
        _config('c'),
      ]);
      expect(entry.configured, isTrue);
      expect(entry.summary, '3 个配置 · 1 个已绑定 Key');
    });

    test('一个都没绑定时不计入已配置', () {
      final entry = chatStatus([_config('a'), _config('b')]);
      expect(entry.configured, isFalse);
      expect(entry.summary, '2 个配置 · 均未绑定 Key');
    });
  });

  group('speakerPickerStatus', () {
    test('未选择时说明回落本地规则', () {
      final entry =
          speakerPickerStatus(selectedConfigId: null, selectedConfig: null);
      expect(entry.id, ApiKeyCategory.speakerPicker);
      expect(entry.configured, isFalse);
      expect(entry.summary, '未选择 · 使用本地规则选人，不额外调用模型');
    });

    test('引用失效按未选择呈现，不提示去补 Key', () {
      final entry = speakerPickerStatus(
        selectedConfigId: 'gone',
        selectedConfig: null,
      );
      expect(entry.configured, isFalse);
      expect(entry.summary, '引用的配置已不存在 · 已回落本地规则，请重新选择');
    });

    test('引用的配置缺少凭据时回落本地规则', () {
      final entry = speakerPickerStatus(
        selectedConfigId: 'a',
        selectedConfig: _config('deepseek v4.1'),
      );
      expect(entry.configured, isFalse);
      expect(entry.summary, 'deepseek v4.1 · 缺少凭据，暂时回落本地规则');
    });

    test('引用有效时显示配置名与模型名', () {
      final entry = speakerPickerStatus(
        selectedConfigId: 'a',
        selectedConfig:
            _config('deepseek v4.1', bound: true, model: 'deepseek-flash'),
      );
      expect(entry.configured, isTrue);
      expect(entry.summary, 'deepseek v4.1 · deepseek-flash');
    });
  });

  group('voiceStatus', () {
    test('未绑定 Key 时说明两项能力都不可用', () {
      final entry = voiceStatus(VoiceServiceConfig.empty);
      expect(entry.id, ApiKeyCategory.voice);
      expect(entry.configured, isFalse);
      expect(entry.summary, '未配置 · 语音播报与语音输入均不可用');
    });

    test('已绑定但没设默认音色', () {
      final entry = voiceStatus(const VoiceServiceConfig(apiKeyBound: true));
      expect(entry.configured, isTrue);
      expect(entry.summary, '已绑定 Key · 未设默认音色（需逐角色选）');
    });

    test('已绑定且设了默认音色时显示中文音色名', () {
      final entry = voiceStatus(const VoiceServiceConfig(
        apiKeyBound: true,
        defaultVoiceId: 'zh_female_meilinvyou_moon_bigtts',
      ));
      expect(entry.configured, isTrue);
      expect(entry.summary, '已绑定 Key · 默认音色 魅力女友');
    });

    test('音色 id 已不在目录中时按未设默认音色处理', () {
      final entry = voiceStatus(const VoiceServiceConfig(
        apiKeyBound: true,
        defaultVoiceId: 'zh_female_removed_in_upgrade',
      ));
      expect(entry.summary, '已绑定 Key · 未设默认音色（需逐角色选）');
    });

    test('绑定但缺 TTS 资源时不具备可用前提', () {
      final entry = voiceStatus(const VoiceServiceConfig(
        apiKeyBound: true,
        ttsResourceId: '   ',
      ));
      expect(entry.configured, isFalse);
      expect(entry.summary, '已绑定 Key · 缺少 TTS 资源 ID，无法合成语音');
    });
  });

  group('imageStatus', () {
    test('未绑定 Key 时说明能力不可用', () {
      final entry = imageStatus(ImageServiceConfig.empty);
      expect(entry.id, ApiKeyCategory.image);
      expect(entry.configured, isFalse);
      expect(entry.summary, '未配置 · 无法生成 IP 形象');
    });

    test('绑定但缺地址或模型时不具备可用前提', () {
      final entry = imageStatus(const ImageServiceConfig(apiKeyBound: true));
      expect(entry.configured, isFalse);
      expect(entry.summary, '已绑定 Key · 缺少 baseUrl 或模型，无法出图');
    });

    test('配置完整时显示模型名', () {
      final entry = imageStatus(const ImageServiceConfig(
        apiKeyBound: true,
        baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
        model: 'cogview-4-flash',
      ));
      expect(entry.configured, isTrue);
      expect(entry.summary, '已绑定 Key · cogview-4-flash');
    });
  });

  group('searchStatus', () {
    test('既没有 Provider 也没配智谱原生搜索', () {
      final entry = searchStatus(
        const <SearchProviderConfig>[],
        zhipuNativeConfigured: false,
      );
      expect(entry.id, ApiKeyCategory.search);
      expect(entry.configured, isFalse);
      expect(entry.summary, '尚未配置 · 联网搜索不可用');
    });

    test('只有智谱原生搜索也算已配置', () {
      final entry = searchStatus(
        const <SearchProviderConfig>[],
        zhipuNativeConfigured: true,
      );
      expect(entry.configured, isTrue);
      expect(entry.summary, '仅智谱原生搜索 · 已绑定 Key');
    });

    test('部分 Provider 未绑定 Key', () {
      final entry = searchStatus(
        [_provider('tavily', bound: true), _provider('brave')],
        zhipuNativeConfigured: false,
      );
      expect(entry.configured, isTrue);
      expect(entry.summary, '2 个 Provider · 1 个已绑定 Key');
    });

    test('需要重新验证凭据时优先报出该状态', () {
      final entry = searchStatus(
        [
          _provider('tavily', bound: true, attention: true),
          _provider('brave', bound: true),
        ],
        zhipuNativeConfigured: false,
      );
      expect(entry.configured, isTrue);
      expect(entry.summary, '2 个 Provider · 1 个需要重新验证凭据');
    });
  });

  group('ApiKeyOverview', () {
    ApiKeyStatusEntry entry(String id, {required bool configured}) =>
        ApiKeyStatusEntry(id: id, configured: configured, summary: id);

    test('分母只数真正持有密钥的类别', () {
      final overview = ApiKeyOverview([
        entry(ApiKeyCategory.chat, configured: true),
        entry(ApiKeyCategory.speakerPicker, configured: true),
        entry(ApiKeyCategory.voice, configured: false),
        entry(ApiKeyCategory.image, configured: false),
        entry(ApiKeyCategory.search, configured: false),
      ]);
      expect(overview.total, 4);
      expect(overview.configuredCount, 1);
      expect(overview.progressLabel, '密钥已配置 1 / 4 项');
    });

    test('选人器的选择状态不影响计数', () {
      final withoutPicker = ApiKeyOverview([
        entry(ApiKeyCategory.chat, configured: true),
        entry(ApiKeyCategory.voice, configured: true),
        entry(ApiKeyCategory.image, configured: true),
        entry(ApiKeyCategory.search, configured: true),
      ]);
      final withPickerUnset = ApiKeyOverview([
        entry(ApiKeyCategory.chat, configured: true),
        entry(ApiKeyCategory.speakerPicker, configured: false),
        entry(ApiKeyCategory.voice, configured: true),
        entry(ApiKeyCategory.image, configured: true),
        entry(ApiKeyCategory.search, configured: true),
      ]);
      expect(withPickerUnset.configuredCount, withoutPicker.configuredCount);
      expect(withPickerUnset.progressLabel, '密钥已配置 4 / 4 项');
      expect(withPickerUnset.allConfigured, isTrue);
    });

    test('缺任意一类都不算配齐', () {
      final overview = ApiKeyOverview([
        entry(ApiKeyCategory.chat, configured: true),
        entry(ApiKeyCategory.voice, configured: true),
        entry(ApiKeyCategory.image, configured: true),
        entry(ApiKeyCategory.search, configured: false),
      ]);
      expect(overview.allConfigured, isFalse);
      expect(overview.progressLabel, '密钥已配置 3 / 4 项');
    });
  });
}
