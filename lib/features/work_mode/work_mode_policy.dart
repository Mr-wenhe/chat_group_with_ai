import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/character_skill.dart';
import 'package:chat_group/features/agentic/character_skill_resolver.dart';
import 'package:chat_group/features/agentic/tool_request.dart';

/// Pure policy boundary for explicit work-mode routing and tool consent.
class WorkModePolicy {
  const WorkModePolicy._();

  static bool shouldRun({
    required bool enabled,
    required AICharacter character,
    required String userRequest,
  }) =>
      enabled && character.agenticEnabled && userRequest.trim().isNotEmpty;

  /// Deterministic group ownership: an explicitly mentioned capable member
  /// wins; otherwise the first active capable member owns the work item.
  static AICharacter? selectExecutor({
    required List<AICharacter> characters,
    required List<String> mentionedIds,
  }) {
    bool capable(AICharacter value) => value.isActive && value.agenticEnabled;
    for (final id in mentionedIds) {
      for (final character in characters) {
        if (character.id == id && capable(character)) return character;
      }
    }
    for (final character in characters) {
      if (capable(character)) return character;
    }
    return null;
  }

  /// Reading local/browser data and mutating or executing on the host always
  /// needs an explicit decision. Skill metadata operations are sandboxed to
  /// the app database and can proceed without a second toggle.
  static bool requiresApproval(AgentToolName tool) => switch (tool) {
        AgentToolName.workspaceList ||
        AgentToolName.workspaceRead ||
        AgentToolName.workspacePatch ||
        AgentToolName.commandRun ||
        AgentToolName.browserContext =>
          true,
        AgentToolName.skillCreate || AgentToolName.skillDownload => false,
      };

  static String approvalSummary(ToolRequest request) => switch (request.tool) {
        AgentToolName.workspaceList => '列出目录：${request.args['path'] ?? '.'}',
        AgentToolName.workspaceRead => '读取文件：${request.args['path'] ?? ''}',
        AgentToolName.workspacePatch => '写入文件：${request.args['path'] ?? ''}',
        AgentToolName.commandRun => '执行命令：${request.args['command'] ?? ''}',
        AgentToolName.browserContext => '读取当前浏览器页面上下文',
        AgentToolName.skillCreate => '创建应用内技能元数据',
        AgentToolName.skillDownload => '安装应用内技能模板',
      };

  static String planningContext(AICharacter character) => '''
【工作模式】
角色职责：${character.role}
角色设定：${character.systemPrompt}
已安装 Skill IDs：${character.skillIds.isEmpty ? '无' : character.skillIds.join(', ')}

你正处于显式工作模式。本轮输入是工作指令或对之前任务的补充，不得改走普通闲聊。
必须选择并遵循至少一个已注入的 SKILL；只有在现有技能确实不足时才创建或安装新技能。
如果任务需要可交付文件，必须通过 workspace.patch 生成完整文件并在获得用户写入批准后执行。
工作区读取、浏览器上下文、文件写入和命令执行均会由应用暂停并请求用户确认；不得尝试绕过。
''';

  static List<CharacterSkill> resolveSkills({
    required AICharacter character,
    required String userRequest,
    required Iterable<CharacterSkill> installedSkills,
    Iterable<CharacterSkill>? resolvedSkills,
  }) {
    final defaults = resolvedSkills ??
        CharacterSkillResolver.resolveFor(character, userRequest).skills;
    final byIdentity = <String, CharacterSkill>{};
    for (final skill in [...defaults, ...installedSkills]) {
      if (skill.characterId == character.id ||
          character.skillIds.contains(skill.id)) {
        byIdentity[skill.id] = skill;
      }
    }
    return byIdentity.values.toList(growable: false);
  }
}
