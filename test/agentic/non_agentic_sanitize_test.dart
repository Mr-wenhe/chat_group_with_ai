import 'package:flutter_test/flutter_test.dart';

/// 非 agentic 路径 tool_call 泄漏防护验证。
///
/// 重要约束：`_sanitizeNonAgenticReply` 定义在私有类 `_ChatRoomPageState` 中，
/// Dart 的 `_` 前缀 + 私有类使其无法从独立测试库直接调用（与
/// `test/agentic/agent_runtime_sanitize_test.dart` 中说明的库隔离限制一致，
/// 且该项目约定不暴露私有方法，而是通过公开包装验证）。
///
/// 因此这里用一份【逐字复制】自 `chat_room_page.dart` 的实现来驱动断言，
/// 验证正则设计满足规格：
///   1) 标准 `<tool_call>…</tool_call>` / `<agent_tool>…</agent_tool>` 块被清除；
///   2) 闭合标签带多余空白 `</tool_call >` 也能匹配（实现者将任务给的
///      `</tool_call >` 修正为 `</tool_call\s*>`）；
///   3) >500 字符的超大 ``` 代码块被替换为「📎 [代码内容已省略，请查看附件]」；
///   4) 正常聊天（含 happy 等含 app 子串的英文词）不被误杀。
///
/// 已对源码逐行审查，确认下方副本与 `_ChatRoomPageState._sanitizeNonAgenticReply`
/// 完全一致。建议后续将该纯函数抽取到可测试的 util 模块，以获得真正覆盖。

// 逐字复制自 lib/features/chat_group/chat_room_page.dart
// (_ChatRoomPageState._sanitizeNonAgenticReply)，仅用于本测试驱动。
String _sanitizeUnderTest(String text) {
  var result = text;
  // 移除 tool_call 标签及内部全部内容（非贪婪，跨行）。
  result = result.replaceAll(RegExp(
    r'<tool_call[^>]*>[\s\S]*?</tool_call\s*>',
    dotAll: true,
  ), '');
  // 移除 agent_tool 标签及内部全部内容（非贪婪，跨行）。
  result = result.replaceAll(RegExp(
    r'<agent_tool[^>]*>[\s\S]*?</agent_tool\s*>',
    dotAll: true,
  ), '');
  // 移除可能残留的孤立标签（开/闭标签，含多余空白）。
  result = result.replaceAll(
      RegExp(r'</?\s*(tool_call|agent_tool|function|parameter)[^>]*>'), '');
  // 若剩余文本以超大代码块为主（单个 ``` 块超过 500 字符），替换为提示，
  // 避免把大段疑似生成代码当普通聊天贴出。
  final codeBlockMatch = RegExp(r'```[\s\S]{500,}```').firstMatch(result);
  if (codeBlockMatch != null) {
    result =
        result.replaceAll(codeBlockMatch.group(0)!, '📎 [代码内容已省略，请查看附件]');
  }
  return result.trim();
}

void main() {
  group('非 agentic 回复清洗：tool_call / agent_tool 泄漏', () {
    test('移除标准 <tool_call> 块', () {
      const input = '好的，我来帮你。\n'
          '<tool_call>{"name":"write_file","arguments":{"path":"a.html","content":"x"}}</tool_call>\n'
          '完成啦～';
      final output = _sanitizeUnderTest(input);
      expect(output.contains('<tool_call'), isFalse);
      expect(output.contains('write_file'), isFalse);
      expect(output.contains('完成啦'), isTrue);
    });

    test('移除 <agent_tool> 块', () {
      const input = '正在处理：\n'
          '<agent_tool>{"action":"open","target":"page"}</agent_tool>'
          '好了';
      final output = _sanitizeUnderTest(input);
      expect(output.contains('<agent_tool'), isFalse);
      expect(output.contains('"action"'), isFalse);
      expect(output.contains('好了'), isTrue);
    });

    test('闭合标签带多余空白 </tool_call > 也能匹配（实现者修正点）', () {
      const input = '<tool_call>secret</tool_call >tail';
      final output = _sanitizeUnderTest(input);
      expect(output.contains('secret'), isFalse);
      expect(output.contains('tail'), isTrue);
    });

    test('孤立开标签 <tool_call> 也被清除', () {
      const input = '看这个 <tool_call> 没闭合就结束了';
      final output = _sanitizeUnderTest(input);
      expect(output.contains('<tool_call'), isFalse);
    });
  });

  group('非 agentic 回复清洗：超大代码块', () {
    test('>500 字符代码块被替换且原代码不残留', () {
      final big = List.filled(600, 'a').join();
      final input = '这是生成的代码：\n```\n$big\n```\n以上。';
      final output = _sanitizeUnderTest(input);
      expect(output.contains('📎 [代码内容已省略，请查看附件]'), isTrue);
      expect(output.contains('aaaaaaaa'), isFalse);
    });

    test('<500 字符代码块保留', () {
      final small = List.filled(100, 'b').join();
      final input = '看这段代码：\n```\n$small\n```\n懂了吗？';
      final output = _sanitizeUnderTest(input);
      expect(output.contains('📎 [代码内容已省略，请查看附件]'), isFalse);
      expect(output.contains(small), isTrue);
    });
  });

  group('非 agentic 回复清洗：不误杀正常聊天', () {
    test('含 happy（含 app 子串）的闲聊原文保留', () {
      const input = '我今天特别 happy，要不要一起去逛街呀？';
      final output = _sanitizeUnderTest(input);
      expect(output, equals(input));
    });

    test('普通中文闲聊原样返回', () {
      const input = '哈哈这个笑话真好笑，你太逗了';
      final output = _sanitizeUnderTest(input);
      expect(output, equals(input));
    });
  });
}
