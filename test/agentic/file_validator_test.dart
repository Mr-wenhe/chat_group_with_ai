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

  test('其他类型拒绝空文件和异常大的文件', () async {
    expect((await FileValidator.validate('empty.txt', '')).isValid, isFalse);
    expect(
      (await FileValidator.validate('huge.txt', 'x' * 5000001)).isValid,
      isFalse,
    );
  });
}
