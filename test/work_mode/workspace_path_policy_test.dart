import 'dart:io';

import 'package:chat_group/features/work_mode/workspace_path_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory sandbox;
  late Directory root;
  late Directory outside;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('workspace-policy-');
    root = await Directory('${sandbox.path}/work').create();
    outside = await Directory('${sandbox.path}/outside').create();
  });

  tearDown(() async {
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  test('resolves existing paths and allows the authorized root itself',
      () async {
    final file = await File('${root.path}/note.txt').writeAsString('hello');
    final policy = WorkspacePathPolicy(
      authorizedRoots: [root.path],
      isWindows: false,
    );

    final resolvedRoot = await policy.resolve(root.path);
    final resolvedFile = await policy.resolve(file.path);

    expect(resolvedRoot.exists, isTrue);
    expect(resolvedRoot.isDirectory, isTrue);
    expect(resolvedFile.path, file.resolveSymbolicLinksSync());
  });

  test('rejects traversal and similarly prefixed directories', () async {
    final sibling = await Directory('${sandbox.path}/workbench').create();
    final policy = WorkspacePathPolicy(
      authorizedRoots: [root.path],
      isWindows: false,
    );

    expect(
      () => policy.resolve('${root.path}/../outside/secret.txt'),
      throwsA(isA<WorkspacePathException>()),
    );
    expect(
      () => policy.resolve('${root.path}\\..\\outside\\secret.txt'),
      throwsA(
        isA<WorkspacePathException>().having(
          (error) => error.kind,
          'kind',
          WorkspacePathErrorKind.invalidPath,
        ),
      ),
    );
    expect(
      () => policy.resolve('${sibling.path}/secret.txt'),
      throwsA(isA<WorkspacePathException>()),
    );
  });

  test('rejects control characters before filesystem resolution', () async {
    final policy = WorkspacePathPolicy(
      authorizedRoots: [root.path],
      isWindows: false,
    );

    expect(
      () => policy.resolve('${root.path}/notes\n.txt'),
      throwsA(
        isA<WorkspacePathException>().having(
          (error) => error.kind,
          'kind',
          WorkspacePathErrorKind.invalidPath,
        ),
      ),
    );
  });

  test('resolves a missing target through its nearest real parent', () async {
    final nested = await Directory('${root.path}/nested').create();
    final link = Link('${root.path}/inside-link');
    await link.create(nested.path);
    final policy = WorkspacePathPolicy(
      authorizedRoots: [root.path],
      isWindows: false,
    );

    final resolved = await policy.resolveNewTarget('${link.path}/new.txt');

    expect(resolved.exists, isFalse);
    expect(resolved.nearestExistingParent, nested.resolveSymbolicLinksSync());
    expect(
      resolved.path,
      '${nested.resolveSymbolicLinksSync()}/new.txt',
    );
    expect(resolved.isAuthorized, isTrue);
  });

  test('rejects a symlink that resolves outside the authorized root', () async {
    final secret = await File('${outside.path}/secret.txt').writeAsString('x');
    final link = Link('${root.path}/outside-link');
    await link.create(secret.path);
    final policy = WorkspacePathPolicy(
      authorizedRoots: [root.path],
      isWindows: false,
    );

    expect(
      () => policy.resolve(link.path),
      throwsA(
        isA<WorkspacePathException>().having(
          (error) => error.kind,
          'kind',
          WorkspacePathErrorKind.symlinkEscape,
        ),
      ),
    );
  });

  test('reports a broken symlink instead of treating it as a new file',
      () async {
    final link = Link('${root.path}/broken-link');
    await link.create('${outside.path}/missing.txt');
    final policy = WorkspacePathPolicy(
      authorizedRoots: [root.path],
      isWindows: false,
    );

    expect(
      () => policy.resolve(link.path),
      throwsA(
        isA<WorkspacePathException>().having(
          (error) => error.kind,
          'kind',
          WorkspacePathErrorKind.brokenSymlink,
        ),
      ),
    );
  });

  // ponytail: Native Windows I/O runs in the Windows matrix; this test keeps
  // the separator, drive-case, and segment rules platform-independent.
  test('provides deterministic Windows normalization and segment checks', () {
    expect(
      WorkspacePathPolicy.normalizePath(
        r'c:\Work\Project\..\Project',
        isWindows: true,
      ),
      'C:/Work/Project',
    );
    expect(
      WorkspacePathPolicy.isWithinRoot(
        r'C:\Work\Project',
        r'c:\work\project\file.txt',
        isWindows: true,
      ),
      isTrue,
    );
    expect(
      WorkspacePathPolicy.isWithinRoot(
        'C:/Work/Project',
        'C:/Work/Project-old/file.txt',
        isWindows: true,
      ),
      isFalse,
    );
    expect(
      WorkspacePathPolicy.isWithinRoot(
        '/work/a',
        '/work/ab/file.txt',
      ),
      isFalse,
    );
  });
}
