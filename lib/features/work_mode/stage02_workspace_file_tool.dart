import 'dart:convert';
import 'dart:io';

import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/work_mode/work_approval_decision.dart';
import 'package:chat_group/features/work_mode/work_approval_fingerprint.dart';
import 'package:chat_group/features/work_mode/work_change_plan.dart';
import 'package:chat_group/features/work_mode/workspace_file_service.dart';
import 'package:chat_group/features/work_mode/workspace_mutation_service.dart';
import 'package:chat_group/features/work_mode/workspace_path_policy.dart';
import 'package:chat_group/features/work_mode/work_resource_lock_manager.dart';
import 'package:crypto/crypto.dart';

/// In-process Stage 02 tool boundary. No cross-process service is created
/// here: every path is resolved against the configured grant and every
/// mutation is checked against a task-scoped approval scope.
class Stage02WorkspaceFileTool {
  final WorkspaceFileService files;
  final WorkspaceMutationService mutations;
  final WorkspacePathPolicy pathPolicy;
  final AgentTask task;
  final String workspaceRoot;
  final WorkApprovalScope? approvalScope;
  final WorkChangeApprovalDecision? approvalDecision;

  /// Exact sensitive-read operation approved for this task. A general
  /// mutation decision is deliberately not accepted as a substitute.
  final String? approvedSensitiveOperation;
  final String? approvalCapability;
  final bool allowImplicitScope;
  final bool allowWithoutUndo;
  final WorkResourceLockManager? resourceLockManager;
  final void Function(String path, String operation)? onSensitiveRead;

  Stage02WorkspaceFileTool({
    required this.files,
    required this.mutations,
    required this.pathPolicy,
    required this.task,
    required this.workspaceRoot,
    this.approvalScope,
    this.approvalDecision,
    this.approvedSensitiveOperation,
    this.approvalCapability,
    this.allowImplicitScope = false,
    this.allowWithoutUndo = false,
    this.resourceLockManager,
    this.onSensitiveRead,
  });

  bool get acceptsAbsolutePaths => true;

  bool isSensitivePath(String path) => files.isSensitivePath(path);

  /// Returns the token the runner stores when a sensitive read is paused.
  /// Resolution happens before hashing so relative and absolute spellings of
  /// the same authorized path cannot accidentally create two approvals.
  String sensitiveReadFingerprint({
    required String operation,
    required String path,
    int startByte = 0,
    int? byteLength,
    String? query,
    bool recursive = false,
    bool caseSensitive = true,
  }) {
    return WorkApprovalFingerprint.sensitiveRead(
      operation: operation,
      path: _absolutePath(path),
      startByte: startByte,
      byteLength: byteLength,
      query: query,
      recursive: recursive,
      caseSensitive: caseSensitive,
    );
  }

  Future<Map<String, dynamic>> list({String path = '.'}) =>
      listWithOptions(path: path);

  Future<Map<String, dynamic>> listWithOptions({
    String path = '.',
    int page = 0,
    int pageSize = 200,
    bool recursive = false,
  }) async {
    try {
      final resolved = await pathPolicy.resolveExisting(_absolutePath(path));
      final result = await _withReadLock(
        resolved.path,
        () => files.listDirectory(
          resolved.path,
          page: page,
          pageSize: pageSize,
          recursive: recursive,
        ),
      );
      return {
        'ok': true,
        'path': resolved.path,
        'entries': result.entries
            .map(
              (entry) => <String, dynamic>{
                'name': entry.name,
                'path': entry.path,
                'type': entry.type == FileSystemEntityType.directory
                    ? 'directory'
                    : entry.type == FileSystemEntityType.link
                        ? 'link'
                        : 'file',
              },
            )
            .toList(growable: false),
        'page': result.page,
        'pageSize': result.pageSize,
        'recursive': result.recursive,
        'truncated': result.truncated,
        'hasMore': result.hasMore,
        'filesExamined': result.filesExamined,
      };
    } on WorkspacePathException catch (error) {
      return _pathError(error, path);
    } on WorkspaceFileException catch (error) {
      return _fileError(error);
    }
  }

  Future<Map<String, dynamic>> read(String path) => readWithOptions(path);

  Future<Map<String, dynamic>> readWithOptions(
    String path, {
    int startByte = 0,
    int? byteLength,
    bool allowSensitive = false,
  }) async {
    try {
      final absolutePath = _absolutePath(path);
      // Do not read a sensitive file into the local service before the user has
      // approved this exact file. The path policy check still proves the path
      // exists and is inside a confirmed grant, while the second resolution in
      // WorkspaceFileService closes the small filesystem race before reading.
      final resolved = await pathPolicy.resolveExisting(absolutePath);
      final sensitivePath = resolved.isFile &&
          (files.isSensitivePath(absolutePath) ||
              files.isSensitivePath(resolved.path));
      final sensitiveReadAllowed = allowSensitive &&
          approvalDecision?.permitsExecution == true &&
          approvalCapability == WorkApprovalCapability.sensitiveRead &&
          !resolved.isDirectory &&
          approvedSensitiveOperation ==
              sensitiveReadFingerprint(
                operation: 'readTextRange',
                path: path,
                startByte: startByte,
                byteLength: byteLength,
              );
      if (!sensitiveReadAllowed && resolved.isFile && sensitivePath) {
        onSensitiveRead?.call(resolved.path, 'readTextRange');
        return {
          'ok': false,
          'error': 'sensitive_read_requires_approval',
          'requiresApproval': true,
          'path': resolved.path,
          'sensitive': true,
          'redacted': true,
          'content': '[敏感文件内容已隐藏]',
          'bytesRead': 0,
        };
      }
      final result = await _withReadLock(
        resolved.path,
        () => files.readTextRange(
          resolved.path,
          startByte: startByte,
          byteLength: byteLength,
        ),
      );
      final sensitive = result.sensitive || sensitivePath;
      if (sensitive && !sensitiveReadAllowed) {
        onSensitiveRead?.call(result.path, 'readTextRange');
        return {
          'ok': false,
          'error': 'sensitive_read_requires_approval',
          'requiresApproval': true,
          'path': result.path,
          'sensitive': true,
          'redacted': true,
          'content': '[敏感文件内容已隐藏]',
          'bytesRead': result.bytesRead,
        };
      }
      return {
        'ok': true,
        'path': result.path,
        'content': result.text,
        'bytesRead': result.bytesRead,
        'truncated': result.truncated,
        'sensitive': sensitive,
        'redacted': false,
      };
    } on WorkspacePathException catch (error) {
      return _pathError(error, path);
    } on WorkspaceFileException catch (error) {
      return _fileError(error);
    }
  }

  Future<Map<String, dynamic>> search(
    String path,
    String query, {
    bool recursive = false,
    bool caseSensitive = true,
    bool allowSensitive = false,
  }) async {
    try {
      final absolutePath = _absolutePath(path);
      final resolved = await pathPolicy.resolveExisting(absolutePath);
      final sensitivePath = resolved.isFile &&
          (files.isSensitivePath(absolutePath) ||
              files.isSensitivePath(resolved.path));
      // Directory searches never inherit a sensitive-file approval: the
      // exact file is unknown until after scanning. Only a direct file search
      // with the matching operation token may return sensitive snippets.
      final sensitiveReadAllowed = allowSensitive &&
          approvalDecision?.permitsExecution == true &&
          approvalCapability == WorkApprovalCapability.sensitiveRead &&
          resolved.isFile &&
          approvedSensitiveOperation ==
              sensitiveReadFingerprint(
                operation: 'search',
                path: path,
                query: query,
                recursive: recursive,
                caseSensitive: caseSensitive,
              );
      if (!sensitiveReadAllowed && resolved.isFile && sensitivePath) {
        return {
          'ok': false,
          'error': 'sensitive_search_requires_approval',
          'requiresApproval': true,
          'sensitive': true,
          'redacted': true,
          'path': resolved.path,
          'query': query,
          'message': '搜索指定的敏感文件需要批准后才能读取。',
        };
      }
      final result = await _withReadLock(
        resolved.path,
        () => files.searchText(
          resolved.path,
          query,
          recursive: recursive,
          caseSensitive: caseSensitive,
          allowSensitive: sensitiveReadAllowed,
        ),
      );
      final sensitiveMatches = result.matches
          .where((match) => match.sensitive || sensitivePath)
          .length;
      if ((sensitiveMatches > 0 || (resolved.isFile && sensitivePath)) &&
          !sensitiveReadAllowed) {
        return {
          'ok': false,
          'error': 'sensitive_search_requires_approval',
          'requiresApproval': true,
          'sensitive': true,
          'redacted': true,
          'sensitiveMatches': sensitiveMatches,
          'path': absolutePath,
          'query': result.query,
          'filesExamined': result.filesExamined,
          'bytesRead': result.bytesRead,
          'message': '搜索命中了敏感文件，需要批准后才能返回匹配内容。',
        };
      }
      return {
        'ok': true,
        'path': absolutePath,
        'query': result.query,
        'matches': result.matches
            .map(
              (match) => <String, dynamic>{
                'path': match.path,
                'line': match.line,
                'column': match.column,
                'snippet': match.snippet,
                'sensitive': match.sensitive || sensitivePath,
              },
            )
            .toList(growable: false),
        'truncated': result.truncated,
        'filesExamined': result.filesExamined,
        'bytesRead': result.bytesRead,
        'nonTextFiles': result.nonTextFiles,
      };
    } on WorkspacePathException catch (error) {
      return _pathError(error, path);
    } on WorkspaceFileException catch (error) {
      return _fileError(error);
    }
  }

  Future<Map<String, dynamic>> write(String path, String content) async {
    try {
      final absolute = _absolutePath(path);
      final resolved = await pathPolicy.resolve(absolute, allowMissing: true);
      final action = resolved.exists
          ? WorkChangeActionType.modify
          : WorkChangeActionType.create;
      if (resolved.exists && !resolved.isFile) {
        return {
          'ok': false,
          'error': 'not_a_file',
          'message': '目标不是普通文件，未执行写入。',
          'path': resolved.path,
        };
      }
      final sensitive = files.isSensitivePath(absolute) ||
          files.isSensitivePath(resolved.path);
      final plan = _filePlan(
        action: action,
        path: resolved.path,
        directory: resolved.authorizedRoot,
        bytes: utf8.encode(content).length,
      );
      // Do not hash a sensitive file until the task carries both an explicit
      // approval and an exact scope covering this concrete plan. Hashing reads
      // old contents before the mutation boundary can return its redacted
      // approval response, so the scope check must precede it.
      final sensitiveApproved = approvalDecision?.permitsExecution == true &&
          approvalScope?.allows(plan) == true;
      if (sensitive && !sensitiveApproved) {
        return {
          'ok': false,
          'error': 'sensitive_mutation_requires_approval',
          'requiresApproval': true,
          'sensitive': true,
          'redacted': true,
          'message': '修改、重命名或删除敏感文件必须再次确认。',
          'path': resolved.path,
        };
      }
      final expectedSha = action == WorkChangeActionType.modify
          ? await _hashFile(File(resolved.path))
          : null;
      return _execute(
        plan,
        WorkspaceMutationRequest(
          path: resolved.path,
          contents: content,
          expectedSha256: expectedSha,
          approvalDecision: approvalDecision,
        ),
        sensitivePath: sensitive,
      );
    } on WorkspacePathException catch (error) {
      return _pathError(error, path);
    } on FileSystemException {
      return {'ok': false, 'error': 'io', 'message': '无法读取目标文件。'};
    }
  }

  Future<Map<String, dynamic>> applyPatch(String patch) async {
    // A diff is always a multi-file/overwrite operation; unlike a simple
    // create in a fixture, it needs a task scope unless the user has
    // explicitly disabled ordinary-write confirmations. In that setting the
    // fully resolved one-file plan below is still used to derive a narrow
    // implicit scope; it never becomes a wildcard permission.
    if (approvalScope == null && !allowImplicitScope) {
      return {
        'ok': false,
        'error': 'stage02_patch_requires_plan',
        'message': 'Stage 02 补丁必须先获得任务级变更计划批准。',
      };
    }
    try {
      final decoded = jsonDecode(patch);
      if (decoded is! Map) {
        throw const FormatException('patch must be an object');
      }
      final path = decoded['path']?.toString() ?? '';
      final expectedSha = decoded['expectedSha256']?.toString();
      final fragment = decoded['expectedFragment']?.toString();
      final replacement = decoded['replacement']?.toString();
      if (path.isEmpty ||
          expectedSha == null ||
          fragment == null ||
          replacement == null) {
        return {
          'ok': false,
          'error': 'invalid_patch',
          'message': '补丁缺少精确路径或原文校验字段。',
        };
      }
      final resolved = await pathPolicy.resolveExisting(_absolutePath(path));
      final plan = _filePlan(
        action: WorkChangeActionType.patch,
        path: resolved.path,
        directory: resolved.authorizedRoot,
        bytes: utf8.encode(replacement).length,
      );
      return _execute(
        plan,
        WorkspaceMutationRequest.patch(
          path: resolved.path,
          expectedSha256: expectedSha,
          expectedFragment: fragment,
          replacement: replacement,
        ),
        sensitivePath:
            files.isSensitivePath(path) || files.isSensitivePath(resolved.path),
      );
    } on FormatException {
      return {'ok': false, 'error': 'invalid_patch', 'message': '补丁格式无效。'};
    } on WorkspacePathException catch (error) {
      return _pathError(error, 'patch');
    }
  }

  Future<Map<String, dynamic>> rename(
    String path,
    String destinationPath,
  ) async {
    try {
      final source = await pathPolicy.resolveExisting(_absolutePath(path));
      final destination = await pathPolicy.resolveNewTarget(
        _absolutePath(destinationPath),
      );
      final snapshot = mutations.snapshotPort != null;
      final plan = WorkChangePlan(
        taskId: task.id,
        actionType: WorkChangeActionType.rename,
        exactPaths: [source.path, destination.path],
        knownAffectedDirectories: {
          source.authorizedRoot,
          destination.authorizedRoot,
        }.toList(growable: false),
        estimatedBytes: 0,
        snapshotAvailable: snapshot,
        reversible: snapshot,
        riskReason: '工作模式需要在授权目录内重命名文件。',
      );
      return _execute(
        plan,
        WorkspaceMutationRequest.rename(
          sourcePath: source.path,
          destinationPath: destination.path,
        ),
        sensitivePath: files.isSensitivePath(path) ||
            files.isSensitivePath(destinationPath) ||
            files.isSensitivePath(source.path) ||
            files.isSensitivePath(destination.path),
      );
    } on WorkspacePathException catch (error) {
      return _pathError(error, destinationPath);
    }
  }

  Future<Map<String, dynamic>> delete(String path) async {
    try {
      final resolved = await pathPolicy.resolveExisting(_absolutePath(path));
      final plan = _filePlan(
        action: WorkChangeActionType.delete,
        path: resolved.path,
        directory: resolved.authorizedRoot,
        bytes: 0,
      );
      return _execute(
        plan,
        WorkspaceMutationRequest.delete(path: resolved.path),
        sensitivePath:
            files.isSensitivePath(path) || files.isSensitivePath(resolved.path),
      );
    } on WorkspacePathException catch (error) {
      return _pathError(error, path);
    }
  }

  Future<Map<String, dynamic>> runCommand(String command) async => {
        'ok': false,
        'error': 'command_not_available_in_stage02',
        'message': '当前版本尚未接入命令执行器。',
      };

  WorkChangePlan _filePlan({
    required WorkChangeActionType action,
    required String path,
    required String directory,
    required int bytes,
  }) {
    final snapshot = mutations.snapshotPort != null;
    return WorkChangePlan(
      taskId: task.id,
      actionType: action,
      exactPaths: [path],
      knownAffectedDirectories: [directory],
      estimatedBytes: bytes,
      snapshotAvailable: snapshot,
      reversible: snapshot,
      riskReason: switch (action) {
        WorkChangeActionType.create => '工作模式需要在授权目录内创建文件。',
        WorkChangeActionType.modify => '工作模式需要在授权目录内原子替换文件。',
        WorkChangeActionType.patch => '工作模式需要在授权目录内应用精确补丁。',
        WorkChangeActionType.delete => '工作模式需要删除一个授权目录内的普通文件。',
        _ => '工作模式需要修改授权目录内的文件。',
      },
    );
  }

  Future<Map<String, dynamic>> _execute(
      WorkChangePlan plan, WorkspaceMutationRequest request,
      {bool sensitivePath = false}) async {
    if (!allowImplicitScope && approvalDecision == null) {
      return {
        'ok': false,
        'error': WorkspaceMutationStatus.notApproved.name,
        'message': '文件变更缺少本任务的明确用户批准。',
      };
    }
    if (approvalDecision != null && approvalScope == null) {
      return {
        'ok': false,
        'error': WorkspaceMutationStatus.notApproved.name,
        'message': '审批范围缺失，已要求任务重新生成变更计划。',
      };
    }
    final scope = approvalScope ??
        (allowImplicitScope ? WorkApprovalScope.fromPlan(plan) : null);
    if (scope == null || !scope.allows(plan)) {
      return {
        'ok': false,
        'error': WorkspaceMutationStatus.notApproved.name,
        'message': '当前路径或动作不在已批准的精确范围内。',
      };
    }
    final sensitiveMutation =
        sensitivePath || plan.exactPaths.any(files.isSensitivePath);
    if (approvalDecision == null && sensitiveMutation) {
      // Sensitive mutations require a second, task-bound confirmation even
      // when ordinary confirmations were disabled in Settings. Keeping this
      // check in the tool boundary also protects direct callers that do not
      // go through DefaultWorkTaskRunner's request policy.
      return {
        'ok': false,
        'error': 'sensitive_mutation_requires_approval',
        'requiresApproval': true,
        'sensitive': true,
        'redacted': true,
        'message': '修改、重命名或删除敏感文件必须再次确认。',
      };
    }
    if (pathPolicy.grantService != null &&
        await _hasReadOnlyTarget(plan.exactPaths)) {
      return {
        'ok': false,
        'error': 'folder_not_writable',
        'requiresFolderGrant': true,
        'requestedPath': plan.exactPaths.first,
        'message': '目标目录当前只读，需要重新选择可写工作目录。',
      };
    }
    return _withMutationLock(
      plan,
      () async {
        final result = await mutations.execute(
          plan: plan,
          approvalScope: scope,
          approvalDecision: approvalDecision,
          allowWithoutUndo: allowWithoutUndo,
          request: request,
        );
        final response = <String, dynamic>{
          'ok': result.succeeded,
          'path': result.destinationPath ?? result.path,
          'sourcePath': result.path,
          'bytes': result.bytesWritten,
          if (sensitiveMutation) 'sensitive': true,
          if (sensitiveMutation) 'redacted': true,
          if (!result.succeeded) 'error': result.status.name,
          if (!result.succeeded) 'message': result.reason,
          if (result.mutationCommitted) 'mutationCommitted': true,
          if (result.status == WorkspaceMutationStatus.snapshotUnavailable)
            'requiresApproval': true,
          if (result.status == WorkspaceMutationStatus.snapshotUnavailable)
            'noUndoRequired': true,
        };
        // Every successful mutation gets a second, independent filesystem
        // check while the same write lock is still held. This prevents another
        // task from changing the target between the mutation and validation.
        if (result.succeeded || result.mutationCommitted) {
          final validation = await _verifyPostcondition(plan, result);
          response['validation'] = validation.toJson();
          if (!validation.valid) {
            response
              ..['ok'] = false
              ..['error'] = 'postcondition_unverified'
              ..['message'] = validation.message
              ..['mutationCommitted'] = true;
          }
        }
        return response;
      },
    );
  }

  Future<T> _withReadLock<T>(String path, Future<T> Function() operation) {
    final manager = resourceLockManager;
    if (manager == null) return operation();
    return manager.withLocks(
      task.id,
      [WorkResourceLockRequest.read(path)],
      operation,
    );
  }

  Future<T> _withMutationLock<T>(
    WorkChangePlan plan,
    Future<T> Function() operation,
  ) {
    final manager = resourceLockManager;
    if (manager == null) return operation();
    final paths = <String>{
      ...plan.knownAffectedDirectories,
      ...plan.exactPaths,
    };
    return manager.withLocks(
      task.id,
      paths.map(WorkResourceLockRequest.treeWrite),
      operation,
    );
  }

  Future<_PostconditionResult> _verifyPostcondition(
    WorkChangePlan plan,
    WorkspaceMutationResult result,
  ) async {
    try {
      switch (plan.actionType) {
        case WorkChangeActionType.create:
        case WorkChangeActionType.modify:
        case WorkChangeActionType.patch:
          final target =
              await pathPolicy.resolveExisting(plan.exactPaths.first);
          return target.isFile
              ? const _PostconditionResult(
                  valid: true,
                  message: '已重新检查目标文件，文件仍可读取。',
                )
              : const _PostconditionResult(
                  valid: false,
                  message: '变更已提交，但最终检查发现目标不是普通文件。',
                );
        case WorkChangeActionType.rename:
          if (plan.exactPaths.length < 2) {
            return const _PostconditionResult(
              valid: false,
              message: '变更已提交，但重命名计划缺少目标路径。',
            );
          }
          final source = await pathPolicy.resolve(
            plan.exactPaths.first,
            allowMissing: true,
          );
          final destinationPath = result.destinationPath ?? plan.exactPaths[1];
          final destination = await pathPolicy.resolveExisting(destinationPath);
          if (!source.exists && destination.isFile) {
            return const _PostconditionResult(
              valid: true,
              message: '已重新检查源路径和目标文件，重命名结果符合计划。',
            );
          }
          return const _PostconditionResult(
            valid: false,
            message: '变更已提交，但最终检查未确认源路径消失且目标文件存在。',
          );
        case WorkChangeActionType.delete:
          final target = await pathPolicy.resolve(
            plan.exactPaths.first,
            allowMissing: true,
          );
          return !target.exists
              ? const _PostconditionResult(
                  valid: true,
                  message: '已重新检查精确路径，目标已不存在。',
                )
              : const _PostconditionResult(
                  valid: false,
                  message: '变更已提交，但最终检查发现删除目标仍然存在。',
                );
        case WorkChangeActionType.command:
          return const _PostconditionResult(
            valid: false,
            message: 'Stage 02 不允许通过文件工具执行命令。',
          );
      }
    } on Object {
      return const _PostconditionResult(
        valid: false,
        message: '变更已提交，但最终路径检查失败。',
      );
    }
  }

  Future<bool> _hasReadOnlyTarget(Iterable<String> paths) async {
    final grants = pathPolicy.grantService;
    if (grants == null) return false;
    for (final path in paths) {
      if (!await grants.isPathWritableResolved(path)) return true;
    }
    return false;
  }

  String _absolutePath(String rawPath) {
    final value = rawPath.trim();
    if (value.isEmpty) throw ArgumentError('Workspace path cannot be empty.');
    if (_containsParentTraversal(value)) {
      throw const WorkspacePathException(
        WorkspacePathErrorKind.invalidPath,
        '路径不能包含 ..。',
      );
    }
    final isAbsolute = value.startsWith('/') ||
        value.startsWith('\\') ||
        RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value);
    final combined =
        isAbsolute ? value : '${workspaceRoot.replaceAll('\\', '/')}/$value';
    return WorkspacePathPolicy.normalizePath(
      combined,
      isWindows: pathPolicy.isWindows,
    );
  }

  bool _containsParentTraversal(String path) =>
      path.replaceAll('\\', '/').split('/').any((segment) => segment == '..');

  Map<String, dynamic> _pathError(WorkspacePathException error, String raw) => {
        'ok': false,
        'error': error.kind.name,
        'message': error.reason,
        'requiresFolderGrant':
            error.kind == WorkspacePathErrorKind.notAuthorized ||
                error.kind == WorkspacePathErrorKind.symlinkEscape,
        'requestedPath': error.path ?? raw,
      };

  Map<String, dynamic> _fileError(WorkspaceFileException error) => {
        'ok': false,
        'error': error.kind.name,
        'message': error.reason,
      };

  Future<String> _hashFile(File file) async {
    final sink = _DigestSink();
    final input = sha256.startChunkedConversion(sink);
    await for (final chunk in file.openRead()) {
      input.add(chunk);
    }
    input.close();
    final digest = sink.value;
    if (digest == null) throw StateError('文件哈希为空');
    return digest.toString();
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest event) => value = event;

  @override
  void close() {}
}

class _PostconditionResult {
  final bool valid;
  final String message;

  const _PostconditionResult({required this.valid, required this.message});

  Map<String, dynamic> toJson() => <String, dynamic>{
        'valid': valid,
        'message': message,
      };
}
