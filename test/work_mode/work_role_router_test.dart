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

  test(
      'HTML deliverable keeps frontend qualification despite requirements context',
      () async {
    final front = _character('front', '前端', '前端工程师');
    for (final request in ['根据需求做一个 HTML 网页', '根据需求，最终由 @前端 生成 HTML 网页']) {
      final result = await router.route(
          request: request,
          conversationId: 'html-context',
          characters: [product, front]);
      expect(result.deliverableContract?.format, 'html');
      if (request.contains('@')) {
        expect(result.characterId, front.id);
      } else {
        expect(result.candidateCharacterIds, [front.id]);
      }
    }
  });

  test('unknown longer Chinese executor is never shortened to a known role',
      () async {
    final result = await router.route(
        request: '最终由 @王明明 出具 Word 文档',
        conversationId: 'unknown-long-name',
        characters: [_character('wang', '王明', '产品经理')]);
    expect(result.isSuccess, isFalse);
    expect(result.characterId, isNull);
    expect(result.publicReason, contains('王明明'));
  });

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

  test('new route contracts start at revision one by default', () async {
    final result = await router.route(
      request: '@all 讨论并确定最终方案',
      conversationId: 'group:default-revision',
      characters: characters,
      skills: skills,
    );

    expect(result.deliverableContract?.requestRevision, 1);
  });

  test('standalone deliverable contracts use the first request revision', () {
    const contract = WorkDeliverableContract(
      deliverableType: 'document',
      format: 'docx',
      location: 'desktop',
      contentScope: '需求文档',
    );

    expect(contract.requestRevision, 1);
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

  test('@all is a discussion audience while the final @ role owns execution',
      () async {
    final result = await router.route(
      request: '@all 讨论 HTML 游戏需求，最后由@小产输出一份 Word 文档，保存到桌面',
      conversationId: 'group:all-final-owner',
      characters: characters,
      skills: skills,
    );

    expect(result.isSuccess, isTrue);
    expect(result.characterId, product.id);
    expect(result.source, WorkRoleRouteSource.explicitMention);
    expect(result.deliverableContract?.format, 'docx');
    expect(result.deliverableContract?.location, 'desktop');
    expect(result.deliverableContract?.explicitExecutorId, product.id);
    expect(result.stages.map((stage) => stage.id), ['product']);
    expect(result.discussionCharacterIds,
        characters.map((item) => item.id).toList());
    expect(result.publicReason, contains('小产'));
  });

  test('consultation stays advisory while the final delegation is preserved',
      () async {
    final result = await router.route(
      request: '@小开评估 HTML 是否可行，最后由@小产输出 Word 需求文档',
      conversationId: 'group:consultation-final-owner',
      characters: characters,
      skills: skills,
    );

    expect(result.isSuccess, isTrue);
    expect(result.characterId, product.id);
    expect(result.consultedCharacterIds, [developer.id]);
    expect(result.discussionCharacterIds, [developer.id]);
    expect(result.deliverableContract?.explicitExecutorId, product.id);
    expect(result.stages.map((stage) => stage.id), ['product']);
  });

  test('a consultation mention without delegation waits for group selection',
      () async {
    final result = await router.route(
      request: '@小开这个方案能实现吗',
      conversationId: 'group:consultation-only',
      characters: characters,
      skills: skills,
    );

    expect(result.isSuccess, isFalse);
    expect(result.source, WorkRoleRouteSource.candidateSelection);
    expect(result.characterId, isNull);
    expect(result.consultedCharacterIds, [developer.id]);
    expect(result.discussionCharacterIds, [developer.id]);
  });

  test('@all without a final owner waits while exposing the discussion group',
      () async {
    final result = await router.route(
      request: '@all 讨论这个方案',
      conversationId: 'group:all-discussion-only',
      characters: characters,
      skills: skills,
    );

    expect(result.isSuccess, isFalse);
    expect(result.source, WorkRoleRouteSource.candidateSelection);
    expect(result.discussionCharacterIds,
        characters.map((item) => item.id).toList());
    expect(result.deliverableContract?.explicitExecutorId, isNull);
  });

  test('ambiguous final delegation waits for clarification', () async {
    final result = await router.route(
      request: '@all 讨论方案，最后由@小产输出，最终由@小开输出',
      conversationId: 'group:ambiguous-final-owner',
      characters: characters,
      skills: skills,
    );

    expect(result.isSuccess, isFalse);
    expect(result.source, WorkRoleRouteSource.explicitMention);
    expect(result.publicReason, contains('多个最终执行人'));
    expect(result.needsMentionClarification, isTrue);
    expect(result.ambiguousExecutorIds, [product.id, developer.id]);
    expect(result.deliverableContract, isNotNull);
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
    expect(result.needsMentionClarification, isTrue);
    expect(result.ambiguousMentionNames, ['小开']);
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
    expect(result.needsMentionClarification, isTrue);
    expect(result.unknownMentionNames, ['不存在']);
  });

  test(
      'returns qualified candidates instead of silently choosing the first role',
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

    for (final result in [productResult, codingResult, testingResult]) {
      expect(result.characterId, isNull);
      expect(result.source, WorkRoleRouteSource.candidateSelection);
      expect(result.needsExecutorSelection, isTrue);
      expect(result.publicReason, contains('候选角色'));
    }
    expect(productResult.candidateCharacterIds, [product.id]);
    expect(codingResult.candidateCharacterIds, [developer.id]);
    expect(testingResult.candidateCharacterIds, [tester.id]);
  });

  test('routes an attachment-only request with an internal routing label',
      () async {
    final result = await router.route(
      request: '   ',
      hasAttachments: true,
      conversationId: 'group:image-only',
      characters: characters,
      skills: skills,
    );

    expect(result.isSuccess, isFalse);
    expect(result.characterId, isNull);
    expect(result.source, WorkRoleRouteSource.candidateSelection);
    expect(result.needsExecutorSelection, isTrue);
    expect(result.candidateCharacterIds, [product.id, developer.id, tester.id]);
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

  test('pure HTML requires front-end capability and waits when unassigned',
      () async {
    final result = await router.route(
      request: '生成一个 HTML 页面',
      conversationId: 'group:html-candidates',
      characters: characters,
      skills: skills,
    );

    expect(result.isSuccess, isFalse);
    expect(result.needsExecutorSelection, isFalse);
    expect(result.candidateCharacterIds, isEmpty);
    expect(result.publicReason, contains('前端'));
    expect(result.deliverableContract?.format, 'html');
  });

  test('a test role cannot be explicitly assigned to HTML work', () async {
    final result = await router.route(
      request: '@小测 生成一个 HTML 页面',
      conversationId: 'group:html-wrong-owner',
      characters: characters,
      skills: skills,
    );

    expect(result.isSuccess, isFalse);
    expect(result.characterId, isNull);
    expect(result.publicReason, contains('前端'));
    expect(result.publicReason, contains('能力'));
  });

  test('a testing-only role is not an HTML executor candidate', () async {
    final frontend = _character('frontend', '小前', '前端工程师')
      ..systemPrompt = '负责前端 HTML、CSS 和浏览器页面交付';
    final result = await router.route(
      request: '生成一个 HTML 页面并执行回归测试',
      conversationId: 'group:html-with-testing',
      characters: [frontend, tester],
      skills: skills,
    );

    expect(result.needsExecutorSelection, isTrue);
    expect(result.candidateCharacterIds, [frontend.id]);
    expect(result.publicReason, contains('前端'));
  });

  test('configured English front-end duties qualify HTML work', () async {
    final frontend = _character('frontend', 'Web Owner', 'Frontend Engineer')
      ..systemPrompt = 'Owns frontend HTML, CSS and browser UI delivery.';
    final result = await router.route(
      request: '生成一个 HTML 页面',
      conversationId: 'group:html-english-role',
      characters: [frontend],
      skills: const [],
    );

    expect(result.needsExecutorSelection, isTrue);
    expect(result.candidateCharacterIds, [frontend.id]);
    expect(result.deliverableContract?.format, 'html');
  });

  test('a full-stack role qualifies HTML only when front-end duty is explicit',
      () async {
    final fullStack = _character('full-stack', '小全', '全栈工程师')
      ..systemPrompt = '负责后端服务，也负责前端 HTML、CSS 和浏览器交互。';
    final result = await router.route(
      request: '生成一个 HTML 页面',
      conversationId: 'group:html-full-stack',
      characters: [fullStack],
      skills: const [],
    );

    expect(result.needsExecutorSelection, isTrue);
    expect(result.candidateCharacterIds, [fullStack.id]);
  });

  test('a display name or global skill cannot grant front-end qualification',
      () async {
    final impostor = _character('impostor', '前端大师', '项目助理')
      ..personalityTags = const ['frontend'];
    final result = await router.route(
      request: '生成一个 HTML 页面',
      conversationId: 'group:html-name-only',
      characters: [impostor],
      skills: [
        CharacterSkill(
          id: 'global-frontend',
          characterId: '',
          name: 'Frontend helper',
          domain: 'frontend',
          description: 'HTML helper',
          instructions: const ['可处理 HTML'],
          requiredPermissions: const [],
        ),
      ],
    );

    expect(result.isSuccess, isFalse);
    expect(result.candidateCharacterIds, isEmpty);
    expect(result.publicReason, contains('前端'));
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

  test('does not let the short model silently assign an unmentioned worker',
      () async {
    var modelCalled = false;
    final routed = WorkRoleRouter(
      modelSelector: (_) {
        modelCalled = true;
        return const WorkRoleModelDecision(
          characterId: 'developer',
          publicReason: '模型不能代替群内推举。',
          confidence: 1,
          needsHandoff: false,
        );
      },
    );
    final result = await routed.route(
      request: '请写一份产品需求文档',
      conversationId: 'group:model',
      characters: characters,
      skills: skills,
    );

    expect(result.isSuccess, isFalse);
    expect(result.source, WorkRoleRouteSource.candidateSelection);
    expect(result.candidateCharacterIds, [product.id]);
    expect(result.needsExecutorSelection, isTrue);
    expect(modelCalled, isTrue);
    expect(result.publicReason, contains('资格'));
  });

  test('accepts only a locally qualified model recommendation as a candidate',
      () async {
    final routed = WorkRoleRouter(
      modelSelector: (_) => const WorkRoleModelDecision(
        characterId: 'product',
        publicReason: '配置职业与需求整理职责匹配。',
        confidence: 0.99,
        needsHandoff: false,
      ),
    );
    final result = await routed.route(
      request: '请写一份产品需求文档',
      conversationId: 'group:model-qualified-candidate',
      characters: characters,
      skills: skills,
    );

    expect(result.isSuccess, isFalse);
    expect(result.characterId, isNull);
    expect(result.candidateCharacterIds, [product.id]);
    expect(result.publicReason, contains('仍需群内推举'));
  });

  test('malformed model recommendation keeps local candidates pending',
      () async {
    final routed = WorkRoleRouter(
      modelSelector: (_) => <String, dynamic>{'analysis': 'ignored'},
    );
    final result = await routed.route(
      request: '请写一份产品需求文档',
      conversationId: 'group:model-malformed-candidate',
      characters: characters,
      skills: skills,
    );

    expect(result.isSuccess, isFalse);
    expect(result.candidateCharacterIds, [product.id]);
    expect(result.publicReason, contains('格式无效'));
  });

  test('explicit final owner carries a Word contract and request revision',
      () async {
    final result = await router.route(
      request: '@all 讨论 HTML 游戏需求，最后由@小产输出一份 Word 文档，保存到桌面',
      conversationId: 'group:router-fallback',
      requestRevision: 7,
      characters: characters,
      skills: skills,
    );

    expect(result.isSuccess, isTrue);
    expect(result.characterId, product.id);
    expect(result.source, WorkRoleRouteSource.explicitMention);
    expect(result.deliverableContract?.deliverableType, 'document');
    expect(result.deliverableContract?.format, 'docx');
    expect(result.deliverableContract?.location, 'desktop');
    expect(result.deliverableContract?.explicitExecutorId, product.id);
    expect(result.deliverableContract?.requestRevision, 7);
  });

  test('contract preserves an explicit revision target', () async {
    final result = await router.route(
      request: '@小产 修改桌面的 report.docx，继续完善需求文档',
      conversationId: 'group:revision-contract',
      requestRevision: 3,
      characters: characters,
      skills: skills,
    );

    expect(result.isSuccess, isTrue);
    expect(result.deliverableContract?.format, 'docx');
    expect(result.deliverableContract?.location, 'report.docx');
    expect(result.deliverableContract?.revisionTarget, 'report.docx');
    expect(result.deliverableContract?.isRevision, isTrue);
  });

  test('Word conversion source path does not become the final DOCX location',
      () async {
    final result = await router.route(
      request: '把 proposal.md 转换成 Word 并保存到桌面',
      conversationId: 'group:word-source-conversion',
      characters: [product],
      skills: skills,
    );

    expect(result.deliverableContract?.format, 'docx');
    expect(result.deliverableContract?.location, 'desktop');
    expect(result.deliverableContract?.revisionTarget, isEmpty);

    final explicitOutput = await router.route(
      request: '把 input.txt 转换成 report.docx 并保存',
      conversationId: 'group:word-explicit-output',
      characters: [product],
      skills: skills,
    );
    expect(explicitOutput.deliverableContract?.format, 'docx');
    expect(explicitOutput.deliverableContract?.location, 'report.docx');

    final absoluteOutput = await router.route(
      request: '生成 Word 文档并保存到 /tmp/report.docx',
      conversationId: 'group:word-absolute-output',
      characters: [product],
      skills: skills,
    );
    expect(absoluteOutput.deliverableContract?.format, 'docx');
    expect(absoluteOutput.deliverableContract?.location, '/tmp/report.docx');

    final chinesePath = await router.route(
      request: '生成 Word 文档并保存到桌面/需求文档.docx',
      conversationId: 'group:word-chinese-output',
      characters: [product],
      skills: skills,
    );
    expect(chinesePath.deliverableContract?.format, 'docx');
    expect(
      chinesePath.deliverableContract?.location,
      '需求文档.docx',
    );
  });

  test(
      'unknown or malformed model output cannot change explicit route semantics',
      () async {
    final routed = WorkRoleRouter(
      modelSelector: (_) => <String, dynamic>{'analysis': 'ignored'},
    );
    final result = await routed.route(
      request: '@小开 实现功能',
      conversationId: 'group:model-invalid',
      characters: characters,
      skills: skills,
    );

    expect(result.isSuccess, isTrue);
    expect(result.characterId, developer.id);
    expect(result.source, WorkRoleRouteSource.explicitMention);
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

  test('handoff failures preserve the deliverable contract for discussion',
      () async {
    final initial = await router.route(
      request: '@小产 输出一份 Word 需求文档到桌面',
      conversationId: 'group:handoff-contract-failure',
      characters: characters,
      skills: skills,
    );
    expect(initial.handoffState, isNotNull);

    final originalState = initial.handoffState!;
    final invalidReceiver = WorkHandoffState(
      conversationId: originalState.conversationId,
      stages: [
        WorkHandoffStage(
          id: originalState.currentStage.id,
          label: originalState.currentStage.label,
          roleId: 'missing-role',
          deliverables: originalState.currentStage.deliverables,
          completionCriteria: originalState.currentStage.completionCriteria,
        ),
      ],
      deliveredArtifacts: originalState.deliveredArtifacts,
      status: originalState.status,
      lastSummary: originalState.lastSummary,
    );
    final result = await router.route(
      request: '继续执行 Word 需求文档到桌面',
      conversationId: 'group:handoff-contract-failure',
      handoff: invalidReceiver,
      characters: characters,
      skills: skills,
    );

    expect(result.isSuccess, isFalse);
    expect(result.source, WorkRoleRouteSource.handoff);
    expect(result.deliverableContract?.format, 'docx');
    expect(result.deliverableContract?.location, 'desktop');
    expect(result.deliverableContract?.requestRevision, 1);
  });

  test('creates and persists product to developer to tester handoff', () async {
    final result = await router.route(
      request: '@小产 先写需求文档，再由@小开实现代码，最后由@小测执行测试',
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
    expect(handoffRoute.deliverableContract?.explicitExecutorId, developer.id);
    expect(handoffRoute.deliverableContract?.requestRevision, 1);

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
