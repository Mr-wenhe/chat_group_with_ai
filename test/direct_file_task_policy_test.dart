import 'package:chat_group/features/chat_group/direct_file_task_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('direct chat file generation still requires explicit approval', () {
    expect(
      shouldAutoApproveDirectFileTask(
        isDirectChat: true,
        userMessage: '帮我生成一个流星雨特效 html',
      ),
      isFalse,
    );
  });

  test('direct personal page generation still requires explicit approval', () {
    expect(
      shouldAutoApproveDirectFileTask(
        isDirectChat: true,
        userMessage: '你帮我写一个酷炫的个人介绍页，要有音乐和菜单',
      ),
      isFalse,
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
