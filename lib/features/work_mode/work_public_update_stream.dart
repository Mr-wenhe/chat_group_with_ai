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

  /// 气泡正文的**目标**字数。
  ///
  /// 这是"瞄准多少"而不是"可以用到多少"：模型会写到被声明的额度，把上限报给它
  /// 等于邀请它写满（线上实测 700–800 区间挤了 71 条，观感因此没改善）。超过目标
  /// 的部分被截断并标注——截的是气泡而不是内容，调用方负责把完整正文转存成详情
  /// 附件（见 v2 会话的 `_attachTruncatedUpdate`）。
  static const int bubbleTargetCharacters = 300;

  /// 协议标识与内部标识符：版本整数、认可布尔值、阶段名、提案引用、字段名与命令编号。
  ///
  /// 这些词只该出现在 JSON 字段里。写进公开正文时，读者看到的是台账复述而不是
  /// 成员的意见（`req=48 / team=22 / ver=10 下我仍判 approved:false`，或
  /// `V-08 的 requiredCapability`）。判据刻意只收完整成词的协议词元，不做
  /// `AC-02` 这类编号的形状猜测——`UTF-8`、`SHA-256` 在正常讨论里就会出现，
  /// 误报会让诊断本身失去可信度。
  static final RegExp _protocolNotation = RegExp(
    r'\b(?:requestRevision|teamRevision|verificationRevision|schemaVersion'
    r'|artifactContract|public_update|approvalIdentifiers|requiredCapability'
    r'|verificationCommands|retestCondition|evidenceRef|resolutionRef'
    r'|artifactDigest|workItems|ownerId|dependencies|acceptances)\b'
    r'|\b(?:req|team|ver|revision|rev)\s*=\s*\d+\b'
    r'|\bapproved\s*[:=]\s*(?:true|false)\b'
    r'|\b(?:reviewApproval|resolveIssue|prepareProposal)\b'
    r'|\b(?:adopt:)?proposal:[0-9a-zA-Z]{6,}'
    r'|\bV-\d{1,2}\b',
    caseSensitive: false,
  );

  /// 编号清单标记：①②③、⑴、行首的 `1.` / `1、` / `(1)`。
  ///
  /// 数字形态只认行首，否则 `1.5 倍` 也会被当成清单。圆括号内是一到两位数字，
  /// 年份这类长数字不会命中。
  static final RegExp _listMarker = RegExp(
    r'[①-⑳⑴-⒇⒈-⒛]|(?:^|\n)\s*[(（]?\d{1,2}[.、)）]',
  );

  /// 编号清单至少出现几处才算"被格式化"：一处可能只是正常引用，两处以上就是清单体。
  static const int listMarkerLimit = 2;

  /// 公开正文里出现的协议标识，按首次出现顺序去重。
  ///
  /// 只做识别，不用于改写：正文换成中性文案会丢掉成员真实说过的内容，这里只
  /// 供调用方记录诊断。
  static List<String> protocolNotations(String value) {
    final found = <String>{};
    for (final match in _protocolNotation.allMatches(value)) {
      found.add(match.group(0)!);
    }
    return found.toList();
  }

  /// 公开正文里的编号清单标记数。
  static int listMarkerCount(String value) => _listMarker.allMatches(value).length;

  /// 公开正文是否被排成编号清单。
  ///
  /// 这是 `_reportFormattedUpdate` 判据里"清单"的那一半：那条诊断还看协议标识，
  /// 而打回重写只看清单——协议标识仍按 2026-10-09 的裁决只记诊断。两处共用
  /// [listMarkerLimit]，各自维护一份会让"诊断说命中、重写说没命中"这种分叉
  /// 只能靠比对日志才发现。
  static bool looksLikeNumberedList(String value) =>
      listMarkerCount(value) >= listMarkerLimit;

  /// 剥掉模型给正文套上的代码围栏。
  ///
  /// 重写请求要求"只输出发言正文"，模型却常把整段正文包进 ``` 交付，围栏落到
  /// 气泡里就是三条反引号。只剥**包住整段**的首尾围栏：行内反引号（引用
  /// `game.html` 这类名字）不动，结尾围栏之后还跟着正文的也不算围栏。
  static String stripCodeFence(String value) {
    final trimmed = value.trim();
    if (!trimmed.startsWith('```')) return trimmed;
    final firstLineEnd = trimmed.indexOf('\n');
    if (firstLineEnd < 0) return trimmed;
    final body = trimmed.substring(firstLineEnd + 1);
    final closing = body.lastIndexOf('```');
    if (closing < 0) return body.trim();
    if (body.substring(closing + 3).trim().isNotEmpty) return body.trim();
    return body.substring(0, closing).trim();
  }

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
