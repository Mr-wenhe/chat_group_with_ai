import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/evidence_memory.dart';

class EvidenceMemoryService {
  final DatabaseService db;

  const EvidenceMemoryService({required this.db});

  Future<EvidenceMemory> remember({
    required String subjectCharacterId,
    required String targetId,
    required String targetType,
    required EvidenceMemoryType type,
    required String content,
    required String evidenceConversationId,
    String? evidenceMessageId,
    String? evidenceTaskId,
    String? evidenceTaskStepId,
    required String evidenceSnippet,
    DateTime? occurredAt,
    double confidence = 0.7,
  }) async {
    if (content.trim().isEmpty || evidenceSnippet.trim().isEmpty) {
      throw ArgumentError('Evidence memory requires content and evidence.');
    }
    final memory = EvidenceMemory(
      subjectCharacterId: subjectCharacterId,
      targetId: targetId,
      targetType: targetType,
      type: type,
      content: _clip(content.trim(), 240),
      evidenceConversationId: evidenceConversationId,
      evidenceMessageId: evidenceMessageId,
      evidenceTaskId: evidenceTaskId,
      evidenceTaskStepId: evidenceTaskStepId,
      evidenceSnippet: _clip(evidenceSnippet.trim(), 300),
      occurredAt: occurredAt,
      confidence: confidence,
    );
    await db.evidenceMemoryBox.put(memory.id, memory);
    return memory;
  }

  Future<EvidenceMemory> correct({
    required EvidenceMemory original,
    required String correctedContent,
    required String evidenceSnippet,
  }) async {
    original
      ..deleted = true
      ..userCorrected = true
      ..updatedAt = DateTime.now();
    await db.evidenceMemoryBox.put(original.id, original);
    return remember(
      subjectCharacterId: original.subjectCharacterId,
      targetId: original.targetId,
      targetType: original.targetType,
      type: EvidenceMemoryType.correction,
      content: correctedContent,
      evidenceConversationId: original.evidenceConversationId,
      evidenceMessageId: original.evidenceMessageId,
      evidenceTaskId: original.evidenceTaskId,
      evidenceTaskStepId: original.evidenceTaskStepId,
      evidenceSnippet: evidenceSnippet,
      occurredAt: DateTime.now(),
      confidence: 1.0,
    );
  }

  List<EvidenceMemory> relevantFor({
    required String subjectCharacterId,
    required Iterable<String> targetIds,
    int limit = 8,
  }) {
    final targets = targetIds.toSet();
    final values = db.evidenceMemoryBox.values
        .where((m) => !m.deleted)
        .where((m) => m.subjectCharacterId == subjectCharacterId)
        .where((m) =>
            m.targetId == subjectCharacterId ||
            m.targetId == 'user' ||
            targets.contains(m.targetId))
        .toList()
      ..sort((a, b) {
        final priority = _priority(b).compareTo(_priority(a));
        if (priority != 0) return priority;
        return b.updatedAt.compareTo(a.updatedAt);
      });
    return values.take(limit).toList();
  }

  static String promptLine(EvidenceMemory memory) {
    final date = memory.occurredAt.toIso8601String().split('T').first;
    return '$date，证据「${memory.evidenceSnippet}」支持：${memory.content}';
  }

  static int _priority(EvidenceMemory memory) {
    if (memory.type == EvidenceMemoryType.correction) return 100;
    return (memory.confidence * 10).round();
  }

  static String _clip(String text, int max) {
    return text.length <= max ? text : text.substring(0, max);
  }
}
