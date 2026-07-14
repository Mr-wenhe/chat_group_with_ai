import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/character_skill.dart';
import 'package:chat_group/core/models/tool_permission.dart';
import 'package:chat_group/features/agentic/expert_skill_catalog.dart';
import 'package:chat_group/features/agentic/skill_download_service.dart';

class CharacterSkillBundle {
  final List<CharacterSkill> skills;
  final List<ToolPermission> permissions;
  final bool needsSkillCreation;
  final String skillCreationHint;

  const CharacterSkillBundle({
    required this.skills,
    required this.permissions,
    this.needsSkillCreation = false,
    this.skillCreationHint = '',
  });
}

class CharacterSkillResolver {
  /// 同时考虑角色职业和当前用户意图，补充本轮最相关的内置技能。
  static CharacterSkillBundle resolveFor(
    AICharacter character,
    String userRequest,
  ) {
    final defaults = defaultsFor(character);
    // 本轮是否缺技能必须只看用户意图；角色文本中的泛词（如“研究咖啡”）
    // 不能把杯测流程误判成浏览器研究。职业默认能力已由 defaultsFor 注入。
    final recommended = ExpertSkillCatalog.recommendForText(userRequest);
    final onlyBuilder = recommended.length == 1 &&
        recommended.first.id == 'general.workbuddy-expert-builder';
    final contextualFollowUp =
        onlyBuilder && _isContextualFollowUp(userRequest);
    final skills = <CharacterSkill>[...defaults.skills];
    final permissions = <ToolPermission>{...defaults.permissions};

    if (!onlyBuilder) {
      for (final template in recommended.take(3)) {
        if (skills.any((skill) => skill.id == template.id)) continue;
        skills.add(template.instantiateFor(character.id));
        permissions.addAll(template.requiredPermissions);
      }
    } else if (!contextualFollowUp) {
      permissions.add(ToolPermission.skillCreate);
    }
    _addIntentPermissions(permissions, userRequest);

    return CharacterSkillBundle(
      skills: skills,
      permissions: permissions.toList(),
      needsSkillCreation: onlyBuilder && !contextualFollowUp,
      skillCreationHint: onlyBuilder && !contextualFollowUp
          ? '没有匹配「${_clipRequest(userRequest)}」的内置技能，建议先调用 skill.create 创建可复用技能。'
          : '',
    );
  }

  static CharacterSkillBundle defaultsFor(AICharacter character) {
    final text = [
      character.name,
      character.role,
      ...character.personalityTags,
      character.systemPrompt,
    ].join(' ').toLowerCase();

    final skills = <CharacterSkill>[_expertSkillManager(character.id)];
    final permissions = <ToolPermission>{
      ToolPermission.skillCreate,
      ToolPermission.skillDownload,
    };

    if (_containsAny(
      text,
      const ['代码', 'code', 'flutter', 'review', 'debug', 'bug'],
    )) {
      skills.addAll(_codingSkills(character.id));
      permissions.addAll(const [
        ToolPermission.workspaceRead,
        ToolPermission.workspacePatch,
        ToolPermission.commandRun,
        ToolPermission.skillCreate,
      ]);
    }

    if (_containsAny(
      text,
      const ['研究', '资料', 'browser', '网页', 'research'],
    )) {
      skills.add(_researchSkill(character.id));
      permissions.addAll(const [
        ToolPermission.browserContext,
        ToolPermission.skillCreate,
      ]);
    }

    if (_containsAny(
      text,
      const ['产品', '需求', 'prd', 'roadmap', '策略', '体验'],
    )) {
      skills.add(_productSkill(character.id));
      permissions.add(ToolPermission.skillCreate);
    }

    if (_containsAny(
      text,
      const ['写作', '文案', '编辑', '邮件', 'copywriting', 'writer'],
    )) {
      skills.add(_writingSkill(character.id));
      permissions.add(ToolPermission.skillCreate);
    }

    if (skills.length == 1) {
      skills.add(_generalSkill(character.id));
    }

    final recommendedTemplates =
        SkillDownloadService.recommendedTemplatesFor(character)
            .take(3)
            .toList();
    if (recommendedTemplates.isNotEmpty) {
      skills.add(_downloadableTemplateSkill(
        character.id,
        recommendedTemplates
            .map((template) => '${template.id} => ${template.name}')
            .toList(),
      ));
    }

    for (final template in recommendedTemplates) {
      for (final permission in template.requiredPermissions) {
        if (permission == ToolPermission.workspaceRead ||
            permission == ToolPermission.browserContext ||
            permission == ToolPermission.skillCreate ||
            permission == ToolPermission.skillDownload) {
          permissions.add(permission);
        }
      }
    }

    return CharacterSkillBundle(
      skills: skills,
      permissions: permissions.toList(),
    );
  }

  static bool _containsAny(String text, List<String> needles) =>
      needles.any(text.contains);

  /// 这些短句依赖对话历史才有完整语义，不是一个新的专业任务。
  /// 把它们交给 AgentRuntime 结合 conversationHistory 处理，避免
  /// “附件呢”之类的追问反复触发 skill.create。
  static bool _isContextualFollowUp(String text) {
    final compact = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (compact.isEmpty || compact.length > 24) return false;
    return RegExp(
      r'^(?:你)?(?:卡了吗|卡住了吗|好了吗|完成了吗|做完了吗)$|'
      r'^(?:附件|文件|结果|交付物)(?:呢|在哪|在哪里|怎么没有|呢？|呢\?)?$|'
      r'^(?:继续|继续吧|接着做|然后呢|进度呢|怎么样了)$',
    ).hasMatch(compact);
  }

  static String _clipRequest(String text) {
    final compact = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    return compact.length <= 48 ? compact : '${compact.substring(0, 48)}…';
  }

  static void _addIntentPermissions(
    Set<ToolPermission> permissions,
    String userRequest,
  ) {
    final lower = userRequest.toLowerCase();
    final needsWorkspace = RegExp(
      r'(文件|路径|文档|代码|脚本|页面|网页|网站|首页|主页|落地页|应用|小程序|'
      r'html?|markdown|\bmd\b|dart|flutter|java|c\+\+|cpp|json|ya?ml|css|javascript|'
      r'\bjs\b|python|\bpy\b|review|修复|bug)',
      caseSensitive: false,
    ).hasMatch(lower);
    if (needsWorkspace) {
      permissions.add(ToolPermission.workspaceRead);
      permissions.add(ToolPermission.workspacePatch);
    }
    final needsCommand = RegExp(
      r'(运行|测试|验证|构建|编译|命令|command|\btest\b|\banalyze\b|\bbuild\b|dart|flutter)',
      caseSensitive: false,
    ).hasMatch(lower);
    if (needsCommand) permissions.add(ToolPermission.commandRun);
  }

  static List<CharacterSkill> _codingSkills(String characterId) => [
        CharacterSkill(
          characterId: characterId,
          name: 'Code Review',
          domain: 'coding',
          description:
              'Review code for bugs, regressions, missing tests, and maintainability.',
          instructions: const [
            'Clarify the target files or diff when the request is ambiguous.',
            'Read the smallest relevant code surface first.',
            'Report findings by severity with file and line references.',
            'Suggest or apply a patch only after the user approves file writes.',
          ],
          requiredPermissions: const [
            ToolPermission.workspaceRead,
            ToolPermission.workspacePatch,
            ToolPermission.commandRun,
          ],
        ),
        CharacterSkill(
          characterId: characterId,
          name: 'Bug Fix',
          domain: 'coding',
          description: 'Reproduce, diagnose, patch, and verify software bugs.',
          instructions: const [
            'Collect error output, reproduction steps, and expected behavior.',
            'Write or identify the narrowest failing test when practical.',
            'Patch the cause instead of hiding symptoms.',
            'Run targeted verification and summarize residual risk.',
          ],
          requiredPermissions: const [
            ToolPermission.workspaceRead,
            ToolPermission.workspacePatch,
            ToolPermission.commandRun,
          ],
        ),
      ];

  static CharacterSkill _expertSkillManager(String characterId) =>
      CharacterSkill(
        characterId: characterId,
        name: 'Workbuddy Expert Skill Manager',
        domain: 'meta',
        description:
            'Create, download, and install profession-specific expert skills when the current skills are not enough.',
        instructions: const [
          'Always check whether the character has a skill that fits the user request.',
          'If a profession-related template exists, request skill.download with a templateId.',
          'If no template fits, request skill.create with a concrete skill JSON draft.',
          'After installing or creating a skill, use it in future similar tasks.',
        ],
        requiredPermissions: const [
          ToolPermission.skillCreate,
          ToolPermission.skillDownload,
        ],
      );

  static CharacterSkill _downloadableTemplateSkill(
    String characterId,
    List<String> templateLines,
  ) =>
      CharacterSkill(
        characterId: characterId,
        name: 'Downloadable Expert Templates',
        domain: 'meta',
        description:
            'Profession-related expert skill templates available for this character.',
        instructions: [
          '可下载模板：${templateLines.join('；')}',
          'Use skill.download with args {"templateId":"模板ID"} when the user needs that expert capability.',
          'Downloading a template installs it as a reusable character skill.',
        ],
        requiredPermissions: const [ToolPermission.skillDownload],
      );

  static CharacterSkill _researchSkill(String characterId) => CharacterSkill(
        characterId: characterId,
        name: 'Browser Research',
        domain: 'research',
        description:
            'Use current browser context to answer questions grounded in the active page.',
        instructions: const [
          'Ask the user to open or select the relevant browser page.',
          'Read URL, title, selected text, and page snapshot through the bridge.',
          'Distinguish page facts from model inference.',
          'Cite the captured URL in the answer.',
        ],
        requiredPermissions: const [ToolPermission.browserContext],
      );

  static CharacterSkill _productSkill(String characterId) => CharacterSkill(
        characterId: characterId,
        name: 'Product Strategy',
        domain: 'product',
        description:
            'Clarify product goals, user jobs, tradeoffs, and executable next steps.',
        instructions: const [
          'Identify the target user and job-to-be-done.',
          'Separate user value, implementation cost, and risk.',
          'Turn fuzzy ideas into a prioritized and testable workflow.',
        ],
        requiredPermissions: const [ToolPermission.skillCreate],
      );

  static CharacterSkill _writingSkill(String characterId) => CharacterSkill(
        characterId: characterId,
        name: 'Writing Partner',
        domain: 'writing',
        description:
            'Draft, critique, and polish writing while preserving the user voice.',
        instructions: const [
          'Ask for audience and intent when they are unclear.',
          'Offer a concrete draft or rewrite instead of abstract advice.',
          'Explain the strongest edits briefly.',
        ],
        requiredPermissions: const [ToolPermission.skillCreate],
      );

  static CharacterSkill _generalSkill(String characterId) => CharacterSkill(
        characterId: characterId,
        name: 'General Workflow Builder',
        domain: 'general',
        description: 'Turn vague requests into reusable character workflows.',
        instructions: const [
          'Restate the desired outcome.',
          'Ask one clarifying question only when execution would be risky.',
          'Create a named skill with steps, required tools, and verification.',
        ],
        requiredPermissions: const [ToolPermission.skillCreate],
      );
}
