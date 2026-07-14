import 'package:chat_group/features/chat_group/fact_discipline_prompt.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fact discipline forbids unsupported memories', () {
    expect(FactDisciplinePrompt.rules, contains('不得编造'));
    expect(FactDisciplinePrompt.rules, contains('必须能从记忆或最近消息中找到依据'));
  });

  test('evidence lines include discipline and sources', () {
    final prompt = FactDisciplinePrompt.withEvidence([
      '用户明确说喜欢简短答复',
      '',
    ]);

    expect(prompt, contains('事实与记忆纪律'));
    expect(prompt, contains('用户明确说喜欢简短答复'));
  });
}
