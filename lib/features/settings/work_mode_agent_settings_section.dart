import 'package:chat_group/core/widgets/app_widgets.dart';
import 'package:chat_group/features/work_mode/work_folder_grant_service.dart';
import 'package:chat_group/features/settings/widgets/settings_section_header.dart';
import 'package:chat_group/features/settings/widgets/settings_tile.dart';
import 'package:chat_group/features/settings/work_folder_grants_page.dart';
import 'package:chat_group/features/work_mode/work_snapshot_service.dart';
import 'package:chat_group/features/work_mode/work_task_error_sanitizer.dart';
import 'package:flutter/material.dart';

/// Settings for the app-wide work-mode folder capability.
///
/// The folder list itself lives on [WorkFolderGrantsPage]; this section keeps
/// the general work-mode settings plus a one-line entry point to that page.
class WorkModeAgentSettingsSection extends StatefulWidget {
  final WorkFolderGrantService service;
  final WorkFolderPicker? pickDirectory;
  final Future<List<String>?> Function()? pickDirectories;
  final WorkSnapshotService? snapshotService;

  const WorkModeAgentSettingsSection({
    super.key,
    required this.service,
    this.pickDirectory,
    this.pickDirectories,
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

  Future<void> _openGrantsPage() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WorkFolderGrantsPage(
          service: widget.service,
          pickDirectory: widget.pickDirectory,
          pickDirectories: widget.pickDirectories,
        ),
      ),
    );
    // Grants may have been added or removed on that page.
    if (mounted) await _load();
  }

  String _grantsSubtitle() {
    if (_loadError != null) return '读取失败，请重试';
    if (_loading) return '正在读取...';
    if (_grants.isEmpty) return '尚未授权 · 启动工作模式任务时会提示选择';
    final unavailable = _grants.where((grant) => !grant.available).length;
    return '已授权 ${_grants.length} 个 · '
        '${unavailable == 0 ? '全部可用' : '$unavailable 个不可用'}';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppCard(
          key: const Key('work-mode-agent-settings'),
          cs: cs,
          margin: EdgeInsets.zero,
          children: [
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
              '群聊协作任务不设累计步数或总时长上限；单次请求超时、有限重试和无进展保护仍有效。'
              '私聊和旧版任务的软上限：${_settings.actionLimit} 步或 ${_settings.timeLimitMinutes} 分钟，达到任一项会暂停并等待继续。',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            if (widget.snapshotService != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '当前快照占用：${_formatBytes(_snapshotUsageBytes ?? 0)}',
                      style:
                          TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                    ),
                  ),
                  TextButton.icon(
                    key: const Key('work-snapshot-cleanup'),
                    onPressed: _cleaningSnapshots ? null : _cleanupSnapshots,
                    icon:
                        const Icon(Icons.cleaning_services_outlined, size: 16),
                    label: const Text('立即清理'),
                  ),
                ],
              ),
            ],
          ],
        ),
        const SizedBox(height: 20),
        SettingsSectionHeader(title: '授权目录', cs: cs),
        const SizedBox(height: 12),
        AppCard(
          cs: cs,
          margin: EdgeInsets.zero,
          children: [
            SettingsTile(
              key: const Key('work-folder-grants-entry'),
              cs: cs,
              icon: Icons.folder_shared_outlined,
              iconColor: cs.secondary,
              title: '授权目录',
              subtitle: _grantsSubtitle(),
              onTap: _openGrantsPage,
            ),
          ],
        ),
      ],
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
