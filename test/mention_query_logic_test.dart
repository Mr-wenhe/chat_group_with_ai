// 验证 @ 弹窗触发逻辑的单元测试
// 模拟 _isInMentionQuery 的核心判断：光标在 @ 后且 @ 与光标间无空格

import 'package:flutter_test/flutter_test.dart';

/// 与 ChatRoomPageState._isInMentionQuery 等价的纯逻辑函数，用于测试。
bool isInMentionQuery(String text, int cursorPos) {
  final textBeforeCursor = text.substring(0, cursorPos);
  final atIndex = textBeforeCursor.lastIndexOf('@');
  if (atIndex < 0) return false;
  final query = textBeforeCursor.substring(atIndex + 1);
  return !query.contains(' ');
}

void main() {
  group('_isInMentionQuery — 弹窗触发条件', () {
    test('输入 @ 后弹窗应出现', () {
      expect(isInMentionQuery('@', 1), isTrue);
    });

    test('输入 @A 后弹窗应出现', () {
      expect(isInMentionQuery('@A', 2), isTrue);
    });

    test('输入 @Alice 后弹窗应出现', () {
      expect(isInMentionQuery('@Alice', 6), isTrue);
    });

    test('输入 @Alice 后跟空格，弹窗应关闭', () {
      expect(isInMentionQuery('@Alice ', 7), isFalse);
    });

    test('选人后插入 @Alice 末尾有空格，不重开弹窗', () {
      // _insertMention 插入 '@Alice '，光标在末尾
      expect(isInMentionQuery('@Alice ', 7), isFalse);
    });

    test('在 @Alice 后面继续输入 hello，弹窗不应出现', () {
      expect(isInMentionQuery('@Alice hello', 12), isFalse);
    });

    test('没有 @ 符号时不弹窗', () {
      expect(isInMentionQuery('hello', 5), isFalse);
    });

    test('@ 在光标前面很远时不弹窗', () {
      expect(isInMentionQuery('hello @world test', 17), isFalse);
      // lastIndexOf('@') = 6, query = "world test", 包含空格
    });

    test('第二个 @ 后无空格时弹窗', () {
      expect(isInMentionQuery('hello @wo', 9), isTrue);
    });

    test('行首 @ 后输入空格关闭弹窗', () {
      expect(isInMentionQuery('@ ', 2), isFalse);
    });
  });
}
