class UserMessageSentiment {
  /// 消息对角色好感度的净影响（正=增进，负=损害）。
  /// 范围约 [-3, +2]，具体值由 [severity] 和 [category] 共同决定。
  final int affinityDelta;

  /// 消息对角色摩擦度的净影响。
  final int frictionDelta;

  /// 态度分类。
  final UserMessageCategory category;

  /// 严重程度（仅 offensive/cold 时有意义，0=轻微，1=中等，2=严重）。
  /// 用于按严重程度调整 delta 幅度。
  final int severity;

  const UserMessageSentiment({
    required this.affinityDelta,
    required this.frictionDelta,
    required this.category,
    this.severity = 0,
  });

  bool get isRespectful => category == UserMessageCategory.respectful;
  bool get isOffensive => category == UserMessageCategory.offensive;
  bool get isCold => category == UserMessageCategory.cold;

  /// 是否为有情感倾向的消息（非纯中性）。
  bool get isEmotional => category != UserMessageCategory.neutral;

  /// 简短的调试描述。
  String get description =>
      '${category.name}(affinity:$affinityDelta, friction:$frictionDelta)';
}

enum UserMessageCategory {
  respectful,
  neutral,
  offensive,
  cold,
}

/// 分析单条用户消息的态度倾向，返回对应的情感分类和数值影响。
///
/// 基于关键词匹配（不调用 LLM，保证实时性），支持中英文。
class UserMessageSentimentAnalyzer {
  // --- 冒犯/不尊重关键词 ---
  // 人身攻击类
  static const _insults = [
    '傻逼', '傻比', '傻X', '煞笔', '沙比', '傻', '白痴', '脑残', '智障',
    '蠢货', '蠢', '笨蛋', '废物', '垃圾', '辣鸡', '垃圾', '滚', '滚蛋',
    '闭嘴', '住嘴', '闭嘴吧', '少废话', '别逼逼', '你妈的',
    '贱人', '婊子', '狗', '猪', '畜生', '禽兽',
    ' idiot', 'stupid', 'shut up', 'dumb', 'fool', 'trash', 'scum',
  ];

  // 贬低/否定角色存在价值
  static const _disrespect = [
    '你算什么', '你懂什么', '你什么水平', '你有什么资格',
    '你就是个', '你一个AI', '你不过是个', '你算什么东西',
    '你的存在', '你配吗', '你也配', '你配不配',
    'who are you', 'what do you know', 'you are nothing',
    "you're just", "you're a",
  ];

  // 命令/不客气要求
  static const _commanding = [
    '快给我', '立刻', '马上', '必须', '给我', '照做',
    '你只需要', '你只管', '别管那么多',
    '别说了', '别插嘴', '没人问你',
  ];

  // 冷淡/无视类
  static const _cold = [
    '不想理', '懒得理', '不想跟你', '跟你没话说',
    '跟你说话', '真无聊', '太没意思了', '好无聊',
    '无话可说', '懒得', '不想理你', '滚一边',
    'boring', 'dont care', "don't care", 'whatever', 'wtf',
  ];

  // 友好/积极关键词（正向）
  static const _friendly = [
    '谢谢', '感谢', '辛苦了', '多亏', '帮大忙', '太棒了', '太好了',
    '厉害', '优秀', '真牛', '真强', '漂亮', '聪明',
    'love', 'thanks', 'thank you', 'appreciate', 'amazing',
    'great', 'awesome', 'nice', 'wonderful',
  ];

  // 对冒犯的礼貌纠正/幽默化解（表现尊重的方式）
  static const _politeDeEscalation = [
    '开玩笑', '别介意', '开玩笑的', '不是故意的', '对不起',
    '抱歉', 'sorry', 'my bad', 'no offense',
  ];

  static UserMessageSentiment analyze(String content) {
    if (content.isEmpty) {
      return const UserMessageSentiment(
        affinityDelta: 0,
        frictionDelta: 0,
        category: UserMessageCategory.neutral,
      );
    }

    final lower = content.toLowerCase();

    // 检查是否用幽默/礼貌方式化解了冒犯（如开玩笑、道歉）。
    // 优先检测：带这类前缀的内容即使后半段有冒犯词，也视为轻度行为。
    final deEscalated = _politeDeEscalation.any(lower.contains);

    // 冒犯检测：先看是否有明显侮辱
    var insultMatches = _insults.where(lower.contains).length;
    var disrespectMatches = _disrespect.where(lower.contains).length;
    var commandMatches = _commanding.where(lower.contains).length;
    var coldMatches = _cold.where(lower.contains).length;

    // 如果用户主动化解了冲突，将冒犯强度降到最低。
    if (deEscalated) {
      insultMatches = insultMatches.clamp(0, 1);
      disrespectMatches = disrespectMatches.clamp(0, 1);
      commandMatches = commandMatches.clamp(0, 1);
    }

    // 综合冒犯分数：insult×2 + disrespect×1 + commanding×1
    var offensiveScore = insultMatches * 2 + disrespectMatches + commandMatches;

    if (offensiveScore > 0) {
      // 冒犯级别：0=轻微(单条命令语气), 1=中等(侮辱+其他), 2=严重(严重人身攻击)
      final severity = offensiveScore >= 4
          ? 2
          : (offensiveScore >= 2 ? 1 : 0);
      return UserMessageSentiment(
        affinityDelta: -2 * (severity + 1),
        frictionDelta: 5 + severity * 5,
        category: UserMessageCategory.offensive,
        severity: severity,
      );
    }

    // 冷淡/无视类（无冒犯但冷淡）
    if (coldMatches > 0) {
      return const UserMessageSentiment(
        affinityDelta: -1,
        frictionDelta: 2,
        category: UserMessageCategory.cold,
        severity: 0,
      );
    }

    // 如果用户用了礼貌化解词，即使没有冒犯内容，也算轻微尊重。
    if (deEscalated) {
      return const UserMessageSentiment(
        affinityDelta: 1,
        frictionDelta: 0,
        category: UserMessageCategory.respectful,
      );
    }

    // 友好/积极关键词（正向）
    var friendlyMatches = _friendly.where(lower.contains).length;
    if (friendlyMatches > 0) {
      return const UserMessageSentiment(
        affinityDelta: 2,
        frictionDelta: 0,
        category: UserMessageCategory.respectful,
      );
    }

    return const UserMessageSentiment(
      affinityDelta: 0,
      frictionDelta: 0,
      category: UserMessageCategory.neutral,
    );
  }
}
