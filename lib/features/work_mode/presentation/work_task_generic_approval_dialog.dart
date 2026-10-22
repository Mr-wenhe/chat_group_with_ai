import 'package:chat_group/features/agentic/tool_request.dart';
import 'package:chat_group/features/work_mode/work_approval_decision.dart';
import 'package:chat_group/features/work_mode/work_mode_policy.dart';
import 'package:flutter/material.dart';

/// Presents the compact approval prompt used by the app-wide task overlay.
///
/// The dialog only returns a durable decision. The coordinator remains the
/// single owner of persisting and executing that decision.
class WorkTaskGenericApprovalDialog extends StatelessWidget {
  final ToolRequest? pending;
  final bool requiresNoUndo;
  final bool continuesAfterRejection;

  const WorkTaskGenericApprovalDialog({
    super.key,
    required this.pending,
    required this.requiresNoUndo,
    this.continuesAfterRejection = false,
  });

  static Future<WorkChangeApprovalDecision?> show(
    BuildContext context, {
    required ToolRequest? pending,
    required bool requiresNoUndo,
    bool continuesAfterRejection = false,
  }) {
    return showDialog<WorkChangeApprovalDecision>(
      context: context,
      barrierDismissible: true,
      builder: (_) => WorkTaskGenericApprovalDialog(
        pending: pending,
        requiresNoUndo: requiresNoUndo,
        continuesAfterRejection: continuesAfterRejection,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final decision = requiresNoUndo
        ? WorkChangeApprovalDecision.approvedWithoutUndo
        : WorkChangeApprovalDecision.approved;
    return AlertDialog(
      key: const Key('work-generic-approval-dialog'),
      title: const Text('工作任务需要审批'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            pending == null
                ? '任务准备执行一项需要确认的操作。'
                : WorkModePolicy.approvalSummary(pending!),
          ),
          if (continuesAfterRejection)
            const Text('拒绝仅禁止本次操作，任务会继续寻找安全替代方案；要暂停整个任务，请关闭此框后点击任务面板“停止”。'),
          if (requiresNoUndo) ...[
            const SizedBox(height: 12),
            const Text('应用内技能配置没有文件快照，执行后无法通过任务撤销恢复。'),
          ],
        ],
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('work-generic-reject'),
          onPressed: () => Navigator.of(context).pop(
            WorkChangeApprovalDecision.rejected,
          ),
          child: Text(continuesAfterRejection ? '拒绝本次操作' : '拒绝并暂停'),
        ),
        FilledButton(
          key: const Key('work-generic-approve'),
          onPressed: () => Navigator.of(context).pop(decision),
          child: Text(
            requiresNoUndo ? '仍然执行（无法撤销）' : '允许本次操作',
          ),
        ),
      ],
    );
  }
}
