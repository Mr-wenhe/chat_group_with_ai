import 'dart:async';

import 'package:chat_group/core/database/data_lifecycle_service.dart';
import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/relationship_event.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/core/models/user_profile.dart';
import 'package:chat_group/features/memory/relationship_audit_detail_page.dart';
import 'package:chat_group/features/memory/relationship_audit_page.dart';
import 'package:chat_group/features/memory/relationship_audit_presenter.dart';
import 'package:chat_group/features/memory/relationship_controls.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

class RelationshipPrivateDetailPage extends ConsumerStatefulWidget {
  final String characterId;

  const RelationshipPrivateDetailPage({
    super.key,
    required this.characterId,
  });

  @override
  ConsumerState<RelationshipPrivateDetailPage> createState() =>
      _RelationshipPrivateDetailPageState();
}

class _RelationshipPrivateDetailPageState
    extends ConsumerState<RelationshipPrivateDetailPage> {
  late final DatabaseService _db;
  late final RelationshipControls _controls;
  AICharacter? _character;
  UserProfile? _userProfile;
  RelationshipState? _relationship;
  List<RelationshipEvent> _events = const [];
  bool _isLoading = true;
  Object? _loadError;

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
      final lifecycle = DataLifecycleService(db: _db);
      final resolved = lifecycle.charactersForIds([widget.characterId]);
      final character = resolved.firstOrNull ?? _deletedCharacterPlaceholder();
      final relationship = _controls
          .globalRelationships()
          .where(
            (candidate) =>
                candidate.sourceCharacterId == widget.characterId &&
                candidate.targetType == RelationshipTargetType.user &&
                candidate.targetId == 'user',
          )
          .firstOrNull;
      final events = relationship == null
          ? const <RelationshipEvent>[]
          : _controls.eventsFor(relationship);
      if (!mounted) return;
      setState(() {
        _character = character;
        _userProfile = _db.userProfileBox.get('me');
        _relationship = relationship;
        _events = events;
        _isLoading = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _loadError = error;
      });
    }
  }

  AICharacter _deletedCharacterPlaceholder() => AICharacter(
        id: widget.characterId,
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
    final character = _character ?? _deletedCharacterPlaceholder();
    final relation = _relationship;
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => Navigator.pop(context)),
        title: Row(
          children: [
            Flexible(
              child: Text(
                '${character.name}对我的关系',
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            const Chip(label: Text('只读')),
          ],
        ),
      ),
      body: relation == null
          ? _emptyRelationship(context, character)
          : _relationshipBody(context, character, relation),
    );
  }

  Widget _relationshipBody(
    BuildContext context,
    AICharacter character,
    RelationshipState relationship,
  ) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _directionCard(context, character, relationship),
          const SizedBox(height: 16),
          _overviewCard(context, relationship),
          const SizedBox(height: 16),
          _recentChanges(context),
          const SizedBox(height: 16),
          Align(
            child: TextButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => RelationshipAuditPage(
                    initialObserverCharacterId: character.id,
                    initialTargetType: RelationshipTargetType.user,
                  ),
                ),
              ),
              icon: const Icon(Icons.arrow_forward_rounded),
              label: const Text('前往完整关系审计'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _directionCard(
    BuildContext context,
    AICharacter character,
    RelationshipState relationship,
  ) {
    final user = _userCharacter;
    return _surface(
      context,
      child: _directionLayout(
        context,
        source: character,
        sourceName: character.name,
        target: user,
        targetName: _userProfile?.displayName.trim().isNotEmpty == true
            ? _userProfile!.displayName.trim()
            : '我',
        trailing: [
          _statusChip(
            context,
            '阶段 · ${RelationshipAuditPresenter.stageLabel(relationship.stage)}',
            Theme.of(context).colorScheme.primary,
          ),
          _statusChip(
            context,
            '情绪 · ${RelationshipAuditPresenter.moodLabel(relationship.recentMood)}',
            Colors.green,
          ),
        ],
      ),
    );
  }

  Widget _directionLayout(
    BuildContext context, {
    required AICharacter? source,
    required String sourceName,
    required AICharacter? target,
    required String targetName,
    required List<Widget> trailing,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final identities = Row(
          children: [
            Expanded(
              child: _identity(context, source, sourceName, compact: true),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Icon(
                Icons.arrow_forward_rounded,
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
            Expanded(
              child: _identity(context, target, targetName, compact: true),
            ),
          ],
        );
        if (trailing.isEmpty || constraints.maxWidth < 720) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              identities,
              if (trailing.isNotEmpty) ...[
                const SizedBox(height: 12),
                Wrap(spacing: 8, runSpacing: 8, children: trailing),
              ],
            ],
          );
        }
        return Row(
          children: [
            Expanded(
                child: _identity(context, source, sourceName, compact: true)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Icon(
                Icons.arrow_forward_rounded,
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
            Expanded(
                child: _identity(context, target, targetName, compact: true)),
            const SizedBox(width: 16),
            Wrap(spacing: 8, runSpacing: 8, children: trailing),
          ],
        );
      },
    );
  }

  Widget _identity(
    BuildContext context,
    AICharacter? character,
    String name, {
    bool compact = false,
    String? fallbackRole,
  }) {
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
                  fallbackRole ??
                      RelationshipAuditPresenter.roleLabel(character),
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
                  fallbackRole ??
                      RelationshipAuditPresenter.roleLabel(character),
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
      const ('亲密度', '范围 -100 到 100', Colors.indigo, true),
      const ('信任', '范围 -100 到 100', Colors.green, true),
      const ('摩擦', '范围 0 到 100', Colors.orange, false),
      const ('熟悉度', '范围 0 到 100', Colors.blue, false),
    ];
    final values = [
      relationship.affinity,
      relationship.trust,
      relationship.friction,
      relationship.familiarity,
    ];
    return _surface(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
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
                        value: values[index],
                        centered: metrics[index].$4,
                        color: metrics[index].$3,
                      ),
                    ),
                ],
              );
            },
          ),
          const Divider(height: 28),
          Text('关系摘要', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 6),
          Text(_summary(relationship)),
          const SizedBox(height: 12),
          if (relationship.notes.trim().isNotEmpty) ...[
            Text('关系备注', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            Text(relationship.notes),
            const SizedBox(height: 12),
          ],
          Wrap(
            spacing: 24,
            runSpacing: 8,
            children: [
              Text(
                '最近互动时间 · ${DateFormat('yyyy-MM-dd HH:mm').format(relationship.lastInteractionAt.toLocal())}',
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
              Text(
                '更新时间 · ${DateFormat('yyyy-MM-dd HH:mm').format(relationship.updatedAt.toLocal())}',
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _recentChanges(BuildContext context) => _surface(
        context,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '最近变化（最新 ${_events.take(3).length} 条）',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            if (_events.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Text('暂无已记录的关系变化'),
              )
            else
              for (final event in _events.take(3)) _changeRow(context, event),
          ],
        ),
      );

  Widget _changeRow(BuildContext context, RelationshipEvent event) {
    final changes = RelationshipAuditPresenter.changedMetricNames(event);
    final detail = changes.isEmpty
        ? event.stageAfter != event.stageBefore
            ? '阶段更新：${RelationshipAuditPresenter.stageLabel(event.stageAfter)}'
            : event.moodAfter != event.moodBefore
                ? '情绪更新：${RelationshipAuditPresenter.moodLabel(event.moodAfter)}'
                : '关系状态更新'
        : changes.join('、');
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
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
          final metadata = Wrap(
            spacing: 12,
            runSpacing: 4,
            children: [
              Text(detail,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant)),
              Text(
                RelationshipAuditPresenter.sourceLabel(event),
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ],
          );
          if (constraints.maxWidth < 620) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.circle, size: 8, color: Colors.indigo),
                    const SizedBox(width: 10),
                    date,
                    const SizedBox(width: 12),
                    Expanded(child: Text(event.reason)),
                  ],
                ),
                const SizedBox(height: 6),
                metadata,
              ],
            );
          }
          return Row(
            children: [
              const Icon(Icons.circle, size: 8, color: Colors.indigo),
              const SizedBox(width: 10),
              SizedBox(width: 120, child: date),
              Expanded(child: Text(event.reason)),
              const SizedBox(width: 12),
              metadata,
            ],
          );
        },
      ),
    );
  }

  Widget _emptyRelationship(BuildContext context, AICharacter character) {
    final user = _userCharacter;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _surface(
            context,
            child: _directionLayout(
              context,
              source: character,
              sourceName: character.name,
              target: user,
              targetName: _userProfile?.displayName.trim().isNotEmpty == true
                  ? _userProfile!.displayName.trim()
                  : '我',
              trailing: const [],
            ),
          ),
          const SizedBox(height: 16),
          _surface(
            context,
            child: const Column(
              children: [
                Icon(Icons.hourglass_empty_rounded, size: 40),
                SizedBox(height: 12),
                Text('尚未形成可展示的关系'),
                SizedBox(height: 8),
                Text('继续聊天后，关系变化会逐步记录在这里。'),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Align(
            child: TextButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => RelationshipAuditPage(
                    initialObserverCharacterId: character.id,
                    initialTargetType: RelationshipTargetType.user,
                  ),
                ),
              ),
              icon: const Icon(Icons.arrow_forward_rounded),
              label: const Text('前往完整关系审计'),
            ),
          ),
        ],
      ),
    );
  }

  String _summary(RelationshipState relation) {
    final notes = relation.notes.trim();
    if (notes.isNotEmpty) return notes;
    final name = _character?.name ?? '该 AI';
    final stage = RelationshipAuditPresenter.stageLabel(relation.stage);
    final mood = switch (relation.recentMood) {
      RelationshipMood.warm || RelationshipMood.protective => '温暖',
      RelationshipMood.annoyed || RelationshipMood.awkward => '有些复杂',
      RelationshipMood.cold => '冷淡',
      RelationshipMood.neutral => '中性',
    };
    final trust = relation.trust >= 50
        ? '信任较高'
        : relation.trust <= -20
            ? '信任偏低'
            : '信任处于中等水平';
    final ending = relation.friction >= 60 ? '近期互动仍有明显摩擦。' : '近期互动让关系保持稳定。';
    return '$name目前把我视为$stage，整体态度$mood，$trust，$ending';
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
          child: Text(text, style: TextStyle(color: color)),
        ),
      );

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
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
