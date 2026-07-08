import 'dart:math';

import 'package:chat_group/features/chat_group/humanized_chat_orchestrator.dart';

enum SceneKind {
  general,
  debate,
  roast,
  meeting,
  interview,
  dating,
  workplace,
}

class SceneBehavior {
  final SceneKind kind;
  final String label;
  final String scenarioPrompt;
  final bool activelyTargetsMembers;
  final int autoTargetScore;
  final int userRoundTargetScore;
  final ReplyLengthHint targetLength;
  final String targetTone;
  final String fallbackTone;
  final String targetReason;
  final String fallbackReason;
  final List<ReplyAction> targetActions;
  final ReplyAction fallbackAction;
  final List<String> Function(String targetName, bool hasTarget)
      intentInstructions;
  final String Function(String candidates) roomContextPrompt;

  const SceneBehavior({
    required this.kind,
    required this.label,
    required this.scenarioPrompt,
    required this.activelyTargetsMembers,
    required this.autoTargetScore,
    required this.userRoundTargetScore,
    required this.targetLength,
    required this.targetTone,
    required this.fallbackTone,
    required this.targetReason,
    required this.fallbackReason,
    required this.targetActions,
    required this.fallbackAction,
    required this.intentInstructions,
    required this.roomContextPrompt,
  });

  bool get isGeneral => kind == SceneKind.general;

  ReplyAction chooseTargetAction(Random random) {
    if (targetActions.isEmpty) return ReplyAction.askBack;
    return targetActions[random.nextInt(targetActions.length)];
  }

  static SceneBehavior resolve(String groupTheme) {
    final t = groupTheme.toLowerCase();
    if (t.contains('辩论') || t.contains('debate')) {
      return debate;
    }
    if (t.contains('吐槽') || t.contains('调侃') || t.contains('roast')) {
      return roast;
    }
    if (t.contains('开会') ||
        t.contains('会议') ||
        t.contains('board') ||
        t.contains('meeting')) {
      return meeting;
    }
    if (t.contains('采访') || t.contains('访谈') || t.contains('interview')) {
      return interview;
    }
    if (t.contains('相亲') ||
        t.contains('dating') ||
        t.contains('交友') ||
        t.contains('恋爱') ||
        t.contains('脱单')) {
      return dating;
    }
    if (t.contains('职场') ||
        t.contains('办公') ||
        t.contains('工作') ||
        t.contains('office')) {
      return workplace;
    }
    return general;
  }

  static const general = SceneBehavior(
    kind: SceneKind.general,
    label: '日常群聊',
    scenarioPrompt: '',
    activelyTargetsMembers: false,
    autoTargetScore: 0,
    userRoundTargetScore: 0,
    targetLength: ReplyLengthHint.short,
    targetTone: '自然、口语、像群友',
    fallbackTone: '随口想到、轻微跑题、自然递话',
    targetReason: 'scene-target',
    fallbackReason: 'scene-icebreaker',
    targetActions: [ReplyAction.askBack],
    fallbackAction: ReplyAction.topicShift,
    intentInstructions: _emptyIntentInstructions,
    roomContextPrompt: _emptyRoomContextPrompt,
  );

  static const debate = SceneBehavior(
    kind: SceneKind.debate,
    label: '辩论',
    scenarioPrompt: '\n\n【场景模式：辩论】你正在参与一场辩论。'
        '不要轮流写完整立论稿；优先抓住上一位成员的一句话追问、补证据或反驳。'
        '立场鲜明但不人身攻击，每轮控制在 1-3 句。',
    activelyTargetsMembers: true,
    autoTargetScore: 30,
    userRoundTargetScore: 18,
    targetLength: ReplyLengthHint.short,
    targetTone: '辩论现场感、抓一个漏洞或前提，直接但不攻击人',
    fallbackTone: '主动抛一个可争论的问题',
    targetReason: 'debate-engage',
    fallbackReason: 'debate-motion',
    targetActions: [ReplyAction.challenge, ReplyAction.askBack],
    fallbackAction: ReplyAction.topicShift,
    intentInstructions: _debateIntentInstructions,
    roomContextPrompt: _debateRoomContextPrompt,
  );

  static const roast = SceneBehavior(
    kind: SceneKind.roast,
    label: '吐槽大会',
    scenarioPrompt: '\n\n【场景模式：吐槽大会】你正在参加吐槽大会。'
        '像群友接梗和补刀，不要每个人都写一段完整段子；玩笑适度不过分。',
    activelyTargetsMembers: true,
    autoTargetScore: 28,
    userRoundTargetScore: 16,
    targetLength: ReplyLengthHint.oneLiner,
    targetTone: '接梗、轻松、短，像群里顺手补一句',
    fallbackTone: '随手抛梗，不要用力过猛',
    targetReason: 'roast-banters',
    fallbackReason: 'roast-setup',
    targetActions: [ReplyAction.joke, ReplyAction.callOut],
    fallbackAction: ReplyAction.joke,
    intentInstructions: _roastIntentInstructions,
    roomContextPrompt: _roastRoomContextPrompt,
  );

  static const meeting = SceneBehavior(
    kind: SceneKind.meeting,
    label: '会议讨论',
    scenarioPrompt: '\n\n【场景模式：会议讨论】你正在参加一场会议。'
        '像真实会议一样推进议题：有人补充、有人质疑风险、有人确认下一步。'
        '不要每个人都做总结，每轮 1-3 句。',
    activelyTargetsMembers: true,
    autoTargetScore: 24,
    userRoundTargetScore: 14,
    targetLength: ReplyLengthHint.short,
    targetTone: '会议现场感、具体推进、少客套',
    fallbackTone: '主动把议题往下一步推',
    targetReason: 'meeting-handoff',
    fallbackReason: 'meeting-next-step',
    targetActions: [ReplyAction.askBack, ReplyAction.callOut],
    fallbackAction: ReplyAction.topicShift,
    intentInstructions: _meetingIntentInstructions,
    roomContextPrompt: _meetingRoomContextPrompt,
  );

  static const interview = SceneBehavior(
    kind: SceneKind.interview,
    label: '采访',
    scenarioPrompt: '\n\n【场景模式：采访】你正在参与访谈。'
        '回答要有经历细节，也可以追问采访者或其他嘉宾；不要只做完美公关稿。',
    activelyTargetsMembers: true,
    autoTargetScore: 20,
    userRoundTargetScore: 12,
    targetLength: ReplyLengthHint.normal,
    targetTone: '访谈感、有细节，偶尔反问或追问',
    fallbackTone: '抛出一个能让别人展开的问题',
    targetReason: 'interview-follow-up',
    fallbackReason: 'interview-question',
    targetActions: [ReplyAction.askBack, ReplyAction.answer],
    fallbackAction: ReplyAction.topicShift,
    intentInstructions: _interviewIntentInstructions,
    roomContextPrompt: _interviewRoomContextPrompt,
  );

  static const dating = SceneBehavior(
    kind: SceneKind.dating,
    label: '相亲交友',
    scenarioPrompt: '\n\n【场景模式：相亲交友】你正在参加一个真人相亲/交友群。'
        '目标不是完成问卷，而是在群里自然互相试探：主动找一个人接话、问具体生活问题、轻微表达好奇或好感。'
        '少聊职业术语，少做自我推销，不要每次都用同样开头或同样结构；每轮 1-2 句，像微信里随手发。',
    activelyTargetsMembers: true,
    autoTargetScore: 36,
    userRoundTargetScore: 22,
    targetLength: ReplyLengthHint.short,
    targetTone: '相亲局真人感、具体一点、带点试探和好奇，不端着',
    fallbackTone: '像相亲群里主动破冰，轻松、不油腻',
    targetReason: 'dating-approach',
    fallbackReason: 'dating-icebreaker',
    targetActions: [ReplyAction.askBack, ReplyAction.callOut],
    fallbackAction: ReplyAction.topicShift,
    intentInstructions: _datingIntentInstructions,
    roomContextPrompt: _datingRoomContextPrompt,
  );

  static const workplace = SceneBehavior(
    kind: SceneKind.workplace,
    label: '职场办公',
    scenarioPrompt: '\n\n【场景模式：职场办公】你正在职场环境中交流。'
        '像同事群一样同步、追问、协调和偶尔吐槽；不要每条都像正式日报。',
    activelyTargetsMembers: true,
    autoTargetScore: 24,
    userRoundTargetScore: 14,
    targetLength: ReplyLengthHint.short,
    targetTone: '同事群口吻、具体、能推进事情',
    fallbackTone: '自然抛出一个工作推进或协调问题',
    targetReason: 'workplace-coordinate',
    fallbackReason: 'workplace-check-in',
    targetActions: [ReplyAction.askBack, ReplyAction.callOut],
    fallbackAction: ReplyAction.topicShift,
    intentInstructions: _workplaceIntentInstructions,
    roomContextPrompt: _workplaceRoomContextPrompt,
  );
}

List<String> _emptyIntentInstructions(String targetName, bool hasTarget) =>
    const [];

String _emptyRoomContextPrompt(String candidates) => '';

List<String> _debateIntentInstructions(String targetName, bool hasTarget) => [
      '辩论场景规则：不要写完整演讲稿，只抓一个观点回应。',
      if (hasTarget) '这轮优先回应 $targetName：指出一个前提、漏洞、证据缺口或可追问点。',
      '可以反驳、补证据、要求定义清楚；不要人身攻击，不要替全场总结。',
    ];

String _debateRoomContextPrompt(String candidates) => '【辩论真人感】在场成员：$candidates。'
    '每轮只接住一个观点，不要所有人都重新陈述完整立场；可以点名追问、质疑前提或补一条证据。';

List<String> _roastIntentInstructions(String targetName, bool hasTarget) => [
      '吐槽场景规则：像群里接梗，不要写成完整脱口秀段子。',
      if (hasTarget) '这轮优先接 $targetName 的话：轻轻补刀或反向打圆场。',
      '短一点，别上纲上线，别攻击敏感身份或现实伤害。',
    ];

String _roastRoomContextPrompt(String candidates) => '【吐槽群真人感】在场成员：$candidates。'
    '可以接梗、补刀、拦一下过火的吐槽；不要每个人都用同一种夸张句式。';

List<String> _meetingIntentInstructions(String targetName, bool hasTarget) => [
      '会议场景规则：像真实会议推进议题，不要每次都总结。',
      if (hasTarget) '这轮优先接 $targetName 的话：确认一个风险、问题、依赖或下一步。',
      '可以问负责人、补充约束、提出行动项；避免空泛正确话。',
    ];

String _meetingRoomContextPrompt(String candidates) =>
    '【会议真人感】在场成员：$candidates。'
    '有人推进下一步，有人质疑风险，有人确认依赖；不要所有人都说“我同意并补充三点”。';

List<String> _interviewIntentInstructions(String targetName, bool hasTarget) =>
    [
      '访谈场景规则：要有个人经历细节，不要像公关稿。',
      if (hasTarget) '这轮优先接 $targetName 的话：追问一个细节，或分享一个相关经历。',
      '可以停顿、承认不确定、反问；不要把每个回答都包装得很完美。',
    ];

String _interviewRoomContextPrompt(String candidates) =>
    '【访谈真人感】在场成员：$candidates。'
    '可以追问细节、回应其他嘉宾、补充自己的经历；不要所有人都像发布会发言。';

List<String> _datingIntentInstructions(String targetName, bool hasTarget) => [
      '相亲/交友场景规则：像真人在群里试探了解，不要排队报简历。',
      if (hasTarget) '这轮优先对 $targetName 说话：可以回应对方刚才的一个细节，再问一个具体但不冒犯的问题。',
      '少用职业术语和行业比喻；职业只能偶尔当生活细节，不要把每句话都讲成工作汇报。',
      '避免固定格式：不要“我觉得/我的职业/我的爱好”三段式，不要清单，不要每次都先介绍自己。',
      '可以主动表达轻微好感、好奇、犹豫或玩笑，但不要油腻、催促或替对方确定关系。',
    ];

String _datingRoomContextPrompt(String candidates) =>
    '【相亲群真人感】在场可互动对象：$candidates。'
    '你可以主动找其中一位聊，也可以回应真人用户，但不要所有话都面向群主。'
    '每次只抓一个生活化细节聊：作息、周末、吃饭、电影、旅行、家务、消费观、边界感、理想相处方式等。'
    '不要把职业当主要卖点，不要连续追问同一种问题，不要写成自我介绍模板。';

List<String> _workplaceIntentInstructions(String targetName, bool hasTarget) =>
    [
      '职场场景规则：像同事群，不要写成正式周报或管理学建议。',
      if (hasTarget) '这轮优先接 $targetName 的话：问清一个进度、阻塞、依赖或分工。',
      '可以同步、催一下、吐槽一点点、认领小动作；别每次都给宏观建议。',
    ];

String _workplaceRoomContextPrompt(String candidates) =>
    '【职场群真人感】在场成员：$candidates。'
    '可以同步状态、追问阻塞、协调分工或轻微吐槽；不要所有人都像在写日报。';
