import 'package:hive/hive.dart';
import 'package:uuid/uuid.dart';

part 'evidence_memory.g.dart';

@HiveType(typeId: 19)
enum EvidenceMemoryType {
  @HiveField(0)
  selfFact,
  @HiveField(1)
  userFact,
  @HiveField(2)
  relationship,
  @HiveField(3)
  taskFact,
  @HiveField(4)
  correction,
}

@HiveType(typeId: 20)
class EvidenceMemory extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  String subjectCharacterId;

  @HiveField(2)
  String targetId;

  @HiveField(3)
  String targetType;

  @HiveField(4)
  EvidenceMemoryType type;

  @HiveField(5)
  String content;

  @HiveField(6)
  String evidenceConversationId;

  @HiveField(7)
  String? evidenceMessageId;

  @HiveField(8)
  String? evidenceTaskId;

  @HiveField(9)
  String? evidenceTaskStepId;

  @HiveField(10)
  String evidenceSnippet;

  @HiveField(11)
  DateTime occurredAt;

  @HiveField(12)
  DateTime createdAt;

  @HiveField(13)
  DateTime updatedAt;

  @HiveField(14)
  double confidence;

  @HiveField(15)
  bool deleted;

  @HiveField(16)
  bool userCorrected;

  EvidenceMemory({
    String? id,
    required this.subjectCharacterId,
    required this.targetId,
    required this.targetType,
    required this.type,
    required this.content,
    required this.evidenceConversationId,
    this.evidenceMessageId,
    this.evidenceTaskId,
    this.evidenceTaskStepId,
    required this.evidenceSnippet,
    DateTime? occurredAt,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.confidence = 0.7,
    this.deleted = false,
    this.userCorrected = false,
  })  : id = id ?? const Uuid().v4(),
        occurredAt = occurredAt ?? DateTime.now(),
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();
}
