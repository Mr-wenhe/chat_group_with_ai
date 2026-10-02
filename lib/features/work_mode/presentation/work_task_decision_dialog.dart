import 'package:chat_group/features/work_mode/work_task_decision.dart';
import 'package:flutter/material.dart';

typedef WorkDecisionReply = Future<bool> Function(
  WorkTaskDecision decision,
  String answer, {
  String? choiceId,
  String disposition,
});

/// The same durable decision can be opened from a chat reminder or task panel.
class WorkTaskDecisionDialog extends StatefulWidget {
  final List<WorkTaskDecision> decisions;
  final WorkDecisionReply onReply;

  const WorkTaskDecisionDialog({
    super.key,
    required this.decisions,
    required this.onReply,
  });

  @override
  State<WorkTaskDecisionDialog> createState() => _WorkTaskDecisionDialogState();
}

class _WorkTaskDecisionDialogState extends State<WorkTaskDecisionDialog> {
  final TextEditingController _controller = TextEditingController();
  int _index = 0;
  bool _busy = false;
  bool _answeredUnresolved = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit(String disposition, {String? choiceId}) async {
    if (_busy) return;
    final decision = widget.decisions[_index];
    final answer = _controller.text.trim();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final resolved = await widget.onReply(decision, answer,
          choiceId: choiceId, disposition: disposition);
      if (!mounted) return;
      if (!resolved) {
        setState(() {
          _answeredUnresolved = true;
          _error = '建议已保存；原问题仍缺少明确选择或条件，请从任务面板查看最新提示后补充。';
        });
        return;
      }
      if (_index + 1 == widget.decisions.length) {
        Navigator.of(context).pop();
      } else {
        setState(() {
          _index++;
          _controller.clear();
        });
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final decision = widget.decisions[_index];
    final options = decision.options;
    return AlertDialog(
      key: const Key('work-task-decision-dialog'),
      title: Text(widget.decisions.length == 1
          ? '需要你的决定'
          : '待处理事项 ${_index + 1}/${widget.decisions.length}'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(decision.reason,
                  key: const Key('work-task-decision-reason')),
              if (decision.evidence.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text('依据：${decision.evidence}'),
              ],
              if (decision.impact.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text('影响：${decision.impact}'),
              ],
              if (decision.missingCondition.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text('仍缺少：${decision.missingCondition}'),
              ],
              if (decision.status == 'deferred') ...[
                const SizedBox(height: 8),
                const Text('此项仍未验收，其他可完成工作结束后需要再次处理。'),
              ],
              for (final option in options)
                ListTile(
                  key: Key('work-task-decision-option-${option['id']}'),
                  title: Text(option['label']!),
                  subtitle: option['impact']!.isEmpty
                      ? null
                      : Text(option['impact']!),
                  onTap: _busy || _answeredUnresolved
                      ? null
                      : () => _submit('answer', choiceId: option['id']),
                ),
              TextField(
                key: const Key('work-task-decision-input'),
                controller: _controller,
                maxLength: 4096,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: '补充建议或解释',
                  border: OutlineInputBorder(),
                ),
              ),
              if (_error != null)
                Text(_error!,
                    key: const Key('work-task-decision-error'),
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('work-task-decision-close'),
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
        if (decision.targetId.isNotEmpty)
          TextButton(
            key: const Key('work-task-decision-defer'),
            onPressed:
                _busy || _answeredUnresolved ? null : () => _submit('defer'),
            child: const Text('此项先放着'),
          ),
        if ((decision.kind == 'acceptance' || decision.kind == 'dispute') &&
            decision.targetId.isNotEmpty) ...[
          if (decision.kind == 'acceptance')
            TextButton(
              key: const Key('work-task-decision-manual'),
              onPressed:
                  _busy || _answeredUnresolved ? null : () => _submit('manual'),
              child: const Text('记录人工验收'),
            ),
          TextButton(
            key: const Key('work-task-decision-waive'),
            onPressed:
                _busy || _answeredUnresolved ? null : () => _submit('waive'),
            child: const Text('明确豁免'),
          ),
        ],
        FilledButton(
          key: const Key('work-task-decision-submit'),
          onPressed:
              _busy || _answeredUnresolved ? null : () => _submit('answer'),
          child: const Text('提交建议'),
        ),
      ],
    );
  }
}
