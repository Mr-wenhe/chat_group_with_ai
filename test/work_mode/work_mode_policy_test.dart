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
      expect(WorkModePolicy.looksLikeWorkRequest('帮我闲聊一下今天的天气'), isFalse);
      expect(WorkModePolicy.workModeHint, contains('工作模式'));
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
