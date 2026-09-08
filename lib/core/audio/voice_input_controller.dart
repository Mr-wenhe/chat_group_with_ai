/// 语音输入会话的协调器：把麦克风 PCM 流喂给火山流式 ASR，并把
/// interim/final 结果合并成稳定的输入框文案。
///
/// 生命周期：`start()`（权限 → 开 ASR 会话 → 开麦克风并转发音频）→
/// `stop()`（末包收尾，等待最终结果落定）或 `cancel()`（直接丢弃）。
/// 每个实例只服务一次会话；再次使用请新建。
library;

import 'dart:async';
import 'dart:typed_data';

import 'asr_transcript_accumulator.dart';
import 'voice_mic_source.dart';
import 'volcengine_asr.dart';

/// 语音输入的运行阶段。
enum VoiceInputPhase {
  /// 空闲（未开始或已结束）。
  idle,

  /// 正在聆听并实时识别。
  listening,

  /// 已点“结束”，正在等待服务端最终结果收尾。
  finishing,
}

class VoiceInputController {
  VoiceInputController({
    required VoiceMicSource mic,
    required VolcengineAsrSession Function() createSession,
  })  : _mic = mic,
        _createSession = createSession;

  final VoiceMicSource _mic;
  final VolcengineAsrSession Function() _createSession;
  final AsrTranscriptAccumulator _transcript = AsrTranscriptAccumulator();

  /// 输入框文案每次变化都会回调（interim 与 final 都算）。
  void Function(String displayText)? onDisplayChanged;

  /// 会话级错误（连接失败 / 服务端拒绝 / 麦克风异常）。一旦回调即会话终结。
  void Function(String message)? onError;

  VoiceInputPhase _phase = VoiceInputPhase.idle;
  VolcengineAsrSession? _session;
  StreamSubscription<Uint8List>? _micSub;
  Uint8List? _lastChunk;
  bool _started = false;
  String? _startError;

  VoiceInputPhase get phase => _phase;

  /// 已定稿文本（停止识别后可安全读取）。
  String get committedText => _transcript.committedText;

  /// 开启一次聆听会话。成功返回 `null`，失败返回可直接展示的错误文案。
  Future<String?> start() async {
    if (_phase != VoiceInputPhase.idle) return '正在语音输入中';
    final permitted = await _mic.hasPermission();
    if (!permitted) return '需要麦克风权限才能使用语音输入';

    _started = false;
    _startError = null;
    _transcript.clear();
    final session = _createSession();
    session.onResult = _onAsrResult;
    session.onError = (message) {
      // 开始阶段（await session.start 尚未返回）先缓存，由 start() 返回错误；
      // 已开始后的错误才是会话级中断，走 _onFatal。
      if (!_started) {
        _startError = message;
      } else {
        _onFatal(message);
      }
    };
    await session.start();
    if (_startError != null || !session.isActive) {
      _teardown(session);
      return _startError ?? '语音连接失败，请稍后重试';
    }

    try {
      final stream = await _mic.startStream(sampleRate: 16000);
      _session = session;
      _started = true;
      _phase = VoiceInputPhase.listening;
      _micSub = stream.listen(
        _feedAudio,
        onError: (Object e) => _onFatal('麦克风异常：$e'),
      );
      return null;
    } catch (e) {
      _teardown(session);
      return '无法打开麦克风：$e';
    }
  }

  /// 结束聆听：末包置位 `isLast` 并发送结束帧，等最终结果落定后复位。
  Future<void> stop() async {
    if (_phase == VoiceInputPhase.idle) return;
    _phase = VoiceInputPhase.finishing;
    final session = _session;
    final sub = _micSub;
    _micSub = null;
    _session = null;
    await sub?.cancel();
    await _mic.stop();
    if (session != null) {
      try {
        final last = _lastChunk ?? Uint8List(0);
        session.sendAudio(last, isLast: true);
        // finish() 内部会等 ~300ms 让服务端把最终一句推回来。
        await session.finish();
      } catch (_) {
        // 收尾失败不致命：已定稿文本依然保留在输入框。
      }
    }
    _phase = VoiceInputPhase.idle;
  }

  /// 直接丢弃本次聆听（错误退出 / 用户放弃），清空已识别文本。
  Future<void> cancel() async {
    if (_phase == VoiceInputPhase.idle) return;
    final session = _session;
    final sub = _micSub;
    _micSub = null;
    _session = null;
    _phase = VoiceInputPhase.idle;
    await sub?.cancel();
    await _mic.stop();
    session?.cancel();
    _transcript.clear();
  }

  Future<void> dispose() async {
    await cancel();
    await _mic.dispose();
  }

  void _feedAudio(Uint8List chunk) {
    if (_phase != VoiceInputPhase.listening || chunk.isEmpty) return;
    _lastChunk = chunk;
    _session?.sendAudio(chunk);
  }

  void _onAsrResult(String text, bool isFinal) {
    if (_transcript.onResult(text, isFinal)) {
      onDisplayChanged?.call(_transcript.displayText);
    }
  }

  void _onFatal(String message) {
    if (_phase == VoiceInputPhase.idle) return;
    _phase = VoiceInputPhase.idle;
    final session = _session;
    final sub = _micSub;
    _micSub = null;
    _session = null;
    unawaited(sub?.cancel());
    unawaited(_mic.stop());
    session?.cancel();
    onError?.call(message);
  }

  /// 复位到空闲（start 失败分支用，不额外触发 onError——错误已由返回值带出）。
  void _teardown(VolcengineAsrSession session) {
    _phase = VoiceInputPhase.idle;
    _session = null;
    session.cancel();
  }
}
