part of 'chat_room_page.dart';

extension _ChatRoomConversationMentionSupport on _ChatRoomPageState {
  void _hideMentionOverlay() {
    _mentionOverlay?.remove();
    _mentionOverlay = null;
    _showMentionPopup = false;
    _filteredMentionMembers = [];
    _mentionSelectedIndex = 0;
    _mentionSearchController.clear();
  }

  /// 在输入框上方弹出 @ 成员选择浮层。
  ///
  /// 用输入框的 [RenderBox] 实时定位：水平居中于输入框并夹在屏幕内，
  /// 垂直放在输入框上方，高度受输入框上方剩余空间限制（120~260px）。
  void _showMentionOverlay(Offset globalPosition) {
    if (_showMentionPopup) return;
    _showMentionPopup = true;
    _mentionSelectedIndex = 0;

    _mentionOverlay = OverlayEntry(
      builder: (context) {
        final cs = Theme.of(context).colorScheme;
        // 用 RenderBox 精确定位：找到输入框在屏幕上的位置，弹窗放在其上方。
        final renderBox =
            _inputFieldKey.currentContext?.findRenderObject() as RenderBox?;
        if (renderBox == null) return const SizedBox.shrink();
        final inputGlobalPos = renderBox.localToGlobal(Offset.zero);
        final screenWidth = MediaQuery.of(context).size.width;
        final screenHeight = MediaQuery.of(context).size.height;
        final inputTop = inputGlobalPos.dy;
        final inputLeft = inputGlobalPos.dx;
        final inputWidth = renderBox.size.width;

        // 弹窗宽度跟随输入框，但保持紧凑，避免遮住整页。
        final popupWidth = min(inputWidth, 280.0);
        // 水平居中于输入框。
        var left = inputLeft + (inputWidth - popupWidth) / 2;
        // 不超出屏幕左右边界。
        left = left.clamp(8.0, max(8.0, screenWidth - popupWidth - 8.0));
        final popupMaxHeight = min(max(inputTop - 16, 120.0), 260.0);

        final content = _buildMentionPopupContent(cs);
        return Positioned(
          left: left,
          // bottom 相对屏幕底部计算，使浮层贴在输入框上沿再留 8px 间隙。
          bottom: screenHeight - inputTop + 8,
          width: popupWidth,
          child: TapRegion(
            // 点击浮层外任意处即收起。
            onTapOutside: (_) => _hideMentionOverlay(),
            child: Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(12),
              color: cs.surfaceContainerHighest,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: popupMaxHeight),
                child: content,
              ),
            ),
          ),
        );
      },
    );

    final overlay = Overlay.of(context);
    overlay.insert(_mentionOverlay!);
  }

  /// 构建 @ 弹窗内容：标题栏（含人数）+ 搜索框 + 成员列表。
  Widget _buildMentionPopupContent(ColorScheme cs) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 280, maxHeight: 260),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题栏
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: Row(
              children: [
                Icon(Icons.alternate_email_rounded,
                    size: 16, color: cs.onSurfaceVariant),
                const SizedBox(width: 6),
                Text('提到谁',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: cs.onSurfaceVariant)),
                const Spacer(),
                Text('${_allGroupCharacters.length} 人',
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
              ],
            ),
          ),
          // 搜索框
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
            child: TextField(
              controller: _mentionSearchController,
              autofocus: false,
              decoration: InputDecoration(
                hintText: '搜索名称、角色或标签…',
                prefixIcon: Icon(Icons.search_rounded,
                    size: 16, color: cs.onSurfaceVariant),
                isDense: true,
                filled: true,
                fillColor: cs.surfaceContainerHighest.withValues(alpha: 0.6),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(
                      color: cs.outlineVariant.withValues(alpha: 0.6)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(
                      color: cs.outlineVariant.withValues(alpha: 0.6)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide:
                      BorderSide(color: cs.primary.withValues(alpha: 0.6)),
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
              onChanged: _onMentionSearchChanged,
            ),
          ),
          Divider(height: 1, color: cs.outlineVariant.withValues(alpha: 0.4)),
          // 成员列表（Expanded 保证 ListView 有可滚动的空间）
          Expanded(
            child: _buildMentionList(cs),
          ),
        ],
      ),
    );
  }

  /// @ 弹窗内搜索框的过滤逻辑：匹配名称 / 角色 / 个性标签。
  void _onMentionSearchChanged(String query) {
    final q = query.trim();
    if (q.isEmpty) {
      _filteredMentionMembers = List.from(_allGroupCharacters);
    } else {
      _filteredMentionMembers = _allGroupCharacters
          .where((c) =>
              c.name.contains(q) ||
              c.role.contains(q) ||
              c.personalityTags.any((tag) => tag.contains(q)))
          .toList();
    }
    _mentionSelectedIndex = 0;
    _mentionOverlay?.markNeedsBuild();
  }

  /// 是否展示 `@all` 选项：搜索为空，或搜索词是 all/所有人/全部 的前缀。
  bool get _showMentionAllOption {
    final q = _mentionSearchController.text.trim().toLowerCase();
    return q.isEmpty ||
        'all'.contains(q) ||
        '所有人'.contains(q) ||
        '全部'.contains(q);
  }

  /// 构建 @ 候选列表；`@all` 占据首项，故成员下标需整体后移一位。
  Widget _buildMentionList(ColorScheme cs) {
    final showAll = _showMentionAllOption;
    if (_filteredMentionMembers.isEmpty && !showAll) {
      return const Padding(
        padding: EdgeInsets.all(20),
        child: Center(child: Text('无匹配角色', style: TextStyle(fontSize: 14))),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: _filteredMentionMembers.length + (showAll ? 1 : 0),
      itemBuilder: (ctx2, i) {
        if (showAll && i == 0) {
          return _buildMentionAllTile(cs, selected: _mentionSelectedIndex == 0);
        }
        final memberIndex = showAll ? i - 1 : i;
        final c = _filteredMentionMembers[memberIndex];
        final pColor = _senderColor(c);
        final selected = i == _mentionSelectedIndex;
        return InkWell(
          onTap: () => _insertMention(c),
          borderRadius: BorderRadius.circular(10),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: selected
                  ? cs.primary.withValues(alpha: 0.14)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: pColor.withValues(alpha: 0.14),
                    border: Border.all(
                        color: pColor.withValues(alpha: 0.3), width: 1.2),
                  ),
                  child: Center(
                    child: Text(
                      c.avatar.isNotEmpty ? c.avatar : c.name[0],
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: pColor),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(c.name,
                          style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: cs.onSurface),
                          overflow: TextOverflow.ellipsis),
                      if (c.role.isNotEmpty)
                        Text(c.role,
                            style: TextStyle(
                                fontSize: 12, color: cs.onSurfaceVariant),
                            overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 构建 `@all`（提到所有群成员）这一项。
  Widget _buildMentionAllTile(ColorScheme cs, {required bool selected}) {
    return InkWell(
      onTap: _insertMentionAll,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? cs.primary.withValues(alpha: 0.14)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: cs.primary.withValues(alpha: 0.14),
                border: Border.all(color: cs.primary.withValues(alpha: 0.3)),
              ),
              child: Icon(Icons.groups_rounded, size: 18, color: cs.primary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('@all',
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: cs.onSurface),
                      overflow: TextOverflow.ellipsis),
                  Text('提到所有群成员',
                      style:
                          TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                      overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// @ 弹窗打开时的键盘导航：↑↓ 选择、回车插入、Esc 关闭。
  KeyEventResult _handleMentionKeyEvent(KeyEvent event) {
    if (!_showMentionPopup) return KeyEventResult.ignored;
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final key = event.logicalKey;
    // @all 占一项，故总选项数 = 成员数 + (是否展示 @all)。
    final optionCount =
        _filteredMentionMembers.length + (_showMentionAllOption ? 1 : 0);
    if (optionCount <= 0) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.arrowDown) {
      _setUiState(() {
        _mentionSelectedIndex =
            (_mentionSelectedIndex + 1).clamp(0, optionCount - 1);
      });
      _mentionOverlay?.markNeedsBuild();
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.arrowUp) {
      _setUiState(() {
        _mentionSelectedIndex =
            (_mentionSelectedIndex - 1).clamp(0, optionCount - 1);
      });
      _mentionOverlay?.markNeedsBuild();
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      // 回车确认当前高亮项：首项可能是 @all，其余按偏移取成员。
      if (_showMentionAllOption && _mentionSelectedIndex == 0) {
        _insertMentionAll();
      } else {
        final memberIndex = _showMentionAllOption
            ? _mentionSelectedIndex - 1
            : _mentionSelectedIndex;
        if (memberIndex >= 0 && memberIndex < _filteredMentionMembers.length) {
          _insertMention(_filteredMentionMembers[memberIndex]);
        }
      }
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.escape) {
      _hideMentionOverlay();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 插入 `@all `（提到所有群成员）。
  void _insertMentionAll() {
    _insertMentionText('@all ');
  }

  /// 插入对某个角色的 @ 引用。
  void _insertMention(AICharacter character) {
    _insertMentionText('@${character.name} ');
  }

  /// 用 [mentionText] 替换掉光标前那段正在输入的 `@查询词`。
  ///
  /// 从光标前一位向左找最近的 `@` 作为替换起点（找不到就从头替换），
  /// 插入后把光标移到 @ 文本之后，并立刻把焦点还给输入框。
  void _insertMentionText(String mentionText) {
    final text = _textController.text;
    int cursorPos = _textController.selection.baseOffset;
    // baseOffset 为 -1 表示无选区（未聚焦），退化为在末尾插入。
    if (cursorPos < 0) cursorPos = text.length;

    final searchEnd = cursorPos > 0 ? cursorPos - 1 : 0;
    int atPos = text.lastIndexOf('@', searchEnd);
    if (atPos < 0) atPos = 0;

    final newText =
        '${text.substring(0, atPos)}$mentionText${text.substring(cursorPos)}';
    _textController.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: atPos + mentionText.length),
    );

    // Overlay dismissal can steal focus; restore it immediately.
    _inputFocusNode.requestFocus();
    _hideMentionOverlay();
  }

  /// 判断光标是否处于「@后跟非空格字符」的输入状态（即应显示 @ 弹窗）。
  bool _isInMentionQuery(String text, int cursorPos) {
    if (cursorPos <= 0) return false;
    final textBeforeCursor = text.substring(0, cursorPos);
    final atIndex = textBeforeCursor.lastIndexOf('@');
    if (atIndex < 0) return false;
    final query = textBeforeCursor.substring(atIndex + 1);
    return !query.contains(' ');
  }

  /// 输入框文本变化时维护 @ 弹窗的显示与候选过滤。
  ///
  /// 私聊没有 @ 概念，直接返回。弹窗未开时检测是否刚进入 `@查询` 状态并弹出；
  /// 已开时按光标前的 `@查询词` 重新过滤，遇到空格或删掉 `@` 则收起。
}
