part of 'chat_room_page.dart';

/// 单条消息的操作清单，以及长按弹窗 / 桌面右键菜单 / 真删除的落点。
///
/// 与 `chat_room_interaction_support.dart` 分开：那份管的是输入与引用之类的
/// 交互，这份管的是"对某一条消息能做什么"。
extension _ChatRoomMessageActionSupport on _ChatRoomPageState {
  /// 一条消息可执行的全部操作。
  ///
  /// 触屏长按弹窗（[MessageActionSheet]）与桌面右键菜单
  /// （[MessageActionContextMenu]）共用这一份：分开维护时新增入口只会落在其中
  /// 一边——桌面右键长期只有平台原生的「Copy」，就是这么来的。
  List<MessageActionItem> _messageActionsFor(
    Message message,
    AICharacter? sender,
  ) =>
      [
        MessageActionItem(
          icon: Icons.copy_rounded,
          label: '复制',
          onSelected: () => _copyMessage(message),
        ),
        ..._aiOnlyActionsFor(message, sender),
        // 引用回复对真人成员的消息同样可用：它只负责把文本带出去，
        // 真正读到这句话并决定谁来接话的是主人端。
        MessageActionItem(
          icon: Icons.format_quote_rounded,
          label: '引用回复',
          onSelected: () => _quoteMessage(message),
        ),
        if (_isTtsEnabled) _speechActionFor(message),
        MessageActionItem(
          icon: Icons.send_to_mobile_rounded,
          label: '推送到企业微信',
          onSelected: () => _showWeComPushDialog(message.content),
        ),
        if (_canDeleteMessage(message)) ...[
          _multiSelectActionFor(message),
          _deleteActionFor(message),
        ],
      ];

  /// 需要发送者身份的入口；真人成员与系统提示没有 sender，一项都不给。
  ///
  /// 客人端一律不调用 LLM，所以直接触发本机生成的入口都要藏掉，但
  /// 「@角色」「查看本条来源」保留：前者只是把文本发出去，真正的生成发生在
  /// 主人端——客人 @ 某个角色，主人端会看到这条消息并让该角色接话；
  /// 「查看来源」是纯本地读取。
  List<MessageActionItem> _aiOnlyActionsFor(
    Message message,
    AICharacter? sender,
  ) {
    if (sender == null) return const <MessageActionItem>[];
    final canRegenerate = !_isRealtimeGuest;
    return [
      if (canRegenerate)
        MessageActionItem(
          icon: Icons.refresh_rounded,
          label: '重新生成',
          onSelected: () => _regenerateAiReply(message, sender),
        ),
      if (canRegenerate && _canRefreshSourcesFor(message))
        MessageActionItem(
          icon: Icons.public_rounded,
          label: '刷新来源并重新生成',
          onSelected: () =>
              _regenerateAiReply(message, sender, forceRefresh: true),
        ),
      if (_canViewSourcesFor(message))
        MessageActionItem(
          icon: Icons.library_books_outlined,
          label: '查看本条来源',
          onSelected: () => _showSourcesForReply(message),
        ),
      MessageActionItem(
        icon: Icons.alternate_email_rounded,
        label: '@${sender.name}',
        onSelected: () => _insertMention(sender),
      ),
    ];
  }

  /// 「刷新来源并重新生成」是否可用：这一轮还能不能凑出一次带来源的生成。
  bool _canRefreshSourcesFor(Message message) =>
      _searchTurnController.contextForRegeneration(message.id) != null ||
      _snapshotFromMessage(message) != null ||
      _userMessageBefore(message) != null;

  /// 「查看本条来源」是否可用：读的是"这条回复当时用了哪些来源"。
  ///
  /// 与可刷新不是同一个判据：能重跑生成不代表这条已有的回复带过来源，
  /// 并成一个就会给出一个点下去没有来源可看的入口。
  bool _canViewSourcesFor(Message message) =>
      _searchTurnController.contextForReply(message.id) != null ||
      _snapshotFromMessage(message) != null;

  MessageActionItem _speechActionFor(Message message) {
    final isSpeakingThis = _isSpeaking && _speakingMessageId == message.id;
    return MessageActionItem(
      icon: isSpeakingThis ? Icons.stop_circle_rounded : Icons.volume_up_rounded,
      label: isSpeakingThis ? '停止朗读' : '朗读',
      onSelected: () {
        if (isSpeakingThis) {
          _ttsStop();
        } else {
          _ttsSpeak(message);
        }
      },
    );
  }

  MessageActionItem _deleteActionFor(Message message) => MessageActionItem(
        icon: Icons.delete_outline_rounded,
        label: '删除这条消息',
        destructive: true,
        onSelected: () => _confirmDeleteMessage(message),
      );

  /// 触屏长按消息弹出的操作面板。
  void _showMessageActionSheet(Message message, AICharacter? sender) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => MessageActionSheet(
        title: sender != null ? '${sender.name} 的消息' : '消息',
        items: _messageActionsFor(message, sender),
      ),
    );
  }

  /// 复制整条正文。
  ///
  /// 桌面右键菜单接管了 [SelectableText] 的原生工具栏之后，鼠标选区不再有复制
  /// 按钮，由这一项补回。它复制的是整条消息，不是当前选区。
  Future<void> _copyMessage(Message message) async {
    await Clipboard.setData(ClipboardData(text: message.content));
    if (!mounted) return;
    AppToast.show(context, '已复制消息内容', icon: Icons.check);
  }

  /// 这条消息是否给「删除」入口。
  ///
  /// 判据与多选的勾选框共用 [canDeleteRoomMessage]：各写一份时，新加的"不可删"
  /// 规则只会落在其中一边。
  bool _canDeleteMessage(Message message) => canDeleteRoomMessage(
        message,
        streamingMessageId: _streamingMessage?.id,
        isRealtimeGuest: _isRealtimeGuest,
      );

  /// 进入多选删除。长按的那条自动勾上：用户已经用动作指明他瞄的是这一条。
  MessageActionItem _multiSelectActionFor(Message message) => MessageActionItem(
        icon: Icons.checklist_rounded,
        label: '多选删除',
        onSelected: () => _enterMessageSelection(seed: message),
      );

  /// 二次确认后删除单条消息。
  ///
  /// 只删这一条气泡：群记忆、角色记忆、关系状态（心情）与永久记忆都不动，
  /// 引用它的消息保留指针并显示「原消息已删除」。
  Future<void> _confirmDeleteMessage(Message message) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除这条消息？'),
        content: const Text(
          '只删除这条气泡。群里和角色的记忆、心情都会保留；'
          '引用它的消息会显示「原消息已删除」。此操作不可撤销。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final result = await _repository.deleteMessage(
      message.id,
      // 保留记忆与心情：本条消息只是从会话里消失。
      invalidateGroupMemory: false,
      // 保留引用指针，被引用方据此显示「原消息已删除」。
      keepReplyReferences: true,
    );
    if (!mounted || !_canTouchUi) return;
    if (!result.isComplete) {
      await showIncompleteDeletionDialog(context, result);
      return;
    }
    _forgetDeletedMessage(message.id);
    if (!mounted) return;
    AppToast.show(context, '已删除这条消息', icon: Icons.check);
  }
}
