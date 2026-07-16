import 'package:chat_group/features/chat_group/models/chat_room_models.dart';

enum ConversationPhase {
  idle,
  userMessageQueued,
  normalGenerating,
  autoGenerating,
  workRunning,
  waitingForApproval,
  stopping,
  failed,
  disposed,
}

enum ConversationRunType { normal, automatic, work }

class ConversationRun {
  final String id;
  final ConversationRunType type;
  final DateTime startedAt;

  const ConversationRun({
    required this.id,
    required this.type,
    required this.startedAt,
  });
}

class ConversationViewState {
  final ConversationPhase phase;
  final ConversationRun? run;
  final int queuedUserMessageCount;
  final String? streamingDraft;
  final String? error;

  const ConversationViewState({
    this.phase = ConversationPhase.idle,
    this.run,
    this.queuedUserMessageCount = 0,
    this.streamingDraft,
    this.error,
  });
}

/// Owns the mutually-exclusive lifecycle shared by normal, automatic and work
/// runs. UI code may render [state], but cannot create overlapping runs.
class ConversationController {
  ConversationController({String Function()? idFactory})
      : _idFactory = idFactory ?? _defaultId;

  final String Function() _idFactory;
  final List<PendingUserMessage> _queue = [];
  ConversationViewState _state = const ConversationViewState();

  ConversationViewState get state => _state;
  bool get isBusy => switch (_state.phase) {
        ConversationPhase.normalGenerating ||
        ConversationPhase.autoGenerating ||
        ConversationPhase.workRunning ||
        ConversationPhase.waitingForApproval ||
        ConversationPhase.stopping =>
          true,
        _ => false,
      };

  ConversationRun? beginNormal() => _begin(ConversationRunType.normal);
  ConversationRun? beginAuto() => _begin(ConversationRunType.automatic);
  ConversationRun? beginWork() => _begin(ConversationRunType.work);

  bool resumeWork() {
    if (_state.phase != ConversationPhase.waitingForApproval) return false;
    _replace(phase: ConversationPhase.workRunning);
    return true;
  }

  ConversationRun? _begin(ConversationRunType type) {
    if (_state.phase == ConversationPhase.disposed || isBusy) return null;
    final run = ConversationRun(
      id: _idFactory(),
      type: type,
      startedAt: DateTime.now(),
    );
    _state = ConversationViewState(
      phase: switch (type) {
        ConversationRunType.normal => ConversationPhase.normalGenerating,
        ConversationRunType.automatic => ConversationPhase.autoGenerating,
        ConversationRunType.work => ConversationPhase.workRunning,
      },
      run: run,
      queuedUserMessageCount: _queue.length,
    );
    return run;
  }

  void enqueue(PendingUserMessage message) {
    if (_state.phase == ConversationPhase.disposed) return;
    _queue.add(message);
    _replace(queuedUserMessageCount: _queue.length);
  }

  PendingUserMessage? takeNext() {
    if (_queue.isEmpty) return null;
    final next = _queue.removeAt(0);
    _state = ConversationViewState(
      phase: _queue.isEmpty
          ? ConversationPhase.idle
          : ConversationPhase.userMessageQueued,
      queuedUserMessageCount: _queue.length,
    );
    return next;
  }

  bool waitForApproval() {
    if (_state.phase != ConversationPhase.workRunning) return false;
    _replace(phase: ConversationPhase.waitingForApproval);
    return true;
  }

  bool requestStop() {
    if (!isBusy || _state.phase == ConversationPhase.stopping) return false;
    _replace(phase: ConversationPhase.stopping);
    return true;
  }

  void updateStreamingDraft(String draft) {
    if (!isBusy || _state.phase == ConversationPhase.disposed) return;
    _replace(streamingDraft: draft);
  }

  void complete() {
    if (_state.phase == ConversationPhase.disposed) return;
    _state = ConversationViewState(
      phase: _queue.isEmpty
          ? ConversationPhase.idle
          : ConversationPhase.userMessageQueued,
      queuedUserMessageCount: _queue.length,
    );
  }

  void fail(String error) {
    if (_state.phase == ConversationPhase.disposed) return;
    _state = ConversationViewState(
      phase: ConversationPhase.failed,
      queuedUserMessageCount: _queue.length,
      error: error,
    );
  }

  void dispose() {
    _queue.clear();
    _state = const ConversationViewState(phase: ConversationPhase.disposed);
  }

  void _replace({
    ConversationPhase? phase,
    int? queuedUserMessageCount,
    String? streamingDraft,
  }) {
    _state = ConversationViewState(
      phase: phase ?? _state.phase,
      run: _state.run,
      queuedUserMessageCount:
          queuedUserMessageCount ?? _state.queuedUserMessageCount,
      streamingDraft: streamingDraft ?? _state.streamingDraft,
      error: _state.error,
    );
  }

  static String _defaultId() =>
      'run:${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
}
