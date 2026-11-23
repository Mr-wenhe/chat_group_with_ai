part of 'network_reply_stream.dart';

/// Splits streamed markdown into visible text and a tool request.
///
/// Models drift on the fence marker: the prompt asks for ```agent_tool, but a
/// real reply used ```json with the same payload, which the old strict regex
/// ignored — the JSON was then published as chat text. They also like to write
/// a sentence before the fence, which the old "visible already? then stream
/// everything" check turned into the same leak.
///
/// This scanner keeps a small tail buffered, hides any fenced block that
/// declares a tool call, and passes every other block through unchanged
/// (ordinary code blocks still render).
///
/// 判据本身（label 归一化、payload 分类）在 [ToolFenceProtocol] 里，与提交层
/// 清洗共用一份；这里只负责"边收边切、边切边吐"的流式流程。
class _ReplyFenceScanner {
  final StringBuffer _pending = StringBuffer();
  final StringBuffer _raw = StringBuffer();

  ToolRequest? request;
  bool sawDelta = false;
  bool startedWithFence = false;

  /// 本轮第一个围栏块是否**声明了工具调用**（可执行请求或坏请求）。
  ///
  /// 只认第一个块，且以块内容分类为准。协议回复与普通代码块的形态一样
  /// （都以 ``` 开头、前后没有正文），区别只在围栏里写的是什么：用
  /// [startedWithFence]（"是否以 ``` 开头"）当判据，会把 ```dart 代码块整段
  /// 判成协议错误并替换成联网失败提示。
  bool firstBlockDeclaredTool = false;
  bool _sawFirstBlock = false;

  /// Set when a block declared a tool call but could not be parsed.
  bool malformedToolRequest = false;
  bool repairableJson = false;

  /// Everything emitted as chat text in this round. Used when a round has to
  /// end early: the provider's `done.content` still carries the hidden fence,
  /// so the visible text is what the message must keep.
  final StringBuffer _visible = StringBuffer();

  /// Characters already emitted as chat text in this round.
  int get visibleLength => _visible.length;

  String get visibleText => _visible.toString();

  String get raw => _raw.toString();

  /// 记录本轮最早那个围栏块的分类。
  void _noteBlockVerdict(ToolFenceVerdict parsed) {
    if (_sawFirstBlock) return;
    _sawFirstBlock = true;
    firstBlockDeclaredTool = parsed.kind != ToolFenceKind.code;
  }

  String feed(String delta) {
    if (delta.isEmpty) return '';
    sawDelta = true;
    if (request == null && !startedWithFence && _raw.isEmpty) {
      // The opening fence may arrive split across deltas ("`", "``", "```json"),
      // so decide on the concatenated head rather than a single delta.
      startedWithFence = delta.trimLeft().startsWith('```');
    }
    _raw.write(delta);
    _pending.write(delta);
    return _drain(finalizing: false);
  }

  String finish() => _drain(finalizing: true);

  String _drain({required bool finalizing}) {
    final out = StringBuffer();
    while (true) {
      final text = _pending.toString();
      final start = text.indexOf('```');
      if (start < 0) {
        // Some models ignore the requested fence and return the tool object as
        // the entire reply. Hold a leading JSON object until the turn ends so
        // a valid web request can execute without leaking its payload. Other
        // JSON examples remain ordinary visible text.
        final trimmed = text.trimLeft();
        if (_visible.isEmpty && !startedWithFence && trimmed.startsWith('{')) {
          if (!finalizing) break;
          final parsed = ToolFenceProtocol.parse(trimmed);
          _noteBlockVerdict(parsed);
          switch (parsed.kind) {
            case ToolFenceKind.request:
              request ??= parsed.request;
            case ToolFenceKind.malformedTool:
              malformedToolRequest = true;
              repairableJson = parsed.repairableJson;
            case ToolFenceKind.code:
              out.write(text);
          }
          _pending.clear();
          break;
        }
        if (finalizing) {
          out.write(text);
          _pending.clear();
          break;
        }
        // A delta may end in the middle of a fence marker; keep that prefix.
        final keep = text.endsWith('``') ? 2 : (text.endsWith('`') ? 1 : 0);
        out.write(text.substring(0, text.length - keep));
        _pending.clear();
        _pending.write(text.substring(text.length - keep));
        break;
      }
      if (start > 0) {
        out.write(text.substring(0, start));
        _pending.clear();
        _pending.write(text.substring(start));
        continue;
      }
      final close = text.indexOf('```', 3);
      if (close < 0) {
        if (!finalizing) break;
        // The stream ended (or the user stopped it) inside a fence. A code
        // sample may still be shown; a half-written tool request must not be,
        // which is exactly what "回复好奇怪" looked like.
        final parsed = ToolFenceProtocol.parse(text.substring(3));
        _noteBlockVerdict(parsed);
        if (parsed.kind == ToolFenceKind.code) {
          out.write(text);
        } else {
          malformedToolRequest = true;
          repairableJson = parsed.repairableJson;
        }
        _pending.clear();
        break;
      }
      final block = text.substring(0, close + 3);
      final inner = text.substring(3, close);
      _pending.clear();
      _pending.write(text.substring(close + 3));
      final parsed = ToolFenceProtocol.parse(inner);
      _noteBlockVerdict(parsed);
      switch (parsed.kind) {
        case ToolFenceKind.request:
          request ??= parsed.request;
        case ToolFenceKind.malformedTool:
          // Hide the payload; the caller reports the protocol failure.
          malformedToolRequest = true;
          repairableJson = parsed.repairableJson;
        case ToolFenceKind.code:
          out.write(block);
      }
    }
    final emitted = out.toString();
    _visible.write(emitted);
    return emitted;
  }
}
