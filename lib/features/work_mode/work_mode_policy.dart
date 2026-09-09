import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/character_skill.dart';
import 'package:chat_group/features/agentic/character_skill_resolver.dart';
import 'package:chat_group/features/agentic/tool_request.dart';

/// Pure policy boundary for explicit work-mode routing and tool consent.
class WorkModePolicy {
  const WorkModePolicy._();

  /// Returns true when a normal-chat request clearly asks the character to
  /// perform local work. This is deliberately a conservative hint: it only
  /// explains how to enter work mode and never enables work mode implicitly.
  static bool looksLikeWorkRequest(String request) {
    final text = request.trim();
    if (text.isEmpty) return false;
    return RegExp(
      r'(写入|修改|创建|生成|读取|打开|查看|分析|审查|修复|实现|运行|执行|测试|构建|编译|部署|提交|脚本|代码|文件|项目|目录|附件|网页|页面|UI|应用|小程序|'
      r'\b(?:read|open|inspect|analy[sz]e|review|fix|implement|write|create|generate|edit|run|execute|test|build|compile|deploy|commit|script|code|file|project|directory|ui|app)\b)',
      caseSensitive: false,
    ).hasMatch(text);
  }

  static const String workModeHint =
      '这条请求需要读取或修改工作区。请先点击聊天顶部的“工作模式”按钮，开启后我才能以职业身份读取代码、写文件、运行验证或生成项目。';

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
已启用 Skill IDs：${character.skillIds.isEmpty ? '无' : character.skillIds.join(', ')}

内置技能发现入口：meta.find-skills。角色已安装/绑定的 Skill 全部启用并注入；全局技能目录按当前任务按需发现。若现有能力不足，先用该入口查找并通过 skill.download 安装匹配模板，确实没有匹配项才创建新技能。

你正处于显式工作模式。本轮输入是工作指令或对之前任务的补充，不得改走普通闲聊。
必须选择并遵循与任务相关的已注入 SKILL；只有在现有技能确实不足时才创建或安装新技能。
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
    for (final skill in defaults) {
      byIdentity[skill.id] = skill;
    }
    for (final skill in installedSkills) {
      if (!skill.isGlobal &&
          skill.characterId != character.id &&
          !character.skillIds.contains(skill.id)) {
        continue;
      }
      // A role explicitly binds these skills, so their complete bodies are
      // always active. Global skills remain lazy to keep a large shared
      // library out of every prompt until the task asks for one.
      if (character.skillIds.contains(skill.id) ||
          _matchesRequest(skill, userRequest)) {
        byIdentity[skill.id] = skill;
      }
    }
    return byIdentity.values.toList(growable: false);
  }

  /// Returns metadata for every skill the role may discover. Instructions are
  /// deliberately omitted by callers so a large skill library never consumes
  /// the model context before a task asks for it.
  static List<CharacterSkill> discoverableSkills({
    required AICharacter character,
    required Iterable<CharacterSkill> installedSkills,
    Iterable<CharacterSkill>? resolvedSkills,
  }) {
    final byIdentity = <String, CharacterSkill>{};
    for (final skill in resolvedSkills ?? const <CharacterSkill>[]) {
      byIdentity[skill.id] = skill;
    }
    for (final skill in installedSkills) {
      if (skill.isGlobal ||
          skill.characterId == character.id ||
          character.skillIds.contains(skill.id)) {
        byIdentity[skill.id] = skill;
      }
    }
    return byIdentity.values.toList(growable: false);
  }

  static bool _matchesRequest(CharacterSkill skill, String request) {
    final normalizedRequest = request.toLowerCase();
    final corpus = [
      skill.id,
      skill.name,
      skill.domain,
      skill.description,
      ...skill.instructions,
    ].join(' ').toLowerCase();
    final asciiTokens = RegExp(r'[a-z0-9][a-z0-9._-]{2,}', caseSensitive: false)
        .allMatches(normalizedRequest)
        .map((match) => match.group(0)!)
        .toSet();
    if (asciiTokens.any(corpus.contains)) return true;
    // Only compare actual CJK bigrams. Scanning every adjacent character in a
    // mixed Chinese/ASCII request would make an unrelated skill match on
    // incidental pairs such as the `al` inside "installed".
    final chineseBigrams = RegExp(r'[\u3400-\u9fff]{2}')
        .allMatches(normalizedRequest.replaceAll(RegExp(r'\s+'), ''))
        .map((match) => match.group(0)!)
        .toSet();
    return chineseBigrams.any(corpus.contains);
  }
}
