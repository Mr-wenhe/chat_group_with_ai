import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/models/api_protocol.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/features/ai_character/ip_visual_description_llm.dart';
import 'package:chat_group/services/chat_api_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeCredentials implements ApiCredentialResolver {
  _FakeCredentials(this.value);
  final String? value;
  final requested = <String>[];

  @override
  Future<String?> resolve(ApiConfig config) async {
    requested.add(config.id);
    return value;
  }
}

class _FakeChatApiService extends ChatApiService {
  _FakeChatApiService({this.result, this.error});

  final Map<String, dynamic>? result;
  final Object? error;
  final calls = <({String model, List<Map<String, dynamic>> messages})>[];

  @override
  Future<Map<String, dynamic>> sendChatMessage({
    required String apiKey,
    required ApiProvider provider,
    ApiProtocol apiProtocol = ApiProtocol.defaultValue,
    String? customBaseUrl,
    required String model,
    required List<Map<String, dynamic>> messages,
    double temperature = 0.85,
    int maxTokens = 1024,
    Duration? receiveTimeout,
    int maxRetries = 3,
    CancelToken? cancelToken,
  }) async {
    calls.add((model: model, messages: messages));
    final failure = error;
    if (failure != null) throw failure;
    return result ?? const <String, dynamic>{'success': true, 'message': ''};
  }
}

ApiConfig _config({bool hasCredential = true}) => ApiConfig(
      id: 'cfg-1',
      name: 'cfg-1',
      provider: 'custom',
      modelName: 'chat-model',
      customBaseUrl: 'https://example.invalid',
      hasCredential: hasCredential,
      credentialId: hasCredential ? 'credential-1' : '',
    );

AICharacter _character({String voiceId = ''}) => AICharacter(
      name: '小美',
      avatar: '美',
      age: 25,
      role: '游戏主播',
      personalityTags: const ['活泼', '开朗'],
      systemPrompt: '留着银色短发，常穿荧光绿卫衣。',
      apiKey: '',
      apiProvider: 'custom',
      voiceId: voiceId,
    );

void main() {
  test('改写结果被压空白并剥掉引号与代码块围栏', () async {
    final api = _FakeChatApiService(result: {
      'success': true,
      'message': '```\n"short  silver hair",\n\tamber eyes\n```',
    });
    final llm = IpVisualDescriptionLlm(api: api, credentials: _FakeCredentials('sk-x'));

    final description = await llm.describe(_character(), _config());

    expect(description, 'short silver hair, amber eyes');
  });

  test('人设与音色名进 user 消息，音色按中文名给出', () async {
    final api = _FakeChatApiService(result: {
      'success': true,
      'message': 'long silver hair',
    });
    final llm = IpVisualDescriptionLlm(api: api, credentials: _FakeCredentials('sk-x'));

    await llm.describe(
      _character(voiceId: 'zh_female_gaolengyujie_moon_bigtts'),
      _config(),
    );

    final userMessage = api.calls.single.messages.last['content'] as String;
    expect(userMessage, contains('姓名: 小美'));
    expect(userMessage, contains('朗读音色: 高冷御姐'));
    expect(userMessage, contains('银色短发'));
    expect(userMessage, contains('性格标签: 活泼, 开朗'));
    expect(userMessage, isNot(contains('unknown voice')));
  });

  test('系统提示把脸排在头发前、给头发压词量预算', () async {
    final api = _FakeChatApiService(result: {'success': true, 'message': 'x'});
    final llm = IpVisualDescriptionLlm(api: api, credentials: _FakeCredentials('sk-x'));

    await llm.describe(_character(), _config());

    final systemMessage = api.calls.single.messages.first['content'] as String;
    // 顺序即优先级：发型发色排在脸前面，出图就成了发丝特写。
    expect(
      systemMessage.indexOf('脸型五官'),
      lessThan(systemMessage.indexOf('发型发色')),
    );
    expect(systemMessage, contains('绝不能以头发'));
    // 只排顺序不控词量治不了满屏头发：头发写 10 个形容词、脸写 3 个，
    // 顺序再对也还是头发。
    expect(systemMessage, contains('至少 18 个英文单词'));
    expect(systemMessage, contains('最多 10 个英文单词'));
    expect(systemMessage, contains('头发是配角'));
    // 人物名词由 prompt 拼装处提供，模型只写外观属性。
    expect(systemMessage, contains('不要出现人物名词'));
    // 半身取景里画不到的东西写了只会把镜头往外拽。
    expect(systemMessage, contains('画面外的东西不要写'));
  });

  test('换行还原成短语边界逗号，不让相邻短语黏成一句', () async {
    // 模型照系统提示的分项列表换行输出。压成空格会出现
    // `bright innocent gaze short sturdy toddler frame` 这种黏连，
    // 生图模型读不出这是两件事。
    final api = _FakeChatApiService(result: {
      'success': true,
      'message': 'round cheeks, bright gaze\ntoddler frame, blue overalls\nmessy brown hair',
    });
    final llm = IpVisualDescriptionLlm(api: api, credentials: _FakeCredentials('sk-x'));

    final description = await llm.describe(_character(), _config());

    expect(
      description,
      'round cheeks, bright gaze, toddler frame, blue overalls, messy brown hair',
    );
  });

  test('换行转逗号后不留重复逗号与首尾逗号', () async {
    final api = _FakeChatApiService(result: {
      'success': true,
      'message': 'round cheeks,\n\n\ntoddler frame,\n',
    });
    final llm = IpVisualDescriptionLlm(api: api, credentials: _FakeCredentials('sk-x'));

    expect(await llm.describe(_character(), _config()), 'round cheeks, toddler frame');
  });

  test('未指定音色时不写出朗读音色行', () async {
    final api = _FakeChatApiService(result: {'success': true, 'message': 'x'});
    final llm = IpVisualDescriptionLlm(api: api, credentials: _FakeCredentials('sk-x'));

    await llm.describe(_character(), _config());

    final userMessage = api.calls.single.messages.last['content'] as String;
    expect(userMessage, isNot(contains('朗读音色')));
  });

  test('超长结果截断到上限', () async {
    final api = _FakeChatApiService(result: {
      'success': true,
      'message': 'A' * (kIpVisualDescriptionMaxChars + 100),
    });
    final llm = IpVisualDescriptionLlm(api: api, credentials: _FakeCredentials('sk-x'));

    final description = await llm.describe(_character(), _config());

    expect(description, hasLength(kIpVisualDescriptionMaxChars));
  });

  test('无 ApiConfig 时直接返回 null，不发起请求', () async {
    final api = _FakeChatApiService();
    final llm = IpVisualDescriptionLlm(api: api, credentials: _FakeCredentials('sk-x'));

    expect(await llm.describe(_character(), null), isNull);
    expect(api.calls, isEmpty);
  });

  test('配置未绑凭据时返回 null，不发起请求', () async {
    final api = _FakeChatApiService();
    final llm = IpVisualDescriptionLlm(api: api, credentials: _FakeCredentials('sk-x'));

    expect(await llm.describe(_character(), _config(hasCredential: false)), isNull);
    expect(api.calls, isEmpty);
  });

  test('凭据解析不到时返回 null，不发起请求', () async {
    final api = _FakeChatApiService();
    final llm = IpVisualDescriptionLlm(api: api, credentials: _FakeCredentials(null));

    expect(await llm.describe(_character(), _config()), isNull);
    expect(api.calls, isEmpty);
  });

  test('success=false / 空 message / 请求抛错 都回落 null', () async {
    for (final (result, error) in [
      (<String, dynamic>{'success': false, 'message': 'boom'}, null),
      (<String, dynamic>{'success': true, 'message': '   '}, null),
      (null, StateError('offline')),
    ]) {
      final api = _FakeChatApiService(result: result, error: error);
      final llm = IpVisualDescriptionLlm(api: api, credentials: _FakeCredentials('sk-x'));

      expect(
        await llm.describe(_character(), _config()),
        isNull,
        reason: '失败一律回落本地模板，不该让整次生成失败',
      );
    }
  });
}
