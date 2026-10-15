import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 反显出口禁止把异常 `toString()` 直接交给用户。
///
/// 规则（按优先级）：
/// 1. 行内已出现 `sanitize*` / `humanize` / `redact` → 合格。
/// 2. 同文件别处已经用了这套清洗（说明该文件采纳了约定）→ 这一行漏了，失败。
/// 3. 在 [_pendingGenericErrorToasts] 里 → 已知的另一批（通用 UI 提示，从未清洗过），
///    登记在案；修掉一处就从清单里删一处，清单过期同样失败。
/// 4. 在 [_allowedRawDisplays] 里 → 逐条写明理由。
///
/// 例外清单必须带理由：写不出理由的裸反显不该存在。
const _pendingGenericErrorToasts = <String>{
  // 通用 UI 提示（保存/选文件/打开媒体失败等），从未走过清洗，
  // 与本次修复的「任务/备份 sanitize* 出口」不是同一批，留待用户决定是否一并收口。
  'lib/features/settings/user_profile_page.dart:160',
  'lib/features/chat_group/chat_room_task_action_support.dart:54',
  'lib/features/chat_group/chat_room_input_attachments_support.dart:55',
  'lib/features/chat_group/chat_room_input_attachments_support.dart:90',
  'lib/features/chat_group/chat_room_input_attachments_support.dart:146',
  'lib/features/chat_group/chat_room_input_attachments_support.dart:201',
  'lib/features/chat_group/chat_room_input_attachments_support.dart:316',
  'lib/features/chat_group/widgets/chat_message_media.dart:239',
  'lib/features/chat_group/chat_group_form_page.dart:320',
  'lib/features/ai_character/ai_character_form_page.dart:850',
};

const _allowedRawDisplays = <String, String>{};

final _displayToken = RegExp(r'(SnackBar|_toast|_snack|AppToast|Text\(|content:)');
final _errorInterpolation = RegExp(r'\$e\b|\$\{e\}|\$error\b|\$\{error\}');
final _sanitized = RegExp(r'sanitize|humanize|redact');

void main() {
  test('反显出口不得直接展示异常 toString', () {
    final offenders = <String>[];
    var pendingSeen = 0;
    var allowedSeen = 0;
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final path = entity.path;
      final lines = entity.readAsLinesSync();
      final fileKnowsConvention = lines.any(_sanitized.hasMatch);
      for (var index = 0; index < lines.length; index++) {
        final line = lines[index];
        final at = '$path:${index + 1}';
        if (!_displayToken.hasMatch(line) || !_errorInterpolation.hasMatch(line)) {
          continue;
        }
        if (line.trimLeft().startsWith('//')) continue;
        if (_sanitized.hasMatch(line)) continue;
        if (_allowedRawDisplays.containsKey(at)) {
          allowedSeen++;
          continue;
        }
        if (_pendingGenericErrorToasts.contains(at)) {
          pendingSeen++;
          continue;
        }
        // 同文件别处已在清洗，说明这一行是漏网，而不是「这批还没轮到」。
        offenders.add('$at${fileKnowsConvention ? '' : '（同文件未采纳清洗约定）'}');
      }
    }
    expect(_pendingGenericErrorToasts.length, pendingSeen,
        reason: '待办清单过期：清单里的行已不存在或已清洗，请同步删除');
    expect(_allowedRawDisplays.length, allowedSeen,
        reason: '例外清单过期：列出的行已不存在或已改为清洗');
    expect(
      offenders,
      isEmpty,
      reason: '这些位置仍在反显未清洗的异常：$offenders',
    );
  });
}
