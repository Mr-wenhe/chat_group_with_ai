import 'dart:async';
import 'dart:io';

import 'work_folder_grant_service.dart';

enum WorkspacePathErrorKind {
  invalidPath,
  notFound,
  notAuthorized,
  symlinkEscape,
  brokenSymlink,
  inaccessible,
  timeout,
}

class WorkspacePathException implements Exception {
  final WorkspacePathErrorKind kind;
  final String reason;
  final String? path;

  const WorkspacePathException(this.kind, this.reason, {this.path});

  String get message => reason;

  @override
  String toString() => 'WorkspacePathException: $reason';
}

class WorkspaceResolvedPath {
  final String requestedPath;
  final String path;
  final FileSystemEntityType type;
  final bool exists;
  final bool wasSymbolicLink;
  final String? nearestExistingParent;
  final String authorizedRoot;

  const WorkspaceResolvedPath({
    required this.requestedPath,
    required this.path,
    required this.type,
    required this.exists,
    required this.wasSymbolicLink,
    required this.nearestExistingParent,
    required this.authorizedRoot,
  });

  bool get isFile => type == FileSystemEntityType.file;
  bool get isDirectory => type == FileSystemEntityType.directory;
  bool get isLink => type == FileSystemEntityType.link;
  bool get isAuthorized => true;
  bool get isNewTarget => !exists;
}

class WorkspacePathPolicy {
  static const int maxPathCharacters = 4096;
  static const Duration defaultResolutionTimeout = Duration(seconds: 10);

  final WorkFolderGrantService? grantService;
  final bool isWindows;
  final Duration resolutionTimeout;
  final List<_AuthorizedRoot> _configuredRoots;

  WorkspacePathPolicy({
    this.grantService,
    Iterable<WorkFolderGrant>? grants,
    Iterable<String>? authorizedRoots,
    bool? isWindows,
    this.resolutionTimeout = defaultResolutionTimeout,
  })  : isWindows = isWindows ?? Platform.isWindows,
        _configuredRoots = [
          if (grants != null)
            ...grants.map(
              (grant) => _AuthorizedRoot(
                path: grant.path,
                available: grant.available,
                writable: grant.writable,
              ),
            ),
          if (authorizedRoots != null)
            ...authorizedRoots.map((path) => _AuthorizedRoot(
                  path: path,
                  available: true,
                  writable: true,
                )),
        ] {
    if (resolutionTimeout <= Duration.zero) {
      throw ArgumentError.value(
        resolutionTimeout,
        'resolutionTimeout',
        'must be positive',
      );
    }
  }

  /// Resolves an existing path or, when it is absent, the nearest real parent
  /// plus the missing segments. The latter is needed by a future mutation
  /// layer, while this stage's read methods use [resolveExisting].
  Future<WorkspaceResolvedPath> resolve(
    String rawPath, {
    bool allowMissing = true,
  }) async {
    final budget = _ResolutionBudget(resolutionTimeout);
    final lexical = _validateAndNormalize(rawPath);
    final probe = await _probe(lexical, budget);
    final candidate =
        probe.exists ? probe : await _resolveMissing(lexical, budget);
    final roots = await _resolvedRoots(budget);
    final matchedRoot = roots.cast<_ResolvedRoot?>().firstWhere(
          (root) =>
              root != null &&
              isWithinRoot(root.path, candidate.path, isWindows: isWindows),
          orElse: () => null,
        );
    if (matchedRoot == null) {
      final kind = candidate.wasSymbolicLink
          ? WorkspacePathErrorKind.symlinkEscape
          : WorkspacePathErrorKind.notAuthorized;
      throw WorkspacePathException(
        kind,
        kind == WorkspacePathErrorKind.symlinkEscape
            ? '路径通过符号链接越过授权目录。'
            : '路径不在任何有效授权目录内。',
        path: candidate.path,
      );
    }
    if (!candidate.exists && !allowMissing) {
      throw WorkspacePathException(
        WorkspacePathErrorKind.notFound,
        '目标不存在。',
        path: candidate.path,
      );
    }
    return WorkspaceResolvedPath(
      requestedPath: rawPath,
      path: candidate.path,
      type: candidate.type,
      exists: candidate.exists,
      wasSymbolicLink: candidate.wasSymbolicLink,
      nearestExistingParent: candidate.nearestExistingParent,
      authorizedRoot: matchedRoot.path,
    );
  }

  Future<WorkspaceResolvedPath> resolveExisting(String rawPath) =>
      resolve(rawPath, allowMissing: false);

  Future<WorkspaceResolvedPath> resolveNewTarget(String rawPath) =>
      resolve(rawPath, allowMissing: true);

  /// Returns whether a target is covered by a currently writable capability.
  /// Explicit in-process roots (used by tests and local integrations) are
  /// treated as writable; grant-backed roots use the OS validation result.
  bool isPathWritable(String rawPath) {
    final grants = grantService;
    if (grants != null) return grants.isPathWritable(rawPath);
    try {
      final normalized = _validateAndNormalize(rawPath);
      return _configuredRoots.any(
        (root) =>
            root.available &&
            root.writable &&
            isWithinRoot(root.path, normalized, isWindows: isWindows),
      );
    } on Object {
      return false;
    }
  }

  static String normalizePath(String rawPath, {bool isWindows = false}) =>
      WorkFolderGrantService.normalizePath(rawPath, isWindows: isWindows);

  /// Segment comparison deliberately avoids string-prefix authorization.
  static bool isWithinRoot(
    String root,
    String candidate, {
    bool isWindows = false,
  }) {
    final rootSegments = _pathSegments(
      normalizePath(root, isWindows: isWindows),
      isWindows: isWindows,
    );
    final candidateSegments = _pathSegments(
      normalizePath(candidate, isWindows: isWindows),
      isWindows: isWindows,
    );
    if (rootSegments.length > candidateSegments.length) return false;
    for (var index = 0; index < rootSegments.length; index++) {
      if (_comparisonKey(rootSegments[index], isWindows: isWindows) !=
          _comparisonKey(candidateSegments[index], isWindows: isWindows)) {
        return false;
      }
    }
    return true;
  }

  String _validateAndNormalize(String rawPath) {
    final value = rawPath.trim();
    if (value.isEmpty || value.length > maxPathCharacters) {
      throw const WorkspacePathException(
        WorkspacePathErrorKind.invalidPath,
        '路径为空或超过长度上限。',
      );
    }
    if (RegExp(r'[\u0000-\u001f\u007f]').hasMatch(value)) {
      throw const WorkspacePathException(
        WorkspacePathErrorKind.invalidPath,
        '路径包含不允许的字符。',
      );
    }
    if (isWindows &&
        RegExp(r'^[A-Za-z]:').hasMatch(value) &&
        !RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value)) {
      throw const WorkspacePathException(
        WorkspacePathErrorKind.invalidPath,
        'Windows 驱动器相对路径不受支持。',
      );
    }
    final segments = value.replaceAll('\\', '/').split('/');
    if (segments.any((segment) => segment == '..')) {
      throw const WorkspacePathException(
        WorkspacePathErrorKind.invalidPath,
        '路径不能包含 ..。',
      );
    }
    try {
      return normalizePath(value, isWindows: isWindows);
    } on Object {
      throw const WorkspacePathException(
        WorkspacePathErrorKind.invalidPath,
        '路径格式无效。',
      );
    }
  }

  Future<List<_ResolvedRoot>> _resolvedRoots(_ResolutionBudget budget) async {
    if (grantService != null) await grantService!.load();
    final configured = _configuredGrantRoots();
    final resolved = <_ResolvedRoot>[];
    for (final root in configured) {
      if (!root.available) continue;
      budget.check();
      String path;
      try {
        path = _validateAndNormalize(root.path);
      } on WorkspacePathException {
        continue;
      }
      _Probe probe;
      try {
        probe = await _probe(path, budget);
      } on WorkspacePathException {
        continue;
      }
      if (probe.exists && probe.type == FileSystemEntityType.directory) {
        resolved.add(_ResolvedRoot(probe.path));
      }
    }
    return resolved;
  }

  List<_AuthorizedRoot> _configuredGrantRoots() {
    if (grantService == null) return _configuredRoots;
    return grantService!.grants
        .where((grant) => grant.cloudDisclosureConfirmedAt != null)
        .map(
          (grant) => _AuthorizedRoot(
            path: grant.path,
            available: grant.available,
            writable: grant.writable,
          ),
        )
        .toList(growable: false);
  }

  Future<_Probe> _probe(String path, _ResolutionBudget budget) async {
    budget.check();
    late final FileSystemEntityType type;
    try {
      type = await _bounded(
        FileSystemEntity.type(path, followLinks: false),
        budget,
      );
    } on WorkspacePathException {
      rethrow;
    } on Object {
      throw WorkspacePathException(
        WorkspacePathErrorKind.inaccessible,
        '无法检查路径可达性。',
        path: path,
      );
    }
    if (type == FileSystemEntityType.notFound) {
      return _Probe.missing(path);
    }
    if (type == FileSystemEntityType.link) {
      try {
        final resolved =
            await _bounded(Link(path).resolveSymbolicLinks(), budget);
        final resolvedPath = normalizePath(resolved, isWindows: isWindows);
        final resolvedType = await _bounded(
          FileSystemEntity.type(resolvedPath),
          budget,
        );
        if (resolvedType == FileSystemEntityType.notFound) {
          throw WorkspacePathException(
            WorkspacePathErrorKind.brokenSymlink,
            '符号链接目标不存在。',
            path: path,
          );
        }
        return _Probe(
          path: resolvedPath,
          type: resolvedType,
          exists: true,
          wasSymbolicLink: true,
        );
      } on WorkspacePathException {
        rethrow;
      } on Object {
        throw WorkspacePathException(
          WorkspacePathErrorKind.brokenSymlink,
          '符号链接无法解析。',
          path: path,
        );
      }
    }
    try {
      final resolved = switch (type) {
        FileSystemEntityType.directory =>
          await _bounded(Directory(path).resolveSymbolicLinks(), budget),
        FileSystemEntityType.file =>
          await _bounded(File(path).resolveSymbolicLinks(), budget),
        _ => path,
      };
      return _Probe(
        path: normalizePath(resolved, isWindows: isWindows),
        type: type,
        exists: true,
        wasSymbolicLink: resolved != path,
      );
    } on WorkspacePathException {
      rethrow;
    } on Object {
      throw WorkspacePathException(
        WorkspacePathErrorKind.inaccessible,
        '无法解析路径。',
        path: path,
      );
    }
  }

  Future<_Probe> _resolveMissing(
    String lexical,
    _ResolutionBudget budget,
  ) async {
    var probePath = lexical;
    final missingSegments = <String>[];
    while (true) {
      budget.check();
      final probe = await _probe(probePath, budget);
      if (probe.exists) {
        if (probe.type != FileSystemEntityType.directory) {
          throw const WorkspacePathException(
            WorkspacePathErrorKind.invalidPath,
            '新目标的最近存在父级不是目录。',
          );
        }
        final candidatePath = _joinPath(probe.path, missingSegments);
        return _Probe(
          path: candidatePath,
          type: FileSystemEntityType.notFound,
          exists: false,
          wasSymbolicLink: probe.wasSymbolicLink || probe.path != probePath,
          nearestExistingParent: probe.path,
        );
      }
      final segment = _lastSegment(probePath);
      if (segment.isEmpty) {
        throw const WorkspacePathException(
          WorkspacePathErrorKind.notFound,
          '找不到最近存在的父目录。',
        );
      }
      missingSegments.insert(0, segment);
      final parent = _parentPath(probePath);
      if (parent == probePath) {
        throw const WorkspacePathException(
          WorkspacePathErrorKind.notFound,
          '找不到最近存在的父目录。',
        );
      }
      probePath = parent;
    }
  }

  Future<T> _bounded<T>(Future<T> operation, _ResolutionBudget budget) {
    final remaining = budget.remaining;
    if (remaining <= Duration.zero) {
      throw const WorkspacePathException(
        WorkspacePathErrorKind.timeout,
        '路径校验超时。',
      );
    }
    return operation.timeout(
      remaining,
      onTimeout: () => throw const WorkspacePathException(
        WorkspacePathErrorKind.timeout,
        '路径校验超时。',
      ),
    );
  }

  static List<String> _pathSegments(
    String path, {
    required bool isWindows,
  }) {
    final normalized = path.replaceAll('\\', '/');
    final segments = normalized.split('/').where((item) => item.isNotEmpty);
    final result = <String>[];
    if (normalized.startsWith('/')) result.add('/');
    result.addAll(segments);
    return result;
  }

  static String _comparisonKey(String value, {required bool isWindows}) =>
      isWindows ? value.toLowerCase() : value;

  String _joinPath(String parent, List<String> segments) {
    if (segments.isEmpty) return parent;
    if (parent == '/' || RegExp(r'^[A-Za-z]:/$').hasMatch(parent)) {
      return normalizePath(
        '$parent${segments.join('/')}',
        isWindows: isWindows,
      );
    }
    return normalizePath(
      '$parent/${segments.join('/')}',
      isWindows: isWindows,
    );
  }

  String _parentPath(String path) {
    if (path == '/' || RegExp(r'^[A-Za-z]:/$').hasMatch(path)) return path;
    final slash = path.lastIndexOf('/');
    if (slash < 0) return path;
    if (slash == 0) return '/';
    if (isWindows && slash == 2 && path.length > 2 && path[1] == ':') {
      return path.substring(0, 3);
    }
    return path.substring(0, slash);
  }

  String _lastSegment(String path) {
    final slash = path.lastIndexOf('/');
    return slash < 0 ? path : path.substring(slash + 1);
  }
}

class _AuthorizedRoot {
  final String path;
  final bool available;
  final bool writable;

  const _AuthorizedRoot({
    required this.path,
    required this.available,
    required this.writable,
  });
}

class _ResolvedRoot {
  final String path;

  const _ResolvedRoot(this.path);
}

class _Probe {
  final String path;
  final FileSystemEntityType type;
  final bool exists;
  final bool wasSymbolicLink;
  final String? nearestExistingParent;

  const _Probe({
    required this.path,
    required this.type,
    required this.exists,
    required this.wasSymbolicLink,
    this.nearestExistingParent,
  });

  const _Probe.missing(String path)
      : this(
          path: path,
          type: FileSystemEntityType.notFound,
          exists: false,
          wasSymbolicLink: false,
        );
}

class _ResolutionBudget {
  final Duration limit;
  final Stopwatch _stopwatch = Stopwatch()..start();

  _ResolutionBudget(this.limit);

  Duration get remaining {
    final left = limit - _stopwatch.elapsed;
    return left.isNegative ? Duration.zero : left;
  }

  void check() {
    if (remaining <= Duration.zero) {
      throw const WorkspacePathException(
        WorkspacePathErrorKind.timeout,
        '路径校验超时。',
      );
    }
  }
}
