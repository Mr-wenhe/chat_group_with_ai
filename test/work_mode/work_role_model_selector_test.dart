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
      throwsFormatException,
    );
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
}
