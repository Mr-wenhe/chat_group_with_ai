import 'package:chat_group/features/chat_group/direct_file_task_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('allows direct chat file generation request', () {
    expect(
      shouldAutoApproveDirectFileTask(
        isDirectChat: true,
        userMessage: '帮我生成一个流星雨特效 html',
      ),
      isTrue,
    );
  });

  test('rejects group chat file generation request', () {
    expect(
      shouldAutoApproveDirectFileTask(
        isDirectChat: false,
        userMessage: '帮我生成一个流星雨特效 html',
      ),
      isFalse,
    );
  });

  test('rejects command execution request', () {
    expect(
      shouldAutoApproveDirectFileTask(
        isDirectChat: true,
        userMessage: '帮我运行 flutter test',
      ),
      isFalse,
    );
  });

  test('rejects writing without file target', () {
    expect(
      shouldAutoApproveDirectFileTask(
        isDirectChat: true,
        userMessage: '帮我写一首诗',
      ),
      isFalse,
    );
  });
}
