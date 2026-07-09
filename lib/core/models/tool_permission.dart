import 'package:hive/hive.dart';

part 'tool_permission.g.dart';

@HiveType(typeId: 10)
enum ToolPermission {
  @HiveField(0)
  workspaceRead,
  @HiveField(1)
  workspacePatch,
  @HiveField(2)
  commandRun,
  @HiveField(3)
  browserContext,
  @HiveField(4)
  skillCreate,
  @HiveField(5)
  skillDownload,
}
