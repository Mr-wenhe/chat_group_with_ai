enum WorkTaskEventKind {
  queued,
  planning,
  stepStarted,
  toolOutput,
  approvalRequired,
  paused,
  stepCompleted,
  failed,
  completed,
  undoCompleted,
  modelOutput,
}

/// A public, persisted task update. It intentionally has no field for model
/// reasoning or raw tool output; callers must provide only display-safe text.
class WorkTaskEvent {
  final String taskId;
  final int sequence;
  final DateTime timestamp;
  final WorkTaskEventKind kind;
  final String title;
  final String detail;
  final int? progressCurrent;
  final int? progressTotal;
  final Map<String, dynamic> safeMetadata;

  WorkTaskEvent({
    required this.taskId,
    required this.sequence,
    required DateTime timestamp,
    required this.kind,
    required this.title,
    this.detail = '',
    this.progressCurrent,
    this.progressTotal,
    Map<String, dynamic>? safeMetadata,
  })  : timestamp = timestamp.toUtc(),
        safeMetadata = Map.unmodifiable(
          Map<String, dynamic>.from(safeMetadata ?? const {}),
        );

  Map<String, dynamic> toJson() => {
        'taskId': taskId,
        'sequence': sequence,
        'timestamp': timestamp.toIso8601String(),
        'kind': kind.name,
        'title': title,
        'detail': detail,
        'progressCurrent': progressCurrent,
        'progressTotal': progressTotal,
        'safeMetadata': safeMetadata,
      };

  factory WorkTaskEvent.fromJson(Map<String, dynamic> json) {
    final taskId = json['taskId'];
    final sequence = json['sequence'];
    final timestamp = json['timestamp'];
    final kind = json['kind'];
    final title = json['title'];
    if (taskId is! String ||
        taskId.isEmpty ||
        sequence is! num ||
        sequence.toInt() <= 0 ||
        timestamp is! String ||
        kind is! String ||
        title is! String ||
        title.isEmpty) {
      throw const FormatException('任务事件字段无效');
    }
    final parsedTimestamp = DateTime.tryParse(timestamp);
    if (parsedTimestamp == null) {
      throw const FormatException('任务事件时间无效');
    }
    final parsedKind = WorkTaskEventKind.values.where(
      (candidate) => candidate.name == kind,
    );
    if (parsedKind.isEmpty) {
      throw const FormatException('任务事件类型无效');
    }
    return WorkTaskEvent(
      taskId: taskId,
      sequence: sequence.toInt(),
      timestamp: parsedTimestamp,
      kind: parsedKind.single,
      title: title,
      detail: json['detail'] is String ? json['detail'] as String : '',
      progressCurrent: _optionalInteger(json['progressCurrent']),
      progressTotal: _optionalInteger(json['progressTotal']),
      safeMetadata: _metadata(json['safeMetadata']),
    );
  }

  static int? _optionalInteger(Object? value) {
    if (value == null) return null;
    if (value is! num) throw const FormatException('任务事件进度无效');
    return value.toInt();
  }

  static Map<String, dynamic> _metadata(Object? value) {
    if (value == null) return const {};
    if (value is! Map) throw const FormatException('任务事件元数据无效');
    return Map<String, dynamic>.from(value);
  }
}
