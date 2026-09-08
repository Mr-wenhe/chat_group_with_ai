import 'package:chat_group/core/audio/sentence_segmenter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SentenceSegmenter', () {
    test('句末标点到达即成句，标点归属该句，其余文字保持缓冲', () {
      final seg = SentenceSegmenter();
      expect(seg.push('你好'), isEmpty);
      expect(seg.push('！'), ['你好！']);
      expect(seg.push('接下来是第二句'), isEmpty);
      expect(seg.finish(), '接下来是第二句');
    });

    test('一次推送多句时按顺序逐句切出', () {
      final seg = SentenceSegmenter();
      expect(seg.push('第一句。第二句！第三句？'), ['第一句。', '第二句！', '第三句？']);
    });

    test('覆盖英文问号/省略号/分号/换行等标点', () {
      // 中文句号/问号切句。
      final seg = SentenceSegmenter();
      expect(seg.push('如何？'), ['如何？']);
      expect(seg.push('好的。'), ['好的。']);

      // 省略号在句末成句。
      final seg2 = SentenceSegmenter();
      expect(seg2.push('他说等等…'), ['他说等等…']);

      // 分号/句号同段多句。
      final seg3 = SentenceSegmenter();
      expect(seg3.push('A；B。'), ['A；', 'B。']);

      // 换行也是切点，标点归属该句。
      final seg4 = SentenceSegmenter();
      expect(seg4.push('第一行\n第二行'), ['第一行\n']);
      expect(seg4.finish(), '第二行');

      // 英文句点（.）不作为切点，避免数字/URL 被截断；由 finish 兜底。
      final seg5 = SentenceSegmenter();
      expect(seg5.push('Fine. Version 3.14'), isEmpty);
      expect(seg5.finish(), 'Fine. Version 3.14');
    });

    test('未达 minLen 的零碎标点不切，finish 时整体输出', () {
      final seg = SentenceSegmenter(minLen: 5);
      expect(seg.push('嗯？'), isEmpty);
      expect(seg.push('对，'), isEmpty);
      expect(seg.finish(), '嗯？对，');
    });

    test('无标点时超过 maxLen 强制切分', () {
      final seg = SentenceSegmenter(maxLen: 5);
      const long = '一二三四五六七八九';
      final out = <String>[...seg.push(long), seg.finish()!];
      expect(out, ['一二三四五', '六七八九']);
    });

    test('强制切分不切断 emoji 代理对', () {
      final seg = SentenceSegmenter(maxLen: 4);
      final out = <String>[...seg.push('ab😀c'), seg.finish()!];
      expect(out, ['ab😀', 'c']);
    });

    test('finish 为空/纯空白时返回 null', () {
      final seg = SentenceSegmenter();
      expect(seg.finish(), isNull);
      seg.push('   ');
      expect(seg.finish(), isNull);
    });
  });

  group('stripMarkdownForSpeech', () {
    test('去掉代码围栏与行内反引号', () {
      expect(
        stripMarkdownForSpeech('```dart\nvoid main() {}\n```\n结论如上'),
        'void main() {}\n结论如上',
      );
      expect(stripMarkdownForSpeech('看 `code` 这里'), '看 code 这里');
    });

    test('链接保留文字、图片整体去掉', () {
      expect(
          stripMarkdownForSpeech('[标题](https://x.com)内容'), '标题内容');
      expect(stripMarkdownForSpeech('![图](a.png)继续'), '继续');
    });

    test('去掉行首标题号与成对装饰符', () {
      expect(stripMarkdownForSpeech('## 章节\n**加粗**和~~删除~~'),
          '章节\n加粗和删除');
      expect(stripMarkdownForSpeech('_斜_体'), '斜体');
    });
  });
}
