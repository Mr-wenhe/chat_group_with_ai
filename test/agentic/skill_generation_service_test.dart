import 'package:chat_group/features/agentic/skill_generation_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses generated skill json into safe draft', () {
    final draft = SkillGenerationService.parseDraft('''
```skill_json
{"name":"Flutter Riverpod Reviewer","domain":"coding","description":"Review Riverpod code","instructions":["Read providers","Check lifecycle"],"permissions":["workspaceRead"]}
```
''');

    expect(draft, isNotNull);
    expect(draft!.name, 'Flutter Riverpod Reviewer');
    expect(draft.instructions, contains('Read providers'));
  });
}
