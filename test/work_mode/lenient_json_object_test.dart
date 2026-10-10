import 'package:chat_group/features/work_mode/lenient_json_object.dart';
import 'package:flutter_test/flutter_test.dart';

/// OpenAI 兼容网关会在协议正文前加一句解释，这是现场最常见的违约形状
/// （2026-10-10 12:16 执行决策连续三次因此被判"不是单个合法 JSON object"）。
const _prosePrefixedObject =
    '{"action":"tool","public_update":"先看下工作区现状，然后开始写材料。",'
    '"tool":{"name":"workspace.list","arguments":{}},"completion":null}';

const _prosePrefixed =
    '\n\n先看看工作区现状，然后开始写材料。\n\n$_prosePrefixedObject';

const _bare =
    '{"action":"tool","public_update":"读取目标文件。",'
    '"tool":{"name":"workspace.read","arguments":{"path":"lib/main.dart"}},'
    '"completion":null}';

void main() {
  group('findSingleJsonObject', () {
    test('裸 JSON 原样返回', () {
      expect(findSingleJsonObject(_bare), _bare);
    });

    test('容忍中文散文前缀', () {
      expect(findSingleJsonObject(_prosePrefixed), _prosePrefixedObject);
    });

    test('容忍散文后缀', () {
      expect(findSingleJsonObject('$_bare\n\n需要我继续吗？'), _bare);
    });

    test('容忍 Markdown 围栏加前后散文', () {
      expect(
        findSingleJsonObject('模型输出如下：\n```json\n$_bare\n```\n希望有帮助。'),
        _bare,
      );
    });

    test('字符串里的大括号不参与配对', () {
      const withBraces =
          '{"action":"tool","public_update":"写入模板。","tool":{"name":'
          '"workspace.patch","arguments":{"path":"a.html","content":'
          '"<style>body{color:red}</style>\\"quoted\\""}},"completion":null}';
      expect(findSingleJsonObject('先写入。\n\n$withBraces'), withBraces);
    });

    test('转义引号不提前结束字符串', () {
      const escaped =
          '{"action":"plan","public_update":"含 \\" 引号","tool":null,'
          '"completion":null}';
      expect(findSingleJsonObject(escaped), escaped);
    });

    test('两个顶层 object 判为不唯一', () {
      expect(findSingleJsonObject('$_bare\n$_bare'), isNull);
    });

    test('散文里自带配对的 object 也判为不唯一', () {
      expect(findSingleJsonObject('按 {a,b} 的形式写\n$_bare'), isNull);
    });

    test('第二个 object 只写了一半同样是"第二个顶层 object"', () {
      // 模型先吐草稿再吐修正版时，被截断的正是第二个；只取第一个等于照草稿执行。
      expect(findSingleJsonObject('$_bare\n\n{"action":"tool","pub'), isNull);
    });

    test('没有 object 返回 null', () {
      expect(findSingleJsonObject('我先看看工作区现状。'), isNull);
    });

    test('括号不闭合返回 null', () {
      expect(findSingleJsonObject('{"action":"tool"'), isNull);
    });

    test('空串返回 null', () {
      expect(findSingleJsonObject(''), isNull);
    });
  });
}
