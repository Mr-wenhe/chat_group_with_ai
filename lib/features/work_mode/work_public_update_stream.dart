import 'package:chat_group/features/web_search/security/search_secret_scanner.dart';

/// Extracts the user-facing `public_update` field from a streamed decision.
///
/// The model response is a private protocol payload.  This class deliberately
/// exposes only the JSON string field intended for the user, so the live panel
/// never renders tool arguments, protocol fragments, or private reasoning.
class WorkPublicUpdateStream {
  static final RegExp _publicUpdateField = RegExp(r'"public_update"\s*:\s*"');
  static final RegExp _privateReasoningMarker = RegExp(
    r'<\s*/?\s*think\b|chain[- ]of[- ]thought|思维链|隐藏思维|私有思维|内部推理',
    caseSensitive: false,
  );
  static final RegExp _urlPattern = RegExp(r'https?://[^\s"<>]+');
  static final RegExp _localPathPattern = RegExp(
    r'(?<![A-Za-z0-9_.-])(?:/[^\s"<>]+|[A-Za-z]:[\\/][^\s"<>]+|\\\\[^\s"<>]+)',
  );

  static const int maximumDraftCharacters = 1200;
  static const int _maximumSourceCharacters = 64 * 1024;

  /// 截断标记：正文被裁掉时追加，说明原文有多长。
  ///
  /// 只补一个 `…` 会让读者以为模型就写了这么多；持久化的消息和协议字段
  /// 被裁时必须能看出来，否则内容丢失是静默的。
  static String truncationNotice(int originalLength) =>
      '…（已截断，原文 $originalLength 字）';

  /// Bounds text to the limit its caller asked for.
  ///
  /// 上限由调用方按用途决定，不能由这个类统一负责：实时草稿每多 24 个字符
  /// 就整串重写一次事件日志（[maximumDraftCharacters]），而一条持久化的讨论
  /// 消息有自己的预算。两者共用一个常量，会让消息的预算永远达不到。
  ///
  /// [explicitNotice] 区分两种语义：[false] 用于仍在增长的实时草稿，只补
  /// `…`；[true] 用于会落库的正文，附上 [truncationNotice]。
  static String boundText(
    String value, {
    required int maximum,
    bool explicitNotice = false,
  }) {
    final limit = maximum < 1 ? 1 : maximum;
    if (value.length <= limit) return value;
    if (!explicitNotice) return '${value.substring(0, limit)}…';
    final notice = truncationNotice(value.length);
    final body = limit - notice.length;
    return body <= 0 ? notice : '${value.substring(0, body)}$notice';
  }

  /// 实时草稿的对外取值：脱敏后按 [maximumDraftCharacters] 封顶。
  static String boundedDraft(String value) =>
      boundText(sanitize(value), maximum: maximumDraftCharacters);

  String _source = '';
  String _lastDecodedValue = '';

  /// Adds an SSE delta and returns the newest decoded public update.
  ///
  /// An empty string means that no safe, non-empty update is available yet.
  String add(String delta) {
    if (delta.isEmpty) {
      return _lastDecodedValue;
    }

    _source += delta;
    if (_source.length > _maximumSourceCharacters) {
      _source = _source.substring(_source.length - _maximumSourceCharacters);
    }

    final valueStart = _findTopLevelPublicUpdateStart(_source);
    if (valueStart == null) {
      return _lastDecodedValue;
    }

    final decoded = _decodePartialJsonString(_source, valueStart);
    if (decoded == null || decoded == _lastDecodedValue) {
      return _lastDecodedValue;
    }

    _lastDecodedValue = decoded;
    return _lastDecodedValue;
  }

  static int? _findTopLevelPublicUpdateStart(String source) {
    for (final match in _publicUpdateField.allMatches(source)) {
      if (_isTopLevelField(source, match.start)) return match.end;
    }
    return null;
  }

  static bool _isTopLevelField(String source, int fieldStart) {
    var nesting = 0;
    var inString = false;
    var escaping = false;
    for (var index = 0; index < fieldStart; index++) {
      final character = source[index];
      if (inString) {
        if (escaping) {
          escaping = false;
        } else if (character == '\\') {
          escaping = true;
        } else if (character == '"') {
          inString = false;
        }
        continue;
      }
      if (character == '"') {
        inString = true;
      } else if (character == '{' || character == '[') {
        nesting += 1;
      } else if ((character == '}' || character == ']') && nesting > 0) {
        nesting -= 1;
      }
    }
    return !inString && nesting == 1;
  }

  /// Redacts secrets and locations before the text is shown or stored.
  ///
  /// 只脱敏，不截断——长度上限由调用方给出（见 [boundText]）。
  static String sanitize(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || _privateReasoningMarker.hasMatch(trimmed)) {
      return '';
    }

    const scanner = SearchSecretScanner();
    var safe = scanner.redact(trimmed, includeOpaqueTokens: true);
    safe = safe.replaceAll(_urlPattern, '[外部地址]');
    safe = safe.replaceAll(_localPathPattern, '[本地路径]');
    return safe;
  }

  static String? _decodePartialJsonString(String source, int start) {
    final output = StringBuffer();
    var escaping = false;
    var unicodeDigitsRemaining = 0;
    var unicodeBuffer = '';

    for (var index = start; index < source.length; index++) {
      final character = source[index];

      if (unicodeDigitsRemaining > 0) {
        if (!RegExp(r'[0-9a-fA-F]').hasMatch(character)) {
          return null;
        }
        unicodeBuffer += character;
        unicodeDigitsRemaining -= 1;
        if (unicodeDigitsRemaining == 0) {
          output
              .write(String.fromCharCode(int.parse(unicodeBuffer, radix: 16)));
          unicodeBuffer = '';
        }
        continue;
      }

      if (escaping) {
        escaping = false;
        switch (character) {
          case '"':
          case '\\':
          case '/':
            output.write(character);
          case 'b':
            output.write('\b');
          case 'f':
            output.write('\f');
          case 'n':
            output.write('\n');
          case 'r':
            output.write('\r');
          case 't':
            output.write('\t');
          case 'u':
            unicodeDigitsRemaining = 4;
          default:
            return null;
        }
        continue;
      }

      if (character == '\\') {
        escaping = true;
        continue;
      }
      if (character == '"') {
        return output.toString();
      }
      output.write(character);
    }

    // The final quote may arrive in a later SSE event.  The decoded prefix is
    // still safe to display while the model continues producing the field.
    return output.toString();
  }
}
