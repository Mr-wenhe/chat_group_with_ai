import 'package:chat_group/core/database/data_lifecycle_service.dart';
import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/character_memory.dart';
import 'package:chat_group/core/models/permanent_memory.dart';
import 'package:chat_group/features/ai_character/character_gender_migrator.dart';
import 'package:chat_group/features/memory/memory_audit_presenter.dart';
import 'package:chat_group/features/memory/memory_migrator.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

part 'memory_migration_diagnostics_widgets.dart';

/// Read-only view of the data left by the pre-permanent-memory model.
class MemoryMigrationDiagnosticsPage extends ConsumerStatefulWidget {
  const MemoryMigrationDiagnosticsPage({super.key});

  @override
  ConsumerState<MemoryMigrationDiagnosticsPage> createState() =>
      _MemoryMigrationDiagnosticsPageState();
}

class _MemoryMigrationDiagnosticsPageState
    extends ConsumerState<MemoryMigrationDiagnosticsPage> {
  late final DatabaseService _db;
  _MigrationSnapshot? _snapshot;
  String? _expandedCharacterId;
  final _expandedSessionIds = <String>{};
  bool _isLoading = true;
  Object? _loadError;

  @override
  void initState() {
    super.initState();
    _db = ref.read(databaseServiceProvider);
    _loadSnapshot();
  }

  void _updateExpansion(VoidCallback update) {
    if (mounted) setState(update);
  }

  Future<void> _loadSnapshot() async {
    if (mounted) {
      setState(() {
        _isLoading = true;
        _loadError = null;
      });
    }
    try {
      final snapshot = _readSnapshot();
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _isLoading = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = error;
        _isLoading = false;
      });
    }
  }

  _MigrationSnapshot _readSnapshot() {
    final characters = _db.aiCharacterBox.values.toList(growable: false);
    final sessions = _db.characterMemoryBox.values.toList(growable: false);
    final characterById = <String, AICharacter>{
      for (final character in characters) character.id: character,
    };
    final legacyCharacterIds = <String>{
      for (final session in sessions) session.characterId,
      for (final character in characters)
        if (character.memorySummary.trim().isNotEmpty) character.id,
    };
    final lifecycle = DataLifecycleService(db: _db);
    final resolvedCharacters = {
      for (final character in lifecycle.charactersForIds(legacyCharacterIds))
        character.id: character,
    };
    final characterNames = <String, String>{
      for (final character in characters) character.id: character.name,
    };
    for (final character in lifecycle.deletedCharacters()) {
      characterNames.putIfAbsent(character.id, () => character.name);
    }
    final presenter = MemoryAuditPresenter(
      characterNames: characterNames,
      conversationNames: {
        for (final group in _db.chatGroupBox.values) group.id: group.name,
      },
    );
    final records = [
      for (final characterId in legacyCharacterIds)
        (
          characterId: characterId,
          name: _characterName(resolvedCharacters[characterId]),
          summary: characterById[characterId]?.memorySummary.trim() ?? '',
          sessions: sessions
              .where((session) => session.characterId == characterId)
              .toList(growable: false),
        ),
    ]..sort((left, right) => left.name.compareTo(right.name));
    return (
      characters: records,
      legacySessionMemoryCount: sessions.length,
      migratedPermanentMemoryCount: _db.permanentMemoryBox.values
          .where(
              (memory) => memory.originType == MemoryOriginType.legacyMigration)
          .length,
      genderMigration: _genderMigrationStatus(characters.length),
      memoryMigration: _memoryMigrationStatus(),
      presenter: presenter,
    );
  }

  String _characterName(AICharacter? character) {
    final name = character?.name.trim() ?? '';
    return name.isEmpty ||
            MemoryAuditPresenter.isTechnicalName(name, character?.id)
        ? '已删除角色'
        : name;
  }

  _GenderMigrationStatus _genderMigrationStatus(int characterCount) {
    final raw = _db.appSettingsBox.get(CharacterGenderMigrator.diagnosticKey);
    final diagnostic = raw is Map ? raw : const <dynamic, dynamic>{};
    final locked =
        _db.appSettingsBox.get(CharacterGenderMigrator.migrationKey) == true;
    final rawStatus = diagnostic['status']?.toString();
    final status = locked || rawStatus == 'completed'
        ? '已完成'
        : switch (rawStatus) {
            'partial' => '部分完成',
            'failed' => '未完成',
            _ => '尚无记录',
          };
    final migratedCount =
        _asInt(diagnostic['characterCount']) ?? (locked ? characterCount : 0);
    return (status: status, characterCount: migratedCount);
  }

  int? _asInt(Object? value) => switch (value) {
        int value => value,
        num value => value.toInt(),
        String value => int.tryParse(value),
        _ => null,
      };

  _MemoryMigrationStatus _memoryMigrationStatus() {
    final raw = _db.appSettingsBox.get(MemoryMigrator.diagnosticKey);
    final diagnostic = raw is Map ? raw : const <dynamic, dynamic>{};
    final status = switch (diagnostic['status']?.toString()) {
      'completed' => '已完成',
      'partial' => '部分完成',
      'failed' => '未完成',
      _ => '尚无记录',
    };
    return (
      status: status,
      warningCount: _asInt(diagnostic['warningCount']) ?? 0,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return _loadingScaffold();
    if (_loadError != null) return _errorScaffold();
    final snapshot = _snapshot!;
    return Scaffold(
      appBar: AppBar(
        title: const Text('迁移诊断'),
        leading: const BackButton(),
      ),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(child: _buildHeader(context, snapshot)),
          if (snapshot.characters.isEmpty)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: Text('没有发现可诊断的旧版数据。')),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) => _buildCharacterTile(
                    context,
                    snapshot.characters[index],
                  ),
                  childCount: snapshot.characters.length,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _loadingScaffold() => Scaffold(
        appBar: AppBar(
          title: const Text('迁移诊断'),
          leading: const BackButton(),
        ),
        body: const Center(child: CircularProgressIndicator()),
      );

  Widget _errorScaffold() => Scaffold(
        appBar: AppBar(
          title: const Text('迁移诊断'),
          leading: const BackButton(),
        ),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('迁移诊断加载失败'),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _loadSnapshot,
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
}

typedef _MigrationSnapshot = ({
  List<_LegacyCharacterRecord> characters,
  int legacySessionMemoryCount,
  int migratedPermanentMemoryCount,
  _GenderMigrationStatus genderMigration,
  _MemoryMigrationStatus memoryMigration,
  MemoryAuditPresenter presenter,
});
typedef _LegacyCharacterRecord = ({
  String characterId,
  String name,
  String summary,
  List<CharacterMemory> sessions,
});
typedef _LegacyConversationRecord = ({
  String id,
  String name,
  List<CharacterMemory> memories,
});
typedef _GenderMigrationStatus = ({String status, int characterCount});
typedef _MemoryMigrationStatus = ({String status, int warningCount});
