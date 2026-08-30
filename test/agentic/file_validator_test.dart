import 'package:chat_group/features/agentic/file_validator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('完整 HTML 通过而未闭合标签失败', () async {
    final valid = await FileValidator.validate(
      'page.html',
      '<!doctype html><html><head><title>x</title></head><body><h1>Hi</h1></body></html>',
    );
    final invalid = await FileValidator.validate(
      'broken.html',
      '<html><body><div>missing</body></html>',
    );

    expect(valid.isValid, isTrue);
    expect(valid.message, contains('HTML'));
    expect(invalid.isValid, isFalse);
    expect(invalid.message, contains('div'));
  });

  test('HTML 出现多余结束标签时返回失败而不是抛异常', () async {
    final result = await FileValidator.validate(
      'broken.html',
      '<!doctype html><br></div>',
    );

    expect(result.isValid, isFalse);
    expect(result.message, contains('多余的结束标签 </div>'));
  });

  test('HTML 校验忽略 script 内的小于比较但仍识别脚本截断', () async {
    final valid = await FileValidator.validate(
      'page.html',
      '<!doctype html><html><body><script>'
          'for (let i = 0; i < positions.length; i++) {}'
          '</script></body></html>',
    );
    final truncated = await FileValidator.validate(
      'broken.html',
      '<!doctype html><html><body><script>'
          'for (let i = 0; i < positions.length; i++) {',
    );

    expect(valid.isValid, isTrue);
    expect(truncated.isValid, isFalse);
    expect(truncated.message, contains('script'));
    expect(truncated.message, isNot(contains('positions')));
  });

  test('Markdown 标题不能跨级', () async {
    final result = await FileValidator.validate(
      'report.md',
      '# 标题\n\n### 跳过二级标题\n',
    );

    expect(result.isValid, isFalse);
    expect(result.message, contains('标题层级'));
  });

  test('Dart 文件调用 flutter analyze 并保留命令证据', () async {
    String? command;
    final result = await FileValidator.validate(
      'lib/generated.dart',
      'void main() {}',
      commandRunner: (value) async {
        command = value;
        return {'ok': true, 'exitCode': 0, 'stdout': 'No issues found!'};
      },
    );

    expect(command, 'flutter analyze lib/generated.dart');
    expect(result.isValid, isTrue);
    expect(result.message, contains('No issues found'));
  });

  test('Dart 验证命令会保护 shell 元字符路径', () async {
    String? command;
    await FileValidator.validate(
      'lib/a;echo injected.dart',
      'void main() {}',
      commandRunner: (value) async {
        command = value;
        return {'ok': true, 'exitCode': 0};
      },
    );

    expect(command, "flutter analyze 'lib/a;echo injected.dart'");
  });

  test('没有命令执行器时，Dart 使用轻量结构校验而不是误报失败', () async {
    final valid = await FileValidator.validate(
      'main.dart',
      'void main() { final message = "ok"; print(message); }',
    );
    final invalid = await FileValidator.validate(
      'broken.dart',
      'void main() { print("missing");',
    );

    expect(valid.isValid, isTrue);
    expect(valid.message, contains('轻量验证'));
    final bareMain = await FileValidator.validate('bare.dart', 'main() {}');
    expect(invalid.isValid, isFalse);
    expect(invalid.message, contains('括号'));
    expect(bareMain.isValid, isTrue);
  });

  test('轻量 Dart 校验支持三引号字符串和普通类型声明', () async {
    final result = await FileValidator.validate(
      'messages.dart',
      "const title = '''第一行\n第二行''';\nString label = \"ok\";",
    );

    expect(result.isValid, isTrue);
    expect(result.message, contains('轻量验证'));
  });

  test('Stage 02 不提供 command.run 时仍保留轻量 Dart 验证', () async {
    final result = await FileValidator.validate(
      'main.dart',
      'void main() {}',
      commandRunner: (_) async => {
        'ok': false,
        'error': 'command_not_available_in_stage02',
      },
    );

    expect(result.isValid, isTrue);
    expect(result.message, contains('未执行 flutter analyze'));
  });

  test('其他类型拒绝空文件和异常大的文件', () async {
    expect((await FileValidator.validate('empty.txt', '')).isValid, isFalse);
    expect(
      (await FileValidator.validate('huge.txt', 'x' * 5000001)).isValid,
      isFalse,
    );
  });

  test('Java 和 C++ 只验证源码结构，不虚构编译结果', () async {
    final java = await FileValidator.validate(
      'Main.java',
      'public class Main { public static void main(String[] args) {} }',
    );
    final cpp = await FileValidator.validate(
      'main.cpp',
      '#include <iostream>\nint main() { return 0; }',
    );

    expect(java.isValid, isTrue);
    expect(java.message, contains('Java'));
    expect(java.message, isNot(contains('编译通过')));
    expect(cpp.isValid, isTrue);
    expect(cpp.message, contains('C/C++'));
    expect(cpp.message, isNot(contains('编译通过')));
  });

  test('纯 C 函数库与头文件（无 main/无 include）也能通过结构验证', () async {
    final libC = await FileValidator.validate(
      'math_utils.c',
      'int add(int a, int b) { return a + b; }\n'
          'double average(double* arr, int n) {'
          'double s = 0; for (int i = 0; i < n; i++) s += arr[i]; return s / n; }',
    );
    final header = await FileValidator.validate(
      'point.h',
      'typedef struct Point { double x; double y; } Point;',
    );

    expect(libC.isValid, isTrue);
    expect(libC.message, contains('C/C++'));
    expect(header.isValid, isTrue);
  });

  test('无函数定义/类型声明的 C/C++ 内容判定结构失败', () async {
    final result = await FileValidator.validate(
      'notes.c',
      '// 仅注释，没有任何函数或类型定义\n/* no code here */',
    );

    expect(result.isValid, isFalse);
    expect(result.message, contains('函数定义'));
  });
}
