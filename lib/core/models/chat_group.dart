import 'package:hive/hive.dart';
import 'package:uuid/uuid.dart';

part 'chat_group.g.dart';

@HiveType(typeId: 1)
class ChatGroup extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  String name;

  @HiveField(2)
  String theme;

  @HiveField(3)
  String description;

  @HiveField(4)
  List<String> aiCharacterIds;

  @HiveField(5)
  final DateTime createdAt;

  ChatGroup({
    String? id,
    required this.name,
    required this.theme,
    this.description = '',
    required this.aiCharacterIds,
    DateTime? createdAt,
  })  : id = id ?? const Uuid().v4(),
        createdAt = createdAt ?? DateTime.now();
}
