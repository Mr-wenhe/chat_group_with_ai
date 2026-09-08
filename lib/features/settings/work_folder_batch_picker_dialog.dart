import 'package:flutter/material.dart';

/// Collects several native directory-picker results before one consent step.
///
/// macOS and Windows expose a single-directory picker in the current Flutter
/// desktop stack. Re-opening that picker from this small dialog preserves the
/// one app-wide authorization action without pretending the platform supports
/// a native multi-select panel.
class WorkFolderBatchPickerDialog extends StatefulWidget {
  final Future<String?> Function() pickDirectory;

  const WorkFolderBatchPickerDialog({super.key, required this.pickDirectory});

  @override
  State<WorkFolderBatchPickerDialog> createState() =>
      _WorkFolderBatchPickerDialogState();
}

class _WorkFolderBatchPickerDialogState
    extends State<WorkFolderBatchPickerDialog> {
  final List<String> _selected = <String>[];
  bool _picking = false;

  Future<void> _addDirectory() async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final path = await widget.pickDirectory();
      final normalized = path?.trim();
      if (!mounted || normalized == null || normalized.isEmpty) return;
      if (_selected.contains(normalized)) return;
      setState(() => _selected.add(normalized));
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('work-folder-batch-picker-dialog'),
      title: const Text('选择多个授权目录'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('可以连续选择目录；完成后只需确认一次，授权将绑定到整个 App。'),
            const SizedBox(height: 12),
            if (_selected.isEmpty)
              const Text('尚未选择目录。')
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _selected.length,
                  itemBuilder: (context, index) => ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.folder_outlined),
                    title: SelectableText(_selected[index]),
                    trailing: IconButton(
                      key: Key('work-folder-batch-remove:$index'),
                      tooltip: '移除',
                      onPressed: _picking
                          ? null
                          : () => setState(() => _selected.removeAt(index)),
                      icon: const Icon(Icons.close, size: 18),
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const Key('work-folder-batch-pick'),
              onPressed: _picking ? null : _addDirectory,
              icon: _picking
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.create_new_folder_outlined),
              label: const Text('选择目录'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('work-folder-batch-cancel'),
          onPressed: _picking ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('work-folder-batch-confirm'),
          onPressed: _picking || _selected.isEmpty
              ? null
              : () => Navigator.of(context).pop(List<String>.of(_selected)),
          child: const Text('完成选择'),
        ),
      ],
    );
  }
}
