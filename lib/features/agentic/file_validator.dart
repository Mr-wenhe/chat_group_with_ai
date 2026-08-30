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
      return _validateDart(path, content, commandRunner);
    }
    if (extension == 'java') {
      return _validateJava(content);
    }
    if (const {'c', 'cc', 'cpp', 'h', 'hpp'}.contains(extension)) {
      return _validateCFamily(content);
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
    var structuralContent = content;
    for (final rawTag in const ['script', 'style']) {
      structuralContent = structuralContent.replaceAllMapped(
        RegExp(
          '(<$rawTag\\b[^>]*>)[\\s\\S]*?(</$rawTag\\s*>)',
          caseSensitive: false,
        ),
        (match) => '${match.group(1)}${match.group(2)}',
      );
    }
    final stack = <String>[];
    String? rawTextTag;
    final tags = RegExp(r'<\s*(/?)\s*([a-zA-Z][\w:-]*)\b[^>]*>');
    for (final match in tags.allMatches(structuralContent)) {
      final tag = match.group(2)!.toLowerCase();
      final isClosing = match.group(1) == '/';
      final raw = match.group(0)!;
      if (rawTextTag != null) {
        if (isClosing && tag == rawTextTag) {
          stack.removeLast();
          rawTextTag = null;
        }
        continue;
      }
      if (voidTags.contains(tag) || raw.endsWith('/>')) continue;
      if (!isClosing) {
        stack.add(tag);
        if (tag == 'script' || tag == 'style') rawTextTag = tag;
        continue;
      }
      if (stack.isEmpty) {
        return FileValidationResult(
          isValid: false,
          message: 'HTML 验证失败：存在多余的结束标签 </$tag>。',
        );
      }
      if (stack.last != tag) {
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

  static FileValidationResult _validateJava(String content) {
    final declaresType = RegExp(
      r'\b(class|interface|enum|record)\s+[A-Za-z_$][\w$]*',
    ).hasMatch(content);
    if (!declaresType) {
      return const FileValidationResult(
        isValid: false,
        message: 'Java 结构验证失败：未找到类、接口、枚举或 record 声明。',
      );
    }
    return const FileValidationResult(
      isValid: true,
      message: 'Java 结构验证通过：已识别类型声明；未执行 javac 编译。',
    );
  }

  static FileValidationResult _validateCFamily(String content) {
    // 宽松识别 C/C++ 源码结构：include、类型声明（class/struct/union/enum/namespace），
    // 或至少一个函数定义（返回类型 + 函数名 + 参数列表 + 左大括号）。
    // 纯 C 库（仅函数实现、无 main/无 include）也能通过，避免误判无效。
    final hasSourceStructure = RegExp(
      r'(#\s*include\s*[<"]|'
      r'\b(?:class|struct|union|enum|namespace)\s+\w+|'
      r'\b[a-zA-Z_]\w*\s+[a-zA-Z_]\w*\s*\([^;]*\)\s*\{)',
    ).hasMatch(content);
    if (!hasSourceStructure) {
      return const FileValidationResult(
        isValid: false,
        message: 'C/C++ 结构验证失败：未找到 include、类型声明或函数定义。',
      );
    }
    return const FileValidationResult(
      isValid: true,
      message: 'C/C++ 结构验证通过：已识别源码结构；未执行编译器。',
    );
  }

  static Future<FileValidationResult> _validateDart(
    String path,
    String content,
    ValidationCommandRunner? commandRunner,
  ) async {
    if (commandRunner == null) {
      return _validateDartLightweight(content: content);
    }
    final result = await commandRunner('flutter analyze ${_quote(path)}');
    if (result['error'] == 'command_not_available_in_stage02') {
      return _validateDartLightweight(content: content);
    }
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

  static FileValidationResult _validateDartLightweight({
    required String content,
  }) {
    final stack = <String>[];
    var quote = '';
    var escaped = false;
    var lineComment = false;
    var blockComment = false;
    for (var index = 0; index < content.length; index++) {
      final character = content[index];
      final next = index + 1 < content.length ? content[index + 1] : '';
      if (lineComment) {
        if (character == '\n') lineComment = false;
        continue;
      }
      if (blockComment) {
        if (character == '*' && next == '/') {
          blockComment = false;
          index++;
        }
        continue;
      }
      if (quote.isNotEmpty) {
        if (escaped) {
          escaped = false;
        } else if (character == '\\') {
          escaped = true;
        } else if (content.startsWith(quote, index)) {
          final delimiterLength = quote.length;
          quote = '';
          index += delimiterLength - 1;
        }
        continue;
      }
      if (character == '/' && next == '/') {
        lineComment = true;
        index++;
        continue;
      }
      if (character == '/' && next == '*') {
        blockComment = true;
        index++;
        continue;
      }
      if (character == '\'' || character == '"') {
        final third = index + 2 < content.length ? content[index + 2] : '';
        quote = next == character && third == character
            ? '$character$character$character'
            : character;
        if (quote.length == 3) index += 2;
        continue;
      }
      if (character == '{' || character == '[' || character == '(') {
        stack.add(character);
        continue;
      }
      if (character == '}' || character == ']' || character == ')') {
        if (stack.isEmpty ||
            !_matchingDelimiter(stack.removeLast(), character)) {
          return const FileValidationResult(
            isValid: false,
            message: 'Dart 轻量验证失败：括号结构不匹配。',
          );
        }
      }
    }
    if (quote.isNotEmpty || blockComment || stack.isNotEmpty) {
      return const FileValidationResult(
        isValid: false,
        message: 'Dart 轻量验证失败：字符串、注释或括号未闭合。',
      );
    }
    if (!_hasDartSourceStructure(content)) {
      return const FileValidationResult(
        isValid: false,
        message: 'Dart 轻量验证失败：未找到常见 Dart 结构。',
      );
    }
    return const FileValidationResult(
      isValid: true,
      message: 'Dart 轻量验证通过：已检查基本结构；未执行 flutter analyze。',
    );
  }

  static bool _hasDartSourceStructure(String content) {
    // Keep this intentionally permissive: this is a fallback when the
    // command runner is unavailable, so rejecting valid declarations such as
    // `String title = ...` or a top-level `main()` would block safe writes.
    return RegExp(
      r'\b(import|export|library|part|class|enum|mixin|extension|typedef|'
      r'void|final|const|var|late|return|if|for|while|switch|try|throw|'
      r'(?:String|bool|int|double|num|dynamic|Object|List|Map|Set|Future|'
      r'Stream|Widget))\b|'
      r'\b[A-Za-z_$][\w$]*(?:<[^;{}()]+>)?\s+[A-Za-z_$][\w$]*\s*=|'
      r'\b[A-Za-z_$][\w$]*(?:<[^;{}()]+>)?\s+[A-Za-z_$][\w$]*\s*\([^;]*\)\s*\{|'
      r'\bmain\s*\([^;{}]*\)\s*\{',
    ).hasMatch(content);
  }

  static bool _matchingDelimiter(String opening, String closing) =>
      (opening == '{' && closing == '}') ||
      (opening == '[' && closing == ']') ||
      (opening == '(' && closing == ')');

  static String _quote(String path) {
    // Keep shell metacharacters inside the quoted argument even when a path
    // has no whitespace. The validator may call a legacy bridge command
    // runner, so a filename such as `a;rm -rf` must never become two commands.
    if (RegExp(r'^[A-Za-z0-9_./\\:-]+$').hasMatch(path)) return path;
    return "'${path.replaceAll("'", "'\\''")}'";
  }
}
