import 'package:chat_group/features/work_mode/work_folder_grant_service.dart';
import 'package:flutter/material.dart';

/// Shows the one-time, app-wide disclosure that accompanies a folder grant.
///
/// ponytail: Keep the disclosure in one dialog so Settings and the execution
/// panel cannot drift into different permission promises.
Future<bool> showWorkFolderGrantConsent(
  BuildContext context,
  WorkFolderGrant grant,
) async {
  final decision = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => AlertDialog(
      key: const Key('work-folder-grant-consent-dialog'),
      title: const Text('确认授权工作目录'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('授权范围：整个 App 的工作模式任务。'),
            const SizedBox(height: 10),
            const Text('规范化路径：'),
            SelectableText(grant.path),
            const SizedBox(height: 10),
            Text(
              grant.writable ? '能力：可读取、可写入。' : '能力：只读。',
            ),
            const SizedBox(height: 10),
            const Text(
              '为完成你的请求，必要的文件内容可能会发送给当前角色配置的云端模型 API。'
              '应用不会把目录内容预先全部上传；只有任务按需读取时才会发送。',
            ),
            const SizedBox(height: 10),
            const Text('敏感文件（例如 .env、私钥和凭据）仍会单独提示并默认隐藏。'),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('work-folder-grant-consent-cancel'),
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('work-folder-grant-consent-confirm'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('确认并授权'),
        ),
      ],
    ),
  );
  return decision == true;
}

/// Shows one disclosure/authorization action for a batch of directories.
///
/// The paths are listed together so the user can verify the complete scope
/// before any of them is persisted; cancelling leaves the whole batch
/// unchanged.
Future<bool> showWorkFolderGrantBatchConsent(
  BuildContext context,
  List<WorkFolderGrant> grants,
) async {
  if (grants.isEmpty) return false;
  final decision = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => AlertDialog(
      key: const Key('work-folder-grant-batch-consent-dialog'),
      title: const Text('确认授权多个工作目录'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('授权范围：整个 App 的工作模式任务。'),
            const SizedBox(height: 10),
            for (final grant in grants) ...[
              SelectableText(grant.path),
              Text(grant.writable ? '能力：可读取、可写入。' : '能力：只读。'),
              const SizedBox(height: 8),
            ],
            const Text(
              '为完成你的请求，必要的文件内容可能会发送给当前角色配置的云端模型 API。'
              '应用不会把目录内容预先全部上传；只有任务按需读取时才会发送。',
            ),
            const SizedBox(height: 10),
            const Text('敏感文件（例如 .env、私钥和凭据）仍会单独提示并默认隐藏。'),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('work-folder-grant-batch-consent-cancel'),
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('work-folder-grant-batch-consent-confirm'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('确认并授权全部'),
        ),
      ],
    ),
  );
  return decision == true;
}
