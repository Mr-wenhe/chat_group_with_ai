import 'package:chat_group/features/work_mode/work_follow_up_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const policy = WorkFollowUpPolicy();

  test('explicit current/previous/same wording targets structured artifact',
      () {
    for (final request in const [
      '请修改当前文件',
      '把上次的结果修复一下',
      'Please revise the same file',
    ]) {
      final decision = policy.resolve(
        request: request,
        lastArtifactPaths: const ['/workspace/report.md'],
      );
      expect(decision.kind, WorkFollowUpKind.reviseArtifact);
      expect(decision.artifactPath, '/workspace/report.md');
      expect(decision.autoRenameIfExists, isFalse);
    }
  });

  test('colloquial edit wording still targets the original artifact', () {
    final decision = policy.resolve(
      request: '帮我改一下当前文件',
      lastArtifactPaths: const ['/workspace/report.md'],
    );
    expect(decision.kind, WorkFollowUpKind.reviseArtifact);
    expect(decision.artifactPath, '/workspace/report.md');
  });

  test('equivalent same-file wording also targets the original artifact', () {
    final decision = policy.resolve(
      request: '请修改相同文件',
      lastArtifactPaths: const ['/workspace/report.md'],
    );
    expect(decision.kind, WorkFollowUpKind.reviseArtifact);
    expect(decision.artifactPath, '/workspace/report.md');
  });

  test('new-file wording allows collision rename but revision never does', () {
    final newFile = policy.resolve(
      request: '新建一个 report.md',
      lastArtifactPaths: const ['/workspace/report.md'],
    );
    expect(newFile.kind, WorkFollowUpKind.newArtifact);
    expect(newFile.autoRenameIfExists, isTrue);

    final revision = policy.resolve(
      request: '修改 report.md',
      lastArtifactPaths: const ['/workspace/report.md'],
    );
    expect(revision.kind, WorkFollowUpKind.reviseArtifact);
    expect(revision.autoRenameIfExists, isFalse);
  });

  test('design-and-implement wording is recognized as a new artifact', () {
    final decision = policy.resolve(
      request: '设计并实现一个 html 教师节贺卡',
      lastArtifactPaths: const ['/workspace/flight-chess.html'],
    );

    expect(decision.kind, WorkFollowUpKind.newArtifact);
    expect(decision.autoRenameIfExists, isTrue);
  });

  test('relative and resolved copies of one artifact are not ambiguous', () {
    final decision = policy.resolve(
      request: '请修改当前文件',
      lastArtifactPaths: const [
        '/workspace/conversations/group-a/report.md',
        'report.md',
      ],
    );
    expect(decision.kind, WorkFollowUpKind.reviseArtifact);
    expect(decision.artifactPath, '/workspace/conversations/group-a/report.md');
  });

  test('an explicit absolute path is a revision target', () {
    final decision = policy.resolve(
      request: '请修复 /workspace/report.md',
    );
    expect(decision.kind, WorkFollowUpKind.reviseArtifact);
    expect(decision.artifactPath, '/workspace/report.md');
    expect(decision.autoRenameIfExists, isFalse);
  });

  test('an explicit full path wins over a basename-only checkpoint', () {
    final decision = policy.resolve(
      request: '请修改 /workspace/report.md',
      lastArtifactPaths: const ['report.md'],
    );
    expect(decision.kind, WorkFollowUpKind.reviseArtifact);
    expect(decision.artifactPath, '/workspace/report.md');
  });

  test('ambiguous target asks one precise question and pauses', () {
    final decision = policy.resolve(
      request: '请修改当前文件',
      lastArtifactPaths: const [
        '/workspace/report.md',
        '/workspace/summary.md',
      ],
    );

    expect(decision.kind, WorkFollowUpKind.clarification);
    expect(decision.artifactPath, isNull);
    expect(decision.clarificationQuestion, isNotNull);
    expect(decision.clarificationQuestion!.split('？').length - 1, 1);
  });

  test('missing structured artifact never falls back to global recent files',
      () {
    final decision = policy.resolve(
      request: '修改上次文件',
      lastArtifactPaths: const [],
    );

    expect(decision.kind, WorkFollowUpKind.clarification);
    expect(decision.artifactPath, isNull);
    expect(decision.clarificationQuestion, contains('文件路径'));
  });

  test('ordinary follow-up remains a normal continuation', () {
    final decision = policy.resolve(
      request: '继续检查错误并给我结论',
      lastArtifactPaths: const ['/workspace/report.md'],
    );
    expect(decision.kind, WorkFollowUpKind.continueTask);
    expect(decision.autoRenameIfExists, isFalse);
  });

  test('a file path without an explicit revision verb is not overwritten', () {
    final decision = policy.resolve(
      request: '请查看 report.md',
      lastArtifactPaths: const ['/workspace/report.md'],
    );
    expect(decision.kind, WorkFollowUpKind.continueTask);
    expect(decision.artifactPath, isNull);
    expect(decision.autoRenameIfExists, isFalse);
  });
}
