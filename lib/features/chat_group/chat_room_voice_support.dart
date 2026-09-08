part of 'chat_room_page.dart';

/// 群聊「流式语音播报」的接线层。
///
/// 职责：把正在流式输出的 AI 回复按句切分、逐句 TTS 合成并播放。
/// 语音开关按会话持久化（见 [DatabaseService.voiceBroadcastEnabled]），
/// 默认关闭。这里的钩子都是“廉价早退”的——未开启/未配置时几乎不做事，
/// 避免拖慢流式渲染热路径。
extension _ChatRoomVoiceSupport on _ChatRoomPageState {
  /// 语音服务是否具备可用前提（原生平台 + 已绑定 Key）。
  bool get _voiceBroadcastUsable {
    if (kIsWeb) return false;
    final config = _db.voiceServiceConfig;
    return config.isConfigured && config.apiKeyBound;
  }

  /// 开启/关闭当前会话的流式语音播报（持久化 + 管理播放器生命周期）。
  Future<void> _setVoiceBroadcastEnabled(bool enabled) async {
    if (enabled && !_voiceBroadcastUsable) {
      if (_canTouchUi) {
        AppToast.show(
          context,
          '请先在「设置 → API 配置 → 语音服务」绑定语音 Key',
          icon: Icons.record_voice_over_outlined,
        );
      }
      return;
    }
    await _db.setVoiceBroadcastEnabled(widget.groupId, enabled);
    if (!mounted || _disposed || !_pageActive) return;
    _setUiState(() => _voiceBroadcastEnabled = enabled);
    if (enabled) {
      _ensureVoiceBroadcaster();
      // 没有任何角色配置音色、也没有默认音色时给一句引导。
      final config = _db.voiceServiceConfig;
      final hasAnyVoice = config.defaultVoiceId != null ||
          _allGroupCharacters.any((c) => c.voiceId.trim().isNotEmpty);
      if (!hasAnyVoice) {
        AppToast.show(
          context,
          '语音播报已开启：给角色选个音色，或在语音服务里设置默认音色',
          icon: Icons.record_voice_over_outlined,
        );
      }
    } else {
      await _stopVoiceBroadcast();
    }
  }

  /// 按需创建页面级播报器。合成闭包在句级从安全存储读取 Key，
  /// 避免 Key 变更/重绑后需要重建队列。
  SpeechBroadcaster? _ensureVoiceBroadcaster() {
    if (kIsWeb) return null;
    final existing = _voiceBroadcaster;
    if (existing != null) return existing;
    final ttsClient = VolcengineTtsClient(open: openVolcWs);
    final broadcaster = SpeechBroadcaster(
      synthesize: (text, speaker) =>
          _synthesizeVoiceSentence(ttsClient, text, speaker),
      sink: AudioplayersVoiceSink(),
      onError: _onVoiceBroadcastError,
    );
    _voiceBroadcaster = broadcaster;
    return broadcaster;
  }

  Future<Uint8List?> _synthesizeVoiceSentence(
    VolcengineTtsClient client,
    String text,
    String speaker,
  ) async {
    final apiKey = await _db.readVoiceApiKey();
    if (apiKey == null) return null;
    final config = _db.voiceServiceConfig;
    return client.synthesize(
      text: text,
      speaker: speaker,
      resourceId: config.ttsResourceId,
      apiKey: apiKey,
    );
  }

  void _onVoiceBroadcastError(String message) {
    if (!_canTouchUi) return;
    AppToast.show(context, '语音播报失败：$message',
        icon: Icons.volume_off_rounded);
  }

  /// 开启一条新的流式回复：重置切句缓冲。角色没有可用音色时整条不朗读。
  void _beginVoiceReply(AICharacter character) {
    _cancelVoiceReply();
    if (kIsWeb || _disposed || !_voiceBroadcastEnabled) return;
    if (_voiceBroadcaster == null) return;
    final config = _db.voiceServiceConfig;
    final voiceId =
        VoiceServiceConfig.resolveVoiceId(character.voiceId, config);
    if (voiceId == null) return;
    _voiceActiveSpeaker = voiceId;
    _voiceSegmenter = SentenceSegmenter();
  }

  /// 追加流式增量；产出完整句子即入播报队列（文本与音频同序）。
  void _feedVoiceReplyDraft(String draft) {
    final segmenter = _voiceSegmenter;
    if (segmenter == null) return;
    // 流式 onDraft 携带累计全文；取本次新增部分，避免重复成句。
    final previous = _voiceFedTail;
    String delta;
    if (previous.isNotEmpty && draft.length >= previous.length &&
        draft.startsWith(previous)) {
      delta = draft.substring(previous.length);
    } else {
      // 前缀不稳定（极少数重写场景）：重新喂入，宁可让缓冲重新切分。
      delta = draft;
    }
    _voiceFedTail = draft;
    if (delta.isEmpty) return;
    _enqueueVoiceSentences(segmenter.push(delta));
  }

  /// 流式回复正常收尾：把缓冲里的最后一句（可能无句末标点）读完。
  void _flushVoiceReply() {
    final segmenter = _voiceSegmenter;
    final speaker = _voiceActiveSpeaker;
    _voiceSegmenter = null;
    _voiceActiveSpeaker = null;
    _voiceFedTail = '';
    if (segmenter == null || speaker == null) return;
    final broadcaster = _voiceBroadcaster;
    if (broadcaster == null) return;
    final tail = segmenter.finish();
    if (tail == null) return;
    final text = stripMarkdownForSpeech(tail);
    if (text.isNotEmpty) {
      broadcaster.speak(text: text, speaker: speaker);
    }
  }

  /// 放弃当前流式回复的缓冲（失败/被丢弃时调用；不会回头读残缺句）。
  void _cancelVoiceReply() {
    _voiceSegmenter = null;
    _voiceActiveSpeaker = null;
    _voiceFedTail = '';
  }

  void _enqueueVoiceSentences(List<String> sentences) {
    final broadcaster = _voiceBroadcaster;
    final speaker = _voiceActiveSpeaker;
    if (broadcaster == null || speaker == null) return;
    for (final raw in sentences) {
      final text = stripMarkdownForSpeech(raw);
      if (text.isEmpty) continue;
      broadcaster.speak(text: text, speaker: speaker);
    }
  }

  /// 停止播放并清空缓冲（用于关闭播报或页面失活）。
  Future<void> _stopVoiceBroadcast() async {
    _cancelVoiceReply();
    await _voiceBroadcaster?.stop();
  }

  /// 释放播报器底层资源（页面销毁时）。
  Future<void> _disposeVoiceBroadcast() async {
    _cancelVoiceReply();
    final broadcaster = _voiceBroadcaster;
    _voiceBroadcaster = null;
    await broadcaster?.dispose();
  }

  // —— 语音输入（麦克风 → 流式 ASR → 输入框文本，默认文字输入）——

  /// 语音输入是否可用（原生平台 + 绑定 Key + 配置了 ASR 资源）。
  bool get _asrUsable {
    if (kIsWeb) return false;
    final config = _db.voiceServiceConfig;
    return config.apiKeyBound && config.asrResourceId.trim().isNotEmpty;
  }

  /// 语音输入不可用时的引导文案（可用时返回 null）。
  String? _voiceInputUnusableHint() {
    if (kIsWeb) return null;
    final config = _db.voiceServiceConfig;
    if (!config.apiKeyBound) return '请先到 设置 → API 配置 → 语音服务 绑定语音 Key';
    if (config.asrResourceId.trim().isEmpty) return '语音服务未配置 ASR 资源，请到设置页填写';
    return null;
  }

  /// 输入区麦克风开关：空闲 → 开始聆听；聆听中 → 结束聆听（文本落定可编辑）。
  Future<void> _toggleVoiceInput() async {
    if (_voiceInputActive) {
      await _finishVoiceInput();
    } else {
      await _startVoiceInput();
    }
  }

  Future<void> _startVoiceInput() async {
    if (kIsWeb || _voiceInputActive) return;
    final hint = _voiceInputUnusableHint();
    if (hint != null) {
      if (_canTouchUi) {
        AppToast.show(context, hint, icon: Icons.mic_none_rounded);
      }
      return;
    }
    // 语音输入会接管整条输入内容；已有未发送文本时先请用户处理，避免静默丢失。
    if (_textController.text.trim().isNotEmpty ||
        _pendingAttachments.isNotEmpty) {
      if (_canTouchUi) {
        AppToast.show(
          context,
          '请先发送或清空当前内容，再开启语音输入',
          icon: Icons.info_outline_rounded,
        );
      }
      return;
    }
    final config = _db.voiceServiceConfig;
    final apiKey = await _db.readVoiceApiKey();
    if (!mounted || _disposed) return;
    if (apiKey == null || apiKey.trim().isEmpty) {
      if (_canTouchUi) {
        AppToast.show(context, '语音 Key 已失效，请到设置页重新绑定',
            icon: Icons.mic_none_rounded);
      }
      return;
    }
    final key = apiKey.trim();
    // 若正在播报上一条 AI 回复，先停掉外放，避免被麦克风收录造成自我识别。
    unawaited(_stopVoiceBroadcast());
    final controller = VoiceInputController(
      mic: RecordVoiceMicSource(),
      createSession: () => VolcengineAsrSession(
        open: openVolcWs,
        apiKey: key,
        resourceId: config.asrResourceId,
      ),
    );
    controller.onDisplayChanged = _applyVoiceInputText;
    controller.onError = _onVoiceInputFatal;
    _voiceInputController = controller;
    final error = await controller.start();
    if (!mounted || _disposed) return;
    if (error != null) {
      _voiceInputController = null;
      if (_canTouchUi) {
        AppToast.show(context, error, icon: Icons.mic_off_rounded);
      }
      // 释放本次尝试占用的麦克风（下次开启会新建实例）。
      unawaited(controller.dispose());
      return;
    }
    _setUiState(() {
      _voiceInputActive = true;
      // 让识别文本成为唯一输入内容（开启前已校验输入框为空）。
      _textController.clear();
    });
  }

  /// 识别文本变化回调：写入输入框（聆听中输入框为只读，无编辑冲突）。
  void _applyVoiceInputText(String text) {
    if (!mounted || _disposed || !_voiceInputActive) return;
    _textController.text = text;
  }

  /// 用户结束聆听：把已识别文本留在输入框，交回普通编辑。
  ///
  /// 先让 [VoiceInputController.stop] 在收尾窗口（~300ms）内把最终句落定，
  /// 再解除只读——否则最后一句 final 会因 [voiceInputActive] 已为 false
  /// 而被 [_applyVoiceInputText] 忽略。
  Future<void> _finishVoiceInput() async {
    final controller = _voiceInputController;
    if (controller == null) {
      _voiceInputActive = false;
      return;
    }
    await controller.stop();
    _voiceInputController = null;
    _voiceInputActive = false;
    if (_canTouchUi) _setUiState(() {});
  }

  void _onVoiceInputFatal(String message) {
    _voiceInputController = null;
    if (!_voiceInputActive) return;
    _voiceInputActive = false;
    if (!_canTouchUi) return;
    _setUiState(() {});
    AppToast.show(context, '语音输入失败：$message', icon: Icons.mic_off_rounded);
  }

  /// 发送入口：若仍在聆听，先结束聆听把文本落定，再走常规发送。
  ///
  /// 输入框实时文本与 ASR 最终结果在 `stop()` 的收尾窗口内对齐，因此发送前
  /// 必须先 [VoiceInputController.stop] 落定，避免带着半句候补就发出去。
  Future<void> _sendAfterVoiceInput() async {
    if (_voiceInputActive) {
      await _finishVoiceInput();
      if (!mounted || _disposed) return;
    }
    await _sendMessage();
  }

  /// 页面失活 / 销毁时立即停下麦克风与 ASR（已展示的识别文本保留在输入框）。
  Future<void> _disposeVoiceInput() async {
    final controller = _voiceInputController;
    _voiceInputController = null;
    _voiceInputActive = false;
    await controller?.dispose();
  }
}
