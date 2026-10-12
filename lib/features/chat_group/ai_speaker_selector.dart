import 'dart:convert';

import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/features/agentic/context_window_manager.dart';
import 'package:chat_group/features/chat_group/group_shared_context.dart';

/// 选择器对"下一步"的判定结果。
enum AiSpeakerDecisionStatus {
  /// 选中了某位候选成员。
  chosen,

  /// 模型认为这一轮不需要再有人说话。
  finished,

  /// 响应不可用：不是 JSON、字段缺失或类型不对、指向不存在的成员、超长。
  ///
  /// 与 [finished] 严格区分：前者是模型的正常决定，后者是失败。
  invalid,
}

/// 一次选人判定的结果。
///
/// 只携带「谁来说」这一件事，模型返回的任何其他内容都被丢弃，绝不当作指令
/// 执行——协议里没有第二个字段，解析层也只读 `speakerId`。
class AiSpeakerDecision {
  final AiSpeakerDecisionStatus status;

  /// 仅在 [AiSpeakerDecisionStatus.chosen] 时非空，且保证是候选集合中的 id。
  final String? speakerId;

  const AiSpeakerDecision._(this.status, this.speakerId);

  const AiSpeakerDecision.chosen(String speakerId)
      : this._(AiSpeakerDecisionStatus.chosen, speakerId);

  const AiSpeakerDecision.finished()
      : this._(AiSpeakerDecisionStatus.finished, null);

  const AiSpeakerDecision.invalid()
      : this._(AiSpeakerDecisionStatus.invalid, null);
}

/// 普通群聊「下一位发言者」的选择协议。
///
/// 这是一次幕后的、非流式的短 JSON 调用：它只读当前群共同可见的对话与成员
/// 公开资料，回答下一位该由谁开口，或回答"到此为止"。它不产生聊天气泡，
/// 也不是群成员，因此不进入任何 prompt 的成员列表。
///
/// 本类只负责**协议本身**（提示词与解析），不持有网络、凭据或状态，便于用
/// 假模型直接验证。参数是工程起点而不是调优结果：真实提供商的自然度、延迟
/// 与费用需要实测，见 `AiSpeakerPickerSettings` 的调用方。
class AiSpeakerSelector {
  /// 估算输入上限（token）。真正的上限还要被所选模型的能力表进一步压低。
  static const int maxInputTokens = 2048;

  /// 输出上限（token）。协议只有一个字段，128 足够，同时挡住跑飞的生成。
  static const int maxOutputTokens = 128;

  /// 响应体上限（字节）。先于 JSON 解码挡住无界响应。
  static const int maxResponseBytes = 16 * 1024;

  /// 整次选择的时限。
  static const Duration timeout = Duration(seconds: 15);

  /// 用量账本里的"角色"标识。
  ///
  /// 选人器不是群成员，也不产生聊天气泡；用一个固定标识把它的费用与群成员的
  /// 发言区分开，账本里能一眼看出这笔钱花在选人上。
  static const String ledgerCharacterId = 'group-speaker-picker';

  /// 响应正文的防御性长度上限（字符）。传输层已按字节挡住，这里再挡一次，
  /// 让解析层对任何来源（含测试替身）都保持同样的边界。
  static const int maxResponseChars = 4096;

  /// 传给模型的历史消息条数与字符数上限，避免选择器把整段历史读进去。
  static const int maxHistoryMessages = 16;
  static const int maxHistoryChars = 1200;

  /// 协议说明。刻意把「结束」与「未知 id」的后果写清楚：模型越少自由发挥，
  /// 解析层越不需要兜底。
  static const String protocolInstruction =
      '你只负责决定"下一位该由谁说"。'
      '只输出一个 JSON 对象，形如 {"speakerId":"成员ID"}；'
      '如果你认为这一轮不必再有人开口，输出 {"speakerId":null}。'
      'speakerId 必须是下面候选成员里的 ID 原文，不能是名字，也不能自造。'
      '不要输出 JSON 以外的任何文字、解释或代码块标记。';

  /// 协议说明区块的识别标记：窗口裁剪时它必须整体保留，模型才知道该输出什么。
  static const String protocolBlockMarker =
      '你在一个多人 AI 群聊里担任幕后"接话调度"。';

  /// 候选名单区块的识别标记：它同样必须整体保留。
  ///
  /// 名单里每个 `id=` 都是模型唯一可用的发言者标识，裁掉任何一个都等于凭空
  /// 剥夺那位角色的发言权——模型看不见它，也就永远不会选它。
  static const String candidateBlockMarker =
      '候选成员（只能从这里选，名单外的 id 一律无效）：';

  /// 候选行里稳定 ID 与展示名之间的分隔符。
  ///
  /// 它同时是"候选 ID 是否完整保留"的核对依据：只匹配 `id=` 前缀会让 `a`
  /// 匹配到 `id=ab` 那一行，把已经被裁掉的候选判成幸存。
  static const String candidateIdSeparator = '｜';

  /// 组装选择器请求。
  ///
  /// [visibleHistory] 必须是**候选成员共同可见**的历史交集，调用方负责过滤；
  /// 本方法不读取其他群、私聊或观察者私有记忆。
  ///
  /// [sharedContext] 是**当前这个群**的固定共同设定（见 `GroupSharedContext`）。
  /// 选人器据此理解称呼、固定关系和群内约定，避免把"甲是乙的姐姐"这类设定
  /// 当成陌生关系而选错人；它同样只读当前允许运行的群，不查询其他群的设定。
  ///
  /// [compactCandidates] 只保留协议必需的稳定 ID 与名称，丢掉性别/职业/年龄/
  /// 标签（见 [buildBoundedMessages] 的降级顺序）。
  static List<Map<String, dynamic>> buildMessages({
    required String groupTheme,
    required List<AICharacter> candidates,
    required List<Message> visibleHistory,
    required Map<String, String> senderNames,
    required String ownerName,
    String sharedContext = '',
    bool compactCandidates = false,
  }) {
    final candidateLines = candidates
        .map((character) => compactCandidates
            ? '- id=${character.id}$candidateIdSeparator${character.name}'
            : '- id=${character.id}$candidateIdSeparator${character.name}'
                '（${character.displayGenderLabel}，${character.role}，'
                '${character.age}岁${_tagsSuffix(character)}）')
        .join('\n');
    final transcript = buildTranscript(
      messages: visibleHistory,
      senderNames: senderNames,
      ownerName: ownerName,
      maxMessages: maxHistoryMessages,
      maxChars: maxHistoryChars,
    );
    final theme = groupTheme.trim().isEmpty ? '日常聊天' : groupTheme.trim();
    final shared = sharedContext.trim();

    return [
      {
        'role': 'system',
        'content': '$protocolBlockMarker'
            '群的主题是「$theme」。群主叫「$ownerName」。'
            '你的输出不会显示给任何人，只用来决定下一位发言者。$protocolInstruction'
      },
      if (shared.isNotEmpty) {'role': 'system', 'content': shared},
      {
        'role': 'system',
        'content': '$candidateBlockMarker\n$candidateLines'
      },
      {
        'role': 'user',
        'content': transcript.trim().isEmpty
            ? '最近还没有人说话。请决定谁先开口，或输出 {"speakerId":null} 结束这一轮。'
            : '最近群里的对话（按时间从早到晚）：\n$transcript\n\n'
                '请决定下一位该由谁开口，或输出 {"speakerId":null} 表示这一轮到此为止。',
      },
    ];
  }

  /// 组装**已按输入预算拟合**的选择器请求；连必需内容都装不下时返回 null。
  ///
  /// 优先级：协议、候选稳定 ID 与**本群固定共同设定**必需，候选公开资料、旧
  /// 对话可选。先用完整候选名单拟合并保护必需区块；若拟合仍丢掉了候选 ID（说明
  /// 公开资料大到把必要内容挤了出去），再改用紧凑候选名单重建一次；两次都不满足
  /// 就返回 null——调用方据此回落本地规则。宁可本地选人，也不把一份缺了成员的
  /// 名单、或一份被裁掉一半的设定交给模型，让它"公平地"漏掉几位角色或误解关系。
  static List<Map<String, dynamic>>? buildBoundedMessages({
    required String groupTheme,
    required List<AICharacter> candidates,
    required List<Message> visibleHistory,
    required Map<String, String> senderNames,
    required String ownerName,
    String sharedContext = '',
    required int maxInputTokens,
  }) {
    final budget = maxInputTokens < 1 ? 1 : maxInputTokens;
    for (final compact in const [false, true]) {
      final fitted = ContextWindowManager.fitToTokenBudget(
        buildMessages(
          groupTheme: groupTheme,
          candidates: candidates,
          visibleHistory: visibleHistory,
          senderNames: senderNames,
          ownerName: ownerName,
          sharedContext: sharedContext,
          compactCandidates: compact,
        ),
        maxTokens: budget,
        isProtected: isRequiredBlock,
      );
      if (!candidateIdsSurvive(fitted, candidates)) continue;
      // `isProtected` 是裁剪**优先级**，不等于整体保留：窗口小到连协议本身都装不下
      // 时，裁剪会按比例缩短最长的 system 文本，协议正文被截短而区块标记与候选 ID
      // 都还在。拿着半份协议去问模型，它就只能自由发挥。
      if (!protocolSurvives(fitted)) continue;
      // 设定被裁掉一半比整段不带更糟：模型会照着一份残缺的关系设定选人。
      if (!GroupSharedContext.survives(fitted, sharedContext)) continue;
      // 病态自定义窗口下拟合仍可能整体超预算，这种请求不发。
      if (ContextWindowManager.estimateRequestTokens(fitted) > budget) continue;
      return fitted;
    }
    return null;
  }

  /// 该条消息是否是**必须整体保留**的区块：协议、候选名单或本群固定共同设定。
  static bool isRequiredBlock(Map<String, dynamic> message) {
    if (GroupSharedContext.carriesBlock(message)) return true;
    final content = message['content'];
    if (content is! String) return false;
    return content.contains(protocolBlockMarker) ||
        content.contains(candidateBlockMarker);
  }

  /// 每位候选的稳定 ID 是否都还在即将发送的正文里。
  static bool candidateIdsSurvive(
    List<Map<String, dynamic>> messages,
    List<AICharacter> candidates,
  ) {
    final sent = messages
        .map((message) => message['content'])
        .whereType<String>()
        .join('\n');
    return candidates.every(
      (character) => sent.contains('id=${character.id}$candidateIdSeparator'),
    );
  }

  /// 协议正文是否**完整**留在即将发送的请求里。
  ///
  /// 与 [candidateIdsSurvive] 同一层校验，但看的是另一半必需内容：区块标记只是
  /// 协议那条 system 的开头，裁剪保留首尾，所以只查标记会把被截掉中间那句话的
  /// 协议判成幸存。要求 [protocolInstruction] 也在，模型才知道该输出什么形状。
  static bool protocolSurvives(List<Map<String, dynamic>> messages) {
    final sent = messages
        .map((message) => message['content'])
        .whereType<String>()
        .join('\n');
    return sent.contains(protocolBlockMarker) &&
        sent.contains(protocolInstruction);
  }

  /// 把对话渲染成带说话人名的文字稿，并按条数/字符数从旧到新裁剪。
  ///
  /// 保留**最新**的内容：选择器要判断的是"接着上一句谁该说"，远古历史只会
  /// 白占预算。
  static String buildTranscript({
    required List<Message> messages,
    required Map<String, String> senderNames,
    required String ownerName,
    int maxMessages = maxHistoryMessages,
    int maxChars = maxHistoryChars,
  }) {
    final recent = messages.length > maxMessages
        ? messages.sublist(messages.length - maxMessages)
        : messages;
    final lines = <String>[];
    for (final message in recent) {
      final text = message.content.trim();
      if (text.isEmpty) continue;
      final name = message.senderId == 'user'
          ? ownerName
          : (senderNames[message.senderId] ?? '某人');
      lines.add('$name：${truncate(text, _maxLineChars)}');
    }
    // 从最早的一行开始丢，直到整段文字稿落进字符预算。
    var start = 0;
    var total = lines.fold<int>(0, (sum, line) => sum + line.length + 1);
    while (start < lines.length && total > maxChars) {
      total -= lines[start].length + 1;
      start++;
    }
    return lines.sublist(start).join('\n');
  }

  /// 解析选择器响应。
  ///
  /// 严格校验：正文必须是一个 JSON 对象、含 `speakerId` 字段、值是 null 或
  /// 候选集合中的 id 原文。任何其他形状（数组、裸字符串、多余字段里夹带的
  /// 指令、超长正文、指向不存在成员的 id）都判为 [AiSpeakerDecisionStatus.invalid]，
  /// 由调用方回落到本地编排器。
  static AiSpeakerDecision parseResponse(
    String? raw, {
    required Set<String> candidateIds,
  }) {
    final text = raw?.trim() ?? '';
    if (text.isEmpty || text.length > maxResponseChars) {
      return const AiSpeakerDecision.invalid();
    }
    final decoded = _decodeObject(text);
    if (decoded == null) return const AiSpeakerDecision.invalid();
    if (!decoded.containsKey('speakerId')) {
      return const AiSpeakerDecision.invalid();
    }
    final value = decoded['speakerId'];
    if (value == null) return const AiSpeakerDecision.finished();
    if (value is! String) return const AiSpeakerDecision.invalid();
    final id = value.trim();
    if (id.isEmpty || !candidateIds.contains(id)) {
      return const AiSpeakerDecision.invalid();
    }
    return AiSpeakerDecision.chosen(id);
  }

  /// 单行内容上限，避免一句话吃掉整段文字稿预算。
  static const int _maxLineChars = 120;

  static String _tagsSuffix(AICharacter character) {
    final tags = character.personalityTags
        .where((tag) => tag.trim().isNotEmpty)
        .take(4)
        .join('/');
    return tags.isEmpty ? '' : '，$tags';
  }

  /// 先按整段解析；失败时退一步取出最外层的 `{...}` 再解析。
  ///
  /// 模型偶尔会包一层 ```json 围栏或加一句赘述；只在**能解析出对象**的前提下
  /// 接受，解析不出就按失败处理，不做更宽松的猜测。
  ///
  /// 整段本身已经是合法的 JSON 非对象（数组 / 字符串）时直接判失败，不再往里
  /// 抠对象——那是模型给错了形状，而不是围栏；否则 `[{"speakerId":"a"}]` 会被
  /// 当成一次正常选择。
  static Map<String, dynamic>? _decodeObject(String text) {
    final direct = _tryDecodeMap(text);
    if (direct != null) return direct;
    if (text.startsWith('[') || text.startsWith('"')) return null;
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    return _tryDecodeMap(text.substring(start, end + 1));
  }

  static Map<String, dynamic>? _tryDecodeMap(String text) {
    try {
      final decoded = jsonDecode(text);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  /// 按字符数截断并加省略号。
  static String truncate(String text, int maxChars) {
    if (maxChars <= 0) return '';
    if (text.length <= maxChars) return text;
    return '${text.substring(0, maxChars)}…';
  }
}
