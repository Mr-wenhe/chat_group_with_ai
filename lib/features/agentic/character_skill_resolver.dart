import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/character_skill.dart';
import 'package:chat_group/core/models/tool_permission.dart';
import 'package:chat_group/features/agentic/skill_download_service.dart';

class CharacterSkillBundle {
  final List<CharacterSkill> skills;
  final List<ToolPermission> permissions;

  const CharacterSkillBundle({
    required this.skills,
    required this.permissions,
  });
}

class CharacterSkillResolver {
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
        SkillDownloadService.recommendedTemplatesFor(character).take(3).toList();
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
