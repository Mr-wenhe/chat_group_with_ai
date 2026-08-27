part of 'chat_room_page.dart';

extension _ChatRoomUiSupport on _ChatRoomPageState {
  /// 空会话时的引导页：图标 + 标题 + 用法说明 + 提示 chip（群聊/私聊文案不同）。
  Widget _buildEmptyState(ColorScheme cs) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 88,
              height: 88,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: AppTheme.primaryGradient,
              ),
              child: Icon(
                  _isDirectChat
                      ? Icons.chat_bubble_rounded
                      : Icons.groups_rounded,
                  size: 44,
                  color: Colors.white),
            ),
            const SizedBox(height: 24),
            Text(
                _isDirectChat
                    ? (_group?.name ?? '私聊')
                    : '欢迎来到 ${_group?.name ?? '群聊'}',
                style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface)),
            const SizedBox(height: 8),
            Text(
              _isDirectChat
                  ? '发条消息，和这个角色单独聊聊。\n对话会保存在本地。'
                  : '这是一个 AI 群聊模拟器。\n发条消息，AI 角色会自动回复；\n用 @ 可以指定某个角色回应。',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 14, height: 1.6, color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                HintChip(text: '说句「你好」试试', cs: cs),
                if (!_isDirectChat) HintChip(text: '@角色名 提到谁', cs: cs),
                if (!_isDirectChat && _characters.isNotEmpty)
                  HintChip(text: '${_characters.length} 位 AI 在线', cs: cs),
                if (_isDirectChat && _allGroupCharacters.isNotEmpty)
                  HintChip(text: _allGroupCharacters.first.role, cs: cs),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 弹出群成员列表面板（可查看状态、进角色设置、发起私聊）。
  void _showMembersSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => MemberSheet(
        characters: _characters,
        ownerName: _ownerMentionName,
        senderColor: _senderColor,
        statusText: _memberStatusText,
        onOpenSettings: _openCharacterSettings,
        onDirectChat: (character) {
          if (mounted) Navigator.of(context).pushNamed('/dm/${character.id}');
        },
      ),
    );
  }

  /// 清空当前群聊或私聊，并让用户明确选择是否删除来源永久数据。
  Future<void> _showClearConversationDialog() async {
    final service = DataLifecycleService(db: _db);
    var deleteAssociatedPermanentData = false;
    var displayedPlan = await service.previewConversation(widget.groupId);
    if (!mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          icon: const Icon(Icons.delete_sweep_outlined, color: Colors.orange),
          title: Text(_isDirectChat ? '清空私聊' : '清空群聊'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '默认删除：${displayedPlan.count('messages')} 条消息、'
                    '${displayedPlan.count('groupMemories') + displayedPlan.count('characterMemories')} 条场合记忆、'
                    '${displayedPlan.count('relationshipStates')} 条旧关系、'
                    '${displayedPlan.count('tasks')} 个任务、'
                    '${displayedPlan.count('workspaces')} 条工作区记录。',
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '默认保留：${displayedPlan.retainedCount('permanentMemories')} 条永久记忆、'
                    '${displayedPlan.retainedCount('relationshipEvents')} 条关系事件、'
                    '${displayedPlan.retainedCount('globalRelationshipStates')} 条全局关系快照。',
                  ),
                  const SizedBox(height: 8),
                  if (displayedPlan.optionalCounts.isNotEmpty)
                    Text(
                      '可选关联删除：${displayedPlan.optionalCount('permanentMemories')} 条永久记忆、'
                      '${displayedPlan.optionalCount('relationshipEvents')} 条关系事件。',
                    )
                  else
                    Text(
                      '本次将删除来源永久数据：${displayedPlan.count('permanentMemories')} 条永久记忆、'
                      '${displayedPlan.count('relationshipEvents')} 条关系事件。',
                    ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: deleteAssociatedPermanentData,
                    title: const Text('同时删除源自此会话的永久记忆和关系事件'),
                    subtitle: const Text(
                      '只匹配完整来源 ID；未知来源、其他场合和全局关系快照不会删除。',
                    ),
                    onChanged: (value) async {
                      final nextValue = value ?? false;
                      final nextPlan = await service.previewConversation(
                        widget.groupId,
                        deleteAssociatedPermanentData: nextValue,
                      );
                      if (!dialogContext.mounted) return;
                      setDialogState(() {
                        deleteAssociatedPermanentData = nextValue;
                        displayedPlan = nextPlan;
                      });
                    },
                  ),
                  Text(
                    '会话状态 ${displayedPlan.count('settings')} 项，'
                    '索引 ${displayedPlan.count('sessionIndexes')} 项，'
                    '记忆 pin ${displayedPlan.count('memoryPins')} 个，'
                    '重试记录 ${displayedPlan.count('retryRecords')} 条，'
                    '附件 ${displayedPlan.count('attachments')} 个。'
                    '此操作不可撤销。',
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              child: const Text('清空'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;

    final result = await _repository.clearConversation(
      deleteAssociatedPermanentData: deleteAssociatedPermanentData,
    );
    if (!_canTouchUi) return;
    final loaded = await _loader.load(widget.groupId);
    if (!_canTouchUi) return;
    _setUiState(() {
      _group = loaded.displayGroup;
      _userProfile = loaded.userProfile;
      _characters = loaded.activeCharacters;
      _allGroupCharacters = loaded.allCharacters;
      _messages = loaded.messages;
      _hasRestrictedHistory = loaded.hasRestrictedHistory;
      _hasOlderMessages = loaded.hasOlderMessages;
      _totalMessageCount = loaded.totalMessageCount;
      _groupMemory = loaded.groupMemory;
      _characterMemories = loaded.characterMemories;
      _relationshipStates = loaded.relationships;
      _streamingMessage = null;
      _pendingMentionedIds.clear();
      _pendingUserMentionMessageIds.clear();
      _searchResults = const <Message>[];
    });
    if (!result.isComplete && mounted) {
      await showIncompleteDeletionDialog(context, result);
      return;
    }
    if (mounted) {
      final message = deleteAssociatedPermanentData
          ? '会话已清空，来源永久数据已按选择删除'
          : '会话已清空，永久记忆和关系事件已保留';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  /// 打开只读记忆浏览页；返回时保留聊天页已有的消息和滚动状态。
  Future<void> _openMemoryManagement() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => MemoryManagementPage(
        scope: _isDirectChat && _directCharacterId != null
            ? MemoryConversationScope.direct(_directCharacterId!)
            : MemoryConversationScope.group(
                (_group?.aiCharacterIds ??
                        _characters.map((character) => character.id))
                    .toSet(),
              ),
      ),
    ));
  }

  /// Opens a read-only directional relationship for DMs and the scoped audit
  /// browser for groups. The group scope only narrows observers; the snapshot
  /// itself remains global and the conversation ID is used by the detail page.
  Future<void> _openRelationshipAudit() async {
    if (_isDirectChat && _directCharacterId != null) {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => RelationshipPrivateDetailPage(
            characterId: _directCharacterId!,
          ),
        ),
      );
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RelationshipAuditPage(
          conversationId: widget.groupId,
          conversationName: _group?.name,
          allowedObserverCharacterIds: (_group?.aiCharacterIds ??
                  _characters.map((character) => character.id))
              .toSet(),
        ),
      ),
    );
  }

  /// 成员面板里的单行状态文案：「性别 · 职业 · 年龄 · 回复状态 · 本小时用量」。
  String _memberStatusText(AICharacter c) {
    return formatMemberStatus(c, _blockReasonFor(c));
  }

  /// 跳转到角色编辑页。
  void _openCharacterSettings(AICharacter character) {
    Navigator.of(context).push(
      MaterialPageRoute(
          builder: (_) => AICharacterFormPage(character: character)),
    );
  }
}
