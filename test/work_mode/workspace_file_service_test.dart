import 'dart:io';

import 'package:chat_group/features/work_mode/workspace_file_service.dart';
import 'package:chat_group/features/work_mode/workspace_path_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory sandbox;
  late Directory root;
  late Directory outside;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('workspace-files-');
    root = await Directory('${sandbox.path}/work').create();
    outside = await Directory('${sandbox.path}/outside').create();
    await File('${root.path}/alpha.txt').writeAsString('alpha\nneedle\n');
    await File('${root.path}/beta.txt').writeAsString('beta\nneedle\n');
    await Directory('${root.path}/nested').create();
    await File('${root.path}/nested/gamma.txt').writeAsString('nested needle');
    await File('${root.path}/binary.bin').writeAsBytes([0, 159, 255, 0]);
    await File('${root.path}/large.txt').writeAsString('x' * 200);
  });

  tearDown(() async {
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  WorkspaceFileService service({
    WorkspaceReadLimits limits = const WorkspaceReadLimits(),
    WorkspaceFileEventSink? onEvent,
  }) {
    return WorkspaceFileService(
      pathPolicy: WorkspacePathPolicy(
        authorizedRoots: [root.path],
        isWindows: false,
      ),
      limits: limits,
      onEvent: onEvent,
    );
  }

  test('lists one non-recursive page and reports pagination metadata',
      () async {
    final result = await service().listDirectory(root.path, pageSize: 2);

    expect(result.entries, hasLength(2));
    expect(result.recursive, isFalse);
    expect(result.hasMore, isTrue);
    expect(result.filesExamined, greaterThanOrEqualTo(2));
    expect(result.elapsed, isNotNull);
    expect(
        result.entries.any((entry) => entry.path.contains('gamma')), isFalse);
  });

  test('stats files without reading their contents', () async {
    final result = await service().stat('${root.path}/alpha.txt');

    expect(result.isFile, isTrue);
    expect(result.size, greaterThan(0));
    expect(result.bytesRead, 0);
  });

  test('reads a bounded strict UTF-8 byte range', () async {
    final result = await service().readTextRange(
      '${root.path}/alpha.txt',
      startByte: 0,
      byteLength: 5,
    );

    expect(result.text, 'alpha');
    expect(result.bytesRead, 5);
    expect(result.outputCharacters, 5);
    expect(result.truncated, isTrue);
  });

  test('bounds oversized text and rejects invalid UTF-8 as non-text', () async {
    final bounded = await service(
      limits: const WorkspaceReadLimits(maxReadBytes: 32),
    ).readTextRange('${root.path}/large.txt');
    expect(bounded.text, hasLength(32));
    expect(bounded.truncated, isTrue);

    expect(
      () => service().readTextRange('${root.path}/binary.bin'),
      throwsA(
        isA<WorkspaceFileException>().having(
          (error) => error.kind,
          'kind',
          WorkspaceFileErrorKind.nonText,
        ),
      ),
    );
  });

  test('searches within a bounded file and output budget', () async {
    final result = await service(
      limits: const WorkspaceReadLimits(
        maxSearchBytes: 64,
        maxOutputCharacters: 20,
      ),
    ).searchText(root.path, 'needle');

    expect(result.matches, isNotEmpty);
    expect(result.filesExamined, lessThanOrEqualTo(4));
    expect(result.bytesRead, lessThanOrEqualTo(64));
    expect(result.outputCharacters, lessThanOrEqualTo(20));
    expect(result.truncated, isTrue);
  });

  test('supports recursive search only when requested', () async {
    final shallow = await service().searchText(root.path, 'nested');
    final deep =
        await service().searchText(root.path, 'nested', recursive: true);

    expect(shallow.matches, isEmpty);
    expect(deep.matches.single.path, contains('gamma.txt'));
  });

  test('returns cancellation without touching the file', () async {
    final token = WorkspaceReadCancellation()..cancel();
    final result = await service().searchText(
      root.path,
      'needle',
      cancellation: token,
    );

    expect(result.cancelled, isTrue);
    expect(result.filesExamined, 0);
  });

  test('rejects an outside symlink and emits only a sanitized sensitive event',
      () async {
    final secret =
        await File('${root.path}/.env').writeAsString('TOKEN=secret');
    final outsideLink = Link('${root.path}/outside-link');
    await outsideLink.create('${outside.path}/outside.txt');
    final events = <WorkspaceFileEvent>[];
    final reader = service(onEvent: events.add);

    final result = await reader.readTextRange(secret.path);

    expect(result.text, contains('TOKEN'));
    expect(events, hasLength(1));
    expect(events.single.kind, WorkspaceFileEventKind.sensitiveRead);
    expect(events.single.path, '[redacted]');
    expect(events.single.detail, isNot(contains('TOKEN')));
    expect(
      () => reader.readTextRange(outsideLink.path),
      throwsA(isA<WorkspacePathException>()),
    );
  });

  test('redacts sensitive search snippets before they cross the read result',
      () async {
    final sensitive = await File('${root.path}/tokens.env')
        .writeAsString('TOKEN=secret-value');

    // Directory traversal skips sensitive names by default. A direct file
    // request still returns a redacted match for the local service caller.
    final result = await service().searchText(sensitive.path, 'TOKEN');

    expect(result.matches, hasLength(1));
    expect(result.matches.single.sensitive, isTrue);
    expect(result.matches.single.snippet, isNot(contains('secret-value')));
    expect(result.matches.single.snippet, contains('敏感文件内容已隐藏'));
  });

  test('classifies common credential naming variants as sensitive', () {
    final reader = service();

    expect(reader.isSensitivePath('${root.path}/api_key.env'), isTrue);
    expect(reader.isSensitivePath('${root.path}/client_secret.json'), isTrue);
    expect(reader.isSensitivePath('${root.path}/access_token.txt'), isTrue);
    expect(reader.isSensitivePath('${root.path}/private_key.pem'), isTrue);
  });
}
