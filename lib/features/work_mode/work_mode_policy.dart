import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/character_skill.dart';
import 'package:chat_group/features/agentic/character_skill_resolver.dart';
import 'package:chat_group/features/agentic/tool_request.dart';

/// Pure policy boundary for explicit work-mode routing and tool consent.
class WorkModePolicy {
  const WorkModePolicy._();

  /// Durable label used when a user sends an attachment without text.
  ///
  /// The label is internal routing context; the original message remains the
  /// source of truth for the attachment payload.
  static const String attachmentOnlyRequest = '请分析刚刚发送的附件。';

  static bool shouldRun({
    required bool enabled,
    required AICharacter character,
    required String userRequest,
    bool hasAttachments = false,
  }) {
    // ponytail: an attachment-only request is actionable even without text.
    return enabled &&
        character.agenticEnabled &&
        (userRequest.trim().isNotEmpty || hasAttachments);
  }

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

  /// Conservative default used by callers that do not have the app-wide
  /// folder-grant context. The production work-mode runner overrides ordinary
  /// reads/searches per request once a grant has been verified; keeping this
  /// default strict preserves the old approval boundary for standalone users.
  static bool requiresApproval(AgentToolName tool) => switch (tool) {
        AgentToolName.workspaceList ||
        AgentToolName.workspaceRead ||
        AgentToolName.workspaceSearch ||
        AgentToolName.workspaceDocument =>
          true,
        AgentToolName.workspacePatch ||
        AgentToolName.workspaceRename ||
        AgentToolName.workspaceDelete ||
        AgentToolName.commandRun ||
        AgentToolName.browserContext ||
        AgentToolName.skillCreate ||
        AgentToolName.skillDownload =>
          true,
      };

  static String approvalSummary(ToolRequest request) => switch (request.tool) {
        AgentToolName.workspaceList => '列出目录：${request.args['path'] ?? '.'}',
        AgentToolName.workspaceRead => '读取文件：${request.args['path'] ?? ''}',
        AgentToolName.workspaceSearch => '搜索路径：${request.args['path'] ?? '.'}',
        AgentToolName.workspaceDocument =>
          '读取并分析文档：${request.args['path'] ?? ''}',
        AgentToolName.workspacePatch => '写入文件：${request.args['path'] ?? ''}',
        AgentToolName.workspaceRename => '重命名文件：${request.args['path'] ?? ''}',
        AgentToolName.workspaceDelete => '删除文件：${request.args['path'] ?? ''}',
        AgentToolName.commandRun =>
          '执行命令：${request.args['executable'] ?? request.args['command'] ?? ''}',
        AgentToolName.browserContext => '读取当前浏览器页面上下文',
        AgentToolName.skillCreate => '创建应用内技能元数据',
        AgentToolName.skillDownload => '安装应用内技能模板',
      };

  static String planningContext(AICharacter character) => '''
【工作模式】
角色职责：${character.role}
角色设定：${character.rolePlaySystemPrompt}
已安装 Skill IDs：${character.skillIds.isEmpty ? '无' : character.skillIds.join(', ')}

你正处于显式工作模式。本轮输入是工作指令或对之前任务的补充，不得改走普通闲聊。
必须选择并遵循至少一个已注入的 SKILL；只有在现有技能确实不足时才创建或安装新技能。
如果任务需要可交付文件，必须通过 workspace.patch 生成完整文件并在获得用户写入批准后执行。
普通工作区读取/搜索/文档分析会在既有目录授权内自动执行；敏感读取、写入、删除、重命名、浏览器上下文和命令执行会由应用暂停并请求用户确认；不得尝试绕过。
图片只发送给当前角色已声明支持视觉的模型；不支持时必须暂停并让用户选择已配置的视觉模型，应用不会自动切换。音频和视频在当前版本明确不支持，也不安装转码服务。
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
