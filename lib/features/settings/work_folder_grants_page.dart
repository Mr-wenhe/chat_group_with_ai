import 'package:chat_group/core/widgets/app_widgets.dart';
import 'package:chat_group/features/work_mode/work_folder_grant_service.dart';
import 'package:chat_group/features/work_mode/presentation/work_folder_grant_consent_dialog.dart';
import 'package:chat_group/features/settings/work_folder_batch_picker_dialog.dart';
import 'package:chat_group/features/work_mode/work_task_error_sanitizer.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

/// Full list of app-wide work-mode folder grants.
///
/// The list lives on its own page because it grows with every authorized
/// directory; the settings page keeps only a one-line entry point.
class WorkFolderGrantsPage extends StatefulWidget {
  final WorkFolderGrantService service;
  final WorkFolderPicker? pickDirectory;
  final Future<List<String>?> Function()? pickDirectories;

  const WorkFolderGrantsPage({
    super.key,
    required this.service,
    this.pickDirectory,
    this.pickDirectories,
  });

  @override
  State<WorkFolderGrantsPage> createState() => _WorkFolderGrantsPageState();
}

class _WorkFolderGrantsPageState extends State<WorkFolderGrantsPage> {
  /// The AppBar action lives outside the list widget, so it reaches the list's
  /// state through this key rather than lifting the whole list state up here.
  final _managerKey = GlobalKey<_WorkFolderGrantsManagerState>();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('授权目录'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton.icon(
              key: const Key('work-folder-add'),
              onPressed: () =>
                  _managerKey.currentState?.addDirectoryFromPicker(),
              icon: const Icon(Icons.add, size: 17),
              label: const Text('添加'),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 48),
        children: [
          Text(
            '授权一次后，所有工作模式对话默认可访问这些目录；应用只在需要时检查目录可达性，不会递归预扫描。'
            '必要文件内容会按需发送给角色配置的云端模型 API。',
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          _WorkFolderGrantsManager(
            key: _managerKey,
            service: widget.service,
            pickDirectory: widget.pickDirectory,
            pickDirectories: widget.pickDirectories,
          ),
        ],
      ),
    );
  }
}

/// The grant list itself, without page chrome. The page's AppBar action drives
/// it through a [GlobalKey].
class _WorkFolderGrantsManager extends StatefulWidget {
  final WorkFolderGrantService service;
  final WorkFolderPicker? pickDirectory;
  final Future<List<String>?> Function()? pickDirectories;

  const _WorkFolderGrantsManager({
    super.key,
    required this.service,
    this.pickDirectory,
    this.pickDirectories,
  });

  @override
  State<_WorkFolderGrantsManager> createState() =>
      _WorkFolderGrantsManagerState();
}

class _WorkFolderGrantsManagerState extends State<_WorkFolderGrantsManager> {
  List<WorkFolderGrant> _grants = const [];
  bool _loading = true;
  String? _loadError;
  final Set<String> _busyPaths = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final grants = await widget.service.load();
      if (!mounted) return;
      setState(() {
        _grants = grants;
        _loading = false;
        _loadError = null;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = error.toString();
      });
    }
  }

  Future<void> addDirectoryFromPicker() async {
    final batchPicker = widget.pickDirectories;
    if (batchPicker != null) {
      final selected = await _pickDirectoriesSafely(batchPicker);
      if (selected == null || selected.isEmpty) return;
      await _authorizeBatch(selected);
      return;
    }
    // Tests and embedders can still provide the original single-directory
    // callback. The desktop default uses the batch flow below.
    if (widget.pickDirectory != null) {
      final selected = await _pickDirectorySafely();
      if (selected == null || selected.trim().isEmpty) return;
      await _authorizeSingleDirectory(selected);
      return;
    }
    final selected = await _pickDirectoriesSafely(_showBatchPicker);
    if (selected == null || selected.isEmpty) return;
    await _authorizeBatch(selected);
  }

  Future<void> _authorizeBatch(List<String> selected) async {
    await _runBusy('batch', () async {
      final grants = await widget.service.authorizeDirectories(
        selected,
        consent: (candidates) =>
            showWorkFolderGrantBatchConsent(context, candidates),
      );
      if (grants == null || grants.isEmpty) return;
      await _load();
    });
  }

  Future<void> _authorizeSingleDirectory(String selected) async {
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

  Future<List<String>?> _pickDirectoriesSafely(
    Future<List<String>?> Function() picker,
  ) async {
    try {
      return await picker();
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

  Future<List<String>?> _showBatchPicker() async {
    return showDialog<List<String>>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => WorkFolderBatchPickerDialog(
        pickDirectory: _pickDirectory,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AppCard(
      key: const Key('work-folder-grants-list'),
      cs: cs,
      margin: EdgeInsets.zero,
      children: [
        if (_loading)
          const Center(child: CircularProgressIndicator())
        else if (_loadError != null)
          _errorState(cs)
        else if (_grants.isEmpty)
          _emptyState(cs)
        else
          ..._grants.map((grant) => _grantTile(grant, cs)),
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
          Expanded(child: _grantSummary(grant, cs)),
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

  Widget _grantSummary(WorkFolderGrant grant, ColorScheme cs) {
    return Column(
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
    );
  }
}
