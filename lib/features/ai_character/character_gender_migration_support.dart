import 'package:chat_group/core/database/database_service.dart';

class CharacterGenderMigrationReport {
  int remoteResolved = 0;
  int localFallback = 0;
  int saved = 0;
  int saveFailures = 0;
  int stateSaveFailures = 0;
  bool completed = false;
}

typedef CharacterGenderDecisionPersistenceResult = ({
  bool characterSaved,
  bool characterSaveFailed,
  bool stateSaveFailed,
});

Future<void> writeCharacterGenderDiagnosticSafely(
  DatabaseService db, {
  required String diagnosticKey,
  required String status,
  required int characterCount,
  int remoteResolved = 0,
  int localFallback = 0,
  int saved = 0,
  int saveFailures = 0,
  int stateSaveFailures = 0,
  int batches = 0,
  Iterable<String> reasonCodes = const [],
}) async {
  try {
    final reasons = reasonCodes.toSet().toList()..sort();
    await db.appSettingsBox.put(diagnosticKey, {
      'version': 1,
      'status': status,
      'characterCount': characterCount,
      'remoteResolved': remoteResolved,
      'localFallback': localFallback,
      'saved': saved,
      'saveFailures': saveFailures,
      'stateSaveFailures': stateSaveFailures,
      'batches': batches,
      'reasonCodes': reasons,
      'completedAt': DateTime.now().toIso8601String(),
    });
  } on Object {
    // Diagnostics are best effort and must never mask the migration result.
  }
}
