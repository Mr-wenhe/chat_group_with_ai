import 'package:chat_group/features/chat_group/context_compaction_decision.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('本轮窗口放得下时不压缩', () {
    expect(
      decideContextCompaction(windowTokens: 900, inputBudget: 1000),
      ContextCompactionDecision.none,
    );
  });

  test('窗口放不下但上次摘要 + 增量放得下时复用摘要', () {
    expect(
      decideContextCompaction(
        windowTokens: 1200,
        inputBudget: 1000,
        reusableTokens: 800,
      ),
      ContextCompactionDecision.reuseSummary,
    );
  });

  test('没有可复用摘要时重新压缩', () {
    expect(
      decideContextCompaction(windowTokens: 1200, inputBudget: 1000),
      ContextCompactionDecision.resummarize,
    );
  });

  test('摘要 + 增量也放不下时重新压缩', () {
    expect(
      decideContextCompaction(
        windowTokens: 1200,
        inputBudget: 1000,
        reusableTokens: 1100,
      ),
      ContextCompactionDecision.resummarize,
    );
  });

  test('刚好等于预算按放得下处理', () {
    expect(
      decideContextCompaction(windowTokens: 1000, inputBudget: 1000),
      ContextCompactionDecision.none,
    );
    expect(
      decideContextCompaction(
        windowTokens: 1000,
        inputBudget: 999,
        reusableTokens: 999,
      ),
      ContextCompactionDecision.reuseSummary,
    );
  });
}
