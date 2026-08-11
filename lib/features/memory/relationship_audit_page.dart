import 'dart:async';

import 'package:chat_group/core/database/data_lifecycle_service.dart';
import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/core/models/user_profile.dart';
import 'package:chat_group/features/chat_group/chat_room_page.dart';
import 'package:chat_group/features/memory/relationship_audit_card.dart';
import 'package:chat_group/features/memory/relationship_audit_filter.dart';
import 'package:chat_group/features/memory/relationship_audit_filter_widget.dart';
import 'package:chat_group/features/memory/relationship_controls.dart';
import 'package:chat_group/features/memory/relationship_edit_dialog.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class RelationshipAuditPage extends ConsumerStatefulWidget {
  /// The optional conversation only seeds an event-timeline filter.
  final String? conversationId;

  const RelationshipAuditPage({
    super.key,
    this.conversationId,
  });

  @override
  ConsumerState<RelationshipAuditPage> createState() =>
      _RelationshipAuditPageState();
}

class _RelationshipAuditPageState extends ConsumerState<RelationshipAuditPage> {
  late final DatabaseService _db;
  late final RelationshipControls _controls;
  late RelationshipAuditFilter _filter;
  List<RelationshipState> _relationships = const [];
  List<RelationshipState> _legacyRelationships = const [];
  List<AICharacter> _characters = const [];
  UserProfile? _userProfile;
  Map<String, Message> _sourceMessagesById = const {};
  Map<String, String> _originConversations = const {};
  bool _isLoading = true;
  Object? _loadError;

  @override
  void initState() {
    super.initState();
    _db = ref.read(databaseServiceProvider);
    _controls = RelationshipControls(_db);
    _filter = RelationshipAuditFilter(
      originConversationId: widget.conversationId,
    );
    unawaited(_loadSnapshot());
  }

  Future<void> _loadSnapshot() async {
    if (mounted) {
      setState(() {
        _isLoading = true;
        _loadError = null;
      });
    }
    try {
      await Future<void>.value();
      final allStates = _db.relationshipStateBox.values.toList(growable: false);
      final global = _controls.globalRelationships();
      final legacy = allStates
          .where((relationship) => relationship.groupId != 'global')
          .toList(growable: false);
      final referencedCharacterIds = <String>{
        for (final relationship in allStates) ...{
          relationship.sourceCharacterId,
          if (relationship.targetType == RelationshipTargetType.ai)
            relationship.targetId,
        },
      };
      final characterIds = <String>{
        ..._db.aiCharacterBox.values.map((character) => character.id),
        ...referencedCharacterIds,
      };
      final characters = DataLifecycleService(db: _db).charactersForIds(
        characterIds,
      );
      final userProfile = _db.userProfileBox.get('me');
      final allEvents = _db.relationshipEventBox.values.toList(growable: false);
      final sourceIds =
          allEvents.expand((event) => event.sourceMessageIds).toSet();
      final sourceMessages = <String, Message>{};
      for (final sourceId in sourceIds) {
        final message = _db.messageBox.get(sourceId);
        if (message != null) sourceMessages[sourceId] = message;
      }
      final origins = <String, String>{};
      for (final event in allEvents) {
        final conversationId = event.originConversationId;
        if (conversationId == null || conversationId.trim().isEmpty) continue;
        origins.putIfAbsent(
          conversationId,
          () => event.originNameSnapshot.trim().isEmpty
              ? conversationId
              : event.originNameSnapshot.trim(),
        );
      }
      if (!mounted) return;
      setState(() {
        _relationships = global;
        _legacyRelationships = legacy;
        _characters = characters;
        _userProfile = userProfile;
        _sourceMessagesById = sourceMessages;
        _originConversations = origins;
        _isLoading = false;
        _loadError = null;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _loadError = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return _loadingScaffold();
    if (_loadError != null) return _errorScaffold();

    final filtered = _filter.apply(
      _relationships,
      isPinned: _controls.isPinned,
    );
    final charactersById = {
      for (final character in _characters) character.id: character
    };

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _filter.isEmpty ? '全局关系审计' : '关系筛选（${filtered.length} 条）',
        ),
        actions: [
          if (!_filter.isEmpty)
            IconButton(
              tooltip: '清除筛选',
              onPressed: () => setState(
                () => _filter = const RelationshipAuditFilter(),
              ),
              icon: const Icon(Icons.filter_list_off_rounded),
            ),
          IconButton(
            tooltip: '刷新',
            onPressed: _loadSnapshot,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: RelationshipAuditFilterWidget(
              filter: _filter,
              characters: _characters,
              originConversations: _originConversations,
              onChanged: (filter) => setState(() => _filter = filter),
            ),
          ),
          if (_filter.originConversationId != null)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(14, 0, 14, 8),
                child: Text('当前关系不受场合限制，场合筛选只作用于事件时间线'),
              ),
            ),
          const SliverToBoxAdapter(child: Divider(height: 1)),
          if (filtered.isEmpty)
            const SliverToBoxAdapter(
              child: SizedBox(
                height: 260,
                child: Center(child: Text('没有符合条件的全局关系')),
              ),
            )
          else
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final relationship = filtered[index];
                  return RelationshipAuditCard(
                    relationship: relationship,
                    observerName: _observerName(relationship, charactersById),
                    targetName: _targetName(relationship, charactersById),
                    events: _controls.eventsFor(
                      relationship,
                      originConversationId: _filter.originConversationId,
                    ),
                    pinned: _controls.isPinned(relationship),
                    sourceMessagesById: _sourceMessagesById,
                    canOpenSource: _canOpenSource,
                    onEdit: () => _showEditDialog(relationship),
                    onReset: () => _confirmReset(relationship),
                    onDelete: () => _confirmDelete(relationship),
                    onPin: () => _setPinned(relationship, true),
                    onUnpin: () => _setPinned(relationship, false),
                    onOpenSource: _openSourceMessage,
                  );
                },
                childCount: filtered.length,
              ),
            ),
          _legacyDiagnostic(charactersById),
        ],
      ),
    );
  }

  Widget _loadingScaffold() {
    return const Scaffold(
      appBar: _PageAppBar(),
      body: Center(child: CircularProgressIndicator()),
    );
  }

  Widget _errorScaffold() {
    return Scaffold(
      appBar: const _PageAppBar(),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded, size: 40),
              const SizedBox(height: 12),
              const Text('关系数据加载失败'),
              const SizedBox(height: 8),
              Text(
                '请检查本地数据状态后重试。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _loadSnapshot,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _legacyDiagnostic(Map<String, AICharacter> charactersById) {
    if (_legacyRelationships.isEmpty) return const SliverToBoxAdapter();
    return SliverToBoxAdapter(
      child: Card(
        margin: const EdgeInsets.fromLTRB(12, 18, 12, 24),
        child: ExpansionTile(
          initiallyExpanded: false,
          title: const Text('旧版关系诊断'),
          subtitle: const Text('只读 · 旧版数据不会作为当前关系，也不能编辑'),
          children: [
            for (final relationship in _legacyRelationships)
              ListTile(
                dense: true,
                leading: const Icon(Icons.history_toggle_off_rounded),
                title: Text(
                  '${_observerName(relationship, charactersById)} → '
                  '${_targetName(relationship, charactersById)}',
                ),
                subtitle: Text(
                  '来源群组：${relationship.groupId} · 旧版数据 · 只读',
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _observerName(
    RelationshipState relationship,
    Map<String, AICharacter> charactersById,
  ) =>
      charactersById[relationship.sourceCharacterId]?.name ?? '已删除角色';

  String _targetName(
    RelationshipState relationship,
    Map<String, AICharacter> charactersById,
  ) {
    if (relationship.targetType == RelationshipTargetType.user) {
      final displayName = _userProfile?.displayName.trim() ?? '';
      return displayName.isEmpty ? '我' : displayName;
    }
    return charactersById[relationship.targetId]?.name ?? '已删除角色';
  }

  bool _canOpenSource(Message message) {
    if (message.groupId.startsWith('dm:')) {
      final characterId = message.groupId.substring(3);
      return _db.aiCharacterBox.get(characterId) != null ||
          DataLifecycleService(db: _db).deletedCharacter(characterId) != null;
    }
    return _db.chatGroupBox.get(message.groupId) != null;
  }

  void _openSourceMessage(Message message) {
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatRoomPage(
          groupId: message.groupId,
          initialMessageId: message.id,
        ),
      ),
    );
  }

  Future<void> _setPinned(
    RelationshipState relationship,
    bool pinned,
  ) async {
    try {
      await _controls.setPinned(relationship, pinned);
      await _loadSnapshot();
    } on Object catch (error) {
      _showError('固定状态保存失败：$error');
    }
  }

  Future<void> _showEditDialog(RelationshipState relationship) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => RelationshipEditDialog(
        relationship: relationship,
        onSave: (values) async {
          await _controls.applyManualUpdate(
            relationship: relationship,
            affinity: values.affinity,
            trust: values.trust,
            friction: values.friction,
            familiarity: values.familiarity,
            mood: values.mood,
            stage: values.stage,
            notes: values.notes,
          );
        },
      ),
    );
    if (saved == true) await _loadSnapshot();
  }

  Future<void> _confirmReset(RelationshipState relationship) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('重置关系？'),
        content: const Text('分数、情绪、阶段和备注会恢复默认值，历史事件和固定状态会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('重置'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _controls.resetRelationship(relationship);
      await _loadSnapshot();
    } on Object catch (error) {
      _showError('重置关系失败：$error');
    }
  }

  Future<void> _confirmDelete(RelationshipState relationship) async {
    final first = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除关系及历史？'),
        content: const Text('将删除当前方向关系、全部关系事件和固定标记。消息和永久记忆不会受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('继续'),
          ),
        ],
      ),
    );
    if (first != true || !mounted) return;
    final second = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('确认不可撤销删除'),
        content: const Text('删除后无法恢复关系事件历史，此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
    if (second != true) return;
    try {
      await _controls.deleteRelationshipHistory(relationship);
      await _loadSnapshot();
    } on Object catch (error) {
      _showError('删除关系失败：$error');
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

class _PageAppBar extends StatelessWidget implements PreferredSizeWidget {
  const _PageAppBar();

  @override
  Widget build(BuildContext context) => AppBar(title: const Text('全局关系审计'));

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);
}
