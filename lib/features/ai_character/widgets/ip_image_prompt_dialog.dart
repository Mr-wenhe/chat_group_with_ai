import 'package:flutter/material.dart';

/// 生图 Prompt 的查看弹窗。
///
/// 为什么要摊开原文：拼装是全自动的，用户看不见就只能对着图猜哪句话出了
/// 问题。留一条能直接复制走比对的通道，比再加十个设置项有用。
///
/// 顶部那句话必须把三态分开说：还没生成过、生成时真用了 LLM 改写、生成时
/// 静默回落了本地模板。混成一句「这是 prompt」就又回到「图不对只能猜」。
void showIpImagePromptDialog(
  BuildContext context, {
  required String previewPrompt,
  required String? sentPrompt,
  required bool? usedLlm,
}) {
  showDialog<void>(
    context: context,
    builder: (dialogContext) {
      final cs = Theme.of(dialogContext).colorScheme;
      return AlertDialog(
        title: const Text('生图 Prompt'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  promptProvenanceNote(sentPrompt, usedLlm),
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
                const SizedBox(height: 8),
                SelectableText(sentPrompt ?? previewPrompt),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('关闭'),
          ),
        ],
      );
    },
  );
}

/// 弹窗顶部说明这份 prompt 走的是哪条路。
@visibleForTesting
String promptProvenanceNote(String? sentPrompt, bool? usedLlm) {
  if (sentPrompt == null) {
    return '以下是本地模板拼装的预览。点「生成形象」后这里会换成真实发出的原文。';
  }
  return usedLlm == true
      ? '以下是最近一次生成真实发出的原文，外观描述由聊天模型改写。'
      : '以下是最近一次生成真实发出的原文。外观描述走的是本地模板 '
          '—— 聊天模型那次改写没生效，所以只有性格没有长相。';
}
