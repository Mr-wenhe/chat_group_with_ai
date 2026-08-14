part of 'memory_management_page.dart';

extension _MemoryManagementContent on _MemoryManagementPageState {
  Widget _buildContent(
    BuildContext context, {
    required MemoryAuditPresenter presenter,
    required MemoryAuditSections sections,
    required int filteredCount,
    required bool narrow,
  }) {
    return CustomScrollView(
      key: const ValueKey('memory-content'),
      controller: _contentScrollController,
      slivers: _contentSlivers(
        context,
        presenter: presenter,
        sections: sections,
        filteredCount: filteredCount,
        narrow: narrow,
      ),
    );
  }

  List<Widget> _contentSlivers(
    BuildContext context, {
    required MemoryAuditPresenter presenter,
    required MemoryAuditSections sections,
    required int filteredCount,
    required bool narrow,
  }) =>
      [
        if (narrow && widget.scope.showsObserverFilter)
          SliverToBoxAdapter(
            child: MemoryObserverSelector(
              characters: _observerCharacters,
              selectedObserverId: _observerCharacterId,
              showAll:
                  widget.scope.type == MemoryConversationScopeType.settings,
              onSelectAll: _selectAllObservers,
              onSelectObserver: _selectObserver,
            ),
          ),
        SliverToBoxAdapter(
          child: MemoryIdentityHeader(
            selectedObserver: _selectedObserver,
            filteredCount: filteredCount,
            isDirectScope:
                widget.scope.type == MemoryConversationScopeType.direct,
            isGroupScope:
                widget.scope.type == MemoryConversationScopeType.group,
            actions: _buildHeaderActions(presenter),
          ),
        ),
        if (widget.scope.showsSubjectFilter)
          SliverToBoxAdapter(child: _buildSubjectToolbar(context)),
        SliverToBoxAdapter(
          child: MemoryAuditFilterWidget(
            filter: _controlsFilter,
            characters: _characters,
            originConversations: _originConversations(),
            presenter: presenter,
            scope: widget.scope,
            showAdvancedControls: false,
            showNavigationSelectors: false,
            onChanged: _handleFilterChanged,
          ),
        ),
        ..._buildMemorySlivers(context, sections, filteredCount),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ];

  List<Widget> _buildMemorySlivers(
    BuildContext context,
    MemoryAuditSections sections,
    int filteredCount,
  ) {
    if (_characters.isEmpty || _scopedMemories.isEmpty || filteredCount == 0) {
      return [SliverToBoxAdapter(child: _buildEmptyState(context))];
    }

    return [
      if (sections.active.isNotEmpty)
        SliverToBoxAdapter(
          child: MemorySectionHeading(
            title: '有效记录',
            count: sections.active.length,
          ),
        ),
      if (sections.active.isNotEmpty)
        _buildMemoryList('active', sections.active),
      if (sections.history.isNotEmpty)
        SliverToBoxAdapter(
          child: MemoryHistorySurface(
            rows: sections.history,
            expanded: _historyExpanded,
            onToggle: _toggleHistory,
          ),
        ),
      if (sections.history.isNotEmpty && _historyExpanded)
        _buildMemoryList('history', sections.history),
    ];
  }

  Widget _buildEmptyState(BuildContext context) => MemoryEmptyState(
        hasNoCharacters: _characters.isEmpty,
        hasNoMemories: widget.scope.type == MemoryConversationScopeType.settings
            ? _scopedMemories.isEmpty
            : _contextMemories.isEmpty,
        hasSearch: _hasSearch,
        hasFilter: _advancedFilter.hasAdvancedCriteria,
        onCreateCharacter: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const AICharacterListPage()),
        ),
        onClearSearch: _clearSearch,
        onClearFilter: _clearAdvancedFilters,
        onResetAll: _resetBrowsingContext,
        onBack: () => Navigator.of(context).maybePop(),
        backLabel: widget.scope.type == MemoryConversationScopeType.settings
            ? '返回设置'
            : '返回聊天',
      );

  MemoryAuditSliverList _buildMemoryList(
    String surfaceKey,
    List<MemoryAuditRow> rows,
  ) =>
      MemoryAuditSliverList(
        surfaceKey: surfaceKey,
        rows: rows,
        showObserver:
            widget.scope.showsObserverFilter && _observerCharacterId == null,
        onOpenDetails: _openMemoryDetails,
      );

  Future<void> _openMemoryDetails(String memoryId) async {
    final memory = _allMemories.cast<PermanentMemory?>().firstWhere(
          (item) => item?.id == memoryId,
          orElse: () => null,
        );
    if (memory == null) return;
    final scrollOffset = _contentScrollController.hasClients
        ? _contentScrollController.offset
        : null;
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => MemoryDetailPage(
          memory: memory,
          scope: widget.scope,
        ),
      ),
    );
    if (changed == true && mounted) {
      await _loadSnapshot(showLoading: false);
      if (scrollOffset != null) {
        await _restoreContentScrollOffset(scrollOffset);
      }
    }
  }
}
