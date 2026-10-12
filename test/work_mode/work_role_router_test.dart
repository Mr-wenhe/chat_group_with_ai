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

  test('Markdown references do not suppress HTML implementation routing',
      () async {
    final front = _character('front', '小前', '前端工程师');
    final result = await router.route(
      request:
          'Read the Dou Dizhu design Markdown as input. Product Manager defines rules; the front-end developer creates a playable HTML page, then a tester tests that page and writes a Markdown report.',
      conversationId: 'group:markdown-html-test',
      characters: [product, front, tester],
      skills: skills,
    );

    expect(result.deliverableContract?.format, 'html');
    expect(result.candidateCharacterIds, [front.id]);
    expect(result.publicReason, contains('前端'));
  });

  test('生成式软件请求也要拉起测试阶段，不能只剩一个前端自签', () {
    final front = _character('front', '小前', '前端工程师');
    final result = WorkRoleRouter.selectTeam(
      request: '在\n/Users/fengye/Desktop/chat_group_out 这个文件家中 创建一个目录，'
          '目录中的内容生成一份 飞行棋游戏的HTML，第一版只需要和AI对战即可',
      characters: [product, front, tester],
      skills: [
        _skill('front-skill', front.id, 'frontend'),
        _skill('testing-skill', tester.id, 'testing'),
      ],
    );
    final roles = result.team.map((m) => m['role']).toList();

    // 「生成/创建」曾经不在动词表里，requestsSoftwareImplementation 判 false，
    // selectTeam 就不追加 testing 阶段：整队只剩前端一人，讨论退化为自提案自签字。
    expect(roles, contains('frontend'));
    expect(roles, contains('testing'));
  });

  test('QA of an existing HTML file routes to testing and the report output',
      () async {
    final front = _character('front', '小前', '前端工程师');
    final result = await router.route(
      request:
          'Test the App-generated attachment Desktop/doudizhu_game.html against Desktop/doudizhu_design.md. The product manager coordinates only; the testing engineer executes cases and creates and attaches Desktop/doudizhu_test_report.md. If QA finds defects, only then fix the same Desktop/doudizhu_game.html and attach the revised version.',
      conversationId: 'group:existing-html-qa',
      characters: [product, front, tester],
      skills: skills,
    );

    expect(result.deliverableContract?.format, 'markdown');
    expect(result.deliverableContract?.location, 'doudizhu_test_report.md');
    expect(result.candidateCharacterIds, [tester.id]);
    expect(
      WorkRoleRouter.startsWithTestingStage(
        'Test existing Desktop/doudizhu_game.html and create '
        'Desktop/doudizhu_test_report.md.',
      ),
      isTrue,
    );
    expect(
      WorkRoleRouter.startsWithTestingStage(
        'Create a playable HTML game, then let a tester validate it.',
      ),
      isFalse,
    );
  });

  test('a QA-only continuation treats its HTML attachment as input', () async {
    final front = _character('front', '小前', '前端工程师');
    final result = await router.route(
      request:
          'Continue testing the attached Desktop/doudizhu_game.html; do not modify it.',
      conversationId: 'group:qa-html-input-only',
      characters: [front, tester],
      skills: skills,
    );

    expect(result.deliverableContract?.format, 'unspecified');
    expect(result.candidateCharacterIds, [tester.id]);
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

  test('模型推荐缺少理由时仍作为首位候选，不再整条作废', () async {
    final p1 = _character('p1', '产品甲', '产品经理');
    final p2 = _character('p2', '产品乙', '产品经理');
    final routed = WorkRoleRouter(
      modelSelector: (_) => const WorkRoleModelDecision(
        characterId: 'p2',
        publicReason: '',
        confidence: 0.8,
        needsHandoff: false,
      ),
    );
    final result = await routed.route(
      request: '整理一份产品需求文档',
      conversationId: 'group:optional-reason',
      characters: [p1, p2],
      skills: [
        _skill('p1-skill', p1.id, 'product'),
        _skill('p2-skill', p2.id, 'product'),
      ],
    );

    // 解析层允许缺理由（它是唯一会长到撑破输出上限的字段），路由器必须认同同一份
    // 契约：整条拒绝会把一条完全可用的推荐丢掉，用户只看到"缺少可展示依据"，而
    // 实际推荐的角色根本没进候选顺序。
    expect(result.candidateCharacterIds.first, 'p2');
    expect(result.publicReason, contains('产品乙'));
    expect(result.publicReason, isNot(contains('缺少可展示依据')));
    expect(result.publicReason, isNot(contains('（）')),
        reason: '缺理由时不能写出空括号');
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

  test('pure HTML 没有实现人时仍报前端缺口，有开发则作为候选列出', () async {
    final noImplementer = await router.route(
      request: '生成一个 HTML 页面',
      conversationId: 'group:html-no-implementer',
      characters: [product, tester],
      skills: skills,
    );

    expect(noImplementer.isSuccess, isFalse);
    expect(noImplementer.needsExecutorSelection, isFalse);
    expect(noImplementer.candidateCharacterIds, isEmpty);
    expect(noImplementer.publicReason, contains('前端'));

    // 前端与开发是同一个实现阶段的两个别名，所以通用开发是合格候选；但自动选人
    // （selectTeam）仍只认明确的前端职责，不静默把界面派给不做界面的人。
    final withDeveloper = await router.route(
      request: '生成一个 HTML 页面',
      conversationId: 'group:html-candidates',
      characters: characters,
      skills: skills,
    );

    expect(withDeveloper.candidateCharacterIds, [developer.id]);
    expect(withDeveloper.deliverableContract?.format, 'html');
  });

  test('候选推举的公开说明给出"无需操作"与真的可用出口', () async {
    final front = _character('front', '小前', '前端工程师');
    final result = await router.route(
      request: '生成一个 HTML 页面',
      conversationId: 'group:html-nominate',
      characters: [front, tester],
      skills: [
        _skill('front-skill', front.id, 'frontend'),
        _skill('testing-skill', tester.id, 'testing'),
      ],
    );

    // 旧文案「请由群内讨论后推举一位」在描述 App 会自动做的事，却写成了给用户的
    // 指令：用户既不知道要不要回、也不知道从哪推举。
    expect(result.needsExecutorSelection, isTrue);
    expect(result.publicReason, contains('你无需操作'));
    expect(result.publicReason, contains('@'));
    expect(result.publicReason, isNot(contains('请由群内讨论后推举一位')));
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

  test('游戏引擎开发是 HTML 的合格候选，自动选人仍只认前端职责', () async {
    final engine = _character('engine', '周鹏飞', '游戏引擎开发')
      ..systemPrompt = '你是游戏引擎程序员，对渲染管线如数家珍。';
    final result = await router.route(
      request: '生成一个 HTML 页面',
      conversationId: 'group:html-engine',
      characters: [engine],
      skills: const [],
    );

    expect(result.candidateCharacterIds, [engine.id]);
    expect(
        WorkRoleRouter.qualifiesForResponsibility(
            engine, 'frontend', const []),
        isTrue,
        reason: '换人候选列表走的就是这条判据，否则周鹏飞根本进不了候选');

    // 岗位与电脑里的现场：群里只有引擎开发时，v2 的 selectTeam 不会静默把界面
    // 派给他，而是如实报前端缺口让用户定——但候选列表里已经有人可选了。
    final team = WorkRoleRouter.selectTeam(
      request: '生成一个 HTML 页面',
      characters: [engine],
      skills: const [],
    );
    expect(team.team.map((m) => m['role']), isNot(contains('frontend')));
    expect(team.missing.map((kind) => kind.name), contains('frontend'));
  });

  test('前端与引擎开发并存时自动选人仍选前端，引擎开发只是候选', () async {
    final frontend = _character('frontend', '程序媛', '前端工程师')
      ..systemPrompt = '负责前端 HTML、CSS 和浏览器页面交付';
    final engine = _character('engine', '周鹏飞', '游戏引擎开发')
      ..systemPrompt = '你是游戏引擎程序员，对渲染管线如数家珍。';
    // 引擎开发排在前面，仍然不该被自动选中。
    final team = WorkRoleRouter.selectTeam(
      request: '生成一个 HTML 页面',
      characters: [engine, frontend],
      skills: const [],
    );

    expect(team.team.first['memberId'], frontend.id);
    expect(
        WorkRoleRouter.qualifiedCandidatesForRequest(
          request: '生成一个 HTML 页面',
          characters: [engine, frontend],
        ).map((c) => c.id),
        containsAll(<String>[frontend.id, engine.id]));
  });

  test('可以明确 @ 游戏引擎开发做 HTML，不再判成能力不足', () async {
    final engine = _character('engine', '周鹏飞', '游戏引擎开发')
      ..systemPrompt = '你是游戏引擎程序员，对渲染管线如数家珍。';
    final result = await router.route(
      request: '@周鹏飞 生成一个 HTML 页面',
      conversationId: 'group:html-engine-explicit',
      characters: [engine],
      skills: const [],
    );

    expect(result.isSuccess, isTrue);
    expect(result.characterId, engine.id);
  });

  test('英文 QA 不会因 engineer 与 bug 被算成 HTML 实现人', () async {
    final qa = _character('qa', 'QA Owner', 'QA Engineer')
      ..systemPrompt = 'Owns regression testing and bug reports.';
    final result = await router.route(
      request: '生成一个 HTML 页面',
      conversationId: 'group:html-english-qa',
      characters: [qa],
      skills: const [],
    );

    expect(result.candidateCharacterIds, isEmpty);
    expect(result.publicReason, contains('前端'));
  });

  test('中文「测试开发」不会因含「开发」被算成前端实现人', () async {
    // 测试岗常常带一个实现词（测试开发、自动化开发），但他们不写交付物。
    // 只拉黑 engineer/bug 那种做法挡得住英文 QA，挡不住这一类中文复合职称。
    final qaDev = _character('qa-dev', '小测开', '测试开发工程师')
      ..systemPrompt = '负责自动化测试与回归用例开发。';
    final result = await router.route(
      request: '生成一个 HTML 页面',
      conversationId: 'group:html-qa-dev',
      characters: [qaDev],
      skills: const [],
    );

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

  test('model selection failure names its cause instead of one blanket phrase',
      () async {
    final routed = WorkRoleRouter(
      modelSelector: (_) async => throw const WorkRoleModelSelectionException(
        kind: WorkRoleModelFailureKind.truncated,
        outputTokenLimit: 256,
      ),
    );
    final result = await routed.route(
      request: '请写一份产品需求文档',
      conversationId: 'group:model-truncated',
      characters: characters,
      skills: skills,
    );

    expect(result.isSuccess, isFalse);
    // 本地合格候选必须保留：模型那一路失败不该把群内推举也一起取消。
    expect(result.candidateCharacterIds, [product.id]);
    expect(result.needsExecutorSelection, isTrue);
    expect(result.publicReason, contains('截断'));
    expect(result.publicReason, contains('256'));
    expect(result.publicReason, isNot(contains('暂不可用')));
  });

  test('an unclassified selection error still carries a redacted cause',
      () async {
    final routed = WorkRoleRouter(
      modelSelector: (_) async =>
          throw StateError('无法读取 /Users/fengye/keys 下的模型凭据'),
    );
    final result = await routed.route(
      request: '请写一份产品需求文档',
      conversationId: 'group:model-unclassified',
      characters: characters,
      skills: skills,
    );

    expect(result.isSuccess, isFalse);
    expect(result.publicReason, contains('[本地路径]'));
    expect(result.publicReason, isNot(contains('/Users/fengye')));
    expect(result.publicReason, isNot(contains('暂不可用')));
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
