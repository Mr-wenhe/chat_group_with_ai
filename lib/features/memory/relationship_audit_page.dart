import 'dart:async';

import 'package:chat_group/core/database/data_lifecycle_service.dart';
import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/core/models/user_profile.dart';
import 'package:chat_group/features/memory/memory_management_widgets.dart';
import 'package:chat_group/features/memory/memory_observer_sidebar.dart';
import 'package:chat_group/features/memory/relationship_audit_card.dart';
import 'package:chat_group/features/memory/relationship_audit_detail_page.dart';
import 'package:chat_group/features/memory/relationship_audit_filter.dart';
import 'package:chat_group/features/memory/relationship_audit_filter_widget.dart';
import 'package:chat_group/features/memory/relationship_audit_presenter.dart';
import 'package:chat_group/features/memory/relationship_controls.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class RelationshipAuditPage extends ConsumerStatefulWidget {
  /// A conversation ID only constrains event timelines, never snapshots.
  final String? conversationId;
  final String? conversationName;
  final Set<String>? allowedObserverCharacterIds;
  final String? initialObserverCharacterId;
  final RelationshipTargetType? initialTargetType;

  const RelationshipAuditPage({
    super.key,
    this.conversationId,
    this.conversationName,
    this.allowedObserverCharacterIds,
    this.initialObserverCharacterId,
    this.initialTargetType,
  });

  @override
  ConsumerState<RelationshipAuditPage> createState() =>
      _RelationshipAuditPageState();
}

class _RelationshipAuditPageState extends ConsumerState<RelationshipAuditPage> {
  static const _wideBreakpoint = 900.0;

  late final DatabaseService _db;
  late final RelationshipControls _controls;
  late RelationshipAuditFilter _filter;
  final ScrollController _scrollController = ScrollController();
  List<RelationshipState> _relationships = const [];
  List<RelationshipState> _legacyRelationships = const [];
  List<AICharacter> _characters = const [];
  List<AICharacter> _observerCharacters = const [];
  String _observerSearchQuery = '';
  String? _observerCharacterId;
  UserProfile? _userProfile;
  Map<String, String> _originConversations = const {};
  bool _isLoading = true;
  Object? _loadError;
  int _loadRequest = 0;

  @override
  void initState() {
    super.initState();
    _db = ref.read(databaseServiceProvider);
    _controls = RelationshipControls(_db);
    _observerCharacterId = widget.initialObserverCharacterId;
    _filter = RelationshipAuditFilter(
      observerCharacterId: widget.initialObserverCharacterId,
      targetType: widget.initialTargetType,
      originConversationId: widget.conversationId,
    );
    unawaited(_loadSnapshot());
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadSnapshot({bool showLoading = true}) async {
    final request = ++_loadRequest;
    if (mounted && showLoading) {
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
        for (final relationship in global) ...{
          relationship.sourceCharacterId,
          if (relationship.targetType == RelationshipTargetType.ai)
            relationship.targetId,
        },
      };
      final allowedObservers = widget.allowedObserverCharacterIds;
      final observerIds = <String>{
        if (allowedObservers == null)
          ..._db.aiCharacterBox.values.map((character) => character.id),
        ...?allowedObservers,
        ...global
            .where(
              (relationship) =>
                  allowedObservers == null ||
                  allowedObservers.contains(relationship.sourceCharacterId),
            )
            .map((relationship) => relationship.sourceCharacterId),
      };
      final characterIds = {
        ...referencedCharacterIds,
        ...observerIds,
      };
      final lifecycle = DataLifecycleService(db: _db);
      final characters = _resolveCharacters(lifecycle, characterIds);
      final observerCharacters = _resolveCharacters(lifecycle, observerIds);
      final origins = _loadOriginConversations();
      final userProfile = _db.userProfileBox.get('me');
      final selectedObserverId = _selectedObserverId(observerCharacters);
      if (!mounted || request != _loadRequest) return;
      setState(() {
        _relationships = global;
        _legacyRelationships = legacy;
        _characters = characters;
        _observerCharacters = observerCharacters;
        _userProfile = userProfile;
        _originConversations = origins;
        _observerCharacterId = selectedObserverId;
        if (allowedObservers != null) {
          _filter = selectedObserverId == null
              ? _filter.copyWith(clearObserverCharacterId: true)
              : _filter.copyWith(observerCharacterId: selectedObserverId);
        }
        _isLoading = false;
        _loadError = null;
      });
    } on Object catch (error) {
      if (!mounted || request != _loadRequest) return;
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
    final normalized =
        ids.map((id) => id.trim()).where((id) => id.isNotEmpty).toSet();
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

  String? _selectedObserverId(List<AICharacter> characters) {
    final allowed = widget.allowedObserverCharacterIds;
    final current = _observerCharacterId;
    if (current != null &&
        characters.any((character) => character.id == current) &&
        (allowed == null || allowed.contains(current))) {
      return current;
    }
    final initial = widget.initialObserverCharacterId;
    if (initial != null &&
        characters.any((character) => character.id == initial) &&
        (allowed == null || allowed.contains(initial))) {
      return initial;
    }
    if (allowed == null) return null;
    final active = characters.where((character) => character.isActive);
    return active.isNotEmpty ? active.first.id : characters.firstOrNull?.id;
  }

  Map<String, String> _loadOriginConversations() {
    final origins = <String, String>{};
    for (final group in _db.chatGroupBox.values) {
      final name = group.name.trim();
      if (name.isNotEmpty) origins[group.id] = name;
    }
    for (final event in _db.relationshipEventBox.values) {
      final id = event.originConversationId?.trim() ?? '';
      if (id.isEmpty) continue;
      origins.putIfAbsent(
        id,
        () => event.originNameSnapshot.trim().isEmpty
            ? id.startsWith('dm:')
                ? '私聊'
                : id
            : event.originNameSnapshot.trim(),
      );
    }
    if (widget.conversationId != null) {
      origins.putIfAbsent(
        widget.conversationId!,
        () => widget.conversationName?.trim().isNotEmpty == true
            ? widget.conversationName!.trim()
            : widget.conversationId!,
      );
    }
    return Map.unmodifiable(origins);
  }

  List<RelationshipState> get _visibleRelationships {
    final allowed = widget.allowedObserverCharacterIds;
    var values = _relationships.where(
      (relationship) =>
          allowed == null || allowed.contains(relationship.sourceCharacterId),
    );
    final filtered = _filter.apply(values, isPinned: _controls.isPinned);
    final characterById = {
      for (final character in _characters) character.id: character,
    };
    return filtered
        .where(
          (relationship) => RelationshipAuditPresenter.matchesSearch(
            relationship,
            observerName: _observerName(relationship, characterById),
            observerRole: _observerRole(relationship, characterById),
            targetName: _targetName(relationship, characterById),
            targetRole: _targetRole(relationship, characterById),
            query: _filter.searchQuery,
          ),
        )
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return _loadingScaffold();
    if (_loadError != null) return _errorScaffold();

    final filtered = _visibleRelationships;
    final sections = RelationshipAuditPresenter.sections(
      filtered,
      isPinned: _controls.isPinned,
    );
    return Scaffold(
      appBar: MemoryPageAppBar(
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _loadSnapshot,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= _wideBreakpoint;
          final content = _buildContent(
            context,
            filtered: filtered,
            sections: sections,
            narrow: !wide,
          );
          if (!wide) return content;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              MemoryObserverSidebar(
                sidebarWidth: 240,
                characters: _observerCharacters,
                selectedObserverId: _observerCharacterId,
                searchQuery: _observerSearchQuery,
                showAll: widget.allowedObserverCharacterIds == null,
                onSearchChanged: (value) =>
                    setState(() => _observerSearchQuery = value),
                onClearSearch: () => setState(() => _observerSearchQuery = ''),
                onSelectAll: _selectAllObservers,
                onSelectObserver: _selectObserver,
              ),
              const VerticalDivider(width: 1),
              Expanded(child: content),
            ],
          );
        },
      ),
    );
  }

  Widget _buildContent(
    BuildContext context, {
    required List<RelationshipState> filtered,
    required List<RelationshipAuditSection> sections,
    required bool narrow,
  }) {
    return CustomScrollView(
      key: const ValueKey('relationship-audit-content'),
      controller: _scrollController,
      slivers: [
        if (narrow)
          SliverToBoxAdapter(
            child: MemoryObserverSelector(
              characters: _observerCharacters,
              selectedObserverId: _observerCharacterId,
              showAll: widget.allowedObserverCharacterIds == null,
              onSelectAll: _selectAllObservers,
              onSelectObserver: _selectObserver,
            ),
          ),
        SliverToBoxAdapter(child: _header(context, filtered.length)),
        SliverToBoxAdapter(child: _contextBar(context)),
        SliverToBoxAdapter(child: _quickTargetFilter(context)),
        SliverToBoxAdapter(
          child: RelationshipAuditFilterWidget(
            filter: _filter,
            characters: _characters,
            originConversations: _originConversations,
            originConversationLocked: widget.conversationId != null,
            observerSelectionLocked: widget.allowedObserverCharacterIds != null,
            onChanged: _handleFilterChanged,
          ),
        ),
        if (filtered.isEmpty)
          SliverToBoxAdapter(child: _emptyState(context))
        else
          for (final section in sections) ...[
            SliverToBoxAdapter(
              child: _sectionHeading(
                  context, section.title, section.relationships.length),
            ),
            _relationshipList(section.relationships),
          ],
        _legacyDiagnostic(context),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }

  Widget _header(BuildContext context, int count) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Text(
              '全局关系审计',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
          ),
          Text('$count 条关系', style: TextStyle(color: cs.onSurfaceVariant)),
        ],
      ),
    );
  }

  Widget _contextBar(BuildContext context) {
    final selected = _selectedObserver;
    final observer = selected == null
        ? '全部 AI · 所有关系视角'
        : '${_displayName(selected)} · ${_displayName(selected)}的关系视角';
    final parts = [observer];
    if (widget.allowedObserverCharacterIds != null) {
      parts.add(widget.conversationName?.trim().isNotEmpty == true
          ? widget.conversationName!.trim()
          : '当前群聊');
      parts.add('仅群成员');
      parts.add('事件来源已锁定');
    }
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          CircleAvatar(
            radius: 14,
            backgroundColor: Theme.of(context).colorScheme.primaryContainer,
            child: Text(
              selected == null
                  ? 'AI'
                  : RelationshipAuditPresenter.avatar(selected, 'AI'),
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onPrimaryContainer,
              ),
            ),
          ),
          for (var index = 0; index < parts.length; index++) ...[
            if (index > 0)
              Text('·',
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.outline)),
            Text(
              parts[index],
              style: TextStyle(
                color: index == 0
                    ? Theme.of(context).colorScheme.onSurface
                    : Theme.of(context).colorScheme.primary,
                fontWeight: index == 0 ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _quickTargetFilter(BuildContext context) {
    final selected = switch (_filter.targetType) {
      RelationshipTargetType.user => RelationshipTargetQuickFilter.user,
      RelationshipTargetType.ai => RelationshipTargetQuickFilter.ai,
      null => RelationshipTargetQuickFilter.all,
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SegmentedButton<RelationshipTargetQuickFilter>(
          key: const ValueKey('relationship-target-quick-filter'),
          segments: const [
            ButtonSegment(
              value: RelationshipTargetQuickFilter.all,
              label: Text('全部目标'),
            ),
            ButtonSegment(
              value: RelationshipTargetQuickFilter.user,
              label: Text('关于我'),
            ),
            ButtonSegment(
              value: RelationshipTargetQuickFilter.ai,
              label: Text('其他角色'),
            ),
          ],
          selected: {selected},
          onSelectionChanged: (values) {
            final value = values.first;
            setState(() {
              _filter = switch (value) {
                RelationshipTargetQuickFilter.all => _filter.copyWith(
                    clearTargetType: true,
                    clearTargetAiId: true,
                  ),
                RelationshipTargetQuickFilter.user => _filter.copyWith(
                    targetType: RelationshipTargetType.user,
                    clearTargetAiId: true,
                  ),
                RelationshipTargetQuickFilter.ai => _filter.copyWith(
                    targetType: RelationshipTargetType.ai,
                  ),
              };
            });
          },
        ),
      ),
    );
  }

  Widget _sectionHeading(BuildContext context, String title, int count) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
        child: Row(
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(width: 8),
            Text('$count',
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ],
        ),
      );

  Widget _relationshipList(List<RelationshipState> relationships) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      sliver: SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final relationship = relationships[index];
            final characterById = {
              for (final character in _characters) character.id: character,
            };
            final events = _controls.eventsFor(
              relationship,
              originConversationId: _filter.originConversationId,
            );
            return DecoratedBox(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                border: Border(
                  left: BorderSide(
                      color: Theme.of(context).colorScheme.outlineVariant),
                  right: BorderSide(
                      color: Theme.of(context).colorScheme.outlineVariant),
                  top: index == 0
                      ? BorderSide(
                          color: Theme.of(context).colorScheme.outlineVariant)
                      : BorderSide.none,
                  bottom: index == relationships.length - 1
                      ? BorderSide(
                          color: Theme.of(context).colorScheme.outlineVariant)
                      : BorderSide.none,
                ),
              ),
              child: Column(
                children: [
                  RelationshipAuditCard(
                    key: ValueKey('relationship-row-${relationship.id}'),
                    relationship: relationship,
                    targetName: _targetName(relationship, characterById),
                    targetRole: _targetRole(relationship, characterById),
                    targetAvatar: _targetAvatar(relationship, characterById),
                    stageLabel: RelationshipAuditPresenter.stageLabel(
                        relationship.stage),
                    moodLabel: RelationshipAuditPresenter.moodLabel(
                        relationship.recentMood),
                    recentChange:
                        RelationshipAuditPresenter.recentChangeSummary(
                      events,
                      emptyLabel: widget.conversationId == null
                          ? '当前来源暂无关系事件'
                          : '当前群暂无关系事件',
                    ),
                    pinned: _controls.isPinned(relationship),
                    onOpenDetails: () => _openDetails(relationship),
                  ),
                  if (index < relationships.length - 1)
                    Divider(
                      height: 1,
                      indent: 20,
                      endIndent: 20,
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                ],
              ),
            );
          },
          childCount: relationships.length,
        ),
      ),
    );
  }

  Widget _emptyState(BuildContext context) {
    final hasSearch = _filter.searchQuery?.trim().isNotEmpty == true;
    final hasFilter = _filter.hasAdvancedCriteria || _filter.targetType != null;
    final observer = _selectedObserver;
    final title = _relationships.isEmpty
        ? '暂无关系记录'
        : hasSearch
            ? '没有找到匹配的关系'
            : hasFilter
                ? '没有符合筛选条件的关系'
                : observer == null
                    ? '暂无可显示的关系'
                    : '${_displayName(observer)}尚未形成可展示的关系';
    final description =
        hasSearch ? '换个关键词试试，或清除搜索后浏览全部关系。' : '关系会在聊天中的互动被记录后逐步形成。';
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 48, 24, 56),
        child: Column(
          children: [
            Icon(Icons.people_outline_rounded,
                size: 42,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              description,
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
            if (hasSearch) ...[
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => setState(
                  () => _filter = _filter.copyWith(clearSearchQuery: true),
                ),
                child: const Text('清除搜索'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _legacyDiagnostic(BuildContext context) {
    if (_legacyRelationships.isEmpty) return const SliverToBoxAdapter();
    final characterById = {
      for (final character in _characters) character.id: character,
    };
    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.fromLTRB(20, 20, 20, 0),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          border:
              Border.all(color: Theme.of(context).colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(12),
        ),
        child: ExpansionTile(
          title: const Text('旧版关系诊断'),
          subtitle: const Text('只读 · 旧版数据不会作为当前关系，也不能编辑'),
          children: [
            for (final relationship in _legacyRelationships)
              ListTile(
                dense: true,
                leading: const Icon(Icons.history_toggle_off_rounded),
                title: Text(
                  '${_observerName(relationship, characterById)} → '
                  '${_targetName(relationship, characterById)}',
                ),
                subtitle: Text('来源群组：${relationship.groupId} · 旧版数据 · 只读'),
              ),
          ],
        ),
      ),
    );
  }

  void _selectAllObservers() {
    if (widget.allowedObserverCharacterIds != null) return;
    setState(() {
      _observerCharacterId = null;
      _filter = _filter.copyWith(clearObserverCharacterId: true);
    });
  }

  void _selectObserver(String id) {
    if (widget.allowedObserverCharacterIds != null &&
        !widget.allowedObserverCharacterIds!.contains(id)) {
      return;
    }
    setState(() {
      _observerCharacterId = id;
      _filter = _filter.copyWith(observerCharacterId: id);
    });
  }

  void _handleFilterChanged(RelationshipAuditFilter next) {
    var constrained = next;
    if (widget.allowedObserverCharacterIds != null &&
        _observerCharacterId != null) {
      constrained =
          constrained.copyWith(observerCharacterId: _observerCharacterId);
    }
    if (widget.conversationId != null) {
      constrained = constrained.copyWith(
        originConversationId: widget.conversationId,
      );
    }
    setState(() {
      _filter = constrained;
      _observerCharacterId = constrained.observerCharacterId;
    });
  }

  Future<void> _openDetails(RelationshipState relationship) async {
    final offset =
        _scrollController.hasClients ? _scrollController.offset : null;
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => RelationshipAuditDetailPage(
          relationshipId: relationship.id,
          originConversationId: _filter.originConversationId,
          originConversationName: widget.conversationName,
        ),
      ),
    );
    if (!mounted || changed != true) return;
    await _loadSnapshot(showLoading: false);
    if (offset != null) {
      await WidgetsBinding.instance.endOfFrame;
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(
          offset.clamp(0, _scrollController.position.maxScrollExtent),
        );
      }
    }
  }

  AICharacter? get _selectedObserver {
    final id = _observerCharacterId;
    if (id == null) return null;
    for (final character in _observerCharacters) {
      if (character.id == id) return character;
    }
    return null;
  }

  String _observerName(
    RelationshipState relationship,
    Map<String, AICharacter> characters,
  ) =>
      RelationshipAuditPresenter.displayName(
        characters[relationship.sourceCharacterId],
        relationship.sourceCharacterId,
      );

  String _observerRole(
    RelationshipState relationship,
    Map<String, AICharacter> characters,
  ) =>
      RelationshipAuditPresenter.roleLabel(
          characters[relationship.sourceCharacterId]);

  String _targetName(
    RelationshipState relationship,
    Map<String, AICharacter> characters,
  ) {
    if (relationship.targetType == RelationshipTargetType.user) {
      final name = _userProfile?.displayName.trim() ?? '';
      return name.isEmpty ? '我' : name;
    }
    return RelationshipAuditPresenter.displayName(
      characters[relationship.targetId],
      relationship.targetId,
    );
  }

  String _targetRole(
    RelationshipState relationship,
    Map<String, AICharacter> characters,
  ) =>
      relationship.targetType == RelationshipTargetType.user
          ? '用户'
          : RelationshipAuditPresenter.roleLabel(
              characters[relationship.targetId]);

  String _targetAvatar(
    RelationshipState relationship,
    Map<String, AICharacter> characters,
  ) {
    if (relationship.targetType == RelationshipTargetType.user) {
      return RelationshipAuditPresenter.avatar(_userProfileCharacter, '我');
    }
    return RelationshipAuditPresenter.avatar(
      characters[relationship.targetId],
      'AI',
    );
  }

  AICharacter? get _userProfileCharacter {
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
      isActive: true,
    );
  }

  String _displayName(AICharacter character) =>
      RelationshipAuditPresenter.displayName(character, character.id);

  Widget _loadingScaffold() => const Scaffold(
        appBar: MemoryPageAppBar(title: '关系审计'),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('正在加载关系数据'),
            ],
          ),
        ),
      );

  Widget _errorScaffold() => Scaffold(
        appBar: const MemoryPageAppBar(title: '关系审计'),
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

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
