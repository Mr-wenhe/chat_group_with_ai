import 'package:chat_group/features/autonomous/evidence_memory_prompt.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fact discipline forbids unsupported memories', () {
    expect(EvidenceMemoryPrompt.factDiscipline, contains('不得编造'));
    expect(EvidenceMemoryPrompt.factDiscipline, contains('必须能从记忆或最近消息中找到依据'));
  });

  test('evidence lines include discipline and sources', () {
    final prompt = EvidenceMemoryPrompt.evidenceLines([
      '2026-07-09，用户说过：“喜欢 C++”。',
    ]);

    expect(prompt, contains('事实与记忆纪律'));
    expect(prompt, contains('喜欢 C++'));
  });
}
