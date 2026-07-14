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
          WorkModePolicy.requiresApproval(AgentToolName.skillCreate), isFalse);
      expect(WorkModePolicy.requiresApproval(AgentToolName.skillDownload),
          isFalse);
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

    test('planning context contains role, memory, and installed skills', () {
      final character = _character(id: 'worker')
        ..role = '产品经理'
        ..memorySummary = '用户偏好简洁周报'
        ..skillIds = const ['weekly-report'];

      final context = WorkModePolicy.planningContext(character);

      expect(context, contains('产品经理'));
      expect(context, contains('用户偏好简洁周报'));
      expect(context, contains('weekly-report'));
      expect(context, contains('工作区读取'));
    });

    test('resolved work skills include every installed character skill', () {
      final character = _character(id: 'worker')
        ..skillIds = const ['installed-a', 'installed-b'];
      final installed = [
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
        userRequest: '继续上一轮工作',
        installedSkills: installed,
      );

      expect(skills.map((item) => item.id),
          containsAll(['installed-a', 'installed-b']));
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
