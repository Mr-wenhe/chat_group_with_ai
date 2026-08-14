part of 'memory_management_page.dart';

extension _MemoryManagementPageHelpers on _MemoryManagementPageState {
  List<AICharacter> _orderObservers(
    List<AICharacter> characters,
    MemoryConversationScope scope,
  ) {
    if (scope.type != MemoryConversationScopeType.group) {
      return characters;
    }
    final byId = {for (final character in characters) character.id: character};
    return [
      for (final id in scope.groupCharacterIds)
        if (byId[id] case final character?) character,
      for (final character in characters)
        if (!scope.groupCharacterIds.contains(character.id)) character,
    ];
  }

  String? _selectedObserverId(
    List<AICharacter> observerCharacters,
    MemoryConversationScope scope,
  ) {
    if (scope.type != MemoryConversationScopeType.group) {
      return _observerCharacterId;
    }
    final allowed = scope.allowedObserverCharacterIds ?? const <String>{};
    if (_observerCharacterId != null &&
        allowed.contains(_observerCharacterId) &&
        observerCharacters
            .any((character) => character.id == _observerCharacterId)) {
      return _observerCharacterId;
    }
    final activeCharacters = observerCharacters
        .where((character) => character.isActive)
        .toList(growable: false);
    if (activeCharacters.isNotEmpty) return activeCharacters.first.id;
    for (final character in observerCharacters) {
      if (allowed.contains(character.id)) return character.id;
    }
    return null;
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

  Map<String, String> _originConversations() {
    final result = <String, String>{};
    final scopedConversationIds = _scopedMemories
        .map((memory) => memory.originConversationId)
        .whereType<String>()
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    for (final group in _db.chatGroupBox.values) {
      if (widget.scope.type == MemoryConversationScopeType.settings ||
          scopedConversationIds.contains(group.id)) {
        result[group.id] = group.name.trim();
      }
    }
    for (final memory in _scopedMemories) {
      final id = memory.originConversationId;
      if (id == null || id.trim().isEmpty) continue;
      result.putIfAbsent(id, () => memory.originNameSnapshot.trim());
    }
    return result;
  }

  Widget _loadingScaffold() => const Scaffold(
        appBar: MemoryPageAppBar(title: '永久记忆'),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('正在加载永久记忆'),
            ],
          ),
        ),
      );

  Widget _errorScaffold() => Scaffold(
        appBar: const MemoryPageAppBar(title: '永久记忆'),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline_rounded, size: 40),
                const SizedBox(height: 12),
                const Text('永久记忆加载失败'),
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
