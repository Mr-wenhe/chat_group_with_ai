import 'package:chat_group/core/widgets/app_widgets.dart';
import 'package:chat_group/features/work_mode/work_folder_grant_service.dart';
import 'package:chat_group/features/work_mode/presentation/work_folder_grant_consent_dialog.dart';
import 'package:chat_group/features/work_mode/work_snapshot_service.dart';
import 'package:chat_group/features/work_mode/work_task_error_sanitizer.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

/// Settings for the app-wide work-mode folder capability.
class WorkModeAgentSettingsSection extends StatefulWidget {
  final WorkFolderGrantService service;
  final WorkFolderPicker? pickDirectory;
  final WorkSnapshotService? snapshotService;

  const WorkModeAgentSettingsSection({
    super.key,
    required this.service,
    this.pickDirectory,
    this.snapshotService,
  });

  @override
  State<WorkModeAgentSettingsSection> createState() =>
      _WorkModeAgentSettingsSectionState();
}

class _WorkModeAgentSettingsSectionState
    extends State<WorkModeAgentSettingsSection> {
  List<WorkFolderGrant> _grants = const [];
  WorkModeAgentSettings _settings = const WorkModeAgentSettings();
  bool _loading = true;
  String? _loadError;
  final Set<String> _busyPaths = <String>{};
  int? _snapshotUsageBytes;
  bool _cleaningSnapshots = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final grants = await widget.service.load();
      final settings = await widget.service.loadSettings();
      final usage = await widget.snapshotService?.currentUsageBytes();
      if (!mounted) return;
      setState(() {
        _grants = grants;
        _settings = settings;
        _loading = false;
        _loadError = null;
        _snapshotUsageBytes = usage;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = error.toString();
      });
    }
  }

  Future<void> _addDirectory() async {
    final selected = await _pickDirectorySafely();
    if (selected == null || selected.trim().isEmpty) return;
    await _runBusy(selected, () async {
      final grant = await widget.service.authorizeDirectory(
        selected,
        consent: (candidate) => showWorkFolderGrantConsent(context, candidate),
      );
      if (grant == null) return;
      await _load();
    });
  }

  Future<void> _reauthorize(WorkFolderGrant grant) async {
    final selected = await _pickDirectorySafely();
    if (selected == null || selected.trim().isEmpty) return;
    await _runBusy(grant.path, () async {
      await widget.service.reauthorize(
        grant.path,
        selected,
        consent: (candidate) => showWorkFolderGrantConsent(context, candidate),
      );
      await _load();
    });
  }

  Future<void> _remove(WorkFolderGrant grant) async {
    await _runBusy(grant.path, () async {
      await widget.service.removeDirectory(grant.path);
      await _load();
    });
  }

  Future<void> _runBusy(String path, Future<void> Function() action) async {
    if (_busyPaths.contains(path)) return;
    setState(() => _busyPaths.add(path));
    try {
      await action();
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('操作失败：${sanitizeWorkTaskError(error)}')),
        );
      }
    } finally {
      _busyPaths.remove(path);
      if (mounted) setState(() {});
    }
  }

  Future<String?> _pickDirectory() {
    final picker = widget.pickDirectory;
    if (picker != null) return picker();
    return FilePicker.platform.getDirectoryPath(dialogTitle: '选择工作模式目录');
  }

  Future<String?> _pickDirectorySafely() async {
    try {
      return await _pickDirectory();
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('无法打开目录选择器：${sanitizeWorkTaskError(error)}'),
          ),
        );
      }
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AppCard(
      key: const Key('work-mode-agent-settings'),
      cs: cs,
      margin: EdgeInsets.zero,
      children: [
        Row(
          children: [
            Icon(Icons.folder_shared_outlined, color: cs.secondary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '授权目录',
                style: TextStyle(
                  color: cs.onSurface,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            FilledButton.icon(
              key: const Key('work-folder-add'),
              onPressed: _loading ? null : _addDirectory,
              icon: const Icon(Icons.add, size: 17),
              label: const Text('添加'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          '授权一次后，所有工作模式对话默认可访问这些目录；应用只在需要时检查目录可达性，不会递归预扫描。'
          '必要文件内容会按需发送给角色配置的云端模型 API。',
          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        if (_loading)
          const Center(child: CircularProgressIndicator())
        else if (_loadError != null)
          _errorState(cs)
        else if (_grants.isEmpty)
          _emptyState(cs)
        else
          ..._grants.map((grant) => _grantTile(grant, cs)),
        const Divider(height: 24),
        SwitchListTile(
          key: const Key('work-folder-confirm-writes'),
          contentPadding: EdgeInsets.zero,
          title: const Text('普通写入前确认'),
          subtitle: const Text('关闭后仅普通、可撤销写入不再重复提示。'),
          value: _settings.ordinaryWriteConfirmation,
          onChanged: _loading ? null : _setOrdinaryWriteConfirmation,
        ),
        const SizedBox(height: 4),
        Text(
          '删除文件和不可撤销覆盖始终需要确认，无法关闭。',
          style: TextStyle(color: cs.error, fontSize: 12),
        ),
        const SizedBox(height: 10),
        Text(
          '保留期限：${_settings.retentionDays} 天 · 快照上限：${_formatBytes(_settings.snapshotLimitBytes)}',
          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
        ),
        Text(
          '单任务软上限：${_settings.actionLimit} 步或 ${_settings.timeLimitMinutes} 分钟，达到任一项会暂停并等待继续。',
          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
        ),
        if (widget.snapshotService != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  '当前快照占用：${_formatBytes(_snapshotUsageBytes ?? 0)}',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ),
              TextButton.icon(
                key: const Key('work-snapshot-cleanup'),
                onPressed: _cleaningSnapshots ? null : _cleanupSnapshots,
                icon: const Icon(Icons.cleaning_services_outlined, size: 16),
                label: const Text('立即清理'),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _emptyState(ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(
        '尚未授权目录。首次启动工作模式任务时会提示选择。',
        style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
      ),
    );
  }

  Widget _errorState(ColorScheme cs) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            '授权设置读取失败，请重试。',
            style: TextStyle(color: cs.error, fontSize: 13),
          ),
        ),
        TextButton(
          key: const Key('work-folder-retry'),
          onPressed: () {
            setState(() {
              _loading = true;
              _loadError = null;
            });
            _load();
          },
          child: const Text('重试'),
        ),
      ],
    );
  }

  Widget _grantTile(WorkFolderGrant grant, ColorScheme cs) {
    final busy = _busyPaths.contains(grant.path);
    return Container(
      key: Key('work-folder-grant:${grant.path}'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            grant.available ? Icons.folder : Icons.folder_off_outlined,
            size: 20,
            color: grant.available ? cs.secondary : cs.error,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(grant.displayName,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                SelectableText(
                  grant.path,
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
                const SizedBox(height: 4),
                Text(
                  grant.available
                      ? grant.writable
                          ? '可用 · 可读可写'
                          : '可用 · 只读（写入时会再次请求可写目录）'
                      : '不可用 · 请重新授权',
                  style: TextStyle(
                    fontSize: 12,
                    color: grant.available ? cs.secondary : cs.error,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '移除授权只停止 App 访问，不会删除目录或文件。',
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
          IconButton(
            key: Key('work-folder-reauthorize:${grant.path}'),
            tooltip: '重新授权',
            onPressed: busy ? null : () => _reauthorize(grant),
            icon: const Icon(Icons.refresh, size: 19),
          ),
          IconButton(
            key: Key('work-folder-remove:${grant.path}'),
            tooltip: '移除授权（不删除目录或文件）',
            onPressed: busy ? null : () => _remove(grant),
            icon: const Icon(Icons.remove_circle_outline, size: 19),
          ),
        ],
      ),
    );
  }

  Future<void> _setOrdinaryWriteConfirmation(bool enabled) async {
    try {
      await widget.service.setOrdinaryWriteConfirmation(enabled);
      if (!mounted) return;
      setState(() => _settings = widget.service.settings);
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存工作模式设置失败：${sanitizeWorkTaskError(error)}')),
      );
    }
  }

  Future<void> _cleanupSnapshots() async {
    final service = widget.snapshotService;
    if (service == null) return;
    setState(() => _cleaningSnapshots = true);
    try {
      await service.cleanup();
      final usage = await service.currentUsageBytes();
      if (mounted) {
        setState(() => _snapshotUsageBytes = usage);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已清理符合保留策略的快照。')),
        );
      }
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('清理失败：${sanitizeWorkTaskError(error)}')),
        );
      }
    } finally {
      if (mounted) setState(() => _cleaningSnapshots = false);
    }
  }

  String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      final gb = bytes / (1024 * 1024 * 1024);
      return '${gb.toStringAsFixed(gb == gb.roundToDouble() ? 0 : 1)} GB';
    }
    return '$bytes B';
  }
}
