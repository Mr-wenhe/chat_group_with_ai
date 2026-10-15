import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 反显文件清单：这些文件里的用户可见文案不得再直接插值实体 id。
///
/// 新增反显点时把它加进来；确实要显示技术 id 的位置登记进 [_allowed]，并写明理由。
const _displayFiles = <String>[
  'lib/features/chat_group/widgets/chat_message_bubble.dart',
  'lib/features/work_mode/presentation/work_task_panel.dart',
  'lib/features/work_mode/presentation/work_task_panel_details.dart',
  'lib/features/work_mode/presentation/work_task_panel_timeline.dart',
  'lib/features/work_mode/presentation/work_task_panel_controls.dart',
  'lib/features/work_mode/presentation/work_task_panel_actions.dart',
  'lib/features/work_mode/presentation/work_task_panel_action_recovery.dart',
  'lib/features/work_mode/presentation/work_task_decision_dialog.dart',
  'lib/features/work_mode/presentation/work_change_approval_dialog.dart',
  'lib/features/memory/memory_migration_diagnostics_widgets.dart',
  'lib/features/memory/relationship_audit_page.dart',
  'lib/features/memory/relationship_audit_filter_widget.dart',
  'lib/features/settings/ai_governance_page_support.dart',
];

/// 允许出现实体 id 插值的位置与理由（规格 §9 不动边界）。
const _allowed = <String, String>{
  // 任务需求与历史标题来自用户原话：与「只清洗 ai/system 消息」同一条克制原则。
  'lib/features/work_mode/presentation/work_task_panel_details.dart': '任务需求按用户原话原样显示',
};

/// `$xxxId` / `${xxx.id}` / `${item['id']}` 形态的插值。
final _interpolatedId = RegExp(
  r"""\$\{?[A-Za-z_][A-Za-z0-9_.\[\]'"-]*[iI]d\b""",
);
final _cjk = RegExp(r'[一-龥]');

void main() {
  test('反显文件里不得把实体 id 直接插进中文文案', () {
    final offenders = <String>[];
    for (final path in _displayFiles) {
      final lines = File(path).readAsLinesSync();
      for (var index = 0; index < lines.length; index++) {
        final line = lines[index];
        if (line.trimLeft().startsWith('//')) continue;
        if (!_cjk.hasMatch(line) || !line.contains(RegExp(r"""['"]"""))) continue;
        if (!_interpolatedId.hasMatch(line)) continue;
        // 已过 humanize/labelFor/短码的包装不算：值已经不是裸 id。
        if (RegExp(r'humanize|labelFor|resolveOrNull|shortCode').hasMatch(line)) {
          continue;
        }
        offenders.add('$path:${index + 1}');
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: '这些位置仍在把实体 id 插进反显文案：$offenders',
    );
  });

  test('允许清单必须写明理由', () {
    for (final entry in _allowed.entries) {
      expect(entry.value.trim(), isNotEmpty, reason: '${entry.key} 缺理由');
      expect(File(entry.key).existsSync(), isTrue, reason: '${entry.key} 不存在');
    }
  });
}
