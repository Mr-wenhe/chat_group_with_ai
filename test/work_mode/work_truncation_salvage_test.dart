import 'dart:convert';

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

    test('recombines a complete surrogate pair into one character', () {
      final salvage = WorkTruncationSalvage.extract(
        '{"action":"tool","tool":{"name":"workspace.patch","arguments":'
        '{"path":"a.md","content":"\\uD83D\\uDE00',
      );

      expect(salvage?.content, '😀');
      expect(utf8.encode(salvage!.content), [240, 159, 152, 128]);
      expect(salvage.content.contains('\uFFFD'), isFalse);
    });

    test('drops a lone high surrogate', () {
      // 断点落在代理对的两个转义之间：只写出高代理会让字符串成为非法 UTF-16，
      // 下游 utf8.encode 会静默写成 U+FFFD——模型从没写过这个字符。
      final salvage = WorkTruncationSalvage.extract(
        '{"action":"tool","tool":{"name":"workspace.patch","arguments":'
        '{"path":"a.md","content":"正文\\uD83D',
      );

      expect(salvage?.content, '正文');
      expect(salvage!.content.contains('\uFFFD'), isFalse);
    });

    test('drops a lone low surrogate', () {
      final salvage = WorkTruncationSalvage.extract(
        '{"action":"tool","tool":{"name":"workspace.patch","arguments":'
        '{"path":"a.md","content":"正文\\uDE00',
      );

      expect(salvage?.content, '正文');
      expect(salvage!.content.contains('\uFFFD'), isFalse);
    });

    test('drops a malformed unicode escape instead of throwing', () {
      // `\u-123` 会被十六进制解析成负数 → writeCharCode 抛 RangeError。这条路径
      // 运行在截断失败路径上，抛异常会把「输出被截断」变成一次崩溃。
      final salvage = WorkTruncationSalvage.extract(
        '{"action":"tool","tool":{"name":"workspace.patch","arguments":'
        '{"path":"a.md","content":"正文\\u-123',
      );

      expect(salvage?.content, '正文-123');
    });

    test('keeps the backslash of an unknown escape', () {
      final salvage = WorkTruncationSalvage.extract(
        '{"action":"tool","tool":{"name":"workspace.patch","arguments":'
        '{"path":"a.md","content":"a\\xb',
      );

      expect(salvage?.content, 'a\\xb');
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
