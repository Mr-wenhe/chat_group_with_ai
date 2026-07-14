import 'package:hive/hive.dart';
import 'package:uuid/uuid.dart';

part 'work_mode_workspace.g.dart';

/// Per-conversation sandbox used by explicit work mode.
///
/// It contains no authorization flags: every sensitive operation still needs
/// a fresh, session-local approval at the tool boundary.
@HiveType(typeId: 16)
class WorkModeWorkspace extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final String conversationId;

  @HiveField(2)
  final String conversationType;

  @HiveField(3)
  String workDirPath;

  @HiveField(4)
  DateTime updatedAt;

  WorkModeWorkspace({
    String? id,
    required this.conversationId,
    required this.conversationType,
    this.workDirPath = '',
    DateTime? updatedAt,
  })  : id = id ?? const Uuid().v4(),
        updatedAt = updatedAt ?? DateTime.now();
}
