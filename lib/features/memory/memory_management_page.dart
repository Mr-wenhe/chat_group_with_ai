import 'dart:async';

import 'package:chat_group/core/database/data_lifecycle_service.dart';
import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/permanent_memory.dart';
import 'package:chat_group/features/ai_character/ai_character_list_page.dart';
import 'package:chat_group/features/direct_chat/direct_chat_session.dart';
import 'package:chat_group/features/memory/memory_audit_filter.dart';
import 'package:chat_group/features/memory/memory_audit_list.dart';
import 'package:chat_group/features/memory/memory_audit_filter_widget.dart';
import 'package:chat_group/features/memory/memory_audit_presenter.dart';
import 'package:chat_group/features/memory/memory_detail_page.dart';
import 'package:chat_group/features/memory/memory_management_widgets.dart';
import 'package:chat_group/features/memory/memory_migration_diagnostics_page.dart';
import 'package:chat_group/features/memory/memory_observer_sidebar.dart';
import 'package:chat_group/features/memory/memory_scroll_restore.dart';
import 'package:chat_group/features/memory/memory_subject_selector.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

part 'memory_management_content.dart';
part 'memory_management_page_helpers.dart';

class MemoryManagementPage extends ConsumerStatefulWidget {
  final String? conversationId;
  final MemoryConversationScope scope;

  const MemoryManagementPage({
    super.key,
    required this.scope,
    this.conversationId,
  });

  @override
  ConsumerState<MemoryManagementPage> createState() =>
      _MemoryManagementPageState();
}

class _MemoryManagementPageState extends ConsumerState<MemoryManagementPage> {
  static const _wideBreakpoint = 900.0;

  late final DatabaseService _db;
  late MemoryAuditFilter _advancedFilter;
  List<PermanentMemory> _allMemories = const [];
  List<AICharacter> _charactersSnapshot = const [];
  List<AICharacter> _observerCharactersSnapshot = const [];
  String _observerSearchQuery = '';
  String? _observerCharacterId;
  SubjectFilter _subjectFilter = SubjectFilter.all;
  String? _searchQuery;
  bool _historyExpanded = false;
  bool _isLoading = true;
  Object? _loadError;
  int _loadRequest = 0;
  final ScrollController _contentScrollController = ScrollController();

  List<AICharacter> get _characters => _charactersSnapshot;

  List<AICharacter> get _observerCharacters => _observerCharactersSnapshot;

  @override
  void initState() {
    super.initState();
    _db = ref.read(databaseServiceProvider);
    _advancedFilter = MemoryAuditFilter(
      originConversationId: widget.conversationId,
    );
    unawaited(_loadSnapshot());
  }

  @override
  void didUpdateWidget(covariant MemoryManagementPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_sameScope(oldWidget.scope, widget.scope)) return;

    final safeContext = widget.scope.constrainFilter(_controlsFilter);
    setState(() {
      _observerCharacterId = safeContext.observerCharacterId;
      _subjectFilter = safeContext.subjectFilter;
      _observerCharactersSnapshot = const [];
    });
    unawaited(_loadSnapshot(showLoading: false));
  }

  @override
  void dispose() {
    _contentScrollController.dispose();
    super.dispose();
  }

  Future<void> _restoreContentScrollOffset(double offset) async {
    await MemoryScrollRestorer.restore(
      offset: offset,
      isMounted: () => mounted,
      hasClients: () => _contentScrollController.hasClients,
      maxScrollExtent: () => _contentScrollController.position.maxScrollExtent,
      pixels: () => _contentScrollController.position.pixels,
      jumpTo: (value) => _contentScrollController.position.jumpTo(value),
      endOfFrame: () => WidgetsBinding.instance.endOfFrame,
      scheduleFrame: WidgetsBinding.instance.scheduleFrame,
    );
  }

  bool _sameScope(MemoryConversationScope left, MemoryConversationScope right) {
    if (left.type != right.type ||
        left.directCharacterId != right.directCharacterId) {
      return false;
    }
    return left.groupCharacterIds.length == right.groupCharacterIds.length &&
        left.groupCharacterIds.containsAll(right.groupCharacterIds);
  }

  Future<void> _loadSnapshot({bool showLoading = true}) async {
    final request = ++_loadRequest;
    final scope = widget.scope;
    if (mounted && showLoading) {
      setState(() {
        _isLoading = true;
        _loadError = null;
      });
    }
    try {
      await Future<void>.value();
      final memories = _db.permanentMemoryBox.values.toList(growable: false);
      final scopedMemories = scope.apply(memories);
      final allowedObserverIds = scope.allowedObserverCharacterIds;
      final referencedCharacterIds = <String>{
        ...?allowedObserverIds,
        for (final memory in scopedMemories) ...{
          memory.observerCharacterId,
          ...memory.subjectIds.where((id) => id != 'user'),
          ...memory.participantIds.where((id) => id != 'user'),
        },
        for (final memory in scopedMemories)
          if (DirectChatSession.characterIdFrom(
            memory.originConversationId ?? '',
          )
              case final originCharacterId?)
            originCharacterId,
      };
      final characterIds = <String>{
        if (allowedObserverIds == null)
          ..._db.aiCharacterBox.values.map((character) => character.id),
        ...referencedCharacterIds,
      };
      final observerIds =
          scopedMemories.map((memory) => memory.observerCharacterId).toSet();
      final lifecycle = DataLifecycleService(db: _db);
      final resolvedCharacters = lifecycle.charactersForIds(characterIds);
      final resolvedObserverCharacters = lifecycle.charactersForIds({
        if (allowedObserverIds == null)
          ..._db.aiCharacterBox.values.map((character) => character.id),
        ...?allowedObserverIds,
        ...observerIds,
      });
      final orderedObserverCharacters = _orderObservers(
        resolvedObserverCharacters,
        scope,
      );
      final resolvedIdentityIds =
          resolvedCharacters.map((character) => character.id).toSet();
      final resolvedObserverIds =
          orderedObserverCharacters.map((character) => character.id).toSet();
      final identityCharacters = [
        ...resolvedCharacters,
        for (final observerId in observerIds)
          if (!resolvedIdentityIds.contains(observerId))
            _deletedCharacterPlaceholder(observerId),
      ];
      final observerCharacters = [
        ...orderedObserverCharacters,
        for (final observerId in observerIds)
          if (!resolvedObserverIds.contains(observerId))
            _deletedCharacterPlaceholder(observerId),
      ];
      final selectedObserverId = _selectedObserverId(observerCharacters, scope);
      if (!mounted || request != _loadRequest) return;
      setState(() {
        _allMemories = memories;
        _charactersSnapshot = identityCharacters;
        _observerCharactersSnapshot = observerCharacters;
        _observerCharacterId = selectedObserverId;
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

  List<PermanentMemory> get _scopedMemories => widget.scope.apply(_allMemories);

  List<PermanentMemory> get _contextMemories => MemoryAuditFilter(
        observerCharacterId: _observerCharacterId,
        subjectFilter: _subjectFilter,
      ).apply(_allMemories, scope: widget.scope);

  MemoryAuditPresenter _presenter() => MemoryAuditPresenter(
        characterNames: {
          for (final character in _characters) character.id: character.name,
        },
        characterAvatars: {
          for (final character in _characters) character.id: character.avatar,
        },
        conversationNames: _originConversations(),
      );

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return _loadingScaffold();
    if (_loadError != null) return _errorScaffold();

    final presenter = _presenter();
    final filtered = _effectiveFilter.apply(
      _allMemories,
      scope: widget.scope,
      searchText: (memory) => presenter.present(memory).searchProjection,
    );
    final sections = presenter.sections(filtered);

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
            presenter: presenter,
            sections: sections,
            filteredCount: filtered.length,
            narrow: !wide,
          );
          if (!wide || !widget.scope.showsObserverFilter) return content;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              MemoryObserverSidebar(
                characters: _observerCharacters,
                selectedObserverId: _observerCharacterId,
                searchQuery: _observerSearchQuery,
                showAll:
                    widget.scope.type == MemoryConversationScopeType.settings,
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

  Widget _buildSubjectToolbar(BuildContext context) {
    return MemorySubjectSelector(
      value: _subjectValue,
      characters: _subjectCandidates,
      onChanged: _selectSubject,
    );
  }

  List<AICharacter> get _subjectCandidates {
    final observerId = _observerCharacterId;
    final allowedSubjectIds = widget.scope.allowedSubjectIds;
    final excludeObserver =
        widget.scope.type == MemoryConversationScopeType.group;
    return _characters.where((character) {
      if (excludeObserver && character.id == observerId) return false;
      return allowedSubjectIds == null ||
          allowedSubjectIds.contains(character.id);
    }).toList(growable: false);
  }

  AICharacter? get _selectedObserver {
    final selectedId = _observerCharacterId ?? widget.scope.directCharacterId;
    if (selectedId == null) return null;
    for (final character in _characters) {
      if (character.id == selectedId) return character;
    }
    return null;
  }

  String get _subjectValue =>
      _subjectFilter.characterId ?? MemorySubjectSelector.allValue;

  void _selectAllObservers() {
    if (widget.scope.type == MemoryConversationScopeType.group) return;
    setState(() => _observerCharacterId = null);
  }

  void _toggleHistory() {
    setState(() => _historyExpanded = !_historyExpanded);
  }

  void _selectObserver(String id) {
    setState(() {
      _observerCharacterId = id;
      if (_subjectFilter.characterId == id) {
        _subjectFilter = SubjectFilter.all;
      }
    });
  }

  void _selectSubject(String value) {
    setState(() => _subjectFilter = _subjectFilterForValue(value));
  }

  SubjectFilter _subjectFilterForValue(String value) => switch (value) {
        MemorySubjectSelector.allValue => SubjectFilter.all,
        MemorySubjectSelector.aboutMeValue => SubjectFilter.aboutMe,
        MemorySubjectSelector.selfGrowthValue => SubjectFilter.selfGrowth,
        _ => SubjectFilter.aboutCharacter(value),
      };

  MemoryAuditFilter get _controlsFilter => MemoryAuditFilter(
        observerCharacterId: _observerCharacterId,
        subjectFilter: _subjectFilter,
        originType: _advancedFilter.originType,
        originConversationId: _advancedFilter.originConversationId,
        status: _advancedFilter.status,
        memoryKind: _advancedFilter.memoryKind,
        pinnedOnly: _advancedFilter.pinnedOnly,
        searchQuery: _searchQuery,
        sortOrder: _advancedFilter.sortOrder,
      );

  MemoryAuditFilter get _effectiveFilter => MemoryAuditFilter(
        observerCharacterId: _observerCharacterId,
        subjectFilter: _subjectFilter,
        originType: _advancedFilter.originType,
        originConversationId: _advancedFilter.originConversationId,
        status: _advancedFilter.status,
        memoryKind: _advancedFilter.memoryKind,
        pinnedOnly: _advancedFilter.pinnedOnly,
        searchQuery: _searchQuery,
        sortOrder: _advancedFilter.sortOrder,
      );

  bool get _hasSearch => _searchQuery?.trim().isNotEmpty == true;

  List<Widget> _buildHeaderActions(MemoryAuditPresenter presenter) => [
        MemoryAuditFilterAction(
          filter: _controlsFilter,
          characters: _characters,
          originConversations: _originConversations(),
          presenter: presenter,
          scope: widget.scope,
          showNavigationSelectors: false,
          label: '筛选',
          onChanged: _handleFilterChanged,
        ),
        if (widget.scope.type == MemoryConversationScopeType.settings)
          OutlinedButton.icon(
            key: const ValueKey('memory-migration-diagnostic'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const MemoryMigrationDiagnosticsPage(),
              ),
            ),
            icon: const Icon(Icons.fact_check_outlined, size: 18),
            label: const Text('迁移诊断'),
          ),
        if (_advancedFilter.hasAdvancedCriteria)
          TextButton(
            key: const ValueKey('clear-memory-filter'),
            onPressed: _clearAdvancedFilters,
            child: const Text('清除筛选'),
          ),
      ];

  void _handleFilterChanged(MemoryAuditFilter next) {
    setState(() {
      _searchQuery = next.searchQuery;
      _advancedFilter = MemoryAuditFilter(
        originType: next.originType,
        originConversationId: next.originConversationId,
        status: next.status,
        memoryKind: next.memoryKind,
        pinnedOnly: next.pinnedOnly,
        sortOrder: next.sortOrder,
      );
    });
  }

  void _clearSearch() {
    setState(() => _searchQuery = null);
  }

  void _clearAdvancedFilters() {
    setState(() => _advancedFilter = const MemoryAuditFilter());
  }

  void _resetBrowsingContext() {
    setState(() {
      _observerCharacterId =
          widget.scope.type == MemoryConversationScopeType.group
              ? _selectedObserverId(_observerCharacters, widget.scope)
              : null;
      _subjectFilter = SubjectFilter.all;
      _searchQuery = null;
      _advancedFilter = const MemoryAuditFilter();
    });
  }
}
