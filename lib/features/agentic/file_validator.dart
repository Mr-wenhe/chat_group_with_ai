typedef ValidationCommandRunner = Future<Map<String, dynamic>> Function(
  String command,
);

class FileValidationResult {
  final bool isValid;
  final String message;

  const FileValidationResult({
    required this.isValid,
    required this.message,
  });

  Map<String, dynamic> toJson() => {
        'valid': isValid,
        'message': message,
      };
}

/// 对 Agentic 写出的文件执行轻量、可解释的类型验证。
class FileValidator {
  static const int maxReasonableBytes = 5000000;

  static Future<FileValidationResult> validate(
    String path,
    String content, {
    ValidationCommandRunner? commandRunner,
  }) async {
    if (content.trim().isEmpty) {
      return const FileValidationResult(
        isValid: false,
        message: '文件验证失败：内容为空。',
      );
    }
    if (content.length > maxReasonableBytes) {
      return const FileValidationResult(
        isValid: false,
        message: '文件验证失败：内容超过 5 MB 合理上限。',
      );
    }
    final extension = path.split('.').last.toLowerCase();
    if (extension == 'html' || extension == 'htm') {
      return _validateHtml(content);
    }
    if (extension == 'md' || extension == 'markdown') {
      return _validateMarkdown(content);
    }
    if (extension == 'dart') {
      return _validateDart(path, commandRunner);
    }
    return FileValidationResult(
      isValid: true,
      message: '文件验证通过：内容非空，大小 ${content.length} 字符。',
    );
  }

  static FileValidationResult _validateHtml(String content) {
    const voidTags = {
      'area',
      'base',
      'br',
      'col',
      'embed',
      'hr',
      'img',
      'input',
      'link',
      'meta',
      'param',
      'source',
      'track',
      'wbr'
    };
    final stack = <String>[];
    final tags = RegExp(r'<\s*(/?)\s*([a-zA-Z][\w:-]*)\b[^>]*>');
    for (final match in tags.allMatches(content)) {
      final tag = match.group(2)!.toLowerCase();
      final isClosing = match.group(1) == '/';
      final raw = match.group(0)!;
      if (voidTags.contains(tag) || raw.endsWith('/>')) continue;
      if (!isClosing) {
        stack.add(tag);
        continue;
      }
      if (stack.isEmpty || stack.last != tag) {
        return FileValidationResult(
          isValid: false,
          message: 'HTML 验证失败：标签 <${stack.last}> 未闭合，'
              '不能直接结束 </$tag>。',
        );
      }
      stack.removeLast();
    }
    if (stack.isNotEmpty) {
      return FileValidationResult(
        isValid: false,
        message: 'HTML 验证失败：标签 <${stack.last}> 未闭合。',
      );
    }
    return const FileValidationResult(
      isValid: true,
      message: 'HTML 验证通过：标签结构完整。',
    );
  }

  static FileValidationResult _validateMarkdown(String content) {
    var previousLevel = 0;
    var inFence = false;
    for (final line in content.split('\n')) {
      if (line.trimLeft().startsWith('```')) {
        inFence = !inFence;
        continue;
      }
      if (inFence) continue;
      final match = RegExp(r'^(#{1,6})\s+\S').firstMatch(line);
      if (match == null) continue;
      final level = match.group(1)!.length;
      if (previousLevel > 0 && level > previousLevel + 1) {
        return const FileValidationResult(
          isValid: false,
          message: 'Markdown 验证失败：标题层级存在跨级。',
        );
      }
      previousLevel = level;
    }
    return const FileValidationResult(
      isValid: true,
      message: 'Markdown 验证通过：标题层级合理。',
    );
  }

  static Future<FileValidationResult> _validateDart(
    String path,
    ValidationCommandRunner? commandRunner,
  ) async {
    if (commandRunner == null) {
      return const FileValidationResult(
        isValid: false,
        message: 'Dart 验证未执行：command.run 不可用。',
      );
    }
    final result = await commandRunner('flutter analyze ${_quote(path)}');
    final exitCode = result['exitCode'];
    final valid = result['ok'] == true || exitCode == 0;
    final output =
        (result['stdout'] ?? result['message'] ?? '').toString().trim();
    return FileValidationResult(
      isValid: valid,
      message: valid
          ? 'Dart 验证通过：${output.isEmpty ? 'flutter analyze 无错误' : output}'
          : 'Dart 验证失败：${output.isEmpty ? 'flutter analyze 退出码 $exitCode' : output}',
    );
  }

  static String _quote(String path) {
    if (!RegExp(r'''[\s'"]''').hasMatch(path)) return path;
    return "'${path.replaceAll("'", "'\\''")}'";
  }
}
