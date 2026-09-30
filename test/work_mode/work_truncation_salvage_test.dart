import 'package:chat_group/features/work_mode/work_truncation_salvage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WorkTruncationSalvage.extract', () {
    test('recovers the content prefix cut mid-string', () {
      final body = '{"action":"tool","public_update":"正在写文件。","tool":'
          '{"name":"workspace.patch","arguments":{"path":"report.md",'
          '"content":"第一行\\n第二行';

      final salvage = WorkTruncationSalvage.extract(body);

      expect(salvage, isNotNull);
      expect(salvage!.targetPath, 'report.md');
      expect(salvage.content, '第一行\n第二行');
    });

    test('drops a half-written escape sequence', () {
      // 正文以**单个**反斜杠结尾（Dart 里写成 \\，即一个反斜杠字符）：半个转义
      // 必须被丢掉，留下反斜杠字面量或半个转义都是错的。
      final salvage = WorkTruncationSalvage.extract(
        '{"action":"tool","tool":{"name":"workspace.patch","arguments":'
        '{"path":"a.md","content":"正文\\',
      );

      expect(salvage?.content, '正文');
    });

    test('drops a half-written unicode escape', () {
      final salvage = WorkTruncationSalvage.extract(
        '{"action":"tool","tool":{"name":"workspace.patch","arguments":'
        '{"path":"a.md","content":"正文\\u4e',
      );

      expect(salvage?.content, '正文');
    });

    test('recovers the replacement argument of an exact patch', () {
      final salvage = WorkTruncationSalvage.extract(
        '{"action":"tool","tool":{"name":"workspace.patch","arguments":'
        '{"path":"a.md","expectedSha256":"ff","expectedFragment":"x",'
        '"replacement":"替换正文',
      );

      expect(salvage?.content, '替换正文');
      expect(salvage?.targetPath, 'a.md');
    });

    test('ignores a truncation that is not a file write', () {
      // 现场最常见的截断是模型在写正文说明，没有可捞的动作参数。
      final salvage = WorkTruncationSalvage.extract(
        '{"action":"tool","tool":{"name":"command.run","arguments":'
        '{"executable":"python3","arguments":["script.py"]',
      );

      expect(salvage, isNull);
    });

    test('ignores a body that is not a decision prefix at all', () {
      expect(WorkTruncationSalvage.extract('陆教授：我先把报告写到桌面'), isNull);
      expect(WorkTruncationSalvage.extract(''), isNull);
    });
  });

  group('WorkTruncationSalvage.rescuePath', () {
    test('keeps the directory and the extension', () {
      final first = WorkTruncationSalvage.rescuePath('/work/report.md', '内容');
      final second = WorkTruncationSalvage.rescuePath('/work/report.md', '内容');
      final other = WorkTruncationSalvage.rescuePath('/work/report.md', '别的');

      expect(first, startsWith('/work/report.rescue-'));
      expect(first, endsWith('.md'));
      expect(first, second, reason: '同内容必须同名，重复抢救才是幂等的');
      expect(other, isNot(first));
    });

    test('handles a path without extension', () {
      expect(
        WorkTruncationSalvage.rescuePath('/work/README', 'x'),
        startsWith('/work/README.rescue-'),
      );
    });
  });
}
