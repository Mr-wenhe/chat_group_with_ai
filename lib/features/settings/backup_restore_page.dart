import 'dart:async';
import 'dart:io';

import 'package:chat_group/core/widgets/app_widgets.dart';
import 'package:chat_group/core/widgets/top_toast.dart';
import 'package:chat_group/features/ai_character/providers/ai_character_providers.dart';
import 'package:chat_group/features/backup/backup_models.dart';
import 'package:chat_group/features/backup/backup_restore_service.dart';
import 'package:chat_group/features/chat_group/providers/chat_group_providers.dart';
import 'package:chat_group/features/settings/providers/api_config_providers.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:package_info_plus/package_info_plus.dart';

class BackupRestorePage extends ConsumerStatefulWidget {
  const BackupRestorePage({super.key});

  @override
  ConsumerState<BackupRestorePage> createState() => _BackupRestorePageState();
}

class _BackupRestorePageState extends ConsumerState<BackupRestorePage> {
  BackupScope _scope = BackupScope.all;
  String? _conversationId;
  BackupEstimate? _estimate;
  PreparedBackup? _prepared;
  RestoreConflictStrategy _strategy = RestoreConflictStrategy.emptyOnly;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshEstimate());
  }

  @override
  void dispose() {
    final prepared = _prepared;
    if (prepared != null) unawaited(prepared.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (kIsWeb) {
      return Scaffold(
        appBar: AppBar(title: const Text('完整备份与恢复')),
        body: const Center(child: Text('当前版本暂不支持 Web 端完整恢复')),
      );
    }
    final conversations = _conversations();
    return Scaffold(
      appBar: AppBar(title: const Text('完整备份与恢复')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          AppSectionHeader(
              title: '创建版本化备份', icon: Icons.backup_rounded, cs: cs),
          const SizedBox(height: 12),
          AppCard(
            cs: cs,
            children: [
              DropdownButtonFormField<BackupScope>(
                value: _scope,
                decoration: const InputDecoration(labelText: '备份范围'),
                items: const [
                  DropdownMenuItem(value: BackupScope.all, child: Text('全部数据')),
                  DropdownMenuItem(
                    value: BackupScope.configurationOnly,
                    child: Text('仅角色 / 群组配置'),
                  ),
                  DropdownMenuItem(
                    value: BackupScope.conversation,
                    child: Text('指定会话'),
                  ),
                ],
                onChanged: _busy
                    ? null
                    : (value) {
                        if (value == null) return;
                        setState(() {
                          _scope = value;
                          if (value == BackupScope.conversation) {
                            _conversationId ??= conversations.isEmpty
                                ? null
                                : conversations.first.$1;
                          }
                        });
                        _refreshEstimate();
                      },
              ),
              if (_scope == BackupScope.conversation) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: conversations.any((item) => item.$1 == _conversationId)
                      ? _conversationId
                      : null,
                  decoration: const InputDecoration(labelText: '会话'),
                  items: conversations
                      .map((item) => DropdownMenuItem(
                            value: item.$1,
                            child: Text(item.$2),
                          ))
                      .toList(),
                  onChanged: _busy
                      ? null
                      : (value) {
                          setState(() => _conversationId = value);
                          _refreshEstimate();
                        },
                ),
              ],
              const SizedBox(height: 14),
              Text(_estimateText(),
                  style: TextStyle(color: cs.onSurfaceVariant)),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: _busy || !_selectionIsValid ? null : _createBackup,
                icon: const Icon(Icons.save_alt_rounded),
                label: Text(_busy ? '处理中…' : '创建备份'),
              ),
            ],
          ),
          const SizedBox(height: 28),
          AppSectionHeader(title: '导入与恢复', icon: Icons.restore_rounded, cs: cs),
          const SizedBox(height: 12),
          AppCard(
            cs: cs,
            children: [
              Text(
                '选择文件后只会解压到隔离临时目录并校验；点击确认恢复前不会写入数据库。',
                style: TextStyle(color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 14),
              OutlinedButton.icon(
                onPressed: _busy ? null : _pickBackup,
                icon: const Icon(Icons.file_open_rounded),
                label: const Text('选择备份并预览'),
              ),
              if (_prepared != null) ...[
                const Divider(height: 28),
                BackupPreviewPanel(preview: _prepared!.preview),
                const SizedBox(height: 14),
                DropdownButtonFormField<RestoreConflictStrategy>(
                  value: _strategy,
                  decoration: const InputDecoration(labelText: '冲突策略'),
                  items: const [
                    DropdownMenuItem(
                      value: RestoreConflictStrategy.emptyOnly,
                      child: Text('仅恢复到空库'),
                    ),
                    DropdownMenuItem(
                      value: RestoreConflictStrategy.skipExisting,
                      child: Text('跳过同 ID 条目'),
                    ),
                    DropdownMenuItem(
                      value: RestoreConflictStrategy.copyWithNewIds,
                      child: Text('复制为新 ID 并重写引用'),
                    ),
                  ],
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _strategy = value!),
                ),
                const SizedBox(height: 14),
                FilledButton.icon(
                  onPressed: _busy ? null : _restore,
                  icon: const Icon(Icons.restore_page_rounded),
                  label: const Text('确认恢复'),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  bool get _selectionIsValid =>
      _scope != BackupScope.conversation || _conversationId != null;

  BackupSelection get _selection => switch (_scope) {
        BackupScope.all => const BackupSelection.all(),
        BackupScope.configurationOnly =>
          const BackupSelection.configurationOnly(),
        BackupScope.conversation =>
          BackupSelection.conversation(_conversationId!),
      };

  List<(String, String)> _conversations() {
    final db = ref.read(databaseServiceProvider);
    final result = db.chatGroupBox.values
        .map((group) => (group.id, '群聊 · ${group.name}'))
        .toList();
    final directIds =
        db.conversationSummaries().keys.where((id) => id.startsWith('dm:'));
    for (final id in directIds) {
      final character = db.aiCharacterBox.get(id.substring(3));
      if (character != null) result.add((id, '私聊 · ${character.name}'));
    }
    return result;
  }

  Future<BackupRestoreService> _service() async {
    final db = ref.read(databaseServiceProvider);
    return BackupRestoreService(
      db: db,
      mediaDirectory: await db.mediaDir,
      tempRoot: await getTemporaryDirectory(),
    );
  }

  Future<void> _refreshEstimate() async {
    if (!_selectionIsValid) {
      if (mounted) setState(() => _estimate = null);
      return;
    }
    try {
      final estimate = await (await _service()).estimate(_selection);
      if (mounted) setState(() => _estimate = estimate);
    } on Object catch (error) {
      if (mounted) _toast('无法估算备份：$error');
    }
  }

  String _estimateText() {
    final estimate = _estimate;
    if (estimate == null) return '正在估算…';
    return '${estimate.counts['characters'] ?? 0} 个角色 · '
        '${estimate.counts['groups'] ?? 0} 个群聊 · '
        '${estimate.counts['messages'] ?? 0} 条消息 · '
        '${estimate.attachmentCount} 个附件（${_formatBytes(estimate.attachmentBytes)}）'
        '${estimate.missingAttachments == 0 ? '' : ' · ${estimate.missingAttachments} 个缺失'}';
  }

  Future<void> _createBackup() async {
    final confirmed = await _confirm(
      '创建敏感数据备份？',
      '备份包含完整对话和附件，但不包含任何 API Key。请妥善保管生成的明文文件。',
      '创建',
    );
    if (!confirmed) return;
    setState(() => _busy = true);
    try {
      final documents = await getApplicationDocumentsDirectory();
      final directory = Directory('${documents.path}/chat_group_backups');
      final destination =
          File('${directory.path}/chat_group_${_timestamp()}.cgbak');
      final appVersion = (await PackageInfo.fromPlatform()).version;
      final result = await (await _service()).createBackup(
        destination: destination,
        selection: _selection,
        appVersion: appVersion,
      );
      if (mounted) {
        _toast(
            '备份已完成：${result.file.path}（${_formatBytes(await result.file.length())}）');
      }
    } on Object catch (error) {
      if (mounted) _toast('备份失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickBackup() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['cgbak', 'zip'],
      allowMultiple: false,
    );
    final path = picked?.files.single.path;
    if (path == null) return;
    setState(() => _busy = true);
    try {
      final prepared = await (await _service()).inspect(File(path));
      await _prepared?.dispose();
      if (mounted) setState(() => _prepared = prepared);
    } on Object catch (error) {
      if (mounted) _toast('备份不可用：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    final prepared = _prepared;
    if (prepared == null) return;
    final confirmed = await _confirm(
      '确认恢复？',
      '将按“${_strategyLabel(_strategy)}”提交已验证的数据。API 配置恢复后仍需重新绑定 Key。',
      '恢复',
    );
    if (!confirmed) return;
    setState(() => _busy = true);
    try {
      final report =
          await (await _service()).restore(prepared, strategy: _strategy);
      ref.invalidate(apiConfigsProvider);
      ref.invalidate(aiCharactersProvider);
      ref.invalidate(chatGroupsProvider);
      ref.invalidate(appSkinModeProvider);
      await prepared.dispose();
      if (mounted) {
        setState(() => _prepared = null);
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('恢复完成'),
            content: Text(
              '写入 ${report.inserted.values.fold<int>(0, (a, b) => a + b)} 条，'
              '跳过 ${report.skipped.values.fold<int>(0, (a, b) => a + b)} 条，'
              '重映射 ${report.remapped.values.fold<int>(0, (a, b) => a + b)} 条。',
            ),
            actions: [
              FilledButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('完成')),
            ],
          ),
        );
        if (mounted) Navigator.pop(context, true);
      }
    } on Object catch (error) {
      if (mounted) _toast('恢复失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm(String title, String content, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(content),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(action)),
          ],
        ),
      ) ==
      true;

  void _toast(String message) =>
      AppToast.show(context, message, icon: Icons.info_outline_rounded);

  String _timestamp() => DateTime.now()
      .toIso8601String()
      .replaceAll(RegExp(r'[-:.TZ]'), '')
      .substring(0, 14);

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String _strategyLabel(RestoreConflictStrategy strategy) => switch (strategy) {
        RestoreConflictStrategy.emptyOnly => '仅恢复到空库',
        RestoreConflictStrategy.skipExisting => '跳过同 ID 条目',
        RestoreConflictStrategy.copyWithNewIds => '复制为新 ID',
      };
}

class BackupPreviewPanel extends StatelessWidget {
  final BackupPreview preview;

  const BackupPreviewPanel({super.key, required this.preview});

  @override
  Widget build(BuildContext context) {
    final counts = preview.manifest.counts;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
            '来源 APP ${preview.manifest.appVersion} · schema v${preview.manifest.schemaVersion}'),
        const SizedBox(height: 6),
        Text(
            '${counts['characters'] ?? 0} 个角色 · ${counts['groups'] ?? 0} 个群聊 · '
            '${counts['messages'] ?? 0} 条消息 · ${preview.attachmentCount} 个附件'),
        Text(
            '文件 ${_bytes(preview.packageBytes)} · 校验和已通过 · ${preview.conflicts} 个冲突'),
        if (preview.manifest.missingAttachments.isNotEmpty)
          Text('缺失附件：${preview.manifest.missingAttachments.length} 个'),
        if (preview.credentialsToRebind > 0)
          Text('${preview.credentialsToRebind} 个 API 配置需要重新绑定 Key'),
      ],
    );
  }

  static String _bytes(int bytes) => bytes < 1024 * 1024
      ? '${(bytes / 1024).toStringAsFixed(1)} KB'
      : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
