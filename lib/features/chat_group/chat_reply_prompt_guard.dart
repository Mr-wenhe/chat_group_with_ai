import '../../core/models/message.dart';
import '../direct_chat/direct_chat_session.dart';
import 'group_shared_context.dart';

/// 一次普通回复请求里**必须完整保留**的内容。
///
/// 窗口裁剪可以砍掉旧历史、可选摘要和公开资料，但四类内容缺一不可：
///
/// 1. **本群固定共同设定**——它承诺"每次聊天都生效"；
/// 2. **当前角色人设**——缺了它，角色不知道自己是谁；
/// 3. **本轮真人输入**——缺了它，等于在不知道用户要求了什么的情况下回答；
/// 4. **本轮最新的一条对话**——缺了它，角色接不上刚发生的那句话。
///
/// 第 1、2 类按正文识别；第 3 类由提示词构建器在拼装时交出来（[currentUserTurn]）；
/// 第 4 类按"构建完成后最后一条非 system 消息"的位置识别——提示词按时间顺序
/// 拼接，最新一条永远在末尾（联网证据会插到它前面）。
///
/// 第 3、4 类必须**同时**保护，不能用一个代表另一个：群聊里第二位及以后的角色
/// 生成回复时，末尾那条是上一位 AI 的发言（提示词把其他角色的发言也映射成
/// `user` 角色），而窗口裁剪先删最旧的对话条目——真人这条正好排在最前面，会被
/// 删掉，末尾那位 AI 的发言却还在，于是"最新一条对话"看起来毫发无损，请求照发，
/// 后半段要求（主题、约定、称呼）已经随着真人那条一起消失。
///
/// 只核对共同设定会漏掉几种静默损坏：角色不知道自己是谁、用户刚说的话被清成
/// 空串、或者用户的要求被上一位 AI 的闲聊顶掉，而请求照常发出去、回复看起来还
/// 很正常。因此 [isRequired] 与 [survives] 必须成对使用：前者只是裁剪优先级，
/// 后者才是"能不能发"的判据。
class ChatReplyPromptGuard {
  /// 共同设定的完整正文；空串表示本群没有设定，不作要求。
  final String sharedContext;

  /// 当前角色人设的完整正文。
  final String personaPrompt;

  /// 本轮**真人**输入在最终请求里的形态（由提示词构建器拼装时交出）。
  ///
  /// 多模态内容是列表，按对象同一性比对；null 表示本轮没有新的真人输入
  /// （空闲自动回合、重新生成），或该输入按可见性规则根本没进请求。
  final Object? currentUserTurn;

  /// 本轮最新一条对话的正文。多模态内容是列表，按对象同一性比对。
  final Object? latestTurn;

  /// 续聊调度指令前已发送的 AI 原文；调度指令不能替它占据保护名额。
  final Object? continuationContext;

  final List<String> documentContexts;

  const ChatReplyPromptGuard({
    required this.sharedContext,
    required this.personaPrompt,
    required this.latestTurn,
    this.currentUserTurn,
    this.continuationContext,
    this.documentContexts = const [],
  });

  /// 从**尚未裁剪**的请求里认出这次必须保住的内容。
  ///
  /// [currentUserTurn] 只能由构建器交出实际拼进去的那份内容，不能在这里用
  /// "最后一条非 system 消息"推断——那正是上一位 AI 的发言。刻意标成 required
  /// 而不是可选：漏传就等于退回"上一位 AI 的发言替真人输入背书"的旧行为，
  /// 而那种损坏看不出来，必须让调用方显式表态（本轮确实没有真人输入就传 null）。
  static ChatReplyPromptGuard collect(
    List<Map<String, dynamic>> messages, {
    required String sharedContext,
    required String personaPrompt,
    required Object? currentUserTurn,
  }) {
    Object? latestTurn;
    for (var index = messages.length - 1; index >= 0; index--) {
      if (messages[index]['role'] == 'system') continue;
      latestTurn = messages[index]['content'];
      break;
    }
    Object? continuationContext;
    if (latestTurn == DirectChatSession.continuationInstruction) {
      for (final message in messages.reversed) {
        if (message['role'] != 'assistant') continue;
        continuationContext = message['content'];
        break;
      }
    }
    return ChatReplyPromptGuard(
      sharedContext: sharedContext,
      personaPrompt: personaPrompt,
      latestTurn: latestTurn,
      continuationContext: continuationContext,
      currentUserTurn: currentUserTurn,
      documentContexts: messages
          .where((message) => message['role'] == 'system')
          .map((message) => message['content'])
          .whereType<String>()
          .where((content) => content.startsWith('【本地文档检索资料｜'))
          .toList(growable: false),
    );
  }

  /// **重新生成**时用来定位"这一轮真人输入"的判据：上下文里最后一条真人消息。
  ///
  /// 被重新生成的那条 AI 回复已经先从上下文里剔除，因此它前面最近的一条真人消息
  /// 就是这次答复所依据的要求。两种情形都能定对：群聊里已经有人接过话（末尾是
  /// 另一位角色的发言），以及用户连着追加了两句（末尾那条才是要回应的）。
  ///
  /// 与 [collect] 的第三类必需内容配套：只有找对了这条消息，才能把它的实际形态
  /// 交给守卫去保护。
  static Message? lastHumanInput(Iterable<Message> messages) {
    for (final message in messages.toList().reversed) {
      if (message.senderType == Message.senderTypeUser) return message;
    }
    return null;
  }

  /// 压缩旧历史时保留当前一轮的原文，避免把已回复的输入再次当作待回答。
  static List<Message> currentExchange(List<Message> messages) {
    for (var index = messages.length - 1; index >= 0; index--) {
      if (messages[index].senderType == Message.senderTypeUser) {
        return messages.sublist(index);
      }
    }
    return messages.isEmpty ? const [] : [messages.last];
  }

  /// 裁剪时的保护判据：这些条目只在其它内容都让位之后才被动。
  bool isRequired(Map<String, dynamic> message) {
    if (GroupSharedContext.carriesBlock(message)) return true;
    final content = message['content'];
    if (personaPrompt.trim().isNotEmpty &&
        content is String &&
        content == personaPrompt) {
      return true;
    }
    if (documentContexts.contains(content)) return true;
    if (message['role'] == 'system') return false;
    if (_carries(content, currentUserTurn)) return true;
    if (_carries(content, continuationContext)) return true;
    return _carries(content, latestTurn);
  }

  /// 裁剪之后核对：必需内容里**没能完整保留**的一项的说明；全部幸存时返回 null。
  ///
  /// 任何一项缺失都意味着这次请求不该发出去——请调用方走有界失败，而不是
  /// 把一份"角色不知道自己是谁、或者没读到用户这句话"的提示词交给模型。
  String? missingFrom(List<Map<String, dynamic>> messages) {
    if (!GroupSharedContext.survives(messages, sharedContext)) {
      return '本群「共同背景」与「群公告与约定」';
    }
    final persona = personaPrompt.trim();
    if (persona.isNotEmpty &&
        !messages.any((message) => message['content'] == personaPrompt)) {
      return '当前角色的角色设定';
    }
    // 真人输入先于"最新一条对话"核对：后者常常只是接话上下文，先报它会把
    // "用户的要求被丢了"说成"接话上下文被丢了"。
    if (_turnMissing(messages, currentUserTurn)) return '本轮真人输入';
    if (_turnMissing(messages, latestTurn)) return '本轮最新一条对话';
    if (_turnMissing(messages, continuationContext)) return '续聊前已发送的回复';
    if (documentContexts.any((content) =>
        !messages.any((message) => message['content'] == content))) {
      return '附件正文资料';
    }
    return null;
  }

  /// 必需内容是否都**完整**留在最终请求里。
  bool survives(List<Map<String, dynamic>> messages) =>
      missingFrom(messages) == null;

  /// [turn] 本该完整留在请求里，却已经不在了。
  ///
  /// 本来就缺席或是空白（自动回合没有新输入）时没有可保护的内容。
  static bool _turnMissing(List<Map<String, dynamic>> messages, Object? turn) {
    if (turn == null) return false;
    if (turn is String && turn.trim().isEmpty) return false;
    return !messages.any((message) =>
        message['role'] != 'system' && _sameContent(message['content'], turn));
  }

  static bool _carries(Object? content, Object? turn) =>
      turn != null && _sameContent(content, turn);

  static bool _sameContent(Object? a, Object? b) {
    if (a is String && b is String) return a == b;
    return identical(a, b);
  }
}
