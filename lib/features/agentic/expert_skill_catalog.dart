import 'package:chat_group/core/models/tool_permission.dart';
import 'package:chat_group/features/agentic/document_skill_templates.dart';
import 'package:chat_group/features/agentic/expert_skill_template.dart';

export 'package:chat_group/features/agentic/expert_skill_template.dart';

class ExpertSkillCatalog {
  static const _codingRequestKeywords = [
    '代码',
    '编程',
    '开发',
    'code',
    'coding',
    'dart',
    'flutter',
    'java',
    'kotlin',
    'swift',
    'python',
    'javascript',
    'typescript',
    'c++',
    'cpp',
    'bug',
    'debug',
    'review',
    'refactor',
    '重构',
    '修复',
  ];

  static const List<ExpertSkillTemplate> templates = [
    ExpertSkillTemplate(
      id: 'meta.create-skills',
      name: 'Create Skills',
      domain: 'meta',
      description: '把新的专业流程设计成可复用、可验证并具备最小权限的角色技能。',
      keywords: [
        '创建技能',
        '生成技能',
        '新技能',
        'create skill',
        'skill.create',
        '可复用技能',
      ],
      instructions: [
        '先提炼技能要解决的用户意图、适用边界和可观察产出。',
        '检查已安装技能和内置模板，避免创建重复能力。',
        '把工作流拆成明确步骤，并只申请完成步骤所需的最小工具权限。',
        '调用 skill.create 创建技能，随后用一个代表性请求验证技能可匹配和执行。',
      ],
      requiredPermissions: [
        ToolPermission.skillCreate,
        ToolPermission.skillDownload,
      ],
    ),
    ExpertSkillTemplate(
      id: 'meta.find-skills',
      name: 'Find Skills',
      domain: 'meta',
      description: '在当前内置目录和角色已安装技能中查找最匹配的可复用能力。',
      keywords: [
        '查找技能',
        '找技能',
        '搜索技能',
        '发现技能',
        '技能目录',
        '可用技能',
        '查找 skill',
        'find skill',
        'find skills',
        'skill finder',
        'skill discovery',
        'skill search',
      ],
      instructions: [
        '先查看本轮已经注入的内置技能和角色已安装技能，不要假设存在未列出的能力。',
        '根据用户意图、领域和关键词选择最具体的匹配项，并说明匹配理由。',
        '找到内置模板后使用 skill.download 和准确的 templateId 安装；没有匹配项才使用 skill.create。',
        '只有工具返回成功后才能声称技能已安装，随后在当前任务中实际遵循它。',
      ],
      requiredPermissions: [
        ToolPermission.skillCreate,
        ToolPermission.skillDownload,
      ],
    ),
    ExpertSkillTemplate(
      id: 'meta.grill-me',
      name: 'Grill Me',
      domain: 'planning',
      description: '逐层质询计划或设计，暴露隐含假设并逐个解决决策分支。',
      keywords: [
        'grill me',
        'grill-me',
        'grilling',
        '拷问我',
        '质询我',
        '挑战我的方案',
        '压力测试方案',
        '逐个提问',
        '严厉提问',
      ],
      instructions: [
        '围绕目标、范围、依赖、失败路径和验收标准逐层追问，不接受含糊的默认前提。',
        '一次只问一个关键问题，并同时给出你推荐的答案或选择方向。',
        '如果答案可以通过读取代码或现有资料确认，先读取证据，不要把可验证事实变成问题。',
        '在关键分支达成共识前不要擅自实施会改变结果的方案。',
      ],
      requiredPermissions: [ToolPermission.workspaceRead],
    ),
    ExpertSkillTemplate(
      id: 'coding.ponytail',
      name: 'Ponytail',
      domain: 'coding',
      description: '以 YAGNI 和最小可行改动约束代码任务，优先复用现有能力和标准方案。',
      keywords: [
        'ponytail',
        'be lazy',
        'lazy mode',
        'simplest solution',
        'minimal solution',
        'yagni',
        'do less',
        '最简单方案',
        '最小实现',
        '不要过度设计',
        '少写代码',
        '避免过度工程化',
      ],
      appliesToCodingRequests: true,
      instructions: [
        '先读懂任务和受影响的完整调用链，再选择最小且正确的实现，不用“偷懒”代替理解。',
        '优先复用现有代码，其次使用标准库、平台能力和已安装依赖，避免新增抽象和依赖。',
        '不得省略输入校验、错误处理、安全措施、无障碍基础或用户明确要求的完整能力。',
        '非平凡逻辑留下一个最小可运行验证；发现简化有明确上限时说明升级条件。',
      ],
      requiredPermissions: [
        ToolPermission.workspaceRead,
        ToolPermission.workspacePatch,
        ToolPermission.commandRun,
      ],
    ),
    ExpertSkillTemplate(
      id: 'general.superpowers',
      name: 'Superpowers Workflow',
      domain: 'general',
      description: '用澄清、根因分析、测试驱动和完成前验证处理复杂工程任务。',
      keywords: [
        '测试驱动',
        '根因分析',
        '系统化调试',
        '复杂任务',
        '质量门禁',
        'superpowers',
        'tdd',
      ],
      instructions: [
        '执行前核对目标、约束、现有实现和可复现证据。',
        '对缺失行为先写最小失败测试，确认失败原因与需求一致。',
        '实施能让测试通过的最小修改，避免捎带无关重构。',
        '运行目标测试、回归测试和静态分析，用新鲜输出证明完成状态。',
      ],
      requiredPermissions: [
        ToolPermission.workspaceRead,
        ToolPermission.workspacePatch,
        ToolPermission.commandRun,
      ],
    ),
    ExpertSkillTemplate(
      id: 'planning.planning-with-files',
      name: 'Planning With Files',
      domain: 'planning',
      description: '把复杂任务的计划、证据和进度持久化到文件，支持跨轮次恢复执行。',
      keywords: [
        '计划文件',
        '进度文件',
        '计划和进度',
        '写进文件',
        '写入文件',
        '保存到文件',
        'planning with files',
        '实施计划',
      ],
      instructions: [
        '读取任务相关文件，确认目标、约束和已有状态。',
        '建立包含阶段、验收证据和未解决问题的计划文件。',
        '每完成一个可验证步骤就更新进度和关键发现，保留恢复所需上下文。',
        '结束前对照计划逐项验证，并记录实际命令输出和剩余风险。',
      ],
      requiredPermissions: [
        ToolPermission.workspaceRead,
        ToolPermission.workspacePatch,
        ToolPermission.commandRun,
      ],
    ),
    ExpertSkillTemplate(
      id: 'coding.flutter-reviewer',
      name: 'Flutter Code Expert',
      domain: 'coding',
      description: '像资深 Flutter 工程师一样读代码、review、修 bug 和验证。',
      keywords: [
        '代码',
        'code',
        'flutter',
        'dart',
        'java',
        'c++',
        'cpp',
        'c语言',
        'c 语言',
        'review',
        'debug',
        'bug',
        '修复',
        '重构',
        '开发',
        '编程',
        '工程师'
      ],
      instructions: [
        '先确认用户要改的目标、错误现象或 review 范围。',
        '读取最小相关文件，必要时列出依赖链。',
        '提出具体 patch，并在用户批准后应用。',
        '运行允许的验证命令并总结证据、风险和后续建议。',
      ],
      requiredPermissions: [
        ToolPermission.workspaceRead,
        ToolPermission.workspacePatch,
        ToolPermission.commandRun,
        ToolPermission.skillCreate,
        ToolPermission.skillDownload,
      ],
    ),
    ExpertSkillTemplate(
      id: 'frontend.interactive-artifact',
      name: 'Interactive Frontend Artifact Expert',
      domain: 'frontend',
      description: '生成可直接打开交付的 HTML/CSS/JavaScript 交互页面，并以真实文件和验证结果作为完成依据。',
      keywords: [
        '前端',
        'html',
        'html5',
        'three.js',
        'threejs',
        '交互页面',
        '网页设计',
        '网站设计',
        '视觉冲击',
        'landing page',
        'css 动效',
      ],
      instructions: [
        '提炼页面主题、核心交互、视觉层次、目标设备和可观察的完成标准。',
        '生成完整可运行的 HTML/CSS/JavaScript 内容，避免占位符、空壳和未实现的承诺。',
        '调用 workspace.patch 写入合理的 .html 文件，必须以工具成功回包和读回内容作为交付证据。',
        '检查 HTML 结构、资源依赖、响应式布局和基本交互，再附上文件而不是只用文字声称完成。',
      ],
      requiredPermissions: [
        ToolPermission.workspaceRead,
        ToolPermission.workspacePatch,
      ],
    ),
    ...documentExpertSkillTemplates,
    ExpertSkillTemplate(
      id: 'product.strategy-partner',
      name: 'Product Strategy Expert',
      domain: 'product',
      description: '把模糊需求变成目标、用户价值、取舍和路线图。',
      keywords: ['产品', '需求', 'prd', 'roadmap', '策略', '体验', '增长'],
      instructions: [
        '识别用户、场景、核心任务和成功指标。',
        '拆分必须做、应该做和暂缓做的范围。',
        '把讨论沉淀为可执行步骤或可复用 skill。',
        '指出最关键的风险、验证方式和下一步。',
      ],
      requiredPermissions: [
        ToolPermission.skillCreate,
        ToolPermission.skillDownload,
      ],
    ),
    ExpertSkillTemplate(
      id: 'research.browser-analyst',
      name: 'Browser Research Expert',
      domain: 'research',
      description: '基于当前浏览器页面和选中文本做事实提炼与分析。',
      keywords: ['研究', '资料', 'browser', '网页', 'research', '搜索', '总结'],
      instructions: [
        '要求用户打开或选中相关页面内容。',
        '通过浏览器上下文读取 URL、标题、选中文本和页面正文。',
        '区分页内事实、外部常识和自己的推断。',
        '给出带来源 URL 的结论和下一步行动建议。',
      ],
      requiredPermissions: [
        ToolPermission.browserContext,
        ToolPermission.skillCreate,
        ToolPermission.skillDownload,
      ],
    ),
    ExpertSkillTemplate(
      id: 'writing.voice-editor',
      name: 'Writing Voice Expert',
      domain: 'writing',
      description: '按受众、目的和语气生成、修改、润色文本。',
      keywords: ['写作', '文案', '编辑', '邮件', 'copywriting', 'writer', '润色'],
      instructions: [
        '先确认受众、场景、目标和语气。',
        '给出可直接使用的版本，而不是只给抽象建议。',
        '保留用户原本的语气和意图。',
        '必要时把反复使用的写作流程保存为 skill。',
      ],
      requiredPermissions: [
        ToolPermission.skillCreate,
        ToolPermission.skillDownload,
      ],
    ),
    ExpertSkillTemplate(
      id: 'support.coach',
      name: 'Support And Coaching Expert',
      domain: 'support',
      description: '像专业陪伴者一样倾听、梳理情绪并形成行动建议。',
      keywords: ['鼓励', '心理', '咨询', '陪伴', '情绪', '治愈', '教练', '成长'],
      instructions: [
        '先接住用户情绪，再确认他们真正想要的是陪伴还是建议。',
        '用具体问题帮助用户看清处境。',
        '给出低压力、可执行的一小步。',
        '在对话中记住用户偏好，并把有效陪伴方式沉淀成 skill。',
      ],
      requiredPermissions: [
        ToolPermission.skillCreate,
        ToolPermission.skillDownload,
      ],
    ),
    ExpertSkillTemplate(
      id: 'general.workbuddy-expert-builder',
      name: 'Workbuddy Expert Builder',
      domain: 'general',
      description: '为任何职业角色生成和安装更贴合职业的专家 skill。',
      keywords: [''],
      instructions: [
        '根据角色职业、标签、系统提示和用户任务判断缺失的专业能力。',
        '优先安装已有专家模板；没有模板时创建新的职业 skill。',
        '技能必须包含工作步骤、工具权限和验证方式。',
        '后续类似任务直接复用已安装 skill。',
      ],
      requiredPermissions: [
        ToolPermission.skillCreate,
        ToolPermission.skillDownload,
      ],
    ),
  ];

  static List<ExpertSkillTemplate> recommendForText(String text) {
    final lower = text.toLowerCase();
    final matched = templates.where((template) {
      if (template.id == 'general.workbuddy-expert-builder') return false;
      return template.keywords.any(
        (keyword) =>
            keyword.isNotEmpty && lower.contains(keyword.toLowerCase()),
      );
    }).toList();
    if (_isCodingRequest(lower)) {
      for (final template in templates) {
        if (template.appliesToCodingRequests && !matched.contains(template)) {
          matched.add(template);
        }
      }
    }
    matched.sort(
      (a, b) => _matchScore(b, lower).compareTo(_matchScore(a, lower)),
    );
    if (matched.isEmpty) {
      return [
        templates.firstWhere(
          (template) => template.id == 'general.workbuddy-expert-builder',
        )
      ];
    }
    return matched;
  }

  static bool _isCodingRequest(String lower) => _codingRequestKeywords.any(
        (keyword) => lower.contains(keyword),
      );

  static int _matchScore(ExpertSkillTemplate template, String lower) {
    return template.keywords
        .where((keyword) =>
            keyword.isNotEmpty && lower.contains(keyword.toLowerCase()))
        .fold<int>(0, (score, keyword) => score + keyword.length);
  }

  static ExpertSkillTemplate? findById(String id) {
    for (final template in templates) {
      if (template.id == id) return template;
    }
    return null;
  }
}
