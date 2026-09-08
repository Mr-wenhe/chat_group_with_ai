import 'package:chat_group/core/audio/asr_transcript_accumulator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AsrTranscriptAccumulator', () {
    test('interim 覆盖候补，最终整句定稿', () {
      final acc = AsrTranscriptAccumulator();
      expect(acc.onResult('你', false), isTrue);
      expect(acc.displayText, '你');
      expect(acc.onResult('你好', false), isTrue);
      expect(acc.displayText, '你好');
      expect(acc.onResult('你好世界', true), isTrue);
      expect(acc.displayText, '你好世界');
      expect(acc.committedText, '你好世界');
    });

    test('定稿后新的 interim 追加到定稿之后', () {
      final acc = AsrTranscriptAccumulator();
      acc.onResult('早上好', true);
      expect(acc.onResult('今天', false), isTrue);
      expect(acc.displayText, '早上好今天');
    });

    test('累计式 final 只追加相对已定稿的增量，不重复', () {
      final acc = AsrTranscriptAccumulator();
      acc.onResult('你好世界', true);
      // 服务端累计全文：以已定稿为前缀，应只追加增量。
      expect(acc.onResult('你好世界今天天气不错', true), isTrue);
      expect(acc.displayText, '你好世界今天天气不错');
      // 内容相同（无增量）不触发变化。
      expect(acc.onResult('你好世界今天天气不错', true), isFalse);
    });

    test('按句定稿：停顿后继续说话，后一句追加到前一句之后不覆盖', () {
      final acc = AsrTranscriptAccumulator();
      acc.onResult('今天天气不错', true);
      // 用户停顿超过 VAD 断句阈值后说了第二句；SAUC 对每句单独出 definite 终态。
      expect(acc.onResult('我们出去玩吧', true), isTrue);
      expect(acc.displayText, '今天天气不错我们出去玩吧');
      expect(acc.committedText, '今天天气不错我们出去玩吧');
    });

    test('与已定稿或上一条新句一致的重复帧不重复追加', () {
      final acc = AsrTranscriptAccumulator();
      acc.onResult('今天天气不错', true);
      // 与上一条新句相同的重复帧（按句定稿模型）。
      expect(acc.onResult('我们出去玩吧', true), isTrue);
      expect(acc.onResult('我们出去玩吧', true), isFalse);
      expect(acc.displayText, '今天天气不错我们出去玩吧');
      // 与全部已定稿一致的重复帧（累计式模型）。
      expect(acc.onResult('今天天气不错我们出去玩吧', true), isFalse);
      expect(acc.displayText, '今天天气不错我们出去玩吧');
    });

    test('空白结果不改变展示', () {
      final acc = AsrTranscriptAccumulator();
      acc.onResult('你好', true);
      expect(acc.onResult('   ', false), isFalse);
      expect(acc.onResult('', true), isFalse);
      expect(acc.displayText, '你好');
    });

    test('clear 复位为空白', () {
      final acc = AsrTranscriptAccumulator();
      acc.onResult('你好', true);
      acc.clear();
      expect(acc.displayText, '');
      expect(acc.committedText, '');
    });
  });
}
