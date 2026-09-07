import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:chat_group/core/models/media_attachment.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/attachment_data_uri.dart';
import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/chat_group/multimodal_content.dart';
import 'package:chat_group/features/document/document_understanding_service.dart';

import '../agentic/tool_request.dart';
import 'work_tool_registry.dart';
import 'workspace_path_policy.dart';

part 'work_document_tool_support.dart';

/// Stage 04 / Task 22 document tool.
///
/// The tool owns only the work-mode boundary: authorization, attachment
/// adaptation and result shaping. All document parsing/chunking stays in
/// [DocumentUnderstandingService] and all image payload shaping stays in the
/// existing multimodal content builder.
class WorkDocumentTool {
  final WorkspacePathPolicy pathPolicy;
  final String? workspaceRoot;
  final ModelCapability modelCapability;
  final DocumentTextReader? readText;
  final AsyncFileBytesReader? readBytes;
  final bool Function(String path)? isSensitivePath;
  final bool Function(String path)? allowSensitivePath;
  final void Function(String path)? onSensitiveRead;

  const WorkDocumentTool({
    required this.pathPolicy,
    this.workspaceRoot,
    required this.modelCapability,
    this.readText,
    this.readBytes,
    this.isSensitivePath,
    this.allowSensitivePath,
    this.onSensitiveRead,
  });

  /// Creates the read-only registry definition used by the production loop.
  static WorkToolDefinition definition({
    required WorkspacePathPolicy pathPolicy,
    String? workspaceRoot,
    required ModelCapability modelCapability,
    DocumentTextReader? readText,
    AsyncFileBytesReader? readBytes,
    bool Function(String path)? isSensitivePath,
    bool Function(String path)? allowSensitivePath,
    void Function(String path)? onSensitiveRead,
  }) {
    final tool = WorkDocumentTool(
      pathPolicy: pathPolicy,
      workspaceRoot: workspaceRoot,
      modelCapability: modelCapability,
      readText: readText,
      readBytes: readBytes,
      isSensitivePath: isSensitivePath,
      allowSensitivePath: allowSensitivePath,
      onSensitiveRead: onSensitiveRead,
    );
    return WorkToolDefinition(
      name: AgentToolName.workspaceDocument,
      access: WorkToolAccess.readOnly,
      schema: const WorkToolSchema(
        fields: {
          'path': WorkToolValueType.string,
          'query': WorkToolValueType.string,
        },
        required: {'path'},
      ),
      handler: tool.execute,
    );
  }

  /// Reads one authorized workspace file and returns only model-safe chunks.
  Future<WorkToolResult> execute(WorkToolInvocation invocation) async {
    final rawPath = invocation.arguments['path'];
    if (rawPath is! String || rawPath.trim().isEmpty) {
      return const WorkToolResult.pathRejected(message: '文档路径不能为空。');
    }
    if (invocation.context.isCancelled) {
      return const WorkToolResult.paused(message: '工具执行已停止。');
    }

    final resolution = await _resolvePath(rawPath, invocation);
    final resolutionError = resolution.error;
    if (resolutionError != null) return resolutionError;
    final resolved = resolution.path!;
    if (invocation.context.isCancelled) {
      return const WorkToolResult.paused(message: '工具执行已停止。');
    }
    if (!resolved.isFile) {
      return _pathRejected(rawPath, '目标不是文件。');
    }

    final fileName = _basename(resolved.path);
    final statResult = await _statFile(resolved.path, fileName);
    final statError = statResult.error;
    if (statError != null) return statError;
    final stat = statResult.stat!;
    final mimeType = _mimeType(fileName);
    final kind = _mediaKind(fileName, mimeType);
    if (kind == _MediaKind.audio || kind == _MediaKind.video) {
      return _unsupportedMedia(fileName, kind);
    }
    final sensitiveResult = _sensitiveResult(rawPath, resolved.path, fileName);
    if (sensitiveResult != null) return sensitiveResult;
    if (kind == _MediaKind.image) {
      return _readImage(
          invocation, resolved.path, fileName, stat.size, mimeType);
    }
    return _readDocument(
      invocation,
      resolved.path,
      fileName,
      stat.size,
      mimeType,
    );
  }

  Future<({WorkspaceResolvedPath? path, WorkToolResult? error})> _resolvePath(
    String rawPath,
    WorkToolInvocation invocation,
  ) async {
    try {
      // This is deliberately the first filesystem operation. The parser and
      // image builder receive only the canonical path after this gate passes.
      final resolved = await _cancellable(
        pathPolicy.resolveExisting(_effectivePath(rawPath)),
        invocation,
      );
      if (resolved == null) {
        return (
          path: null,
          error: const WorkToolResult.paused(message: '工具执行已停止。'),
        );
      }
      return (path: resolved, error: null);
    } on WorkspacePathException catch (error) {
      return (
        path: null,
        error: _pathRejected(rawPath, _pathReason(error.kind))
      );
    } on Object {
      return (path: null, error: _pathRejected(rawPath, '路径校验失败。'));
    }
  }

  Future<({FileStat? stat, WorkToolResult? error})> _statFile(
    String path,
    String fileName,
  ) async {
    try {
      return (stat: await File(path).stat(), error: null);
    } on Object {
      return (
        stat: null,
        error: WorkToolResult.failed(
          message: '无法读取 $fileName 的文件信息。',
          failureCode: 'documentReadFailed',
          data: {'fileName': fileName},
        ),
      );
    }
  }

  WorkToolResult? _sensitiveResult(
    String rawPath,
    String resolvedPath,
    String fileName,
  ) {
    final sensitive = isSensitivePath?.call(rawPath) == true ||
        isSensitivePath?.call(resolvedPath) == true;
    if (!sensitive || allowSensitivePath?.call(rawPath) == true) return null;
    onSensitiveRead?.call(rawPath);
    return WorkToolResult.waitingForApproval(
      message: '读取敏感文件 $fileName 需要用户确认。',
      data: {
        'fileName': fileName,
        'requiresApproval': true,
        'sensitive': true,
      },
    );
  }

  static WorkToolResult _pathRejected(String path, String reason) =>
      WorkToolResult.pathRejected(
        message: '未读取 ${_basename(path)}：$reason',
        data: {'fileName': _basename(path), 'pathRejected': true},
      );

  Future<WorkToolResult> _readDocument(
    WorkToolInvocation invocation,
    String path,
    String fileName,
    int fileSize,
    String? mimeType,
  ) async {
    final attachment = MediaAttachment(
      type: 'file',
      localPath: path,
      fileName: fileName,
      fileSize: fileSize,
      mimeType: mimeType,
    );
    if (!DocumentUnderstandingService.supports(attachment)) {
      return _unsupportedDocument(fileName);
    }

    final parsed = await _parseDocument(invocation, attachment);
    if (parsed == null || invocation.context.isCancelled) {
      return const WorkToolResult.paused(message: '工具执行已停止。');
    }
    final failure = _documentFailure(fileName, parsed);
    if (failure != null) return failure;

    final query = _query(invocation);
    final context = DocumentUnderstandingService.buildPromptContextFromChunks(
      query: query,
      chunks: parsed.chunks,
    );
    if (invocation.context.isCancelled) {
      return const WorkToolResult.paused(message: '工具执行已停止。');
    }
    final relevant = DocumentUnderstandingService.selectRelevantChunks(
      query: query,
      chunks: parsed.chunks,
    );
    return WorkToolResult.success(
      message: _documentMessage(fileName, relevant),
      data: {
        'content': context,
        'fileName': fileName,
        'format': _extension(fileName),
        'chunkCount': relevant.length,
        'sources': relevant.map(_sourceData).toList(growable: false),
        'unsupportedMedia': false,
      },
    );
  }

  Future<DocumentParseResult?> _parseDocument(
    WorkToolInvocation invocation,
    MediaAttachment attachment,
  ) async {
    final token = _documentToken(invocation);
    final parsed = await _cancellable(
      DocumentUnderstandingService.parse(
        attachment,
        readText: readText,
        cancelToken: token,
      ),
      invocation,
    );
    if (parsed == null || invocation.context.isCancelled) token.cancel();
    return parsed;
  }

  DocumentProcessingToken _documentToken(WorkToolInvocation invocation) {
    final token = DocumentProcessingToken();
    _forwardCancellation(invocation, token);
    return token;
  }

  static WorkToolResult? _documentFailure(
    String fileName,
    DocumentParseResult parsed,
  ) {
    final safeError = _safeParseError(parsed.error);
    if (parsed.status == DocumentParseStatus.tooLarge) {
      return WorkToolResult.failed(
        message: '$fileName：$safeError。',
        failureCode: 'documentTooLarge',
        data: {
          'fileName': fileName,
          'tooLarge': true,
          'unsupportedMedia': false,
        },
      );
    }
    if (parsed.status == DocumentParseStatus.unsupported) {
      return WorkToolResult.failed(
        message: '暂不支持读取 $fileName。',
        failureCode: 'unsupportedMedia',
        data: {'fileName': fileName, 'unsupportedMedia': true},
      );
    }
    if (parsed.status == DocumentParseStatus.ready) return null;
    return WorkToolResult.failed(
      message: '$fileName 无法解析${_formatHint(fileName)}：$safeError。',
      failureCode: 'documentParseFailed',
      data: {
        'fileName': fileName,
        'unsupportedMedia': false,
        'parseError': safeError,
      },
    );
  }

  static String _safeParseError(String? error) {
    final value = error?.trim();
    if (value == null || value.isEmpty) return '文档内容无法读取';
    // Parser failures can originate in dart:io and include the absolute
    // source path. Events and model-visible results carry only the filename.
    final hasAbsolutePath = RegExp(
      r'(^|[\s=:(])(?:[A-Za-z]:[\\/]|/|\\\\)',
    ).hasMatch(value);
    if (hasAbsolutePath) return '本地文件无法读取';
    return value.length <= 120 ? value : '${value.substring(0, 119)}…';
  }

  Future<WorkToolResult> _readImage(
    WorkToolInvocation invocation,
    String path,
    String fileName,
    int fileSize,
    String? mimeType,
  ) async {
    if (fileSize > defaultMaxInlineImageBytes) {
      return _imageTooLarge(fileName);
    }
    if (!modelCapability.supportsVision) {
      return _visionModelRequired(fileName);
    }

    return _prepareImage(invocation, path, fileName, fileSize, mimeType);
  }

  Future<WorkToolResult> _prepareImage(
    WorkToolInvocation invocation,
    String path,
    String fileName,
    int fileSize,
    String? mimeType,
  ) async {
    final attachment = MediaAttachment(
      type: 'image',
      localPath: path,
      fileName: fileName,
      fileSize: fileSize,
      mimeType: mimeType ?? 'image/jpeg',
    );
    final message = Message(
      groupId: invocation.task.groupId,
      senderId: invocation.task.characterId,
      senderType: 'user',
      content: _query(invocation),
      media: [attachment],
    );
    final content = await _cancellable(
      prepareUserMessageContent(
        message,
        supportsVision: true,
        // Keep the production stream reader and injected/test readers behind
        // the same postcondition.  A custom reader is useful for alternate
        // local stores, but it must not be able to hand an oversized image to
        // the multimodal encoder after the stat-based check above.
        fileReader: readBytes == null
            ? _readImageBytesBounded
            : _readImageBytesFromInjectedReader,
        includeDocumentContext: false,
      ),
      invocation,
    );
    if (content == null || invocation.context.isCancelled) {
      return const WorkToolResult.paused(message: '工具执行已停止。');
    }
    if (content is String) {
      return WorkToolResult.failed(
        message: '$fileName 图片内容无法读取，未发送给模型。',
        failureCode: 'imageReadFailed',
        data: {'fileName': fileName},
      );
    }
    return WorkToolResult.success(
      message: '已读取 $fileName，并发送给当前视觉模型。',
      data: {
        'content': content,
        'fileName': fileName,
        'supportsVision': true,
      },
    );
  }

  Future<Uint8List> _readImageBytesBounded(String source) async {
    final inline = decodeAttachmentDataUriBounded(
      source,
      maxBytes: defaultMaxInlineImageBytes,
      message: '图片超过内联上限',
    );
    if (inline != null) {
      if (!inline.mimeType.trim().toLowerCase().startsWith('image/')) {
        throw const FileSystemException('内联附件不是图片');
      }
      return inline.bytes;
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk
        in File(source).openRead(0, defaultMaxInlineImageBytes + 1)) {
      builder.add(chunk);
      if (builder.length > defaultMaxInlineImageBytes) {
        throw const FileSystemException('图片超过内联上限');
      }
    }
    return builder.takeBytes();
  }

  Future<Uint8List> _readImageBytesFromInjectedReader(String source) async {
    final bytes = await readBytes!(source);
    if (bytes.lengthInBytes > defaultMaxInlineImageBytes) {
      throw const FileSystemException('图片超过内联上限');
    }
    return bytes;
  }

  WorkToolResult _imageTooLarge(String fileName) => WorkToolResult.failed(
        message: '$fileName 超过图片内联上限（5 MB），未发送给模型。',
        failureCode: 'imageTooLarge',
        data: {'fileName': fileName, 'tooLarge': true},
      );

  WorkToolResult _visionModelRequired(String fileName) => WorkToolResult.paused(
        message:
            '当前角色模型 ${modelCapability.modelId} 不支持图片输入，请选择已配置的视觉模型后再继续；应用不会自动切换。',
        failureCode: 'visionModelRequired',
        data: {
          'fileName': fileName,
          'requiresModelSelection': true,
          'requiresVisionModelSelection': true,
          'supportsVision': false,
          'provider': modelCapability.provider,
          'model': modelCapability.modelId,
        },
      );

  void _forwardCancellation(
    WorkToolInvocation invocation,
    DocumentProcessingToken token,
  ) {
    final cancellation = invocation.context.cancellation;
    if (cancellation == null) return;
    unawaited(cancellation.whenCancelled.then((_) => token.cancel()));
  }

  Future<T?> _cancellable<T>(
    Future<T> operation,
    WorkToolInvocation invocation,
  ) {
    final cancellation = invocation.context.cancellation;
    if (cancellation == null) return operation.then<T?>((value) => value);
    return Future.any<T?>([
      operation,
      cancellation.whenCancelled.then<T?>((_) => null),
    ]);
  }

  String _query(WorkToolInvocation invocation) {
    final argument = invocation.arguments['query'];
    if (argument is String && argument.trim().isNotEmpty) {
      return argument.trim();
    }
    return invocation.task.userRequest.trim();
  }

  String _effectivePath(String rawPath) {
    final path = rawPath.trim();
    if (workspaceRoot == null ||
        workspaceRoot!.trim().isEmpty ||
        _isAbsolute(path)) {
      return path;
    }
    return '${workspaceRoot!.replaceAll('\\', '/').replaceFirst(RegExp(r'/+$'), '')}/$path';
  }

  bool _isAbsolute(String path) =>
      path.startsWith('/') ||
      path.startsWith('\\') ||
      RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);
}
