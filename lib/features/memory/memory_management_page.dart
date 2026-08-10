import 'dart:async';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/character_memory.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/permanent_memory.dart';
import 'package:chat_group/features/memory/memory_audit_card.dart';
import 'package:chat_group/features/memory/memory_audit_filter.dart';
import 'package:chat_group/features/memory/memory_audit_filter_widget.dart';
import 'package:chat_group/features/memory/memory_controls.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class MemoryManagementPage extends ConsumerStatefulWidget {
  final String? conversationId;

  const MemoryManagementPage({
    super.key,
    this.conversationId,
  });

  @override
  ConsumerState<MemoryManagementPage> createState() =>
      _MemoryManagementPageState();
}

class _MemoryManagementPageState extends ConsumerState<MemoryManagementPage> {
  late final DatabaseService _db;
  late final MemoryControls _controls;
  late MemoryAuditFilter _filter;
  List<PermanentMemory> _allMemories = const [];
  List<AICharacter> _charactersSnapshot = const [];
  List<CharacterMemory> _legacyCharacterMemories = const [];
  Map<String, Message> _sourceMessagesById = const {};
  bool _isLoading = true;
  Object? _loadError;

  @override
  void initState() {
    super.initState();
    _db = ref.read(databaseServiceProvider);
    _controls = MemoryControls(_db);
    _filter = MemoryAuditFilter(
      originConversationId: widget.conversationId,
    );
    unawaited(_loadSnapshot());
  }

  List<AICharacter> get _characters => _charactersSnapshot;

  Future<void> _loadSnapshot() async {
    try {
      // Yield once so the first frame communicates that Hive data is loading
      // without leaving a fake-async timer behind in widget tests.
      await Future<void>.value();
      final memories = _db.permanentMemoryBox.values.toList(growable: false);
      final sourceIds =
          memories.expand((memory) => memory.sourceMessageIds).toSet();
      final sourceMessages = <String, Message>{};
      for (final id in sourceIds) {
        final message = _db.messageBox.get(id);
        if (message != null) sourceMessages[id] = message;
      }
      final characters = _db.aiCharacterBox.values.toList(growable: false);
      final legacyCharacterMemories =
          _db.characterMemoryBox.values.toList(growable: false);
      if (!mounted) return;
      setState(() {
        _allMemories = memories;
        _charactersSnapshot = characters;
        _legacyCharacterMemories = legacyCharacterMemories;
        _sourceMessagesById = sourceMessages;
        _loadError = null;
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

  Map<String, String> _originConversations() {
    final result = <String, String>{};
    for (final memory in _allMemories) {
      final id = memory.originConversationId;
      if (id == null || id.trim().isEmpty) continue;
      result.putIfAbsent(id, () => memory.originNameSnapshot.trim());
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(title: const Text('永久记忆审计')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_loadError != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('永久记忆审计')),
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
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
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

    final allMemories = _allMemories;
    final filtered = _filter.apply(allMemories);
    final charactersById = {for (final item in _characters) item.id: item};
    final supersededCount = <String, int>{};
    for (final memory in allMemories) {
      if (memory.status != MemoryStatus.active) continue;
      for (final sid in memory.supersedesIds) {
        supersededCount[sid] = (supersededCount[sid] ?? 0) + 1;
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(_filter.isEmpty ? '全部永久记忆' : '筛选结果（${filtered.length} 条）'),
        actions: [
          IconButton(
            tooltip: '清除筛选',
            onPressed: () =>
                setState(() => _filter = const MemoryAuditFilter()),
            icon: const Icon(Icons.filter_list_off_rounded),
          ),
        ],
      ),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: MemoryAuditFilterWidget(
              filter: _filter,
              characters: _characters,
              originConversations: _originConversations(),
              onChanged: (f) => setState(() => _filter = f),
            ),
          ),
          const SliverToBoxAdapter(child: Divider(height: 1)),
          if (filtered.isEmpty)
            const SliverToBoxAdapter(
              child: SizedBox(
                  height: 300, child: Center(child: Text('没有符合条件的永久记忆'))),
            )
          else
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) => MemoryAuditCard(
                  memory: filtered[index],
                  charactersById: charactersById,
                  supersededCount: supersededCount,
                  messagesById: _sourceMessagesById,
                  onPin: () async {
                    await _controls.pinPermanent(filtered[index]);
                    await _loadSnapshot();
                  },
                  onUnpin: () async {
                    await _controls.unpinPermanent(filtered[index]);
                    await _loadSnapshot();
                  },
                  onAction: () => _showActionSheet(filtered[index]),
                ),
                childCount: filtered.length,
              ),
            ),
          SliverToBoxAdapter(child: _buildDiagnostic(context)),
        ],
      ),
    );
  }

  Future<void> _showActionSheet(PermanentMemory memory) async {
    await showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (memory.pinned)
              ListTile(
                leading: const Icon(Icons.push_pin_rounded),
                title: const Text('取消固定'),
                onTap: () async {
                  await _controls.unpinPermanent(memory);
                  await _loadSnapshot();
                  if (ctx.mounted) Navigator.pop(ctx);
                },
              )
            else
              ListTile(
                leading: const Icon(Icons.push_pin_outlined),
                title: const Text('固定'),
                onTap: () async {
                  await _controls.pinPermanent(memory);
                  await _loadSnapshot();
                  if (ctx.mounted) Navigator.pop(ctx);
                },
              ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('修正'),
              onTap: () async {
                if (ctx.mounted) Navigator.pop(ctx);
                await _correctionDialog(memory);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('删除'),
              onTap: () async {
                if (ctx.mounted) Navigator.pop(ctx);
                await _confirmDelete(memory);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _correctionDialog(PermanentMemory old) async {
    final contentController = TextEditingController(text: old.content);
    final subjectController =
        TextEditingController(text: old.subjectIds.join(', '));
    String? subjectError;
    if (!mounted) return;
    final pageContext = context;
    final result = await showDialog<Map<String, dynamic>>(
      context: pageContext,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            return AlertDialog(
              title: const Text('修正记忆'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: contentController,
                    maxLines: 6,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      hintText: '输入修正后的内容',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: subjectController,
                    decoration: InputDecoration(
                      border: const OutlineInputBorder(),
                      hintText: 'user, c1, c2',
                      errorText: subjectError,
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text('取消')),
                FilledButton(
                  onPressed: () {
                    final content = contentController.text.trim();
                    if (content.isEmpty) return;
                    final rawSubjects = subjectController.text
                        .split(',')
                        .map((s) => s.trim())
                        .where((s) => s.isNotEmpty)
                        .toSet()
                        .toList();
                    if (!_validateSubjectIds(rawSubjects)) {
                      setDialogState(() {
                        subjectError = '只允许 "user" 或现有 AI 角色 ID';
                      });
                      return;
                    }
                    setDialogState(() {
                      subjectError = null;
                    });
                    Navigator.pop(dialogContext, <String, dynamic>{
                      'content': content,
                      'subjectIds': rawSubjects,
                    });
                  },
                  child: const Text('保存修正'),
                ),
              ],
            );
          },
        );
      },
    );
    contentController.dispose();
    subjectController.dispose();
    if (result == null) return;

    final wasPinned = old.pinned;
    if (wasPinned) {
      final dialogContext = context;
      if (!dialogContext.mounted) return;
      final confirmed = await showDialog<bool>(
        context: dialogContext,
        builder: (ctx) => AlertDialog(
          title: const Text('此记忆已被固定'),
          content: const Text('修正后将用新记录取代这条固定记忆，原记录保留但标记为已取代。继续？'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('继续修正')),
          ],
        ),
      );
      if (!dialogContext.mounted) return;
      if (confirmed != true) return;
    }

    await _controls.editPermanent(
      old,
      correctedContent: result['content'] as String,
      subjectIds: (result['subjectIds'] as List<String>),
    );
    await _loadSnapshot();
  }

  Future<void> _confirmDelete(PermanentMemory memory) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这条永久记忆？'),
        content: const Text('删除后，后续请求不会再注入该内容。删除不会自动恢复旧版本。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _controls.deletePermanent(memory);
    await _loadSnapshot();
  }

  bool _validateSubjectIds(List<String> ids) {
    if (ids.isEmpty) return true;
    final validIds = _characters.map((c) => c.id).toSet();
    return ids.every((id) => id == 'user' || validIds.contains(id));
  }

  Widget _buildDiagnostic(BuildContext context) {
    final legacyMemories = _allMemories
        .where((m) => m.originType == MemoryOriginType.legacyMigration)
        .length;
    final legacyCharMemories = _legacyCharacterMemories;
    final hasLegacyCharacterData = legacyCharMemories.isNotEmpty ||
        _characters.any((c) => c.memorySummary.trim().isNotEmpty);

    if (!hasLegacyCharacterData && legacyMemories == 0) {
      return const SizedBox.shrink();
    }

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 32),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: ExpansionTile(
        initiallyExpanded: hasLegacyCharacterData,
        title: const Text('迁移诊断'),
        subtitle: const Text(
          '以下为旧版数据，仅供诊断，不会注入 Prompt，也不能在此编辑。',
          style: TextStyle(fontSize: 12),
        ),
        children: [
          if (hasLegacyCharacterData) ...[
            for (final char in _characters)
              if (char.memorySummary.trim().isNotEmpty ||
                  legacyCharMemories.any((cm) => cm.characterId == char.id))
                _CharMemoryTile(
                    char: char, legacyCharMemories: legacyCharMemories),
          ],
          if (legacyMemories > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                '已从旧版迁移 $legacyMemories 条记忆记录。'
                '这些记录可在此页面查看和管理。',
                style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }
}

class _CharMemoryTile extends StatelessWidget {
  final AICharacter char;
  final List<CharacterMemory> legacyCharMemories;

  const _CharMemoryTile({
    required this.char,
    required this.legacyCharMemories,
  });

  @override
  Widget build(BuildContext context) {
    final charMemories = legacyCharMemories
        .where((cm) => cm.characterId == char.id)
        .toList(growable: false);
    final byGroup = <String, List<CharacterMemory>>{};
    for (final cm in charMemories) {
      byGroup.putIfAbsent(cm.groupId, () => []).add(cm);
    }

    return ExpansionTile(
      dense: true,
      initiallyExpanded: true,
      title: Text('旧版记忆（${char.name}）'),
      subtitle: Text(
        char.memorySummary.trim().isNotEmpty
            ? '有跨会话摘要 + ${charMemories.length} 条会话记忆'
            : '${charMemories.length} 条会话记忆',
        style: const TextStyle(fontSize: 12),
      ),
      children: [
        if (char.memorySummary.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('跨会话 legacy 摘要（${char.name}）',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.primary)),
                const SizedBox(height: 4),
                Text(char.memorySummary.trim(),
                    style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
        for (final entry in byGroup.entries)
          ExpansionTile(
            dense: true,
            initiallyExpanded: true,
            title: Text('群组 ${entry.key}'),
            subtitle: Text('${entry.value.length} 条记忆'),
            children: [
              for (final cm in entry.value) ...[
                if (cm.facts.isNotEmpty)
                  _LayerRow(
                      label: '事实',
                      content: cm.facts.join('；'),
                      parentContext: context),
                if (cm.relationshipNotes.isNotEmpty)
                  _LayerRow(
                      label: '关系备注',
                      content: cm.relationshipNotes.join('；'),
                      parentContext: context),
                if (cm.personaGrowth.isNotEmpty)
                  _LayerRow(
                      label: '成长',
                      content: cm.personaGrowth.join('；'),
                      parentContext: context),
                if (cm.facts.isEmpty &&
                    cm.relationshipNotes.isEmpty &&
                    cm.personaGrowth.isEmpty)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Text('（空）',
                        style: TextStyle(
                            fontSize: 13, fontStyle: FontStyle.italic)),
                  ),
              ],
            ],
          ),
      ],
    );
  }
}

class _LayerRow extends StatelessWidget {
  final String label;
  final String content;
  final BuildContext parentContext;

  const _LayerRow({
    required this.label,
    required this.content,
    required this.parentContext,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(parentContext).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: cs.primary)),
          const SizedBox(height: 2),
          Text(content,
              style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
        ],
      ),
    );
  }
}
