import 'package:flutter_test/flutter_test.dart';
import 'package:chat_group/features/chat_group/user_message_sentiment.dart';

void main() {
  group('UserMessageSentimentAnalyzer', () {
    group('empty input', () {
      test('empty string returns neutral', () {
        final result = UserMessageSentimentAnalyzer.analyze('');
        expect(result.category, UserMessageCategory.neutral);
        expect(result.affinityDelta, 0);
        expect(result.frictionDelta, 0);
      });
    });

    group('offensive detection', () {
      test('severe insults trigger offensive with high deltas', () {
        final result = UserMessageSentimentAnalyzer.analyze('你真是个傻逼废物');
        expect(result.category, UserMessageCategory.offensive);
        expect(result.affinityDelta, -6);
        expect(result.frictionDelta, 15);
        expect(result.severity, 2);
      });

      test('multiple disrespect phrases triggers medium offensive', () {
        // 2 disrespect matches → offensiveScore=2 → severity=1 → -4 affinity, +10 friction
        final result = UserMessageSentimentAnalyzer.analyze('你算什么 你懂什么');
        expect(result.category, UserMessageCategory.offensive);
        expect(result.affinityDelta, -4);
        expect(result.frictionDelta, 10);
        expect(result.severity, 1);
      });

      test('multiple commanding phrases triggers medium offensive', () {
        // "别插嘴 没人问你" → 2 matches → offensiveScore=2 → severity=1 → -4, +10
        final result = UserMessageSentimentAnalyzer.analyze('别插嘴 没人问你');
        expect(result.category, UserMessageCategory.offensive);
        expect(result.affinityDelta, -4);
        expect(result.frictionDelta, 10);
        expect(result.severity, 1);
      });
    });

    group('de-escalation', () {
      test('polite joke turns disrespect into respectful', () {
        // "开玩笑的" triggers de-escalation → respectful (+1 affinity)
        final result = UserMessageSentimentAnalyzer.analyze('开玩笑的 别介意');
        expect(result.category, UserMessageCategory.respectful);
        expect(result.affinityDelta, 1);
      });

      test('apology turns insult into respectful', () {
        // "sorry" triggers de-escalation → respectful (+1 affinity)
        final result = UserMessageSentimentAnalyzer.analyze('sorry 我不是故意的');
        expect(result.category, UserMessageCategory.respectful);
        expect(result.affinityDelta, 1);
      });
    });

    group('cold/disrespectful', () {
      test('cold dismissal triggers cold category', () {
        final result = UserMessageSentimentAnalyzer.analyze('真无聊 不想理你了');
        expect(result.category, UserMessageCategory.cold);
        expect(result.affinityDelta, -1);
        expect(result.frictionDelta, 2);
      });

      test('dont care triggers cold', () {
        final result = UserMessageSentimentAnalyzer.analyze("I don't care");
        expect(result.category, UserMessageCategory.cold);
      });
    });

    group('friendly', () {
      test('thanks triggers respectful', () {
        final result = UserMessageSentimentAnalyzer.analyze('谢谢你的帮助');
        expect(result.category, UserMessageCategory.respectful);
        expect(result.affinityDelta, 2);
      });

      test('praise triggers respectful', () {
        final result = UserMessageSentimentAnalyzer.analyze('太棒了 你真的很厉害');
        expect(result.category, UserMessageCategory.respectful);
        expect(result.affinityDelta, 2);
      });

      test('love triggers respectful', () {
        final result = UserMessageSentimentAnalyzer.analyze('love this');
        expect(result.category, UserMessageCategory.respectful);
      });
    });

    group('neutral', () {
      test('plain question is neutral', () {
        final result = UserMessageSentimentAnalyzer.analyze('今天天气怎么样');
        expect(result.category, UserMessageCategory.neutral);
        expect(result.affinityDelta, 0);
      });

      test('topic change is neutral', () {
        final result = UserMessageSentimentAnalyzer.analyze('对了 最近有什么新电影');
        expect(result.category, UserMessageCategory.neutral);
      });
    });

    group('helpers', () {
      test('isRespectful is true for respectful', () {
        final result = UserMessageSentimentAnalyzer.analyze('谢谢');
        expect(result.isRespectful, true);
      });

      test('isOffensive is true for offensive', () {
        final result = UserMessageSentimentAnalyzer.analyze('你闭嘴');
        expect(result.isOffensive, true);
      });

      test('isEmotional distinguishes neutral from emotional', () {
        expect(UserMessageSentimentAnalyzer.analyze('嗯').isEmotional, false);
        expect(UserMessageSentimentAnalyzer.analyze('谢谢').isEmotional, true);
      });
    });

    group('edge cases', () {
      test('whitespace only returns neutral', () {
        final result = UserMessageSentimentAnalyzer.analyze('   ');
        expect(result.category, UserMessageCategory.neutral);
        expect(result.affinityDelta, 0);
      });

      test('mixed friendly and offensive prefers offensive', () {
        // "谢谢 你真是个傻逼" → insult matches → offensive
        final result = UserMessageSentimentAnalyzer.analyze('谢谢 你真是个傻逼');
        expect(result.category, UserMessageCategory.offensive);
        expect(result.affinityDelta, lessThan(0));
      });

      test('very long message is handled without crash', () {
        final long = '你' * 10000;
        final result = UserMessageSentimentAnalyzer.analyze(long);
        expect(
            result.category,
            anyOf(
              UserMessageCategory.offensive,
              UserMessageCategory.neutral,
            ));
      });

      test('friendly praise with long text stays respectful', () {
        final result = UserMessageSentimentAnalyzer.analyze('太棒了 你真的好厉害 辛苦了');
        expect(result.category, UserMessageCategory.respectful);
        expect(result.affinityDelta, 2);
      });

      test('description getter returns readable string', () {
        final result = UserMessageSentimentAnalyzer.analyze('谢谢');
        expect(result.description, contains('respectful'));
        expect(result.description, contains('affinity'));
      });
    });
  });
}
