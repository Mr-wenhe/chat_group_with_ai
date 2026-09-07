import 'package:chat_group/features/backup/backup_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('backup diagnostics redact local paths and credentials', () {
    final safe = sanitizeBackupError(
      'failed at /Users/alice/private.txt api_key=sk-abcdefgh12345678',
    );

    expect(safe, contains('[本地路径]'));
    expect(safe, contains('[REDACTED]'));
    expect(safe, isNot(contains('/Users/alice')));
    expect(safe, isNot(contains('sk-abcdefgh12345678')));
  });
}
