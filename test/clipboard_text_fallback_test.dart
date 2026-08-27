import 'package:chat_group/features/chat_group/attachment_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('uses non-empty clipboard text as composer fallback', () {
    const prompt = '小薇，我现在要你再生成一份html，文件，内容是从宇宙中看到地球，并能拖动地球旋转，看到地球的外貌，一定要炫酷';

    expect(clipboardTextFallback(prompt), prompt);
  });

  test('ignores empty clipboard text', () {
    expect(clipboardTextFallback(null), isNull);
    expect(clipboardTextFallback('  \n'), isNull);
  });
}
