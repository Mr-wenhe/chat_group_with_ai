import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/character_skill.dart';
import 'package:chat_group/features/agentic/tool_request.dart';
import 'package:chat_group/features/work_mode/work_mode_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WorkModePolicy', () {
    test('routes user messages only when the explicit conversation mode is on',
        () {
      final character = _character(id: 'worker');

      expect(
        WorkModePolicy.shouldRun(
          enabled: false,
          character: character,
          userRequest: '生成一个文件',
        ),
        isFalse,
      );
      expect(
        WorkModePolicy.shouldRun(
          enabled: true,
          character: character,
          userRequest: '继续',
        ),
        isTrue,
      );
      expect(
        WorkModePolicy.shouldRun(
          enabled: true,
          character: character,
          userRequest: '   ',
        ),
        isFalse,
      );
      expect(
        WorkModePolicy.shouldRun(
          enabled: true,
          character: character,
          userRequest: '   ',
          hasAttachments: true,
        ),
        isTrue,
      );
    });

    test('does not run for a character without agentic capability', () {
      final character = _character(id: 'chat-only')..agenticEnabled = false;

      expect(
        WorkModePolicy.shouldRun(
          enabled: true,
          character: character,
          userRequest: '整理周报',
        ),
        isFalse,
      );
    });

    test('detects work intent without enabling work mode', () {
      expect(WorkModePolicy.looksLikeWorkRequest('请修改 lib/main.dart'), isTrue);
      expect(WorkModePolicy.looksLikeWorkRequest('请优化当前 HTML 页面'), isTrue);
      expect(WorkModePolicy.looksLikeWorkRequest('帮我闲聊一下今天的天气'), isFalse);
      expect(WorkModePolicy.workModeHint, contains('工作模式'));
    });

    test('continuation wording uses one shared predicate', () {
      for (final text in ['继续', '请继续。', '重试', '接着处理', '恢复任务']) {
        expect(WorkModePolicy.looksLikeWorkContinuation(text), isTrue,
            reason: text);
      }
      for (final text in ['继续写一份报告', '帮我看看这个文件', '']) {
        expect(WorkModePolicy.looksLikeWorkContinuation(text), isFalse,
            reason: text);
      }
    });

    test('closed-mode hint points a running task at the task panel', () {
      expect(WorkModePolicy.chatHintFor(hasActiveTask: false),
          WorkModePolicy.workModeHint);
      expect(
          WorkModePolicy.chatHintFor(hasActiveTask: true), contains('任务面板'));
    });

    test('mode off never routes new input to any historical task', () {
      // 判据只剩开关：请求文本、附件、历史任务都不再参与。这里仍逐个遍历，
      // 一是覆盖曾经影响过路由的那些维度，二是以后有人把隐式路由加回来时
      // 这些断言会先失败。
      for (final request in ['你好', '继续', '请修改当前文件', '']) {
        for (final hasAttachments in [false, true]) {
          expect(
              WorkModePolicy.shouldRouteRequest(enabled: false),
              isFalse,
              reason: '$request $hasAttachments');
          expect(
              WorkModePolicy.shouldRouteRequest(enabled: true),
              isTrue,
              reason: '$request $hasAttachments');
        }
      }
      expect(
          WorkModePolicy.shouldRouteRequest(enabled: false),
          isFalse);
    });

    test('selects mentioned capable worker before the first capable worker',
        () {
      final first = _character(id: 'first');
      final mentioned = _character(id: 'mentioned');

      expect(
        WorkModePolicy.selectExecutor(
          characters: [first, mentioned],
          mentionedIds: const ['mentioned'],
        )?.id,
        'mentioned',
      );
      expect(
        WorkModePolicy.selectExecutor(
          characters: [first, mentioned],
          mentionedIds: const [],
        )?.id,
        'first',
      );
    });

    test('offers a matching character-local draft for its first trial only',
        () {
      final character = _character(id: 'worker');
      final draft = CharacterSkill(
        id: 'draft-flowchart',
        characterId: character.id,
        name: '流程图草稿',
        domain: '流程图',
        description: '绘制流程图并标注分支条件',
        instructions: const ['使用 Mermaid 流程图语法'],
        requiredPermissions: const [],
      );
      final foreignDraft = CharacterSkill(
        id: 'foreign-draft',
        characterId: 'other-worker',
        name: '流程图草稿',
        domain: '流程图',
        description: '绘制流程图并标注分支条件',
        instructions: const ['使用 Mermaid 流程图语法'],
        requiredPermissions: const [],
      );
      final remoteSkill = CharacterSkill(
        id: 'remote-skill',
        characterId: character.id,
        name: '远程流程图技能',
        domain: '流程图',
        description: '绘制流程图并标注分支条件',
        instructions: const ['使用 Mermaid 流程图语法'],
        requiredPermissions: const [],
        resourcePackId: 'unverified-pack',
      );

      final matching = WorkModePolicy.resolveSkills(
        character: character,
        userRequest: '请绘制流程图',
        installedSkills: [draft, foreignDraft, remoteSkill],
      );
      final unrelated = WorkModePolicy.resolveSkills(
        character: character,
        userRequest: '请整理会议纪要',
        installedSkills: [draft],
      );

      expect(matching.map((skill) => skill.id), contains(draft.id));
      expect(
          matching.map((skill) => skill.id), isNot(contains(foreignDraft.id)));
      expect(
          matching.map((skill) => skill.id), isNot(contains(remoteSkill.id)));
      expect(unrelated.map((skill) => skill.id), isNot(contains(draft.id)));
      expect(character.skillIds, isNot(contains(draft.id)));
    });

    test('requires approval for data access and local side effects', () {
      expect(
          WorkModePolicy.requiresApproval(AgentToolName.workspaceList), isTrue);
      expect(
          WorkModePolicy.requiresApproval(AgentToolName.workspaceRead), isTrue);
      expect(WorkModePolicy.requiresApproval(AgentToolName.workspacePatch),
          isTrue);
      expect(WorkModePolicy.requiresApproval(AgentToolName.commandRun), isTrue);
      expect(WorkModePolicy.requiresApproval(AgentToolName.browserContext),
          isTrue);
      expect(
          WorkModePolicy.requiresApproval(AgentToolName.skillCreate), isTrue);
      expect(
          WorkModePolicy.requiresApproval(AgentToolName.skillDownload), isTrue);
    });

    test('approval summary names the exact affected path or command', () {
      expect(
        WorkModePolicy.approvalSummary(const ToolRequest(
          tool: AgentToolName.workspacePatch,
          reason: '生成报告',
          args: {'path': 'reports/week.md', 'content': 'secret body'},
        )),
        allOf(contains('reports/week.md'), isNot(contains('secret body'))),
      );
      expect(
        WorkModePolicy.approvalSummary(const ToolRequest(
          tool: AgentToolName.commandRun,
          reason: '验证产物',
          args: {'command': 'flutter test'},
        )),
        contains('flutter test'),
      );
    });

    test('planning context contains role and installed skills', () {
      final character = _character(id: 'worker')
        ..role = '产品经理'
        ..skillIds = const ['weekly-report'];

      final context = WorkModePolicy.planningContext(character);

      expect(context, contains('产品经理'));
      expect(context, contains(character.promptIdentity));
      expect(context, contains('weekly-report'));
      expect(context, contains('工作区读取'));
      expect(context, contains('meta.find-skills'));
      // memorySummary is no longer injected; global memory is provided by MemoryContextSelector.
      expect(context, isNot(contains('用户偏好简洁周报')));
    });

    test('injects all role-bound skill bodies and exposes all metadata', () {
      final character = _character(id: 'worker')
        ..skillIds = const ['installed-a', 'installed-b'];
      final installed = [
        CharacterSkill(
          id: 'global-skill',
          characterId: '',
          name: 'Global skill',
          domain: 'general',
          description: 'Available to every role',
          instructions: const ['Global instruction'],
          requiredPermissions: const [],
        ),
        CharacterSkill(
          id: 'installed-a',
          characterId: character.id,
          name: 'Same name',
          domain: 'custom',
          description: 'A',
          instructions: const ['A'],
          requiredPermissions: const [],
        ),
        CharacterSkill(
          id: 'installed-b',
          characterId: character.id,
          name: 'Same name',
          domain: 'custom',
          description: 'B',
          instructions: const ['B'],
          requiredPermissions: const [],
        ),
      ];

      final skills = WorkModePolicy.resolveSkills(
        character: character,
        userRequest: '请使用 global-skill 的 Global instruction',
        installedSkills: installed,
      );

      expect(skills.map((item) => item.id), contains('global-skill'));
      expect(
        skills.map((item) => item.id),
        containsAll(['installed-a', 'installed-b']),
      );

      final discoverable = WorkModePolicy.discoverableSkills(
        character: character,
        installedSkills: installed,
        resolvedSkills: [
          CharacterSkill(
            id: 'profession-default',
            characterId: character.id,
            name: '职业默认能力',
            domain: 'general',
            description: '角色默认技能元数据',
            instructions: const ['只用于元数据测试'],
            requiredPermissions: const [],
          ),
        ],
      );
      expect(
          discoverable.map((item) => item.id),
          containsAll([
            'global-skill',
            'installed-a',
            'installed-b',
            'profession-default',
          ]));
    });
  });
}

AICharacter _character({required String id}) => AICharacter(
      id: id,
      name: id,
      avatar: '🤖',
      age: 20,
      role: '助理',
      personalityTags: const [],
      systemPrompt: '完成用户交付任务',
      apiKey: 'key',
      apiProvider: 'deepseek',
    )..agenticEnabled = true;
