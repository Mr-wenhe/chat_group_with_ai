/// Durable decisions made at a work-mode approval boundary.
///
/// The wire value is intentionally small and explicit so a task can be
/// resumed without reconstructing a Flutter dialog. In particular,
/// [approvedWithoutUndo] is not interchangeable with an ordinary approval.
enum WorkChangeApprovalDecision {
  approved('approved'),
  approvedWithoutUndo('approvedWithoutUndo'),
  rejected('rejected');

  final String wireName;
  const WorkChangeApprovalDecision(this.wireName);

  static WorkChangeApprovalDecision? fromWire(Object? value) {
    final raw = value?.toString();
    for (final decision in values) {
      if (decision.wireName == raw) return decision;
    }
    return null;
  }

  bool get permitsExecution => this != rejected;
  bool get permitsWithoutUndo => this == approvedWithoutUndo;
}
