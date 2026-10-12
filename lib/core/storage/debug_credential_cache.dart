import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

/// 本地明文凭据库（Hive box `dev_credentials`），承担两种角色：
///
///   - **macOS 上是唯一存储**（[isPrimaryStore]）。本项目的 macOS 构建始终是 ad-hoc
///     签名，钥匙串 ACL 认不出每次重建后的二进制：debug 下每次读取都弹一次登录密码
///     框，Release 下未启用 App Sandbox 时 Data Protection Keychain 直接写入失败。
///     与其继续和签名方式缠斗，macOS 一律改用本机库，读写删都不再触碰钥匙串。
///   - **其余平台的非 Release 是钥匙串前的镜像缓存**（[enabled]）。首次成功读取钥匙串
///     后把值复制到这里，之后每次读取都命中镜像，把上面那个弹窗收敛到每个键至多一次
///     ——「始终允许」只对点它时那个二进制有效，重建即失效。写入**只写镜像、不碰钥匙
///     串**：重建后的二进制做任何钥匙串写入同样会弹框，而这正是镜像要避开的东西。
///
/// 两种角色下明文都只落在本机：这个 box 被 gitignore、不进 release 模板、不进备份，
/// 也在工作模式交付物的 denylist 里（见 [boxName]）。与平台安全存储相比，它少了系统级
/// 加密，所以**不要**把它扩展到 macOS 以外的平台去当正式存储：那里钥匙串是可用的。
class DebugCredentialCache {
  DebugCredentialCache._();

  /// 存放明文凭据的 Hive box。
  ///
  /// 文件名沿用历史命名（它最初只是 debug 镜像），**不要**因为 macOS 把它当正式存储
  /// 就改名：`dev_credentials.hive` 已经出现在 `.gitignore` 与工作模式交付物的
  /// denylist 里，改名必须同步这两处安全清单，漏掉任何一处都会让明文密钥进仓库或
  /// 进交付物。Gitignored；不进备份；不在 release 模板里。
  static const String boxName = 'dev_credentials';

  static const String _valuePrefix = 'v:';

  /// Tombstone for a key the user deleted.
  ///
  /// Without it the next read would miss the mirror and fall back to secure
  /// storage, resurrecting the deleted secret — the exact failure the credential
  /// layer is built to prevent.
  static const String _tombstonePrefix = 'd:';

  static bool get enabled => !kReleaseMode && !kIsWeb;

  /// macOS 上本库是**唯一**的凭据存储，debug 与 release 都一样。
  ///
  /// 用 `defaultTargetPlatform` 而不是 `dart:io` 的 `Platform.isMacOS`：后者会让
  /// Web 构建直接编译不过，而这一层在 Web 上仍然要能编译（只是永远返回 false）。
  static bool get isPrimaryStore =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  /// 初始化时是否**必须**打开这个 box。
  ///
  /// 与 [enabled] 分开：macOS 上连 release 都要打开（它是正式存储），其余平台只有
  /// 非 Release 的镜像需要。判断 box 该不该开必须用这个，用 [enabled] 会让 macOS
  /// release 拿不到任何凭据。
  static bool get isRequired => isPrimaryStore || enabled;

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

  // ── 直通读写（仅 macOS，[isPrimaryStore] 为 true 时由 SecureStorageService 调用）──
  //
  // 与上面的镜像三件套共用同一套前缀与墓碑，所以两种角色不会对同一个键产生两种
  // 解读。下面三个方法都不接受回退闭包：macOS 上没有「另一个存储」可以退。

  /// 直读本库，不做任何回退。缺失、墓碑、空串一律返回 null。
  ///
  /// box 未打开时返回 null 而不是抛异常：读不到凭据在本层已经能被
  /// [CredentialRepository] 表达成一次明确的失败，没必要让每次读操作都崩。
  static Future<String?> readLocal(String key) async {
    final box = _box;
    if (box == null) return null;
    if (box.get('$_tombstonePrefix$key') == true) return null;
    final value = box.get('$_valuePrefix$key');
    return value is String && value.isNotEmpty ? value : null;
  }

  /// 写入本库，同时清掉可能存在的墓碑。
  ///
  /// box 未打开时抛错而不是静默丢弃：macOS 上这里是凭据唯一的落点，悄悄吞掉会让
  /// 用户以为密钥存住了，实际每次请求都缺凭据。调用方（[CredentialRepository]）
  /// 会把异常收敛成一次明确的保存失败。
  static Future<void> writeLocal(String key, String value) async {
    final box = _box;
    if (box == null) {
      throw StateError('本地凭据库未打开，无法保存凭据');
    }
    await box.put('$_valuePrefix$key', value);
    await box.delete('$_tombstonePrefix$key');
  }

  /// 删除本库里的值并落下墓碑，防止已被删除的键在后续读取中复活。
  static Future<void> deleteLocal(String key) async {
    final box = _box;
    if (box == null) return;
    await box.put('$_tombstonePrefix$key', true);
    await box.delete('$_valuePrefix$key');
  }
}
