import 'package:hive/hive.dart';
import 'package:uuid/uuid.dart';

part 'character_memory.g.dart';

@HiveType(typeId: 5)
class CharacterMemory extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final String groupId;

  @HiveField(2)
  final String characterId;

  @HiveField(3)
  List<String> facts;

  @HiveField(4)
  List<String> relationshipNotes;

  @HiveField(5)
  List<String> personaGrowth;

  @HiveField(6)
  DateTime lastUpdatedAt;

  @HiveField(7)
  final DateTime createdAt;

  CharacterMemory({
    String? id,
    required this.groupId,
    required this.characterId,
    List<String>? facts,
    List<String>? relationshipNotes,
    List<String>? personaGrowth,
    DateTime? lastUpdatedAt,
    DateTime? createdAt,
  })  : id = id ?? const Uuid().v4(),
        facts = facts ?? [],
        relationshipNotes = relationshipNotes ?? [],
        personaGrowth = personaGrowth ?? [],
        lastUpdatedAt = lastUpdatedAt ?? DateTime.now(),
        createdAt = createdAt ?? DateTime.now();
}
