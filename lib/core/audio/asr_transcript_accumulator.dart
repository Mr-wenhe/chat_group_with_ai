/// 流式语音识别结果的文本合并缓冲。
///
/// 火山 SAUC（`volc.bigasr.sauc.duration`）一条流式识别会交替下发两类结果：
/// - **interim**：当前句的候补文本，随时会被下一条更完整的候补覆盖；
/// - **final**：已定稿的文本（`definite` utterance / 末帧），一段话说完后保留。
///
/// final 按句定稿：用户说话途中停顿超过 VAD 断句阈值（`end_window_size`）会
/// 先定稿一句、后续再定稿下一句。因此**每条 final 默认是一句自包含的新文本**，
/// 应追加到已定稿之后；同时也兼容个别服务端返回“相对已定稿的累计全文”的情况
/// （以已定稿为前缀时只取增量），并去重与已定稿或上一条新句完全一致的重复帧。
///
/// 展示层把二者合并成“已定稿 + 当前候补”两块：定稿部分稳定不动，只有当前这句
/// 还在跳动，用户看到的是一个逐字落定、不再整体回退的文案。
class AsrTranscriptAccumulator {
  final StringBuffer _committed = StringBuffer();

  /// 最近一次追加进定稿区的完整片段（用于去重重复的按句 final 帧）。
  String _lastAppended = '';

  /// 当前句子未定稿的候补文本。
  String _pending = '';

  /// 已定稿（不会再被改写）的文本。
  String get committedText => _committed.toString();

  /// 输入框应展示的全文 = 已定稿 + 当前候补。
  String get displayText {
    final head = _committed.toString();
    final tail = _pending.trim();
    if (tail.isEmpty) return head;
    return head.isEmpty ? tail : '$head$tail';
  }

  /// 处理一条识别结果，返回 `true` 表示 [displayText] 发生了变化（调用方应刷新）。
  ///
  /// - interim 直接替换候补（整句重写在定稿前发生，落在这一层）；
  /// - final 的合并规则见类注释：追加新句 / 累计式只取增量 / 去重重复帧。
  bool onResult(String text, bool isFinal) {
    final before = displayText;
    final value = text.trim();
    if (isFinal) {
      _pending = '';
      if (value.isEmpty) return displayText != before; // 空定稿：静音收尾，无变化。
      final head = _committed.toString();
      if (head.isEmpty) {
        _commit(value);
      } else if (value == head) {
        // 与已定稿完全一致（累计式无增量 / 内容重复帧）：不追加。
      } else if (value.startsWith(head)) {
        // 累计式全文：只追加相对已定稿的增量。
        final delta = value.substring(head.length);
        if (delta.isNotEmpty) _commit(delta);
      } else if (value == _lastAppended) {
        // 与上一条新句完全一致（按句定稿的重复帧）：去重。
      } else {
        // 按句定稿：这是定稿的一句新文本，追加到已定稿之后。
        _commit(value);
      }
    } else if (value.isNotEmpty) {
      _pending = value;
    }
    return displayText != before;
  }

  void _commit(String part) {
    _committed.write(part);
    _lastAppended = part;
  }

  /// 复位为空白（一次新的聆听会话开始前调用）。
  void clear() {
    _committed.clear();
    _lastAppended = '';
    _pending = '';
  }
}
