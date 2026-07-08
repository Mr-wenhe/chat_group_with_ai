import 'package:hive/hive.dart';
import 'package:uuid/uuid.dart';

part 'relationship_state.g.dart';

@HiveType(typeId: 6)
enum RelationshipTargetType {
  @HiveField(0)
  ai,
  @HiveField(1)
  user,
}

@HiveType(typeId: 7)
enum RelationshipMood {
  @HiveField(0)
  neutral,
  @HiveField(1)
  warm,
  @HiveField(2)
  annoyed,
  @HiveField(3)
  awkward,
  @HiveField(4)
  protective,
  @HiveField(5)
  cold,
}

@HiveType(typeId: 8)
class RelationshipState extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final String groupId;

  @HiveField(2)
  final String sourceCharacterId;

  @HiveField(3)
  final String targetId;

  @HiveField(4)
  RelationshipTargetType targetType;

  @HiveField(5)
  int affinity;

  @HiveField(6)
  int trust;

  @HiveField(7)
  int friction;

  @HiveField(8)
  int familiarity;

  @HiveField(9)
  RelationshipMood recentMood;

  @HiveField(10)
  String notes;

  @HiveField(11)
  DateTime lastInteractionAt;

  @HiveField(12)
  final DateTime createdAt;

  RelationshipState({
    String? id,
    required this.groupId,
    required this.sourceCharacterId,
    required this.targetId,
    required this.targetType,
    this.affinity = 0,
    this.trust = 0,
    this.friction = 0,
    this.familiarity = 0,
    this.recentMood = RelationshipMood.neutral,
    this.notes = '',
    DateTime? lastInteractionAt,
    DateTime? createdAt,
  })  : id = id ?? const Uuid().v4(),
        lastInteractionAt = lastInteractionAt ?? DateTime.now(),
        createdAt = createdAt ?? DateTime.now();

  void clampScores() {
    affinity = affinity.clamp(-100, 100).toInt();
    trust = trust.clamp(-100, 100).toInt();
    friction = friction.clamp(0, 100).toInt();
    familiarity = familiarity.clamp(0, 100).toInt();
  }
}
