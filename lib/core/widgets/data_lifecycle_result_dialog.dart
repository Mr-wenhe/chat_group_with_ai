import 'package:chat_group/core/database/data_lifecycle_models.dart';
import 'package:flutter/material.dart';

Future<void> showIncompleteDeletionDialog(
  BuildContext context,
  DataLifecycleResult result,
) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      icon: Icon(
        Icons.warning_amber_rounded,
        color: Theme.of(dialogContext).colorScheme.error,
      ),
      title: const Text('删除部分完成'),
      content: Text(
        '未完成项：\n• ${result.incompleteItems.join('\n• ')}\n\n'
        '已完成部分不会回滚；请到设置中安全重试。',
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('知道了'),
        ),
      ],
    ),
  );
}
