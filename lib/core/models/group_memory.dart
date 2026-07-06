import 'package:hive/hive.dart';

part 'group_memory.g.dart';

@HiveType(typeId: 3)
class GroupMemory extends HiveObject {
  @HiveField(0)
  final String groupId;

  @HiveField(1)
  String topicSummary;

  @HiveField(2)
  DateTime lastSummaryAt;

  GroupMemory({
    required this.groupId,
    this.topicSummary = '',
    DateTime? lastSummaryAt,
  }) : lastSummaryAt = lastSummaryAt ?? DateTime.now();
}
