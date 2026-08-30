import 'package:chat_group/features/work_mode/work_change_plan.dart';
import 'package:chat_group/features/work_mode/work_approval_decision.dart';
import 'package:flutter/material.dart';

export 'package:chat_group/features/work_mode/work_approval_decision.dart';

// ponytail: The dialog owns only presentation and decision callbacks; execution
// remains outside this widget so closing or rejecting cannot write anything.
/// Task-level approval dialog for a [WorkChangePlan].
///
/// The dialog only returns a decision and invokes optional callbacks. It never
/// touches the filesystem or starts a process; an executor remains outside the
/// UI boundary and can be called only after an approved decision.
class WorkChangeApprovalDialog extends StatelessWidget {
  final WorkChangePlan plan;
  final String? approvalReason;
  final VoidCallback? onApproved;
  final VoidCallback? onApprovedWithoutUndo;
  final VoidCallback? onRejected;

  const WorkChangeApprovalDialog({
    super.key,
    required this.plan,
    this.approvalReason,
    this.onApproved,
    this.onApprovedWithoutUndo,
    this.onRejected,
  });

  /// Matches the app's existing `showDialog` pattern while making a dismissed
  /// dialog distinguishable from an explicit rejection.
  static Future<WorkChangeApprovalDecision?> show(
    BuildContext context, {
    required WorkChangePlan plan,
    String? approvalReason,
    VoidCallback? onApproved,
    VoidCallback? onApprovedWithoutUndo,
    VoidCallback? onRejected,
  }) {
    return showDialog<WorkChangeApprovalDecision>(
      context: context,
      barrierDismissible: true,
      builder: (_) => WorkChangeApprovalDialog(
        plan: plan,
        approvalReason: approvalReason,
        onApproved: onApproved,
        onApprovedWithoutUndo: onApprovedWithoutUndo,
        onRejected: onRejected,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          const Expanded(child: Text('任务变更需要审批')),
          IconButton(
            tooltip: '关闭',
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _sectionTitle('为什么需要这次变更'),
              Text(approvalReason ?? plan.effectiveCommandReason),
              if (plan.commandReason != null) ...[
                const SizedBox(height: 4),
                Text('风险理由：${plan.riskReason}'),
              ],
              const SizedBox(height: 14),
              _sectionTitle('将做什么：${plan.actionType.displayName}'),
              Text('任务：${plan.taskId}'),
              const SizedBox(height: 10),
              _sectionTitle('准确路径'),
              if (plan.exactPaths.isEmpty)
                const Text('无法逐一枚举文件，将依据下方命令影响范围处理。')
              else
                ...plan.exactPaths.map((path) => _pathRow(path)),
              if (plan.knownAffectedDirectories.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  '影响目录：${plan.knownAffectedDirectories.join('、')}',
                ),
              ],
              const SizedBox(height: 10),
              Text('预计 ${plan.estimatedBytes} 字节'),
              Text(plan.snapshotAvailable ? '可创建快照' : '无法创建快照'),
              Text(plan.reversible ? '可撤销' : '不可撤销'),
              if (!plan.snapshotAvailable || !plan.reversible)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    '快照不可用或变更不可逆；只有单独确认“仍然执行（无法撤销）”后才会执行。',
                  ),
                ),
              if (plan.command != null) ...[
                const SizedBox(height: 14),
                _sectionTitle('命令影响'),
                _commandDetails(plan.command!),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            onRejected?.call();
            Navigator.of(context).pop(WorkChangeApprovalDecision.rejected);
          },
          child: const Text('拒绝并暂停'),
        ),
        if (!plan.snapshotAvailable || !plan.reversible)
          FilledButton(
            key: const Key('work-change-approve-without-undo'),
            onPressed: () {
              onApprovedWithoutUndo?.call();
              Navigator.of(context)
                  .pop(WorkChangeApprovalDecision.approvedWithoutUndo);
            },
            child: const Text('仍然执行（无法撤销）'),
          )
        else
          FilledButton(
            onPressed: () {
              onApproved?.call();
              Navigator.of(context).pop(WorkChangeApprovalDecision.approved);
            },
            child: const Text('允许本次范围'),
          ),
      ],
    );
  }

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        text,
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
    );
  }

  Widget _pathRow(String path) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: SelectableText(path),
    );
  }

  Widget _commandDetails(WorkChangeCommand command) {
    final args =
        command.arguments.isEmpty ? '(无参数)' : command.arguments.join(' ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SelectableText('可执行文件：${command.executable}'),
        SelectableText('参数：$args'),
        SelectableText('工作目录：${command.workingDirectory}'),
        SelectableText(
          '已知文件：${command.knownFiles.isEmpty ? '(无)' : command.knownFiles.join('、')}',
        ),
        SelectableText(
          '可能目录：${command.possibleDirectories.isEmpty ? '(无)' : command.possibleDirectories.join('、')}',
        ),
        if (command.impactUncertain) const Text('影响范围不确定：是，必须再次确认。'),
      ],
    );
  }
}
