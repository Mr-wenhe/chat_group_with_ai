import 'package:chat_group/core/models/tool_permission.dart';
import 'package:flutter/material.dart';

class ToolPermissionChips extends StatelessWidget {
  final List<ToolPermission> selected;
  final ValueChanged<ToolPermission> onToggle;

  const ToolPermissionChips({
    super.key,
    required this.selected,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: ToolPermission.values.map((permission) {
        final checked = selected.contains(permission);
        return FilterChip(
          selected: checked,
          label: Text(_label(permission)),
          avatar: Icon(_icon(permission), size: 16),
          onSelected: (_) => onToggle(permission),
          selectedColor: cs.primaryContainer,
          checkmarkColor: cs.onPrimaryContainer,
        );
      }).toList(),
    );
  }

  String _label(ToolPermission permission) {
    return switch (permission) {
      ToolPermission.workspaceRead => '读工作区',
      ToolPermission.workspacePatch => '改文件',
      ToolPermission.commandRun => '运行命令',
      ToolPermission.browserContext => '浏览器上下文',
      ToolPermission.skillCreate => '生成 Skill',
      ToolPermission.skillDownload => '下载 Skill',
    };
  }

  IconData _icon(ToolPermission permission) {
    return switch (permission) {
      ToolPermission.workspaceRead => Icons.folder_open_rounded,
      ToolPermission.workspacePatch => Icons.edit_note_rounded,
      ToolPermission.commandRun => Icons.terminal_rounded,
      ToolPermission.browserContext => Icons.public_rounded,
      ToolPermission.skillCreate => Icons.auto_fix_high_rounded,
      ToolPermission.skillDownload => Icons.download_rounded,
    };
  }
}
