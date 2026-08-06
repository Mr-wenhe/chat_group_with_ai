import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/character_memory.dart';
import 'package:chat_group/core/models/permanent_memory.dart';
import 'package:chat_group/features/memory/memory_audit_filter.dart';
import 'package:chat_group/features/memory/memory_audit_filter_widget.dart';
import 'package:chat_group/features/memory/memory_controls.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

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
  MemoryAuditFilter _filter = const MemoryAuditFilter();

  @override
  void initState() {
    super.initState();
    _db = ref.read(databaseServiceProvider);
    _controls = MemoryControls(_db);
    _filter = MemoryAuditFilter(
      originConversationId: widget.conversationId,
    );
  }

  List<AICharacter> get _characters => _db.aiCharacterBox.values.toList();

  @override
  Widget build(BuildContext context) {
    final allMemories = _db.permanentMemoryBox.values.toList(growable: false);
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
        title: Text(_filter.isEmpty
            ? '全部永久记忆'
            : '筛选结果（${filtered.length} 条）'),
        actions: [
          IconButton(
            tooltip: '清除筛选',
            onPressed: () {
              setState(() {
                _filter = const MemoryAuditFilter();
              });
            },
            icon: const Icon(Icons.filter_list_off_rounded),
          ),
        ],
      ),
      body: Column(
        children: [
          MemoryAuditFilterWidget(
            filter: _filter,
            characters: _characters,
            onChanged: (f) => setState(() => _filter = f),
          ),
          const Divider(height: 1),
          Expanded(
            child: filtered.isEmpty
                ? const Center(child: Text('没有符合条件的永久记忆'))
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                    itemCount: filtered.length,
                    itemBuilder: (context, index) =>
                        _memoryCard(filtered[index], charactersById, supersededCount),
                  ),
          ),
          _migrationDiagnostic(_characters, _db),
        ],
      ),
    );
  }

  Widget _memoryCard(PermanentMemory memory, Map<String, AICharacter> charactersById, Map<String, int> supersededCount) {
    final observer = charactersById[memory.observerCharacterId];
    final observerName = observer?.name ?? '已删除角色';
    final subjectNames = memory.subjectIds.map((sid) {
      if (sid == 'user') return '我';
      return charactersById[sid]?.name ?? '已删除角色';
    }).toList();

    final kindLabel = switch (memory.kind) {
      MemoryKind.fact => '知',
      MemoryKind.preference => '偏好',
      MemoryKind.commitment => '承诺',
      MemoryKind.sharedExperience => '经历',
      MemoryKind.relationshipNote => '关系',
      MemoryKind.personaGrowth => '成长',
      MemoryKind.explicitInstruction => '指令',
    };

    return Card(
      child: InkWell(
        onLongPress: () => _showActionSheet(memory),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Chip(label: Text(kindLabel)),
                  const SizedBox(width: 8),
                  Text(observerName, style: const TextStyle(fontWeight: FontWeight.w600)),
                  const Spacer(),
                  _statusBadge(memory.status),
                  if (memory.pinned)
                    IconButton(
                      tooltip: '取消固定',
                      icon: const Icon(Icons.push_pin_rounded, size: 18, color: Colors.orange),
                      onPressed: () async {
                        await _controls.unpinPermanent(memory);
                        if (mounted) setState(() {});
                      },
                    )
                  else
                    IconButton(
                      tooltip: '固定',
                      icon: const Icon(Icons.push_pin_outlined, size: 18),
                      onPressed: () async {
                        await _controls.pinPermanent(memory);
                        if (mounted) setState(() {});
                      },
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(memory.content, style: const TextStyle(fontSize: 15)),
              const SizedBox(height: 6),
              if (subjectNames.isNotEmpty)
                Text('主体：${subjectNames.join("、")}',
                    style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
              const SizedBox(height: 4),
              Wrap(
                spacing: 12,
                runSpacing: 4,
                children: [
                  Text('重要度 ${memory.importance} · 置信 ${memory.confidence.toStringAsFixed(2)}',
                      style: const TextStyle(fontSize: 12)),
                  if (memory.explicitlyRequested)
                    const Text('明确记忆', style: TextStyle(fontSize: 12, color: Colors.purple)),
                  Text(_time(memory.occurredAt), style: const TextStyle(fontSize: 12)),
                  Text(memory.originType.name, style: const TextStyle(fontSize: 12)),
                  Text(memory.originNameSnapshot, style: const TextStyle(fontSize: 12)),
                ],
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                children: [
                  if (memory.sourceMessageIds.isNotEmpty)
                    Text('${memory.sourceMessageIds.length} 条证据消息',
                        style: const TextStyle(fontSize: 11, color: Colors.blueGrey))
                  else if (memory.originType == MemoryOriginType.legacyMigration)
                    const Text('旧版迁移记录，无原始消息证据',
                        style: TextStyle(fontSize: 11, color: Colors.orange)),
                  if (memory.supersedesIds.isNotEmpty)
                    Text('取代了 ${memory.supersedesIds.length} 条旧记录',
                        style: const TextStyle(fontSize: 11, color: Colors.teal)),
                  if ((supersededCount[memory.id] ?? 0) > 0)
                    Text('被 ${supersededCount[memory.id]} 条记录取代',
                        style: const TextStyle(fontSize: 11, color: Colors.deepOrange)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusBadge(MemoryStatus status) {
    final (label, color) = switch (status) {
      MemoryStatus.active => ('有效', Colors.green),
      MemoryStatus.superseded => ('已取代', Colors.orange),
      MemoryStatus.invalidated => ('已失效', Colors.red),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(label, style: TextStyle(fontSize: 11, color: color)),
    );
  }

  Future<void> _showActionSheet(PermanentMemory memory) async {
    final canEdit = memory.originType != MemoryOriginType.legacyMigration;
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
                  if (mounted) setState(() {});
                  if (ctx.mounted) Navigator.pop(ctx);
                },
              )
            else
              ListTile(
                leading: const Icon(Icons.push_pin_outlined),
                title: const Text('固定'),
                onTap: () async {
                  await _controls.pinPermanent(memory);
                  if (mounted) setState(() {});
                  if (ctx.mounted) Navigator.pop(ctx);
                },
              ),
            if (canEdit)
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
    final controller = TextEditingController(text: old.content);
    final subjectIds = List<String>.from(old.subjectIds);
    final result = await showDialog<_CorrectionResult>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修正记忆'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              maxLines: 6,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: '输入修正后的内容',
              ),
            ),
            const SizedBox(height: 12),
            const Text('主体 ID（逗号分隔，留空 = 自身成长）'),
            const SizedBox(height: 4),
            TextField(
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'user, c1, c2',
              ),
              onChanged: (v) {
                subjectIds.clear();
                subjectIds.addAll(v.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList());
              },
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              final content = controller.text.trim();
              if (content.isEmpty) return;
              Navigator.pop(ctx, _CorrectionResult(content, subjectIds));
            },
            child: const Text('保存修正'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null) return;

    final wasPinned = old.pinned;
    if (wasPinned) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('此记忆已被固定'),
          content: const Text('修正后将用新记录取代这条固定记忆，原记录保留但标记为已取代。继续？'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('继续修正')),
          ],
        ),
      );
      if (confirmed != true) return;
    }

    await _controls.editPermanent(
      old,
      correctedContent: result.content,
      subjectIds: result.subjectIds,
    );
    if (mounted) setState(() {});
  }

  Future<void> _confirmDelete(PermanentMemory memory) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这条永久记忆？'),
        content: const Text('删除后，后续请求不会再注入该内容。删除不会自动恢复旧版本。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _controls.deletePermanent(memory);
    if (mounted) setState(() {});
  }

  Widget _migrationDiagnostic(List<AICharacter> characters, DatabaseService db) {
    final legacyMemories = _db.permanentMemoryBox.values
        .where((m) => m.originType == MemoryOriginType.legacyMigration)
        .length;
    final legacyCharMemories = _db.characterMemoryBox.values.toList(growable: false);
    final hasLegacyCharacterData = legacyCharMemories.isNotEmpty ||
        characters.any((c) => c.memorySummary.trim().isNotEmpty);

    if (!hasLegacyCharacterData && legacyMemories == 0) {
      return const SizedBox.shrink();
    }

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 32),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: ExpansionTile(
        initiallyExpanded: hasLegacyCharacterData,
        title: const Text('迁移诊断'),
        subtitle: Text(
          hasLegacyCharacterData
              ? '检测到旧版记忆数据，仅展示不编辑'
              : '已迁移 $legacyMemories 条旧版记忆记录',
        ),
        children: [
          if (hasLegacyCharacterData) ...[
            // Group character memories by groupId
            for (final char in characters)
              if (char.memorySummary.trim().isNotEmpty ||
                  legacyCharMemories.any((cm) => cm.characterId == char.id))
                _characterMemorySection(char, legacyCharMemories),
          ],
          if (legacyMemories > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                '已从旧版迁移 $legacyMemories 条记忆记录。'
                '这些记录可在此页面查看和管理。',
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _characterMemorySection(
      AICharacter char, List<CharacterMemory> legacyCharMemories) {
    final charMemories = legacyCharMemories
        .where((cm) => cm.characterId == char.id)
        .toList(growable: false);

    // Group by groupId
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
                Text(
                  '跨会话 legacy 摘要（${char.name}）',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  char.memorySummary.trim(),
                  style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
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
                  _layerRow('事实', cm.facts.join('；')),
                if (cm.relationshipNotes.isNotEmpty)
                  _layerRow('关系备注', cm.relationshipNotes.join('；')),
                if (cm.personaGrowth.isNotEmpty)
                  _layerRow('成长', cm.personaGrowth.join('；')),
                if (cm.facts.isEmpty &&
                    cm.relationshipNotes.isEmpty &&
                    cm.personaGrowth.isEmpty)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Text(
                      '（空）',
                      style: TextStyle(fontSize: 13, fontStyle: FontStyle.italic),
                    ),
                  ),
              ],
            ],
          ),
      ],
    );
  }

  Widget _layerRow(String label, String content) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            content,
            style: TextStyle(
              fontSize: 13,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  String _time(DateTime value) => DateFormat('yyyy-MM-dd HH:mm').format(value.toLocal());
}

class _CorrectionResult {
  final String content;
  final List<String> subjectIds;
  const _CorrectionResult(this.content, this.subjectIds);
}
