import 'package:chat_group/features/chat_group/attachment_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('successful renamed write exposes only the authoritative result file',
      () {
    final paths = resolveAgentArtifactPaths(
      requestedPaths: const ['page.html'],
      actualResultPath: 'page_2.html',
      resultSucceeded: true,
    );

    expect(paths, ['page_2.html']);
  });

  test('failed write exposes no stale requested-path attachment', () {
    final paths = resolveAgentArtifactPaths(
      requestedPaths: const ['report.html'],
      actualResultPath: null,
      resultSucceeded: false,
    );

    expect(paths, isEmpty);
  });
}
