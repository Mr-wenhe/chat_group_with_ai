import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/character_skill.dart';
import 'package:chat_group/features/work_mode/work_handoff_state.dart';
import 'package:chat_group/features/work_mode/work_role_router.dart';
import 'package:flutter_test/flutter_test.dart';

AICharacter _character(String id, String name, String role) => AICharacter(
      id: id,
      name: name,
      avatar: '🤖',
      age: 30,
      role: role,
      personalityTags: const [],
      systemPrompt: '负责$role相关工作',
      apiKey: 'test-key',
      apiProvider: 'deepseek',
      apiConfigId: 'test-config',
    );

CharacterSkill _skill(String id, String characterId, String domain) =>
    CharacterSkill(
      id: id,
      characterId: characterId,
      name: '$domain skill',
      domain: domain,
      description: '$domain capability',
      instructions: const ['完成对应工作'],
      requiredPermissions: const [],
    );

void main() {
  const router = WorkRoleRouter();
  final product = _character('product', '小产', '产品经理');
  final developer = _character('developer', '小开', '开发工程师');
  final tester = _character('tester', '小测', '测试工程师');
  final characters = [product, developer, tester];
  final skills = [
    _skill('product-skill', product.id, 'product'),
    _skill('coding-skill', developer.id, 'coding'),
    _skill('testing-skill', tester.id, 'testing'),
  ];

  test('reuses shared mention parsing for exact explicit @ routing', () async {
    final result = await router.route(
      request: '请 @小开 实现这个页面',
      conversationId: 'group:mentions',
      characters: characters,
      skills: skills,
    );

    expect(result.isSuccess, isTrue);
    expect(result.characterId, developer.id);
    expect(result.source, WorkRoleRouteSource.explicitMention);
    expect(result.publicReason, contains('@小开'));
    expect(result.confidence, greaterThan(0.9));
  });

  test('valid explicit @ wins before handoff and model routing', () async {
    var modelCalled = false;
    final routed = WorkRoleRouter(
      modelSelector: (_) {
        modelCalled = true;
        return const WorkRoleModelDecision(
          characterId: 'tester',
          publicReason: '不应覆盖显式 @。',
          confidence: 1,
          needsHandoff: false,
        );
      },
    );
    final result = await routed.route(
      request: '@小开 实现页面',
      conversationId: 'group:priority',
      handoff: WorkHandoffState(
        conversationId: 'group:priority',
        stages: [
          WorkHandoffStage(
            id: 'product',
            label: '产品需求',
            roleId: product.id,
          ),
        ],
      ),
      characters: characters,
      skills: skills,
    );

    expect(result.characterId, developer.id);
    expect(result.source, WorkRoleRouteSource.explicitMention);
    expect(modelCalled, isFalse);
  });

  test('explicit roles can name each product, development, and test stage',
      () async {
    final result = await router.route(
      request: '@小产 写需求文档 @小开 实现代码 @小测 执行测试',
      conversationId: 'group:explicit-handoff',
      characters: characters,
      skills: skills,
    );

    expect(result.source, WorkRoleRouteSource.explicitMention);
    expect(result.characterId, product.id);
    expect(result.handoffState!.stages.map((stage) => stage.roleId), [
      product.id,
      developer.id,
      tester.id,
    ]);
  });

  test('multiple explicit mentions never auto-fill an unmentioned stage',
      () async {
    final result = await router.route(
      request: '@小产 写需求文档 @小开 实现代码，最后执行测试',
      conversationId: 'group:explicit-boundary',
      characters: characters,
      skills: skills,
    );

    expect(result.isSuccess, isFalse);
    expect(result.source, WorkRoleRouteSource.explicitMention);
    expect(result.characterId, isNull);
    expect(result.publicReason, anyOf(contains('没有活跃角色'), contains('能力')));
  });

  test('does not silently choose one of two characters with the same name',
      () async {
    final result = await router.route(
      request: '@小开 修复登录问题',
      conversationId: 'group:duplicate',
      characters: [
        developer,
        _character('developer-2', '小开', '开发工程师'),
      ],
      skills: skills,
    );

    expect(result.isSuccess, isFalse);
    expect(result.characterId, isNull);
    expect(result.publicReason, contains('重名'));
  });

  test('explains an unknown explicit role instead of falling back', () async {
    final result = await router.route(
      request: '@不存在 实现功能',
      conversationId: 'group:unknown-role',
      characters: characters,
      skills: skills,
    );

    expect(result.isSuccess, isFalse);
    expect(result.source, WorkRoleRouteSource.explicitMention);
    expect(result.publicReason, contains('@不存在'));
  });

  test('automatically routes product, coding, and testing requests by role',
      () async {
    final productResult = await router.route(
      request: '写一份需求文档和验收标准',
      conversationId: 'group:auto-product',
      characters: characters,
      skills: skills,
    );
    final codingResult = await router.route(
      request: '实现 Flutter 页面并修复代码',
      conversationId: 'group:auto-code',
      characters: characters,
      skills: skills,
    );
    final testingResult = await router.route(
      request: '执行回归测试并验证结果',
      conversationId: 'group:auto-test',
      characters: characters,
      skills: skills,
    );

    expect(productResult.characterId, product.id);
    expect(productResult.source, WorkRoleRouteSource.deterministicFallback);
    expect(productResult.publicReason, contains('产品'));
    expect(codingResult.characterId, developer.id);
    expect(codingResult.publicReason, contains('开发'));
    expect(testingResult.characterId, tester.id);
    expect(testingResult.publicReason, contains('测试'));
    expect(
      {
        productResult.publicReason,
        codingResult.publicReason,
        testingResult.publicReason,
      }.every((reason) => reason.trim().isNotEmpty),
      isTrue,
    );
  });

  test('reports capability insufficiency instead of falling back silently',
      () async {
    final result = await router.route(
      request: '实现 Flutter 页面并修复代码',
      conversationId: 'group:insufficient',
      characters: [_character('writer', '小文', '文案编辑')],
      skills: [_skill('writing-skill', 'writer', 'writing')],
    );

    expect(result.isSuccess, isFalse);
    expect(result.characterId, isNull);
    expect(result.publicReason, contains('开发'));
    expect(result.publicReason, contains('能力'));
  });

  test('private chat always keeps the fixed conversation character', () async {
    final result = await router.route(
      request: '@小测 写一份需求文档',
      conversationId: 'dm:developer',
      isDirectChat: true,
      directCharacterId: developer.id,
      characters: characters,
      skills: skills,
    );

    expect(result.isSuccess, isTrue);
    expect(result.characterId, developer.id);
    expect(result.source, WorkRoleRouteSource.privateChat);
    expect(result.publicReason, contains('私聊'));
    expect(result.needsHandoff, isFalse);
  });

  test('rejects a private-role ID that disagrees with the DM key', () async {
    final result = await router.route(
      request: '继续处理',
      conversationId: 'dm:developer',
      isDirectChat: true,
      directCharacterId: tester.id,
      characters: characters,
      skills: skills,
    );

    expect(result.isSuccess, isFalse);
    expect(result.source, WorkRoleRouteSource.privateChat);
    expect(result.publicReason, contains('不一致'));
  });

  test('model route exposes id, public reason, confidence, and handoff flag',
      () async {
    final routed = WorkRoleRouter(
      modelSelector: (context) {
        expect(context.characters, hasLength(3));
        for (final character in context.characters) {
          expect(character.apiKey, isEmpty);
          expect(character.customBaseUrl, isEmpty);
          expect(character.apiConfigId, isEmpty);
        }
        return const WorkRoleModelDecision(
          characterId: 'developer',
          publicReason: '模型判断当前主要是编码任务。',
          confidence: 0.82,
          needsHandoff: true,
        );
      },
    );
    final result = await routed.route(
      request: '实现已有功能',
      conversationId: 'group:model',
      characters: characters,
      skills: skills,
    );

    expect(result.isSuccess, isTrue);
    expect(result.characterId, developer.id);
    expect(result.source, WorkRoleRouteSource.model);
    expect(result.publicReason, '模型判断当前主要是编码任务。');
    expect(result.confidence, 0.82);
    expect(result.needsHandoff, isTrue);
  });

  test('rejects an unknown model role without deterministic substitution',
      () async {
    final routed = WorkRoleRouter(
      modelSelector: (_) => const WorkRoleModelDecision(
        characterId: 'missing',
        publicReason: '模型选择了不存在的角色。',
        confidence: 0.7,
        needsHandoff: false,
      ),
    );
    final result = await routed.route(
      request: '实现功能',
      conversationId: 'group:model-invalid',
      characters: characters,
      skills: skills,
    );

    expect(result.isSuccess, isFalse);
    expect(result.characterId, isNull);
    expect(result.publicReason, contains('不存在'));
    expect(result.source, WorkRoleRouteSource.model);
  });

  test('rejects an invalid model confidence without fallback', () async {
    final routed = WorkRoleRouter(
      modelSelector: (_) => const WorkRoleModelDecision(
        characterId: 'developer',
        publicReason: '模型给出越界置信度。',
        confidence: 1.5,
        needsHandoff: false,
      ),
    );
    final result = await routed.route(
      request: '实现功能',
      conversationId: 'group:model-confidence',
      characters: characters,
      skills: skills,
    );

    expect(result.isSuccess, isFalse);
    expect(result.source, WorkRoleRouteSource.model);
    expect(result.publicReason, contains('置信度'));
  });

  test('rejects a handoff state from another conversation', () async {
    final result = await router.route(
      request: '继续开发阶段',
      conversationId: 'group:handoff-current',
      handoff: WorkHandoffState(
        conversationId: 'group:handoff-other',
        stages: [
          WorkHandoffStage(
            id: 'development',
            label: '开发实现',
            roleId: developer.id,
          ),
        ],
      ),
      characters: characters,
      skills: skills,
    );

    expect(result.isSuccess, isFalse);
    expect(result.source, WorkRoleRouteSource.handoff);
    expect(result.publicReason, contains('另一个 conversationId'));
  });

  test('rejects a handoff receiver that lost the stage capability', () async {
    final result = await router.route(
      request: '继续开发阶段',
      conversationId: 'group:handoff-capability',
      handoff: WorkHandoffState(
        conversationId: 'group:handoff-capability',
        stages: [
          WorkHandoffStage(
            id: 'development',
            label: '开发实现',
            roleId: 'writer',
          ),
        ],
      ),
      characters: [_character('writer', '小文', '文案编辑')],
      skills: [_skill('writing-skill', 'writer', 'writing')],
    );

    expect(result.isSuccess, isFalse);
    expect(result.source, WorkRoleRouteSource.handoff);
    expect(result.publicReason, contains('开发'));
    expect(result.publicReason, contains('能力'));
  });

  test('creates and persists product to developer to tester handoff', () async {
    final result = await router.route(
      request: '先写需求文档，再实现代码，最后执行测试',
      conversationId: 'group:handoff',
      characters: characters,
      skills: skills,
    );

    expect(result.isSuccess, isTrue);
    expect(result.characterId, product.id);
    expect(result.needsHandoff, isTrue);
    final initial = result.handoffState!;
    expect(initial.stageIds, ['product', 'development', 'testing']);
    expect(initial.currentRoleId, product.id);
    expect(initial.receivingRoleId, developer.id);
    expect(initial.completionCriteria, isNotEmpty);

    expect(
      () => initial.advanceAfterStage(previousRoleReleased: false),
      throwsStateError,
    );
    final afterProduct = initial.advanceAfterStage(
      previousRoleReleased: true,
      deliveredArtifacts: const ['requirements.md'],
    );
    expect(afterProduct.isAwaitingReceiver, isTrue);
    expect(afterProduct.currentRoleId, developer.id);
    expect(afterProduct.receivingRoleId, tester.id);
    expect(afterProduct.deliveredArtifacts, ['requirements.md']);

    final handoffRoute = await router.route(
      request: '继续开发阶段',
      conversationId: 'group:handoff',
      handoff: afterProduct,
      characters: characters,
      skills: skills,
    );
    expect(handoffRoute.characterId, developer.id);
    expect(handoffRoute.source, WorkRoleRouteSource.handoff);
    expect(handoffRoute.handoffState!.isAwaitingReceiver, isFalse);

    final afterDeveloper = afterProduct.advanceAfterStage(
      previousRoleReleased: true,
      deliveredArtifacts: const ['lib/feature.dart'],
    );
    expect(afterDeveloper.isAwaitingReceiver, isTrue);
    expect(afterDeveloper.currentRoleId, tester.id);
    expect(afterDeveloper.receivingRoleId, isNull);
    final completed = afterDeveloper.advanceAfterStage(
      previousRoleReleased: true,
      deliveredArtifacts: const ['test/feature_test.dart'],
    );
    expect(completed.isComplete, isTrue);
    expect(completed.deliveredArtifacts, [
      'requirements.md',
      'lib/feature.dart',
      'test/feature_test.dart',
    ]);

    final task = AgentTask(
      groupId: 'group:handoff',
      characterId: product.id,
      userRequest: '执行接力',
      workModeTask: true,
    );
    WorkHandoffState.persistToTask(task, afterProduct);
    final restored = WorkHandoffState.fromTask(task);
    expect(restored, isNotNull);
    expect(restored!.stageIds, initial.stageIds);
    expect(restored.currentRoleId, afterProduct.currentRoleId);
    expect(restored.receivingRoleId, afterProduct.receivingRoleId);
    expect(restored.deliveredArtifacts, ['requirements.md']);
    expect(task.assignedCharacterIds, [product.id, developer.id, tester.id]);
  });
}
