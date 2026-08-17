import 'dart:async';

import 'package:chat_group/core/database/data_lifecycle_service.dart';
import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/relationship_event.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/core/models/user_profile.dart';
import 'package:chat_group/features/chat_group/chat_room_page.dart';
import 'package:chat_group/features/memory/relationship_audit_presenter.dart';
import 'package:chat_group/features/memory/relationship_controls.dart';
import 'package:chat_group/features/memory/relationship_edit_dialog.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

class RelationshipAuditDetailPage extends ConsumerStatefulWidget {
  final String relationshipId;
  final String? originConversationId;
  final String? originConversationName;

  const RelationshipAuditDetailPage({
    super.key,
    required this.relationshipId,
    this.originConversationId,
    this.originConversationName,
  });

  @override
  ConsumerState<RelationshipAuditDetailPage> createState() =>
      _RelationshipAuditDetailPageState();
}

class _RelationshipAuditDetailPageState
    extends ConsumerState<RelationshipAuditDetailPage> {
  late final DatabaseService _db;
  late final RelationshipControls _controls;
  RelationshipState? _relationship;
  List<RelationshipEvent> _events = const [];
  Map<String, AICharacter> _characters = const {};
  Map<String, Message> _sourceMessages = const {};
  UserProfile? _userProfile;
  String _eventQuery = '';
  _RelationshipEventFilter _eventFilter = _RelationshipEventFilter.all;
  bool _ascending = false;
  bool _isLoading = true;
  Object? _loadError;
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _db = ref.read(databaseServiceProvider);
    _controls = RelationshipControls(_db);
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
      final relationship = _controls
          .globalRelationships()
          .where(
            (candidate) =>
                candidate.id == widget.relationshipId ||
                RelationshipState.stableGlobalId(
                      candidate.sourceCharacterId,
                      candidate.targetType,
                      candidate.targetId,
                    ) ==
                    widget.relationshipId,
          )
          .firstOrNull;
      final ids = <String>{
        if (relationship != null) relationship.sourceCharacterId,
        if (relationship?.targetType == RelationshipTargetType.ai)
          relationship!.targetId,
      };
      final lifecycle = DataLifecycleService(db: _db);
      final characters = {
        for (final character in _resolveCharacters(lifecycle, ids))
          character.id: character,
      };
      final events = relationship == null
          ? const <RelationshipEvent>[]
          : _controls.eventsFor(
              relationship,
              originConversationId: widget.originConversationId,
            );
      final sourceMessages = <String, Message>{};
      for (final event in events) {
        for (final messageId in event.sourceMessageIds) {
          final message = _db.messageBox.get(messageId);
          if (message != null) sourceMessages[messageId] = message;
        }
      }
      if (!mounted) return;
      setState(() {
        _relationship = relationship;
        _events = events;
        _characters = characters;
        _sourceMessages = sourceMessages;
        _userProfile = _db.userProfileBox.get('me');
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

  List<AICharacter> _resolveCharacters(
    DataLifecycleService lifecycle,
    Iterable<String> ids,
  ) {
    final normalized = ids.where((id) => id.trim().isNotEmpty).toSet();
    final resolved = lifecycle.charactersForIds(normalized);
    final resolvedIds = resolved.map((character) => character.id).toSet();
    return [
      ...resolved,
      for (final id in normalized)
        if (!resolvedIds.contains(id)) _deletedCharacterPlaceholder(id),
    ];
  }

  AICharacter _deletedCharacterPlaceholder(String id) => AICharacter(
        id: id,
        name: '已删除角色',
        avatar: '?',
        age: 0,
        role: '历史记录',
        personalityTags: const [],
        systemPrompt: '',
        apiKey: '',
        apiProvider: 'custom',
        isActive: false,
        gender: CharacterGender.female,
        hasKnownGender: false,
      );

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return _loadingScaffold();
    if (_loadError != null) return _errorScaffold();
    final relationship = _relationship;
    if (relationship == null) return _missingScaffold();

    final observer = _characters[relationship.sourceCharacterId];
    final target = relationship.targetType == RelationshipTargetType.user
        ? _userCharacter
        : _characters[relationship.targetId];
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => Navigator.pop(context, _changed)),
        title: Text(
          '${_name(observer, relationship.sourceCharacterId)} → '
          '${_targetName(relationship, target)}',
        ),
        actions: [
          PopupMenuButton<_RelationshipDetailAction>(
            tooltip: '更多',
            onSelected: _handleAction,
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: _RelationshipDetailAction.edit,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.edit_outlined),
                  title: Text('编辑关系'),
                ),
              ),
              PopupMenuItem(
                value: _RelationshipDetailAction.pin,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.push_pin_outlined),
                  title: Text(
                    _controls.isPinned(relationship) ? '取消固定关系' : '固定关系',
                  ),
                ),
              ),
              const PopupMenuItem(
                value: _RelationshipDetailAction.reset,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.restore_rounded),
                  title: Text('重置关系'),
                ),
              ),
              const PopupMenuItem(
                value: _RelationshipDetailAction.delete,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.delete_outline_rounded),
                  title: Text('删除关系及历史'),
                ),
              ),
            ],
            icon: const Icon(Icons.more_horiz_rounded),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _buildBody(context, relationship, observer, target),
    );
  }

  Widget _buildBody(
    BuildContext context,
    RelationshipState relationship,
    AICharacter? observer,
    AICharacter? target,
  ) {
    final events = _filteredEvents;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _directionCard(context, relationship, observer, target),
          const SizedBox(height: 16),
          _overviewCard(context, relationship),
          const SizedBox(height: 16),
          _timelineCard(context, events),
        ],
      ),
    );
  }

  Widget _directionCard(
    BuildContext context,
    RelationshipState relationship,
    AICharacter? observer,
    AICharacter? target,
  ) {
    final cs = Theme.of(context).colorScheme;
    final targetId = relationship.targetType == RelationshipTargetType.user
        ? 'user'
        : relationship.targetId;
    final targetName = relationship.targetType == RelationshipTargetType.user
        ? _userProfile?.displayName ?? '我'
        : null;
    final targetRole =
        relationship.targetType == RelationshipTargetType.user ? '用户' : null;
    return _surface(
      context,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final identities = Row(
            children: [
              Expanded(
                child: _identity(
                  context,
                  observer,
                  relationship.sourceCharacterId,
                  compact: true,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Icon(Icons.arrow_forward_rounded, color: cs.outline),
              ),
              Expanded(
                child: _identity(
                  context,
                  target,
                  targetId,
                  compact: true,
                  fallbackName: targetName,
                  fallbackRole: targetRole,
                ),
              ),
            ],
          );
          final statuses = Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _statusChip(
                context,
                '阶段 · ${RelationshipAuditPresenter.stageLabel(relationship.stage)}',
                _stageColor(context, relationship.stage),
              ),
              _statusChip(
                context,
                '情绪 · ${RelationshipAuditPresenter.moodLabel(relationship.recentMood)}',
                _moodColor(context, relationship.recentMood),
              ),
            ],
          );
          if (constraints.maxWidth < 720) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [identities, const SizedBox(height: 12), statuses],
            );
          }
          return Row(
            children: [
              Expanded(
                child: _identity(
                  context,
                  observer,
                  relationship.sourceCharacterId,
                  compact: true,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Icon(Icons.arrow_forward_rounded, color: cs.outline),
              ),
              Expanded(
                child: _identity(
                  context,
                  target,
                  targetId,
                  compact: true,
                  fallbackName: targetName,
                  fallbackRole: targetRole,
                ),
              ),
              const SizedBox(width: 16),
              statuses,
            ],
          );
        },
      ),
    );
  }

  Widget _identity(
    BuildContext context,
    AICharacter? character,
    String id, {
    bool compact = false,
    String? fallbackName,
    String? fallbackRole,
  }) {
    final name = fallbackName ?? _name(character, id);
    final role =
        fallbackRole ?? RelationshipAuditPresenter.roleLabel(character);
    return Row(
      mainAxisSize: compact ? MainAxisSize.max : MainAxisSize.min,
      children: [
        CircleAvatar(
          radius: 24,
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          child: Text(
            RelationshipAuditPresenter.avatar(character, name),
            style: TextStyle(
              color: Theme.of(context).colorScheme.onPrimaryContainer,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: 10),
        if (compact)
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                Text(
                  role,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          )
        else
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 180),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: const TextStyle(fontWeight: FontWeight.w700)),
                Text(
                  role,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _overviewCard(BuildContext context, RelationshipState relationship) {
    final metrics = [
      const (
        '亲密度',
        '对彼此亲近程度的估计，范围 -100 到 100',
        Colors.indigo,
      ),
      const ('信任', '对可靠性和安全感的估计，范围 -100 到 100', Colors.green),
      const ('摩擦', '冲突、抵触或不适程度，范围 0 到 100', Colors.orange),
      const ('熟悉度', '共同经历和了解程度，范围 0 到 100', Colors.blue),
    ];
    final values = [
      (relationship.affinity, true),
      (relationship.trust, true),
      (relationship.friction, false),
      (relationship.familiarity, false),
    ];
    return _surface(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('当前关系概览', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 720;
              final width = wide
                  ? (constraints.maxWidth - 36) / 4
                  : (constraints.maxWidth - 12) / 2;
              return Wrap(
                spacing: 12,
                runSpacing: 16,
                children: [
                  for (var index = 0; index < metrics.length; index++)
                    SizedBox(
                      width: width,
                      child: RelationshipMetricBar(
                        label: metrics[index].$1,
                        hint: metrics[index].$2,
                        value: values[index].$1,
                        centered: values[index].$2,
                        color: metrics[index].$3,
                      ),
                    ),
                ],
              );
            },
          ),
          const Divider(height: 28),
          Text('关系备注', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 6),
          Text(
            relationship.notes.trim().isEmpty ? '暂无关系备注' : relationship.notes,
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 32,
            runSpacing: 8,
            children: [
              _dateInfo('最近互动时间', relationship.lastInteractionAt),
              _dateInfo('更新时间', relationship.updatedAt),
              Text(
                widget.originConversationId == null
                    ? '事件来源 · 全部来源'
                    : '事件来源 · ${widget.originConversationName ?? widget.originConversationId}（已锁定）',
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ],
          ),
          if (widget.originConversationId != null) ...[
            const SizedBox(height: 8),
            Text(
              '来源筛选仅影响下方时间线，当前关系概览仍来自全局快照。',
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }

  Widget _timelineCard(BuildContext context, List<RelationshipEvent> events) {
    final grouped = <String, List<RelationshipEvent>>{};
    for (final event in events) {
      final date = DateFormat('yyyy-MM-dd').format(event.occurredAt.toLocal());
      grouped.putIfAbsent(date, () => []).add(event);
    }
    return _surface(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text('关系事件时间线', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(width: 8),
              Text('${events.length} 条记录',
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ],
          ),
          const SizedBox(height: 12),
          _timelineControls(context),
          const SizedBox(height: 12),
          if (events.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: Text('当前来源暂无关系事件')),
            )
          else
            for (final entry in grouped.entries) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(0, 8, 0, 4),
                child: Text(
                  entry.key,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              for (final event in entry.value)
                _RelationshipEventRow(
                  event: event,
                  sourceMessages: _sourceMessages,
                  canOpenSource: _canOpenSource,
                  onOpenSource: _openSourceMessage,
                ),
            ],
        ],
      ),
    );
  }

  Widget _timelineControls(BuildContext context) => Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          SizedBox(
            width: 260,
            child: TextField(
              key: const ValueKey('relationship-event-search'),
              onChanged: (value) => setState(() => _eventQuery = value),
              decoration: const InputDecoration(
                isDense: true,
                hintText: '搜索事件原因或来源',
                prefixIcon: Icon(Icons.search_rounded, size: 18),
              ),
            ),
          ),
          DropdownButton<_RelationshipEventFilter>(
            value: _eventFilter,
            onChanged: (value) {
              if (value != null) setState(() => _eventFilter = value);
            },
            items: const [
              DropdownMenuItem(
                value: _RelationshipEventFilter.all,
                child: Text('全部变化'),
              ),
              DropdownMenuItem(
                value: _RelationshipEventFilter.automatic,
                child: Text('自动记录'),
              ),
              DropdownMenuItem(
                value: _RelationshipEventFilter.manual,
                child: Text('人工记录'),
              ),
              DropdownMenuItem(
                value: _RelationshipEventFilter.legacy,
                child: Text('旧版迁移'),
              ),
              DropdownMenuItem(
                value: _RelationshipEventFilter.stage,
                child: Text('阶段变化'),
              ),
              DropdownMenuItem(
                value: _RelationshipEventFilter.numeric,
                child: Text('数值变化'),
              ),
            ],
          ),
          OutlinedButton.icon(
            onPressed: () => setState(() => _ascending = !_ascending),
            icon: Icon(_ascending ? Icons.south_rounded : Icons.north_rounded),
            label: Text(_ascending ? '时间正序' : '时间倒序'),
          ),
        ],
      );

  List<RelationshipEvent> get _filteredEvents {
    final query = _eventQuery.trim().toLowerCase();
    final events = _events.where((event) {
      if (query.isNotEmpty &&
          !'${event.reason} ${RelationshipAuditPresenter.sourceLabel(event)}'
              .toLowerCase()
              .contains(query)) {
        return false;
      }
      final numeric =
          RelationshipAuditPresenter.changedMetricNames(event).isNotEmpty;
      final stage = event.stageAfter != event.stageBefore;
      return switch (_eventFilter) {
        _RelationshipEventFilter.all => true,
        _RelationshipEventFilter.automatic =>
          event.createdBy == RelationshipEventCreator.automatic,
        _RelationshipEventFilter.manual =>
          event.createdBy == RelationshipEventCreator.manual,
        _RelationshipEventFilter.legacy =>
          event.createdBy == RelationshipEventCreator.legacyMigration,
        _RelationshipEventFilter.stage => stage,
        _RelationshipEventFilter.numeric => numeric,
      };
    }).toList();
    events.sort((left, right) => _ascending
        ? left.occurredAt.compareTo(right.occurredAt)
        : right.occurredAt.compareTo(left.occurredAt));
    return events;
  }

  Widget _dateInfo(String label, DateTime value) => Text(
        '$label · ${DateFormat('yyyy-MM-dd HH:mm').format(value.toLocal())}',
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      );

  Widget _surface(BuildContext context, {required Widget child}) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          border:
              Border.all(color: Theme.of(context).colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(12),
        ),
        child: child,
      );

  Widget _statusChip(BuildContext context, String text, Color color) =>
      DecoratedBox(
        decoration: BoxDecoration(
          color: color.withValues(alpha: .12),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Text(text,
              style: TextStyle(color: color, fontWeight: FontWeight.w600)),
        ),
      );

  Color _stageColor(BuildContext context, RelationshipStage stage) =>
      switch (stage) {
        RelationshipStage.friend ||
        RelationshipStage.closeFriend ||
        RelationshipStage.romantic =>
          Colors.indigo,
        RelationshipStage.stranger ||
        RelationshipStage.acquaintance =>
          Theme.of(context).colorScheme.primary,
        RelationshipStage.strained ||
        RelationshipStage.hostile =>
          Theme.of(context).colorScheme.error,
      };

  Color _moodColor(BuildContext context, RelationshipMood mood) =>
      switch (mood) {
        RelationshipMood.warm || RelationshipMood.protective => Colors.green,
        RelationshipMood.annoyed || RelationshipMood.awkward => Colors.orange,
        RelationshipMood.cold => Theme.of(context).colorScheme.error,
        RelationshipMood.neutral =>
          Theme.of(context).colorScheme.onSurfaceVariant,
      };

  String _name(AICharacter? character, String id) =>
      RelationshipAuditPresenter.displayName(character, id);

  String _targetName(RelationshipState relationship, AICharacter? target) {
    if (relationship.targetType == RelationshipTargetType.user) {
      return _userProfile?.displayName.trim().isNotEmpty == true
          ? _userProfile!.displayName.trim()
          : '我';
    }
    return _name(target, relationship.targetId);
  }

  AICharacter? get _userCharacter {
    final profile = _userProfile;
    if (profile == null) return null;
    return AICharacter(
      id: 'user',
      name: profile.displayName,
      avatar: profile.avatar,
      age: profile.age ?? 0,
      role: '用户',
      personalityTags: const [],
      systemPrompt: '',
      apiKey: '',
      apiProvider: 'custom',
    );
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
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatRoomPage(
          groupId: message.groupId,
          initialMessageId: message.id,
        ),
      ),
    );
  }

  Future<void> _handleAction(_RelationshipDetailAction action) async {
    final relationship = _relationship;
    if (relationship == null) return;
    switch (action) {
      case _RelationshipDetailAction.edit:
        await _showEditDialog(relationship);
      case _RelationshipDetailAction.pin:
        await _setPinned(relationship, !_controls.isPinned(relationship));
      case _RelationshipDetailAction.reset:
        await _confirmReset(relationship);
      case _RelationshipDetailAction.delete:
        await _confirmDelete(relationship);
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
    if (saved != true) return;
    _changed = true;
    await _loadSnapshot();
  }

  Future<void> _setPinned(RelationshipState relationship, bool pinned) async {
    try {
      await _controls.setPinned(relationship, pinned);
      _changed = true;
      await _loadSnapshot();
    } on Object catch (error) {
      _showError('固定状态保存失败：$error');
    }
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
      _changed = true;
      await _loadSnapshot();
    } on Object catch (error) {
      _showError('重置关系失败：$error');
    }
  }

  Future<void> _confirmDelete(RelationshipState relationship) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除关系及历史？'),
        content: const Text('将删除该方向的全局关系快照、全部来源事件和固定状态，消息和永久记忆不会受影响。'),
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
    if (confirmed != true) return;
    try {
      await _controls.deleteRelationshipHistory(relationship);
      if (mounted) Navigator.pop(context, true);
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

  Widget _loadingScaffold() => Scaffold(
        appBar: AppBar(title: const Text('关系详情')),
        body: const Center(child: CircularProgressIndicator()),
      );

  Widget _errorScaffold() => Scaffold(
        appBar: AppBar(title: const Text('关系详情')),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('关系数据加载失败'),
              const SizedBox(height: 12),
              FilledButton(onPressed: _loadSnapshot, child: const Text('重试')),
            ],
          ),
        ),
      );

  Widget _missingScaffold() => Scaffold(
        appBar: AppBar(
          leading:
              BackButton(onPressed: () => Navigator.pop(context, _changed)),
          title: const Text('关系详情'),
        ),
        body: const Center(child: Text('关系已不存在')),
      );
}

class RelationshipMetricBar extends StatelessWidget {
  final String label;
  final String hint;
  final int value;
  final bool centered;
  final Color color;

  const RelationshipMetricBar({
    super.key,
    required this.label,
    required this.hint,
    required this.value,
    required this.centered,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final min = centered ? -100 : 0;
    const max = 100;
    final visualValue = value.clamp(min, max).toDouble();
    return Tooltip(
      message: hint,
      child: Semantics(
        label: '$label $value，范围 $min 到 $max',
        value: '$value',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(label,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
                Text(
                  '$value',
                  style: TextStyle(
                    color: color,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 12,
              child: LayoutBuilder(
                builder: (context, constraints) => Stack(
                  children: [
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                    if (centered)
                      _centeredFill(context, constraints.maxWidth, visualValue)
                    else
                      Align(
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor: (visualValue / max).clamp(0, 1),
                          child: _fill(),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(centered ? '-100' : '0', style: _scaleStyle(context)),
                if (centered) Text('0', style: _scaleStyle(context)),
                Text('100', style: _scaleStyle(context)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _centeredFill(BuildContext context, double width, double value) {
    final center = width / 2;
    final fillWidth = center * (value.abs() / 100).clamp(0, 1);
    return Positioned(
      left: value < 0 ? center - fillWidth : center,
      width: fillWidth,
      top: 0,
      bottom: 0,
      child: _fill(),
    );
  }

  Widget _fill() => DecoratedBox(
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(8),
        ),
      );

  TextStyle _scaleStyle(BuildContext context) => TextStyle(
        fontSize: 11,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      );
}

enum _RelationshipDetailAction { edit, pin, reset, delete }

enum _RelationshipEventFilter {
  all,
  automatic,
  manual,
  legacy,
  stage,
  numeric,
}

class _RelationshipEventRow extends StatelessWidget {
  final RelationshipEvent event;
  final Map<String, Message> sourceMessages;
  final bool Function(Message message) canOpenSource;
  final ValueChanged<Message> onOpenSource;

  const _RelationshipEventRow({
    required this.event,
    required this.sourceMessages,
    required this.canOpenSource,
    required this.onOpenSource,
  });

  @override
  Widget build(BuildContext context) {
    final changedMetrics = _metricChanges();
    final stageChanged = event.stageAfter != event.stageBefore;
    final moodChanged = event.moodAfter != event.moodBefore;
    final source = event.sourceMessageIds
        .map((id) => sourceMessages[id])
        .whereType<Message>()
        .firstOrNull;
    final sourceAvailable = source != null && canOpenSource(source);
    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(event.reason, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 12,
          runSpacing: 4,
          children: [
            for (final change in changedMetrics) Text(change),
            if (stageChanged)
              Text(
                '阶段 ${RelationshipAuditPresenter.stageLabel(event.stageBefore)} → '
                '${RelationshipAuditPresenter.stageLabel(event.stageAfter)}',
              ),
            if (moodChanged)
              Text(
                '情绪 ${RelationshipAuditPresenter.moodLabel(event.moodBefore)} → '
                '${RelationshipAuditPresenter.moodLabel(event.moodAfter)}',
              ),
            Text('来源 · ${RelationshipAuditPresenter.sourceLabel(event)}'),
          ],
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            if (sourceAvailable)
              TextButton(
                onPressed: () => onOpenSource(source),
                child: const Text('查看原消息'),
              )
            else if (event.sourceMessageIds.isNotEmpty)
              Text(
                '原消息不可用（${RelationshipAuditPresenter.sourceLabel(event)}）',
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              )
            else
              Text(
                '${RelationshipAuditPresenter.creatorLabel(event.createdBy)}记录，无原始消息证据',
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            SizedBox(
              width: 260,
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                dense: true,
                title: const Text('技术详情'),
                childrenPadding: const EdgeInsets.only(bottom: 8),
                children: [
                  _tech('revision', '${event.revision}'),
                  _tech('置信度', event.confidence.toStringAsFixed(2)),
                  _tech('事件 ID', event.id),
                  _tech('原始会话 ID', event.originConversationId ?? '无'),
                  _tech('创建方式',
                      RelationshipAuditPresenter.creatorLabel(event.createdBy)),
                  _tech(
                      '来源消息 ID', event.sourceMessageIds.join('、').ifEmpty('无')),
                ],
              ),
            ),
          ],
        ),
      ],
    );
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        border: Border(
            top: BorderSide(
                color: Theme.of(context).colorScheme.outlineVariant)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final date = Text(
            DateFormat('MM-dd HH:mm').format(event.occurredAt.toLocal()),
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          );
          if (constraints.maxWidth < 620) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [date, const SizedBox(height: 8), details],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 112, child: date),
              Expanded(child: details),
            ],
          );
        },
      ),
    );
  }

  List<String> _metricChanges() => [
        if (event.affinityAfter != event.affinityBefore)
          '亲密度 ${event.affinityBefore} → ${event.affinityAfter}',
        if (event.trustAfter != event.trustBefore)
          '信任 ${event.trustBefore} → ${event.trustAfter}',
        if (event.frictionAfter != event.frictionBefore)
          '摩擦 ${event.frictionBefore} → ${event.frictionAfter}',
        if (event.familiarityAfter != event.familiarityBefore)
          '熟悉度 ${event.familiarityBefore} → ${event.familiarityAfter}',
      ];

  Widget _tech(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 112, child: Text(label)),
            Expanded(child: SelectableText(value)),
          ],
        ),
      );
}

extension _StringFallback on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
