import 'dart:convert';

import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/models/character_skill.dart';
import 'package:chat_group/core/models/tool_permission.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/features/work_mode/work_role_model_selector.dart';
import 'package:chat_group/features/work_mode/work_role_router.dart';
import 'package:flutter_test/flutter_test.dart';

class _Credentials implements ApiCredentialResolver {
  final String value;

  const _Credentials(this.value);

  @override
  Future<String?> resolve(ApiConfig config) async => value;
}

AICharacter _character({required String id, required String role}) =>
    AICharacter(
      id: id,
      name: id,
      avatar: id,
      age: 30,
      role: role,
      personalityTags: const [],
      systemPrompt: '公开人设',
      apiKey: 'must-not-be-sent',
      apiProvider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
      apiConfigId: 'config-$id',
      toolPermissions: const [ToolPermission.workspaceRead],
    );

void main() {
  test('uses a credentialed model and parses the strict routing decision',
      () async {
    final product = _character(id: 'product', role: '产品经理');
    final developer = _character(id: 'developer', role: '开发工程师');
    final config = ApiConfig(
      id: 'config-product',
      name: 'router config',
      provider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
      hasCredential: true,
    );
    List<Map<String, dynamic>>? sentMessages;
    final selector = WorkRoleModelSelectorService(
      characters: [product, developer],
      credentials: const _Credentials('router-secret'),
      resolveApiConfig: (character) =>
          character.id == product.id ? config : null,
      complete: ({
        required character,
        required config,
        required apiKey,
        required provider,
        required messages,
        required timeout,
      }) async {
        sentMessages = messages;
        expect(apiKey, 'router-secret');
        expect(provider, ApiProvider.deepseek);
        return {
          'success': true,
          'message': jsonEncode({
            'characterId': developer.id,
            'publicReason': '开发角色具备实现该任务所需能力。',
            'confidence': 0.91,
            'needsHandoff': false,
          }),
        };
      },
    );

    final decision = await selector.select(
      WorkRoleRoutingContext(
        request: '修复 Flutter 代码',
        conversationId: 'group-1',
        characters: [product, developer],
        skills: [
          CharacterSkill(
            characterId: developer.id,
            name: '代码修复',
            domain: 'development',
            description: '实现和修复代码',
            instructions: const ['读取代码', '提交精确补丁'],
            requiredPermissions: const [ToolPermission.workspaceRead],
          ),
        ],
        candidateCharacterIds: [product.id, developer.id],
      ),
    );

    expect(decision.characterId, developer.id);
    expect(decision.confidence, 0.91);
    final prompt = sentMessages!.last['content'] as String;
    expect(prompt, contains('修复 Flutter 代码'));
    expect(prompt, isNot(contains('must-not-be-sent')));
    expect(prompt, isNot(contains('router-secret')));
  });

  test('rejects non-JSON model output instead of falling back silently',
      () async {
    final character = _character(id: 'worker', role: '开发工程师');
    final config = ApiConfig(
      id: 'config-worker',
      name: 'router config',
      provider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
      hasCredential: true,
    );
    final selector = WorkRoleModelSelectorService(
      characters: [character],
      credentials: const _Credentials('router-secret'),
      resolveApiConfig: (_) => config,
      complete: ({
        required character,
        required config,
        required apiKey,
        required provider,
        required messages,
        required timeout,
      }) async =>
          {'success': true, 'message': 'not json'},
    );

    await expectLater(
      selector.select(
        WorkRoleRoutingContext(
          request: '执行任务',
          conversationId: 'group-1',
          characters: [character],
          candidateCharacterIds: [character.id],
        ),
      ),
      // 契约从"抛 FormatException"改成"抛带成因的选人失败"：路由器要把
      // 成因写进公开说明，只认类型的话无法区分形状不对与输出被截断。
      throwsA(
        isA<WorkRoleModelSelectionException>()
            .having((error) => error.kind, 'kind',
                WorkRoleModelFailureKind.malformed)
            .having((error) => error.responseSnippet, 'snippet', 'not json'),
      ),
    );
  });

  test('accepts a routing decision preceded by one spoken sentence', () async {
    final product = _character(id: 'product', role: '产品经理');
    final developer = _character(id: 'developer', role: '开发工程师');
    final config = ApiConfig(
      id: 'config-product',
      name: 'router config',
      provider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
      hasCredential: true,
    );
    final selector = WorkRoleModelSelectorService(
      characters: [product, developer],
      credentials: const _Credentials('router-secret'),
      resolveApiConfig: (character) =>
          character.id == product.id ? config : null,
      complete: ({
        required character,
        required config,
        required apiKey,
        required provider,
        required messages,
        required timeout,
      }) async =>
          {
        'success': true,
        'message': '先看下谁更适合这个任务。\n\n'
            '${jsonEncode({
              'characterId': developer.id,
              'publicReason': '开发角色具备实现该任务所需能力。',
              'confidence': 0.91,
              'needsHandoff': false,
            })}',
      },
    );

    // 网关常给协议正文加一句口语前缀；从前这里会整条判成 malformed，用户只看到
    // 「模型候选推荐未完成」，看不出模型其实给出了完全可用的选择。
    final decision = await selector.select(
      WorkRoleRoutingContext(
        request: '修复 Flutter 代码',
        conversationId: 'group-1',
        characters: [product, developer],
        candidateCharacterIds: [product.id, developer.id],
      ),
    );

    expect(decision.characterId, developer.id);
    expect(decision.confidence, 0.91);
  });

  test('缺少 reason 的决策仍然可用，理由留空而不是整条作废', () async {
    final product = _character(id: 'product', role: '产品经理');
    final developer = _character(id: 'developer', role: '开发工程师');
    final config = ApiConfig(
      id: 'config-product',
      name: 'router config',
      provider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
      hasCredential: true,
    );
    final selector = WorkRoleModelSelectorService(
      characters: [product, developer],
      credentials: const _Credentials('router-secret'),
      resolveApiConfig: (character) =>
          character.id == product.id ? config : null,
      complete: ({
        required character,
        required config,
        required apiKey,
        required provider,
        required messages,
        required timeout,
      }) async =>
          {
        'success': true,
        // reason 是唯一会长到撑破输出上限的字段。它缺席时，characterId 与
        // confidence 仍然够用，不该因为一句理由丢掉整条选择。
        'message': jsonEncode({
          'characterId': developer.id,
          'confidence': 0.8,
          'needsHandoff': false,
        }),
      },
    );

    final decision = await selector.select(
      WorkRoleRoutingContext(
        request: '修复 Flutter 代码',
        conversationId: 'group-1',
        characters: [product, developer],
        candidateCharacterIds: [product.id, developer.id],
      ),
    );

    expect(decision.characterId, developer.id);
    expect(decision.publicReason, isEmpty);
  });

  test('uses reasoning_content only when standard content is empty', () async {
    final character = _character(id: 'reasoning-worker', role: '开发工程师');
    final config = ApiConfig(
      id: 'config-reasoning-worker',
      name: 'router config',
      provider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
      hasCredential: true,
    );
    final selector = WorkRoleModelSelectorService(
      characters: [character],
      credentials: const _Credentials('router-secret'),
      resolveApiConfig: (_) => config,
      complete: ({
        required character,
        required config,
        required apiKey,
        required provider,
        required messages,
        required timeout,
      }) async =>
          {
        'success': true,
        'content': '',
        'reasoning_content': jsonEncode({
          'characterId': character.id,
          'publicReason': '兼容字段中的严格路由结果。',
          'confidence': 0.8,
          'needsHandoff': false,
        }),
      },
    );

    final decision = await selector.select(
      WorkRoleRoutingContext(
        request: '修复代码',
        conversationId: 'group-1',
        characters: [character],
        candidateCharacterIds: [character.id],
      ),
    );

    expect(decision.characterId, character.id);
  });

  test('bounds oversized routing payload without cutting JSON', () async {
    final characters = List<AICharacter>.generate(
      32,
      (index) => AICharacter(
        id: 'large-$index',
        name: '角色 $index',
        avatar: 'L$index',
        age: 30,
        role: '开发工程师 ${'role ' * 200}',
        personalityTags: List<String>.filled(16, 'tag ${'x' * 80}'),
        systemPrompt: '公开资料 ${'prompt ' * 500}',
        apiKey: 'must-not-be-sent',
        apiProvider: ApiProvider.deepseek.name,
        modelName: 'deepseek-chat',
        apiConfigId: 'large-config-$index',
      ),
    );
    final config = ApiConfig(
      id: 'large-config-0',
      name: 'router config',
      provider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
      hasCredential: true,
    );
    String? prompt;
    final selector = WorkRoleModelSelectorService(
      characters: characters,
      credentials: const _Credentials('router-secret'),
      resolveApiConfig: (character) =>
          character.id == 'large-0' ? config : null,
      complete: ({
        required character,
        required config,
        required apiKey,
        required provider,
        required messages,
        required timeout,
      }) async {
        prompt = messages.last['content'] as String;
        return {
          'success': true,
          'message': jsonEncode({
            'characterId': 'large-0',
            'publicReason': '资料足够',
            'confidence': 0.8,
            'needsHandoff': false,
          }),
        };
      },
    );

    await selector.select(
      WorkRoleRoutingContext(
        request: '选择角色',
        conversationId: 'large-group',
        characters: characters,
        skills: List<CharacterSkill>.generate(
          64,
          (index) => CharacterSkill(
            characterId: 'large-${index % characters.length}',
            name: '技能 $index',
            domain: 'development',
            description: '说明 ${'d' * 500}',
            instructions: List<String>.filled(12, 'instruction ${'i' * 300}'),
            requiredPermissions: const [],
          ),
        ),
        candidateCharacterIds: characters.map((character) => character.id),
      ),
    );

    expect(prompt, isNotNull);
    expect(prompt!.length, lessThanOrEqualTo(24 * 1024));
    expect(utf8.encode(prompt!).length, lessThanOrEqualTo(24 * 1024));
    expect(() => jsonDecode(prompt!), returnsNormally);
    expect((jsonDecode(prompt!) as Map)['truncated'], isTrue);
  });

  test('输出用满本次请求的上限时报截断，而不是笼统的解析失败', () async {
    final character = _character(id: 'worker', role: '开发工程师');
    final config = ApiConfig(
      id: 'config-worker',
      name: 'router config',
      provider: ApiProvider.deepseek.name,
      modelName: 'sensenova-6.8-flash-lite',
      hasCredential: true,
    );
    final selector = WorkRoleModelSelectorService(
      characters: [character],
      credentials: const _Credentials('router-secret'),
      resolveApiConfig: (_) => config,
      maxOutputTokens: 256,
      complete: ({
        required character,
        required config,
        required apiKey,
        required provider,
        required messages,
        required timeout,
      }) async =>
          {
        'success': true,
        // 真实现场的形状：JSON 被截在半句上，输出正好 256 token。
        'message': '{"characterId": "worker", "publicReason": "开发角色具备',
        'completionTokens': 256,
      },
    );

    await expectLater(
      selector.select(
        WorkRoleRoutingContext(
          request: '生成一份 HTML 游戏',
          conversationId: 'group-1',
          characters: [character],
          candidateCharacterIds: [character.id],
        ),
      ),
      throwsA(
        isA<WorkRoleModelSelectionException>()
            .having((error) => error.kind, 'kind',
                WorkRoleModelFailureKind.truncated)
            .having((error) => error.outputTokenLimit, 'outputTokenLimit', 256),
      ),
    );
  });

  test('响应无法解析时留下脱敏且有界的开头，供现场定性', () async {
    final character = _character(id: 'worker', role: '开发工程师');
    final config = ApiConfig(
      id: 'config-worker',
      name: 'router config',
      provider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
      hasCredential: true,
    );
    const secret = 'sk-abcdefghijklmnopqrstuvwxyz0123456789ABCDEF';
    final selector = WorkRoleModelSelectorService(
      characters: [character],
      credentials: const _Credentials('router-secret'),
      resolveApiConfig: (_) => config,
      complete: ({
        required character,
        required config,
        required apiKey,
        required provider,
        required messages,
        required timeout,
      }) async =>
          {
        'success': true,
        'message': '抱歉，我不能决定。凭据 $secret 见 '
            '/Users/fengye/Desktop/chat_group_out/game.html，${'补充说明。' * 200}',
      },
    );

    WorkRoleModelSelectionException? failure;
    try {
      await selector.select(
        WorkRoleRoutingContext(
          request: '执行任务',
          conversationId: 'group-1',
          characters: [character],
          candidateCharacterIds: [character.id],
        ),
      );
    } on WorkRoleModelSelectionException catch (error) {
      failure = error;
    }

    expect(failure, isNotNull);
    expect(failure!.kind, WorkRoleModelFailureKind.malformed);
    final snippet = failure.responseSnippet;
    expect(snippet, isNotNull);
    // 密钥与本地路径都必须消失（长路径会被"不透明长串"规则整段遮掉，不一定会
    // 落成 [本地路径]，所以这里断言的是"原文不出现"而不是某个具体占位符）。
    expect(snippet, isNot(contains(secret)));
    expect(snippet, isNot(contains('/Users/fengye')));
    expect(snippet, isNot(contains('chat_group_out')));
    expect(snippet, contains('[REDACTED]'));
    expect(snippet!.length, lessThanOrEqualTo(160));
  });

  test('网关失败、空内容与缺凭据分成不同成因', () async {
    final character = _character(id: 'worker', role: '开发工程师');
    final config = ApiConfig(
      id: 'config-worker',
      name: 'router config',
      provider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
      hasCredential: true,
    );

    Future<WorkRoleModelFailureKind> kindOf({
      required String credential,
      required Map<String, dynamic> response,
    }) async {
      final selector = WorkRoleModelSelectorService(
        characters: [character],
        credentials: _Credentials(credential),
        resolveApiConfig: (_) => config,
        complete: ({
          required character,
          required config,
          required apiKey,
          required provider,
          required messages,
          required timeout,
        }) async =>
            response,
      );
      try {
        await selector.select(
          WorkRoleRoutingContext(
            request: '执行任务',
            conversationId: 'group-1',
            characters: [character],
            candidateCharacterIds: [character.id],
          ),
        );
      } on WorkRoleModelSelectionException catch (error) {
        return error.kind;
      }
      fail('应当抛出带成因的选人失败');
    }

    expect(
      await kindOf(
        credential: 'router-secret',
        response: {'success': false, 'message': 'HTTP 401 Unauthorized'},
      ),
      WorkRoleModelFailureKind.request,
    );
    expect(
      await kindOf(
        credential: 'router-secret',
        response: {'success': true, 'message': '   '},
      ),
      WorkRoleModelFailureKind.empty,
    );
    expect(
      await kindOf(
        credential: '',
        response: {'success': true, 'message': '{}'},
      ),
      WorkRoleModelFailureKind.credential,
    );
  });
}
