part of 'observation_entry.dart';

/// Work experience is a proved action, never an inferred project conclusion.
/// No extra model call can turn an unresolved chat claim into a global fact.
extension ObservationEntryWork on ObservationEntry {
  static const _methodConditions = {
    'workspace.read': '在已授权范围内查证现有文件；当前内容必须重新读取。',
    'workspace.search': '在已授权范围内定位相关文本；命中不是运行验证。',
    'workspace.list': '在已授权范围内确认目录内容；不推断未读取文件的事实。',
    'workspace.document': '读取已授权文档；格式读取成功不等于内容验收通过。',
  };

  /// Queues before writing so an interrupted/failed write remains retryable.
  /// Memory failure is deliberately separate from the successful tool action.
  Future<void> recordWorkExperience(Message message) async {
    final stored = db.messageBox.get(message.id);
    if (stored == null) return;
    message = stored;
    if (!_eligibleWorkEvidence(message) ||
        !MemoryControls(db).automaticMemoryEnabled) {
      return;
    }
    try {
      await retryQueue.enqueue(
        messageId: message.id,
        observerId: message.senderId,
        conversationId: message.groupId,
        conversationNameSnapshot:
            db.chatGroupBox.get(message.groupId)?.name ?? '',
      );
      if (await writeWorkExperience(message)) {
        await retryQueue.complete(message.id, message.senderId);
      }
    } on Object {
      // The persisted source receipt may be retried by the next work run.
    }
  }

  bool _eligibleWorkEvidence(Message message) {
    final evidence = message.workMemoryEvidence;
    return message.isWorkMode &&
        message.senderType == 'ai' &&
        message.visibleToCharacterIds.contains(message.senderId) &&
        evidence != null &&
        evidence['taskId'] is String &&
        evidence['scopeId'] is String &&
        evidence['evidenceRef'] is String &&
        (evidence['evidenceRef'] as String).isNotEmpty &&
        _methodConditions.containsKey(evidence['tool']);
  }

  Future<bool> writeWorkExperience(Message message) async {
    final stored = db.messageBox.get(message.id);
    if (stored == null) return true;
    message = stored;
    if (!_eligibleWorkEvidence(message)) return true;
    if (!MemoryControls(db).automaticMemoryEnabled) return false;
    final source = message.workMemoryEvidence!;
    final task = db.agentTaskBox.get(source['taskId']);
    if (task == null || task.groupId != message.groupId) return true;
    final id =
        'work-method:${message.senderId}:${message.id}:${source['evidenceRef']}';
    // Includes inactive records: forgetting/correcting is not undone by replay.
    if (db.permanentMemoryBox.containsKey(id)) return true;
    final tool = source['tool'] as String;
    final applicability = _methodConditions[tool]!;
    final content = '曾实际使用 $tool 完成授权材料查证。';
    if (db.permanentMemoryBox.values.any((m) =>
        m.observerCharacterId == message.senderId &&
        m.workSource?['type'] == 'verifiedMethod' &&
        m.content == content)) {
      return true;
    }
    try {
      await db.permanentMemoryBox
          .put(id, _workMethodMemory(message, id, content, applicability));
      return true;
    } on Object {
      return false;
    }
  }

  PermanentMemory _workMethodMemory(
      Message message, String id, String content, String applicability) {
    final source = message.workMemoryEvidence!;
    return PermanentMemory(
      id: id,
      observerCharacterId: message.senderId,
      kind: MemoryKind.personaGrowth,
      content: content,
      status: MemoryStatus.active,
      originType: MemoryOriginType.group,
      originConversationId: message.groupId,
      originNameSnapshot: db.chatGroupBox.get(message.groupId)?.name ?? '',
      sourceMessageIds: [message.id],
      participantIds: [message.senderId],
      occurredAt: message.timestamp,
      workSource: {
        'type': 'verifiedMethod',
        'scopeId': null,
        'originScopeId': source['scopeId'],
        'taskId': source['taskId'],
        'evidenceRef': source['evidenceRef'],
        'issueId': source['issueId'],
        'requestRevision': source['requestRevision'],
        'applicability': applicability,
      },
    );
  }
}
