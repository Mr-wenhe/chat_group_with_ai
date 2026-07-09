import 'dart:async';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/theme/app_theme.dart';
import 'package:chat_group/core/theme/provider_style.dart';
import 'package:chat_group/core/widgets/app_widgets.dart';
import 'package:chat_group/features/direct_chat/direct_chat_inbox.dart';
import 'package:chat_group/features/direct_chat/direct_chat_proactive_service.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:chat_group/services/conversation_presence_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class DirectChatListPage extends ConsumerStatefulWidget {
  const DirectChatListPage({super.key});

  @override
  ConsumerState<DirectChatListPage> createState() => _DirectChatListPageState();
}

class _DirectChatListPageState extends ConsumerState<DirectChatListPage> {
  late final DatabaseService _db;
  Timer? _refreshTimer;
  List<DirectChatSummary> _summaries = [];
  bool _isCheckingProactive = false;

  @override
  void initState() {
    super.initState();
    _db = ref.read(databaseServiceProvider);
    _loadSummaries();
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _loadSummaries(),
    );
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  void _loadSummaries() {
    final summaries = DirectChatInbox.buildSummaries(
      characters: _db.aiCharacterBox.values.toList(),
      messages: _db.messageBox.values.toList(),
      readAtByConversation: _db.directChatReadAtByConversation(),
      sourceByConversation: _db.directChatSourceByConversation(),
      activeConversationId:
          ConversationPresenceService.instance.activeConversationId,
    );
    final pinnedIds = _db.pinnedCharacterIds();
    final originalIndex = <String, int>{
      for (var i = 0; i < summaries.length; i++) summaries[i].conversationId: i,
    };
    summaries.sort((a, b) {
      final aPinned = pinnedIds.contains(a.character.id);
      final bPinned = pinnedIds.contains(b.character.id);
      if (aPinned != bPinned) return aPinned ? -1 : 1;
      return (originalIndex[a.conversationId] ?? 0)
          .compareTo(originalIndex[b.conversationId] ?? 0);
    });
    if (!mounted) return;
    setState(() => _summaries = summaries);
  }

  Future<void> _checkProactiveNow() async {
    if (_isCheckingProactive) return;
    setState(() => _isCheckingProactive = true);
    final messenger = ScaffoldMessenger.of(context);
    final result =
        await DirectChatProactiveService(db: _db).tryCreateProactiveMessage();
    if (!mounted) return;
    setState(() => _isCheckingProactive = false);
    _loadSummaries();
    if (result == null) {
      messenger.showSnackBar(const SnackBar(
        content: Text('暂时没有角色主动来聊'),
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }
    messenger.showSnackBar(SnackBar(
      content: Text('${result.character.name} 主动发来一条私聊'),
      behavior: SnackBarBehavior.floating,
      action: SnackBarAction(
        label: '查看',
        onPressed: () => _openDirectChatByCharacterId(result.character.id),
      ),
    ));
  }

  Future<void> _openDirectChat(DirectChatSummary summary) async {
    await _db.markDirectChatRead(
      summary.conversationId,
      readAt:
          summary.lastMessage.timestamp.add(const Duration(milliseconds: 1)),
    );
    _loadSummaries();
    final characterId = summary.character.id;
    if (!mounted) return;
    await Navigator.of(context).pushNamed('/dm/$characterId');
    _loadSummaries();
  }

  Future<void> _openDirectChatByCharacterId(String characterId) async {
    await Navigator.of(context).pushNamed('/dm/$characterId');
    _loadSummaries();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final unreadCount = DirectChatInbox.totalUnread(_summaries);

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        backgroundColor: cs.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                gradient: AppTheme.primaryGradient,
                borderRadius: BorderRadius.circular(9),
              ),
              child: const Icon(Icons.chat_bubble_rounded,
                  size: 18, color: Colors.white),
            ),
            const SizedBox(width: 12),
            Text('私聊',
                style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 22,
                    color: cs.onSurface)),
            if (unreadCount > 0) ...[
              const SizedBox(width: 8),
              Badge(label: Text('$unreadCount')),
            ],
          ],
        ),
        actions: [
          IconButton(
            onPressed: _isCheckingProactive ? null : _checkProactiveNow,
            icon: _isCheckingProactive
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: cs.primary,
                    ),
                  )
                : const Icon(Icons.auto_awesome_rounded, size: 22),
            tooltip: '检查主动私聊',
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _summaries.isEmpty
          ? _buildEmptyState(cs)
          : ListView.builder(
              padding: const EdgeInsets.all(20),
              itemCount: _summaries.length,
              itemBuilder: (context, index) {
                final summary = _summaries[index];
                return _DirectChatCard(
                  summary: summary,
                  cs: cs,
                  isPinned: _db.pinnedCharacterIds().contains(
                        summary.character.id,
                      ),
                  onTap: () => _openDirectChat(summary),
                  onTogglePin: () =>
                      _togglePinnedCharacter(summary.character.id),
                );
              },
            ),
      bottomNavigationBar: AppBottomNav(currentIndex: 2, cs: cs),
    );
  }

  Widget _buildEmptyState(ColorScheme cs) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                color: cs.primaryContainer.withOpacity(0.5),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.mark_chat_unread_rounded,
                  size: 44, color: cs.primary),
            ),
            const SizedBox(height: 24),
            Text('还没有私聊',
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface)),
            const SizedBox(height: 8),
            Text(
              '从角色卡片或群成员列表点聊天图标，\n也可以等活跃角色主动来找你。',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 14, height: 1.5, color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _togglePinnedCharacter(String characterId) async {
    await _db.togglePinnedCharacter(characterId);
    _loadSummaries();
  }
}

class _DirectChatCard extends StatelessWidget {
  final DirectChatSummary summary;
  final ColorScheme cs;
  final bool isPinned;
  final VoidCallback onTap;
  final VoidCallback onTogglePin;

  const _DirectChatCard({
    required this.summary,
    required this.cs,
    required this.isPinned,
    required this.onTap,
    required this.onTogglePin,
  });

  @override
  Widget build(BuildContext context) {
    final character = summary.character;
    final color = providerColor(character.apiProvider);
    final sourceText = summary.source == DirectChatSource.group ? '来自群聊' : '私聊';
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      color: summary.hasUnread
          ? cs.primaryContainer.withOpacity(0.28)
          : cs.surfaceContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(
          color: summary.hasUnread
              ? cs.primary.withOpacity(0.45)
              : cs.outlineVariant,
          width: summary.hasUnread ? 1.5 : 1,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: color.withOpacity(0.14),
                child: Text(
                  character.avatar.isNotEmpty
                      ? character.avatar
                      : character.name.substring(0, 1),
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            character.name,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: cs.onSurface,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (summary.hasUnread)
                          Badge(label: Text('${summary.unreadCount}')),
                        if (isPinned) ...[
                          const SizedBox(width: 6),
                          Icon(Icons.push_pin_rounded,
                              size: 14, color: cs.primary),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _lastMessagePreview(summary.lastMessage),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: cs.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            sourceText,
                            style: TextStyle(
                                fontSize: 11, color: cs.onSurfaceVariant),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _timeLabel(summary.lastMessage.timestamp),
                          style: TextStyle(
                              fontSize: 12, color: cs.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                onPressed: onTogglePin,
                icon: Icon(
                  isPinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
                  size: 20,
                ),
                color: isPinned ? cs.primary : cs.onSurfaceVariant,
                tooltip: isPinned ? '取消置顶' : '置顶',
              ),
              Icon(Icons.chevron_right_rounded, color: cs.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }

  String _lastMessagePreview(Message message) {
    final speaker = message.senderType == 'user' ? '我' : summary.character.name;
    return '$speaker：${message.content.replaceAll(RegExp(r'\\s+'), ' ')}';
  }

  String _timeLabel(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes}分钟前';
    if (diff.inDays < 1) return '${diff.inHours}小时前';
    if (diff.inDays < 7) return '${diff.inDays}天前';
    return '${dt.month}/${dt.day}';
  }
}
