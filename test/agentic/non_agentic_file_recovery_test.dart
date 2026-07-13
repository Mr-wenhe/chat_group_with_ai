import 'package:chat_group/features/chat_group/agentic_reply_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('non-agentic file recovery helpers', () {
    test('infers html path from attachment-style homepage request', () {
      expect(
        inferRecoverableFilePath(
          '请直接生成一个完整的 html 文件作为附件发给我，不要在聊天里贴源码。我要能直接点击附件打开。',
        ),
        'page.html',
      );
    });

    test('extracts fenced html for recoverable attachment', () {
      const reply = '''
这是完整的页面代码：

```html
<!DOCTYPE html>
<html lang="zh-CN">
<head><meta charset="UTF-8"><title>页面</title></head>
<body><h1>你好</h1></body>
</html>
```
''';
      expect(
        extractRecoverableFileContent(reply, 'page.html'),
        contains('<html lang="zh-CN">'),
      );
    });

    test('rejects narration-only response without file content', () {
      expect(
        extractRecoverableFileContent(
          '这是完整代码，复制保存为 html 即可打开。',
          'page.html',
        ),
        isNull,
      );
    });
  });
}
