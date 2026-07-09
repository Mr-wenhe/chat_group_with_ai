import 'package:hive/hive.dart';
import 'package:uuid/uuid.dart';

import 'tool_permission.dart';

part 'character_skill.g.dart';

@HiveType(typeId: 11)
class CharacterSkill extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final String characterId;

  @HiveField(2)
  String name;

  @HiveField(3)
  String domain;

  @HiveField(4)
  String description;

  @HiveField(5)
  List<String> instructions;

  @HiveField(6)
  List<ToolPermission> requiredPermissions;

  @HiveField(7)
  DateTime createdAt;

  @HiveField(8)
  DateTime updatedAt;

  CharacterSkill({
    String? id,
    required this.characterId,
    required this.name,
    required this.domain,
    required this.description,
    required this.instructions,
    required this.requiredPermissions,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : id = id ?? const Uuid().v4(),
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  bool get isGlobal => characterId.isEmpty;
}
