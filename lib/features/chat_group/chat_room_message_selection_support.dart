part of 'chat_room_page.dart';

/// 多选删除：进入 / 勾选 / 全选 / 删除 / 退出。
///
/// 单条删除与这里共用 [canDeleteRoomMessage] 与 [selectableMessageIds] 两条判据
/// （`message_selection.dart`），不各留一份——两份判据迟早只改一处，多选就能
/// 绕过"不可删"的规则把进度气泡删掉。
extension _ChatRoomMessageSelectionSupport on _ChatRoomPageState {
  /// 本次多选中允许勾选的消息 id：只覆盖已加载的这一页。
  Set<String> get _selectableMessageIds => selectableMessageIds(
        _messages,
        streamingMessageId: _streamingMessage?.id,
        isRealtimeGuest: _isRealtimeGuest,
      );

  /// 多选期间是否还跟随新内容滚动。
  ///
  /// 不跟随：勾选框的位置就是用户手指的位置，列表一动，点下去的就不是他要删的
  /// 那一条，而删除不可撤销。判据只在 `_scrollToBottom` 收口——流式跟随、外部
  /// 同步、发送后回底都经过它，所以多选期间视口整个冻结。
  bool get _shouldFollowNewContent => !_messageSelectionActive;

  /// 进入多选。[seed] 是长按发起时用户已经瞄上的那一条，进来就替他勾上。
  void _enterMessageSelection({Message? seed}) {
    if (_isRealtimeGuest || _messageSelectionActive) return;
    // 与"不跟随滚动"是同一条理由：自动发言在勾选期间冒出新气泡，正好顶动列表。
    _stopAutoChat();
    _setUiState(() {
      _messageSelectionActive = true;
      _selectedMessageIds.clear();
      if (seed != null) _selectedMessageIds.add(seed.id);
    });
  }

  void _exitMessageSelection() {
    if (!_messageSelectionActive) return;
    _setUiState(() {
      _messageSelectionActive = false;
      _selectedMessageIds.clear();
    });
    // 恢复空闲自动聊天；不满足条件时 `_startAutoChat` 自己会让位。
    _startAutoChat();
  }

  void _toggleMessageSelection(String messageId) {
    if (!_messageSelectionActive) return;
    if (!_selectableMessageIds.contains(messageId)) return;
    _setUiState(() {
      if (!_selectedMessageIds.remove(messageId)) {
        _selectedMessageIds.add(messageId);
      }
    });
  }

  /// 全选当前已加载的消息（不可删的那些不在此列）。
  void _selectAllMessages() {
    final selectable = _selectableMessageIds;
    _setUiState(() {
      _selectedMessageIds
        ..clear()
        ..addAll(selectable);
    });
  }

  /// 多选模式下的顶部栏：取消 / 已选 N 条 / 全选 / 删除。
  PreferredSizeWidget _buildMessageSelectionAppBar(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final count = _selectedMessageIds.length;
    return AppBar(
      backgroundColor: WeComChatTokens.chatBackground(context),
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      leadingWidth: 76,
      leading: TextButton(
        onPressed: _exitMessageSelection,
        child: const Text('取消'),
      ),
      title: Text(
        '已选 $count 条',
        style: TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: 18,
          color: cs.onSurface,
        ),
      ),
      actions: [
        TextButton(onPressed: _selectAllMessages, child: const Text('全选')),
        TextButton(
          onPressed: count == 0 ? null : _confirmDeleteSelectedMessages,
          child: Text('删除', style: TextStyle(color: cs.error)),
        ),
        const SizedBox(width: 8),
      ],
    );
  }

  /// 二次确认后删除勾中的消息。
  ///
  /// 与单条删除同一承诺：只删气泡，群记忆、角色记忆、心情都不动，引用它的
  /// 消息保留指针并显示「原消息已删除」。
  Future<void> _confirmDeleteSelectedMessages() async {
    final targets = _selectedMessageIds.toList(growable: false);
    if (targets.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('删除 ${targets.length} 条消息？'),
        content: const Text(
          '只删除勾选的这些气泡。群里和角色的记忆、心情都会保留；'
          '引用它们的消息会显示「原消息已删除」。此操作不可撤销。',
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

    final result = await _repository.deleteMessages(targets);
    if (!mounted || !_canTouchUi) return;
    if (!result.isComplete) {
      await showIncompleteDeletionDialog(context, result);
      return;
    }
    _forgetDeletedMessages(targets);
    _exitMessageSelection();
    if (!mounted) return;
    AppToast.show(
      context,
      '已删除 ${targets.length} 条消息',
      icon: Icons.check,
    );
  }
}
