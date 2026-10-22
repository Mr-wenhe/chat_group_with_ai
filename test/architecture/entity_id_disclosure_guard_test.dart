import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 反显文件清单：这些文件里的用户可见文案不得再直接插值实体 id。
///
/// 新增反显点时把它加进来；确实要显示技术 id 的位置登记进 [_allowed]（键为
/// `路径:行号`）并写明理由。
const _displayFiles = <String>[
  'lib/core/widgets/readable_json_dialog.dart',
  'lib/features/chat_group/widgets/chat_message_bubble.dart',
  'lib/features/chat_group/widgets/progress_log_bubble.dart',
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

/// 允许出现实体 id 插值的位置与理由（规格 §9 不动边界），键为 `路径:行号`。
const _allowed = <String, String>{};

/// `$xxxId` / `${xxx.id}` / `${item['id']}` 形态的插值。
final _interpolatedId = RegExp(
  r"""\$\{?[A-Za-z_][A-Za-z0-9_.\[\]'"-]*[iI]d\b""",
);
final _cjk = RegExp(r'[一-龥]');
final _alreadyLocalized = RegExp(r'humanize|labelFor|resolveOrNull|shortCode');

/// 判定一行是否违规。
///
/// 抽成顶层函数是为了能直接单测「例外清单登记即生效」——它此前只被校验格式、
/// 从未参与判定，等于契约的一半是空的。
bool isDisclosureViolation({
  required String line,
  required String at,
  required Set<String> allowed,
}) {
  if (line.trimLeft().startsWith('//')) return false;
  if (!_cjk.hasMatch(line) || !line.contains(RegExp(r"""['"]"""))) return false;
  if (!_interpolatedId.hasMatch(line)) return false;
  // 已过 humanize/labelFor/短码的包装不算：插进去的值已经不是裸 id。
  if (_alreadyLocalized.hasMatch(line)) return false;
  return !allowed.contains(at);
}

void main() {
  test('反显文件里不得把实体 id 直接插进中文文案', () {
    final offenders = <String>[];
    final allowed = _allowed.keys.toSet();
    final used = <String>{};
    for (final path in _displayFiles) {
      final lines = File(path).readAsLinesSync();
      for (var index = 0; index < lines.length; index++) {
        final at = '$path:${index + 1}';
        if (!isDisclosureViolation(
            line: lines[index], at: at, allowed: allowed)) {
          continue;
        }
        if (allowed.contains(at)) {
          used.add(at);
          continue;
        }
        offenders.add(at);
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: '这些位置仍在把实体 id 插进反显文案：$offenders',
    );
    expect(
      used,
      equals(allowed),
      reason: '例外清单过期：登记的位置已不再命中，请同步删除',
    );
  });

  test('例外清单登记即生效', () {
    const line = r"Text('成员 ${member.id} 不可用')";
    expect(
      isDisclosureViolation(
          line: line, at: 'x.dart:1', allowed: const <String>{}),
      isTrue,
    );
    expect(
      isDisclosureViolation(
        line: line,
        at: 'x.dart:1',
        allowed: const <String>{'x.dart:1'},
      ),
      isFalse,
    );
    // 已走人话替换的行不算违规。
    expect(
      isDisclosureViolation(
        line: r"Text('成员 ${labels.labelFor(member.id)} 不可用')",
        at: 'x.dart:2',
        allowed: const <String>{},
      ),
      isFalse,
    );
  });

  test('例外清单必须写明理由', () {
    for (final entry in _allowed.entries) {
      expect(entry.value.trim(), isNotEmpty, reason: '${entry.key} 缺理由');
    }
  });
}
