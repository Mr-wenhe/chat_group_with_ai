import 'package:chat_group/core/bundle/api_bundle.dart';
import 'package:chat_group/core/bundle/api_bundle_codec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, dynamic> minimal() => <String, dynamic>{'v': 1};

  test('最小载荷（只有版本号）可解析，四类服务均为空', () {
    final bundle = ApiBundle.parse(minimal());
    expect(bundle.chat, isEmpty);
    expect(bundle.voice, isNull);
    expect(bundle.image, isNull);
    expect(bundle.search, isEmpty);
    expect(bundle.issues, isEmpty);
    expect(bundle.hasNoEntries, isTrue);
    expect(bundle.totalEntries, 0);
  });

  test('缺少版本号 → 整包拒绝', () {
    expect(() => ApiBundle.parse(<String, dynamic>{}),
        throwsA(isA<ApiBundleFormatError>()));
  });

  test('版本号不认识 → 整包拒绝，且提示里带上版本号', () {
    expect(
      () => ApiBundle.parse(<String, dynamic>{'v': 99}),
      throwsA(isA<ApiBundleFormatError>().having(
        (e) => e.message,
        'message',
        contains('99'),
      )),
    );
  });

  test('四类服务全字段解析', () {
    final bundle = ApiBundle.parse(<String, dynamic>{
      'v': 1,
      'label': '团队包',
      'issuedAt': '2026-10-15T08:00:00Z',
      'chat': [
        {
          'id': 'cfg-a',
          'name': '主力',
          'provider': 'deepseek',
          'modelName': 'deepseek-chat',
          'customBaseUrl': '',
          'apiProtocol': 'anthropicMessages',
          'apiKey': 'sk-x',
          'makeDefault': true,
        },
      ],
      'voice': {
        'apiKey': 'v-x',
        'ttsResourceId': 'seed-tts-1.0',
        'asrResourceId': 'volc.bigasr.sauc.duration',
      },
      'image': {
        'apiKey': 'i-x',
        'baseUrl': 'https://open.bigmodel.cn/api/paas/v4',
        'model': 'glm-image',
        'size': '1280x1280',
        'quality': 'hd',
        'disableWatermark': true,
      },
      'search': [
        {
          'id': 'tavily-main',
          'name': 'Tavily',
          'provider': 'tavily',
          'baseUrl': 'https://api.tavily.com',
          'apiKey': 't-x',
          'isDefault': true,
        },
      ],
    });

    expect(bundle.label, '团队包');
    expect(bundle.issuedAt, '2026-10-15T08:00:00Z');
    expect(bundle.issues, isEmpty);
    expect(bundle.totalEntries, 4);

    final chat = bundle.chat.single;
    expect(chat.id, 'cfg-a');
    expect(chat.protocol, 'anthropicMessages');
    expect(chat.setDefault, isTrue);

    expect(bundle.voice!.ttsResourceId, 'seed-tts-1.0');
    expect(bundle.image!.disableWatermark, isTrue);
    expect(bundle.image!.quality, 'hd');
    expect(bundle.search.single.isDefault, isTrue);
    expect(bundle.search.single.enabled, isTrue);
  });

  test('未知的顶层与条目字段被忽略（前向兼容）', () {
    final bundle = ApiBundle.parse(<String, dynamic>{
      'v': 1,
      '未知键': '值',
      'realtime': {'apiKey': 'x'},
      'chat': [
        {
          'provider': 'deepseek',
          'apiKey': 'sk-x',
          '将来的字段': 42,
        },
      ],
    });
    expect(bundle.issues, isEmpty);
    expect(bundle.chat.single.provider, 'deepseek');
  });

  test('缺必填字段 → 条目级跳过并给出原因，不抛异常', () {
    final bundle = ApiBundle.parse(<String, dynamic>{
      'v': 1,
      'chat': [
        {'apiKey': 'sk-x'}, // 缺 provider
        {'provider': 'deepseek'}, // 缺 apiKey
      ],
    });
    expect(bundle.chat, isEmpty);
    expect(bundle.issues.length, 2);
    expect(bundle.issues[0].section, '聊天');
    expect(bundle.issues[0].reason, contains('provider'));
    expect(bundle.issues[1].reason, contains('apiKey'));
  });

  test('超长字段 → 明确报错，绝不静默截断', () {
    final bundle = ApiBundle.parse(<String, dynamic>{
      'v': 1,
      'chat': [
        {
          'provider': 'deepseek',
          'apiKey': 'k' * (ApiBundleLimits.maxCredentialLength + 1),
        },
      ],
    });
    expect(bundle.chat, isEmpty);
    expect(bundle.issues.single.reason, contains('过长'));
  });

  test('可选字段缺省是空串，不是 null', () {
    final bundle = ApiBundle.parse(<String, dynamic>{
      'v': 1,
      'chat': [
        {'provider': 'deepseek', 'apiKey': 'sk-x'},
      ],
    });
    final chat = bundle.chat.single;
    expect(chat.id, '');
    expect(chat.model, '');
    expect(chat.baseUrl, '');
    expect(chat.protocol, '');
    expect(chat.setDefault, isFalse);
    expect(chat.name, 'deepseek', reason: '没给名称时回落服务商名，便于预览展示');
  });

  test('条目数超过上限 → 整段跳过并说明', () {
    final bundle = ApiBundle.parse(<String, dynamic>{
      'v': 1,
      'search': [
        for (var i = 0; i <= ApiBundleLimits.maxEntriesPerSection; i++)
          {'id': 'p$i', 'name': 'P$i', 'provider': 'tavily', 'apiKey': 'x'},
      ],
    });
    expect(bundle.search, isEmpty);
    expect(bundle.issues.single.reason, contains('上限'));
  });

  test('非对象条目 → 跳过并说明，不拖垮同段其余条目', () {
    final bundle = ApiBundle.parse(<String, dynamic>{
      'v': 1,
      'chat': [
        '不是对象',
        {'provider': 'deepseek', 'apiKey': 'sk-x'},
      ],
    });
    expect(bundle.chat.length, 1);
    expect(bundle.issues.single.reason, '不是配置对象');
  });

  test('与编解码层串起来：seal → open → parse 全链路一致', () {
    final code = ApiBundleCodec.seal(<String, dynamic>{
      'v': 1,
      'label': '端到端',
      'chat': [
        {'provider': 'moonshot', 'modelName': 'moonshot-v1-8k', 'apiKey': 'sk-e2e'},
      ],
    }, secret: 'e2e-secret');

    final bundle = ApiBundle.parse(ApiBundleCodec.open(code, secret: 'e2e-secret'));
    expect(bundle.label, '端到端');
    expect(bundle.chat.single.provider, 'moonshot');
    expect(bundle.chat.single.apiKey, 'sk-e2e');
  });
}
