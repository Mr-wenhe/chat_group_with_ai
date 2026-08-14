part of 'memory_migration_diagnostics_page.dart';

extension _MemoryMigrationDiagnosticsWidgets
    on _MemoryMigrationDiagnosticsPageState {
  Widget _buildHeader(
    BuildContext context,
    _MigrationSnapshot snapshot,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '旧版数据概览',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text(
            '旧版数据仅供诊断，不注入 Prompt，也不能在这里编辑。',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          _buildStatistics(context, snapshot),
          const SizedBox(height: 12),
          Text(
            '性别迁移：${snapshot.genderMigration.status} · '
            '${snapshot.genderMigration.characterCount} 个角色',
          ),
          const SizedBox(height: 8),
          Text('永久记忆迁移：${snapshot.memoryMigration.status}'),
          if (snapshot.memoryMigration.warningCount > 0)
            Text('${snapshot.memoryMigration.warningCount} 项安全诊断待处理'),
          if (snapshot.characters.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text(
              '按角色查看旧版内容',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              '默认只显示摘要状态和会话数量；点击角色后才展开正文。',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStatistics(
    BuildContext context,
    _MigrationSnapshot snapshot,
  ) {
    final cards = [
      (
        key: const ValueKey('legacy-diagnostic-character-count'),
        label: '旧版角色数',
        value: snapshot.characters.length,
      ),
      (
        key: const ValueKey('legacy-diagnostic-session-count'),
        label: '旧版会话记忆数',
        value: snapshot.legacySessionMemoryCount,
      ),
      (
        key: const ValueKey('legacy-diagnostic-permanent-count'),
        label: '已迁移永久记忆数',
        value: snapshot.migratedPermanentMemoryCount,
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) => Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final card in cards)
            SizedBox(
              width: constraints.maxWidth >= 660
                  ? (constraints.maxWidth - 24) / 3
                  : 190,
              child: Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        card.label,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${card.value}',
                        key: card.key,
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCharacterTile(
    BuildContext context,
    _LegacyCharacterRecord record,
  ) {
    final expanded = _expandedCharacterId == record.characterId;
    final summaryLabel = record.summary.isEmpty ? '无跨会话摘要' : '有跨会话摘要';
    return ExpansionTile(
      key: ValueKey('memory-migration-role-${record.characterId}'),
      initiallyExpanded: expanded,
      onExpansionChanged: (value) => _updateExpansion(() {
        if (value && _expandedCharacterId != record.characterId) {
          _expandedSessionIds.clear();
        }
        _expandedCharacterId = value ? record.characterId : null;
        if (!value) _expandedSessionIds.clear();
      }),
      title: Text(record.name),
      subtitle: Text(
        '$summaryLabel · ${record.sessions.length} 条旧会话记忆',
      ),
      children: expanded ? [_buildCharacterDetails(context, record)] : const [],
    );
  }

  Widget _buildCharacterDetails(
    BuildContext context,
    _LegacyCharacterRecord record,
  ) {
    final conversations = _groupSessions(record.sessions);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (record.summary.isNotEmpty) ...[
            Text(
              '跨会话摘要',
              style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(record.summary),
            const SizedBox(height: 16),
          ],
          Text(
            '旧版会话记忆',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          if (conversations.isEmpty)
            const Text('没有旧版会话正文。')
          else
            ListView.builder(
              key: ValueKey('memory-migration-sessions-${record.characterId}'),
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: conversations.length,
              itemBuilder: (context, index) =>
                  _buildConversation(context, conversations[index]),
            ),
          const SizedBox(height: 8),
          ExpansionTile(
            key: ValueKey(
                'memory-migration-technical-role-${record.characterId}'),
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            title: const Text('技术信息'),
            children: [Text('角色 ID：${record.characterId}')],
          ),
        ],
      ),
    );
  }

  Widget _buildConversation(
    BuildContext context,
    _LegacyConversationRecord conversation,
  ) {
    final expanded = _expandedSessionIds.contains(conversation.id);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: ExpansionTile(
        key: ValueKey('memory-migration-session-${conversation.id}'),
        initiallyExpanded: expanded,
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        onExpansionChanged: (value) => _updateExpansion(() {
          if (value) {
            _expandedSessionIds.add(conversation.id);
          } else {
            _expandedSessionIds.remove(conversation.id);
          }
        }),
        title: Text(
          conversation.name,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        subtitle: Text('${conversation.memories.length} 条旧会话记忆'),
        children: [
          if (expanded) ...[
            for (final memory in conversation.memories)
              ..._buildMemoryEntries(context, memory),
            ExpansionTile(
              key: ValueKey(
                'memory-migration-technical-session-${conversation.id}',
              ),
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              title: const Text('技术信息'),
              children: [Text('会话 ID：${conversation.id}')],
            ),
          ],
        ],
      ),
    );
  }

  List<Widget> _buildMemoryEntries(
    BuildContext context,
    CharacterMemory memory,
  ) {
    final entries = <(String, String)>[
      for (final content in memory.facts) ('事实', content),
      for (final content in memory.relationshipNotes) ('关系备注', content),
      for (final content in memory.personaGrowth) ('成长', content),
    ];
    if (entries.isEmpty) {
      return [
        const Padding(padding: EdgeInsets.only(top: 4), child: Text('（空）'))
      ];
    }
    return [
      for (final entry in entries)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '${entry.$1}：',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                TextSpan(text: entry.$2),
              ],
            ),
          ),
        ),
    ];
  }

  List<_LegacyConversationRecord> _groupSessions(
    List<CharacterMemory> sessions,
  ) {
    final grouped = <String, List<CharacterMemory>>{};
    for (final session in sessions) {
      grouped.putIfAbsent(session.groupId, () => []).add(session);
    }
    return [
      for (final entry in grouped.entries)
        (
          id: entry.key,
          name: _snapshot!.presenter.resolveConversationName(entry.key),
          memories: entry.value,
        ),
    ];
  }
}
