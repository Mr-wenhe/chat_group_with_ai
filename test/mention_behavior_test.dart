// 验证 @ 弹窗两个核心修复的逻辑测试（无需 Hive / widget）
// 1. _isInMentionQuery: 选人后（@Alice ）应关闭弹窗
// 2. Enter 发送: 弹窗关闭时 Enter 不应被拦截

import 'package:flutter_test/flutter_test.dart';

// ─── 复刻 _isInMentionQuery 逻辑（与 chat_room_page.dart 第1217行一致）───
bool _isInMentionQuery(String text, int cursorPos) {
  final textBeforeCursor = text.substring(0, cursorPos);
  final atIndex = textBeforeCursor.lastIndexOf('@');
  if (atIndex < 0) return false;
  final query = textBeforeCursor.substring(atIndex + 1);
  return !query.contains(' ');
}

void main() {
  group('_isInMentionQuery', () {
    test('输入 @ 后应返回 true（弹窗开启）', () {
      expect(_isInMentionQuery('@', 1), true);
      expect(_isInMentionQuery('@A', 2), true);
      expect(_isInMentionQuery('@Alice', 6), true);
    });

    test('选人后 @Alice 含空格应返回 false（弹窗关闭）', () {
      // _insertMention 插入后文本为 "@Alice "，光标在末尾
      expect(_isInMentionQuery('@Alice ', 7), false);
    });

    test('继续输入 "@Alice 你好" 应返回 false', () {
      // "@Alice 你好" = 1+5+1+2 = 9 字符
      expect(_isInMentionQuery('@Alice 你好', 9), false);
    });

    test('光标不在 @ 后应返回 false', () {
      expect(_isInMentionQuery('hello world', 11), false);
      expect(_isInMentionQuery('', 0), false);
    });

    test('@ 后跟空格应返回 false', () {
      expect(_isInMentionQuery('@ ', 2), false);
      expect(_isInMentionQuery('@Alice 你好', 7), false); // 光标在空格处
    });

    test('文本中有多个 @ 时取最后一个', () {
      expect(_isInMentionQuery('hello @Bob @Alice', 16), true);
      expect(_isInMentionQuery('hello @Bob @Ali ', 16), false);
    });
  });

  group('键盘事件拦截逻辑', () {
    // 模拟 _handleKeyEvent 的桌面端 Enter 逻辑
    bool shouldHandleEnter(
        bool showMentionPopup, bool isInputEmpty, bool isStreaming) {
      if (showMentionPopup) return true; // 弹窗开启时 Enter 被拦截（用于选人）
      if (isInputEmpty) return false;
      if (isStreaming) return false; // 流式生成时仍允许发送并排队
      return false; // 正常情况放行（TextField 自行处理）
    }

    test('弹窗关闭 + 有内容 + 非流式 → Enter 应放行（发送消息）', () {
      expect(shouldHandleEnter(false, false, false), false);
    });

    test('弹窗关闭 + 输入为空 → Enter 放行（但不发送）', () {
      expect(shouldHandleEnter(false, true, false), false);
    });

    test('弹窗开启 → Enter 被拦截（选人）', () {
      expect(shouldHandleEnter(true, false, false), true);
    });

    test('流式生成 + 有内容 → Enter 应放行（发送并排队）', () {
      expect(shouldHandleEnter(false, false, true), false);
    });
  });

  group('_handleTextChanged 弹窗开关逻辑', () {
    // 模拟 _handleTextChanged 的弹窗开关判断
    bool shouldOpenPopup(bool showMentionPopup, String text, int cursorPos) {
      if (showMentionPopup) return false; // 已打开，不重复开关
      return _isInMentionQuery(text, cursorPos);
    }

    test('弹窗关闭 + @ 后跟文字 → 应打开', () {
      expect(shouldOpenPopup(false, '@Alice', 6), true);
    });

    test('弹窗关闭 + 选人后含空格 → 不应打开', () {
      expect(shouldOpenPopup(false, '@Alice 你好', 9), false);
    });

    test('弹窗已开 → 不重复开关', () {
      expect(shouldOpenPopup(true, '@Alice 你好', 9), false);
    });

    test('无 @ → 不打开', () {
      expect(shouldOpenPopup(false, 'hello', 5), false);
    });
  });
}
