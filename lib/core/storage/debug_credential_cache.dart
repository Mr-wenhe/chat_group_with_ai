import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

/// Debug-only plaintext mirror of the platform secure store.
///
/// Debug builds are ad-hoc signed, so every rebuild produces a new code
/// identity. macOS then sees the rebuilt binary as a stranger to the Keychain
/// item's ACL and asks for the login keychain password on every read; 「始终允许」
/// only ever covers the binary that was running when it was clicked. The prompt
/// cannot be suppressed from inside the app, so this cache pays it at most once
/// per key instead of once per launch: the first successful secure read is
/// copied here, and every later read is answered without touching the Keychain.
///
/// The scope is deliberately narrow:
///   - [enabled] is false in release builds and on web, and the box is only
///     opened by the non-release initialization path, so a release binary can
///     neither read nor write these values;
///   - writes never reach secure storage. Any write from a rebuilt debug binary
///     can prompt, which is exactly the prompt this cache exists to avoid.
class DebugCredentialCache {
  DebugCredentialCache._();

  /// Hive box holding the mirrored values. Gitignored; never opened in release,
  /// never carried by backups, never listed in the release template.
  static const String boxName = 'dev_credentials';

  static const String _valuePrefix = 'v:';

  /// Tombstone for a key the user deleted.
  ///
  /// Without it the next read would miss the mirror and fall back to secure
  /// storage, resurrecting the deleted secret — the exact failure the credential
  /// layer is built to prevent.
  static const String _tombstonePrefix = 'd:';

  static bool get enabled => !kReleaseMode && !kIsWeb;

  static Box<dynamic>? _bound;

  /// Test seam: binds the cache to a box the caller opened. Pass null to unbind.
  @visibleForTesting
  static void bind(Box<dynamic>? box) => _bound = box;

  static Box<dynamic>? get _box {
    final bound = _bound;
    if (bound != null) {
      if (bound.isOpen) return bound;
      // A closed box would make every credential operation throw, so drop the
      // stale handle and let the lookup below decide.
      _bound = null;
    }
    if (!Hive.isBoxOpen(boxName)) return null;
    return _bound = Hive.box<dynamic>(boxName);
  }

  /// Returns the mirrored value, filling the mirror from [readSecure] on a miss.
  ///
  /// [readSecure] may throw; the failure propagates so the credential layer can
  /// report a permission failure rather than a silently missing key.
  static Future<String?> read(
    String key,
    Future<String?> Function() readSecure,
  ) async {
    final box = _box;
    if (box == null) return readSecure();
    if (box.get('$_tombstonePrefix$key') == true) return null;
    final mirrored = box.get('$_valuePrefix$key');
    if (mirrored is String && mirrored.isNotEmpty) return mirrored;
    final value = await readSecure();
    if (value != null && value.isNotEmpty) {
      await box.put('$_valuePrefix$key', value);
    }
    return value;
  }

  /// Stores [value] in the mirror, falling back to [writeSecure] only when no
  /// mirror is bound — a missing mirror must never swallow the secret.
  static Future<void> write(
    String key,
    String value,
    Future<void> Function() writeSecure,
  ) async {
    if (!await mirror(key, value)) await writeSecure();
  }

  /// Mirrors a value that is already on hand, without touching secure storage.
  ///
  /// Returns false when nothing is bound, i.e. there was nowhere to mirror to.
  static Future<bool> mirror(String key, String value) async {
    final box = _box;
    if (box == null) return false;
    await box.put('$_valuePrefix$key', value);
    await box.delete('$_tombstonePrefix$key');
    return true;
  }

  /// Mirrors the deletion, then lets the caller remove the platform entry.
  ///
  /// The tombstone is written first and is authoritative, so a denied Keychain
  /// prompt — swallowed here by design — cannot leave the secret readable.
  static Future<void> delete(
    String key,
    Future<void> Function() removeSecure,
  ) async {
    final box = _box;
    if (box == null) return removeSecure();
    await box.put('$_tombstonePrefix$key', true);
    await box.delete('$_valuePrefix$key');
    try {
      await removeSecure();
    } on Object {
      // Best effort: the mirror already refuses to serve this key, and a denied
      // prompt must not fail an operation the user asked for. Residual risk is
      // an unreferenced Keychain item, which no configuration can still read.
    }
  }

  /// Drops only the mirrored copy, leaving secure storage untouched.
  ///
  /// Used when a record is removed together with a secret that never lived in
  /// secure storage, so nothing else would clean the mirror up.
  static Future<void> forget(String key) async {
    final box = _box;
    if (box == null) return;
    await box.delete('$_valuePrefix$key');
    await box.delete('$_tombstonePrefix$key');
  }
}
