import 'dart:async';
import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:hive/hive.dart';

typedef WorkFolderDirectoryValidator = Future<bool> Function(String path);
typedef WorkFolderPicker = Future<String?> Function();
typedef WorkFolderGrantConsent = Future<bool> Function(WorkFolderGrant grant);

enum WorkFolderRequestStatus { granted, cancelled, unavailable }

class WorkFolderRequestResult {
  final WorkFolderRequestStatus status;
  final WorkFolderGrant? grant;
  final String reason;

  const WorkFolderRequestResult({
    required this.status,
    this.grant,
    this.reason = '',
  });

  bool get granted => status == WorkFolderRequestStatus.granted;
  bool get paused => status != WorkFolderRequestStatus.granted;
}

class WorkFolderGrant {
  final String path;
  final String displayName;
  final DateTime addedAt;
  final DateTime? lastValidatedAt;
  final DateTime? cloudDisclosureConfirmedAt;
  final bool available;
  final bool writable;

  const WorkFolderGrant({
    required this.path,
    required this.displayName,
    required this.addedAt,
    required this.lastValidatedAt,
    this.cloudDisclosureConfirmedAt,
    required this.available,
    this.writable = true,
  });

  String get normalizedPath => path;
  bool get isAvailable => available;
  DateTime? get lastVerifiedAt => lastValidatedAt;

  WorkFolderGrant copyWith({
    DateTime? lastValidatedAt,
    DateTime? cloudDisclosureConfirmedAt,
    bool? available,
    bool? writable,
  }) {
    return WorkFolderGrant(
      path: path,
      displayName: displayName,
      addedAt: addedAt,
      lastValidatedAt: lastValidatedAt ?? this.lastValidatedAt,
      cloudDisclosureConfirmedAt:
          cloudDisclosureConfirmedAt ?? this.cloudDisclosureConfirmedAt,
      available: available ?? this.available,
      writable: writable ?? this.writable,
    );
  }

  Map<String, dynamic> toMap() => {
        'path': path,
        'displayName': displayName,
        'addedAt': addedAt.toIso8601String(),
        'lastValidatedAt': lastValidatedAt?.toIso8601String(),
        'cloudDisclosureConfirmedAt':
            cloudDisclosureConfirmedAt?.toIso8601String(),
        'available': available,
        'writable': writable,
      };

  factory WorkFolderGrant.fromMap(Map<dynamic, dynamic> raw) {
    final path = raw['path'];
    final displayName = raw['displayName'];
    final addedAt = _parseDate(raw['addedAt']);
    if (path is! String ||
        path.isEmpty ||
        displayName is! String ||
        displayName.isEmpty ||
        addedAt == null) {
      throw const FormatException('工作目录授权记录无效');
    }
    return WorkFolderGrant(
      path: path,
      displayName: displayName,
      addedAt: addedAt,
      lastValidatedAt: _parseDate(raw['lastValidatedAt']),
      cloudDisclosureConfirmedAt: _parseDate(raw['cloudDisclosureConfirmedAt']),
      available: raw['available'] == true,
      writable: raw['writable'] is bool
          ? raw['writable'] == true
          : raw['available'] == true,
    );
  }

  static DateTime? _parseDate(Object? value) {
    if (value is DateTime) return value;
    if (value is String) return DateTime.tryParse(value);
    return null;
  }
}

class WorkModeAgentSettings {
  static const int defaultRetentionDays = 30;
  static const int defaultSnapshotLimitBytes = 2 * 1024 * 1024 * 1024;
  static const int defaultActionLimit = 100;
  static const int defaultTimeLimitMinutes = 60;

  final bool ordinaryWriteConfirmation;
  final int retentionDays;
  final int snapshotLimitBytes;
  final int actionLimit;
  final int timeLimitMinutes;

  const WorkModeAgentSettings({
    this.ordinaryWriteConfirmation = true,
    this.retentionDays = defaultRetentionDays,
    this.snapshotLimitBytes = defaultSnapshotLimitBytes,
    this.actionLimit = defaultActionLimit,
    this.timeLimitMinutes = defaultTimeLimitMinutes,
  });

  bool get confirmOrdinaryWrites => ordinaryWriteConfirmation;

  Map<String, dynamic> toMap() => {
        'ordinaryWriteConfirmation': ordinaryWriteConfirmation,
        'retentionDays': retentionDays,
        'snapshotLimitBytes': snapshotLimitBytes,
        'actionLimit': actionLimit,
        'timeLimitMinutes': timeLimitMinutes,
      };

  factory WorkModeAgentSettings.fromMap(Map<dynamic, dynamic> raw) {
    int positiveInt(Object? value, int fallback) {
      final parsed = value is num ? value.toInt() : fallback;
      return parsed > 0 ? parsed : fallback;
    }

    return WorkModeAgentSettings(
      ordinaryWriteConfirmation: raw['ordinaryWriteConfirmation'] != false,
      retentionDays: positiveInt(raw['retentionDays'], defaultRetentionDays),
      snapshotLimitBytes:
          positiveInt(raw['snapshotLimitBytes'], defaultSnapshotLimitBytes),
      actionLimit: positiveInt(raw['actionLimit'], defaultActionLimit),
      timeLimitMinutes:
          positiveInt(raw['timeLimitMinutes'], defaultTimeLimitMinutes),
    );
  }
}

/// Persists app-wide folder grants only. It does not inspect directory content.
class WorkFolderGrantService {
  static const String grantsStorageKey = 'work_mode_folder_grants_v1';
  static const String settingsStorageKey = 'work_mode_agent_settings_v1';

  final Box<dynamic> box;
  final DateTime Function() clock;
  final WorkFolderDirectoryValidator _directoryValidator;
  final WorkFolderDirectoryValidator _writeDirectoryValidator;
  final bool isWindows;

  List<WorkFolderGrant> _grants;
  WorkModeAgentSettings _settings;
  Future<List<WorkFolderGrant>>? _loadFuture;

  WorkFolderGrantService({
    Box<dynamic>? box,
    DatabaseService? db,
    DateTime Function()? clock,
    WorkFolderDirectoryValidator? directoryValidator,
    WorkFolderDirectoryValidator? writeDirectoryValidator,
    bool? isWindows,
  })  : assert(box != null || db != null),
        box = box ?? db!.appSettingsBox,
        clock = clock ?? DateTime.now,
        _directoryValidator = directoryValidator ?? _directoryExists,
        _writeDirectoryValidator =
            writeDirectoryValidator ?? directoryValidator ?? _directoryWritable,
        isWindows = isWindows ?? Platform.isWindows,
        _grants = _decodeGrants(_resolveBox(box, db).get(grantsStorageKey)),
        _settings =
            _decodeSettings(_resolveBox(box, db).get(settingsStorageKey));

  List<WorkFolderGrant> get grants => List.unmodifiable(_grants);
  WorkModeAgentSettings get settings => _settings;

  Future<List<WorkFolderGrant>> load() {
    final existing = _loadFuture;
    if (existing != null) return existing;
    final operation = _loadAndValidate();
    _loadFuture = operation;
    // A transient Hive/permission failure must be retryable. Caching a failed
    // Future permanently would make every later task appear unauthorized until
    // the whole app process restarted.
    unawaited(
      operation.catchError((Object _) {
        if (identical(_loadFuture, operation)) _loadFuture = null;
        return <WorkFolderGrant>[];
      }),
    );
    return operation;
  }

  Future<List<WorkFolderGrant>> _loadAndValidate() async {
    _grants = _decodeGrants(box.get(grantsStorageKey));
    _settings = _decodeSettings(box.get(settingsStorageKey));
    await _refreshValidation();
    return grants;
  }

  Future<List<WorkFolderGrant>> refreshValidation() async {
    await load();
    await _refreshValidation();
    return grants;
  }

  Future<void> _refreshValidation() async {
    if (_grants.isEmpty) return;
    final now = clock();
    final checked = <WorkFolderGrant>[];
    for (final grant in _grants) {
      bool available;
      bool writable;
      try {
        available = await _directoryValidator(grant.path);
      } on Object {
        available = false;
      }
      try {
        writable = available && await _writeDirectoryValidator(grant.path);
      } on Object {
        writable = false;
      }
      checked.add(
        grant.copyWith(
          lastValidatedAt: now,
          available: available,
          writable: writable,
        ),
      );
    }
    _grants = checked;
    await _persistGrants();
  }

  Future<WorkFolderGrant> addDirectory(String rawPath) async {
    final normalized = normalizePath(rawPath, isWindows: isWindows);
    final existingIndex = _indexOf(normalized);
    if (existingIndex >= 0) {
      final current = _grants[existingIndex];
      final refreshed = await _validatedGrant(current);
      _grants[existingIndex] = refreshed;
      await _persistGrants();
      _loadFuture = null;
      return refreshed;
    }

    final coveringGrant = _grants.cast<WorkFolderGrant?>().firstWhere(
          (grant) =>
              grant != null &&
              grant.available &&
              _containsPath(grant.path, normalized),
          orElse: () => null,
        );
    if (coveringGrant != null) return coveringGrant;

    final now = clock();
    final created = await _validatedGrant(
      WorkFolderGrant(
        path: normalized,
        displayName: displayNameFor(normalized, isWindows: isWindows),
        addedAt: now,
        lastValidatedAt: now,
        available: false,
        writable: false,
      ),
    );
    // A parent grant makes child records redundant. Segment comparison keeps
    // `/work/a` from covering `/work/ab`.
    _grants = [
      ..._grants.where((grant) => !_containsPath(normalized, grant.path)),
      created,
    ];
    _grants.sort((left, right) => left.path.compareTo(right.path));
    await _persistGrants();
    _loadFuture = null;
    return created;
  }

  Future<bool> removeDirectory(String rawPath) async {
    final normalized = normalizePath(rawPath, isWindows: isWindows);
    final oldLength = _grants.length;
    _grants = _grants
        .where((grant) => !_samePath(grant.path, normalized))
        .toList(growable: false);
    if (_grants.length == oldLength) return false;
    await _persistGrants();
    _loadFuture = null;
    return true;
  }

  Future<WorkFolderGrant?> reauthorize(
    String oldPath,
    String selectedPath, {
    WorkFolderGrantConsent? consent,
  }) async {
    if (selectedPath.trim().isEmpty) return null;
    final replacement = await authorizeDirectory(
      selectedPath,
      consent: consent,
    );
    if (replacement == null) return null;
    if (!_samePath(oldPath, replacement.path)) {
      await removeDirectory(oldPath);
    }
    return replacement;
  }

  bool isPathAuthorized(String rawPath) {
    String normalized;
    try {
      normalized = normalizePath(rawPath, isWindows: isWindows);
    } on Object {
      return false;
    }
    return _grants.any(
      (grant) => grant.available && _containsPath(grant.path, normalized),
    );
  }

  bool isPathWritable(String rawPath) {
    final grant = grantForPath(rawPath);
    return grant?.writable == true;
  }

  Future<bool> isPathAuthorizedResolved(String rawPath) async {
    return (await _resolvedGrantForPath(rawPath)) != null;
  }

  Future<bool> isPathWritableResolved(String rawPath) async {
    final grant = await _resolvedGrantForPath(rawPath);
    return grant?.writable == true;
  }

  bool hasAvailableGrant() => _grants.any((grant) => grant.available);

  bool hasWritableGrant() =>
      _grants.any((grant) => grant.available && grant.writable);

  /// Returns only capabilities whose cloud-model disclosure has been
  /// confirmed. Legacy records remain visible in settings, but they cannot
  /// cross the work-mode boundary until the one-time consent is recorded.
  bool hasConfirmedAvailableGrant() => _grants.any(
        (grant) => grant.available && grant.cloudDisclosureConfirmedAt != null,
      );

  bool hasConfirmedWritableGrant() => _grants.any(
        (grant) =>
            grant.available &&
            grant.writable &&
            grant.cloudDisclosureConfirmedAt != null,
      );

  WorkFolderGrant? grantForPath(String rawPath) {
    String normalized;
    try {
      normalized = normalizePath(rawPath, isWindows: isWindows);
    } on Object {
      return null;
    }
    for (final grant in _grants) {
      if (grant.available &&
          grant.cloudDisclosureConfirmedAt != null &&
          _containsPath(grant.path, normalized)) {
        return grant;
      }
    }
    return null;
  }

  Future<WorkFolderRequestResult> requestFolder({
    required WorkFolderPicker picker,
    String? requestedPath,
    bool forcePicker = false,
    bool requireWritable = false,
    WorkFolderGrantConsent? consent,
  }) async {
    await load();
    final requested = requestedPath?.trim();
    if (!forcePicker && (requested == null || requested.isEmpty)) {
      final existing = _firstUsableGrant(requireWritable: requireWritable);
      if (existing != null) {
        final confirmed = await _confirmCloudDisclosure(existing, consent);
        if (!confirmed) {
          return WorkFolderRequestResult(
            status: consent == null
                ? WorkFolderRequestStatus.unavailable
                : WorkFolderRequestStatus.cancelled,
            reason: consent == null
                ? '工作目录授权需要确认云端模型的数据使用范围，请在执行面板中重试。'
                : '用户取消了工作目录授权。',
          );
        }
        final committed = existing.cloudDisclosureConfirmedAt != null
            ? existing
            : await _commitGrant(
                existing,
                cloudDisclosureConfirmedAt: clock(),
              );
        return WorkFolderRequestResult(
          status: WorkFolderRequestStatus.granted,
          grant: committed,
        );
      }
    }
    String? selected;
    try {
      selected = await picker();
    } on Object {
      return const WorkFolderRequestResult(
        status: WorkFolderRequestStatus.unavailable,
        reason: '无法打开目录选择器。',
      );
    }
    if (selected == null || selected.trim().isEmpty) {
      return const WorkFolderRequestResult(
        status: WorkFolderRequestStatus.cancelled,
        reason: '用户取消了工作目录授权。',
      );
    }
    try {
      final grant = await previewDirectory(selected);
      if (!grant.available) {
        return const WorkFolderRequestResult(
          status: WorkFolderRequestStatus.unavailable,
          reason: '所选工作目录当前不可用。',
        );
      }
      if (requireWritable && !grant.writable) {
        return const WorkFolderRequestResult(
          status: WorkFolderRequestStatus.unavailable,
          reason: '所选工作目录只读，工作模式写入需要可写目录。',
        );
      }
      if (requested != null &&
          requested.isNotEmpty &&
          !await _containsPathResolved(grant.path, requested)) {
        return const WorkFolderRequestResult(
          status: WorkFolderRequestStatus.unavailable,
          reason: '所选目录未覆盖原请求路径，请选择其所在目录。',
        );
      }
      final confirmed = await _confirmCloudDisclosure(grant, consent);
      if (!confirmed) {
        return WorkFolderRequestResult(
          status: consent == null
              ? WorkFolderRequestStatus.unavailable
              : WorkFolderRequestStatus.cancelled,
          reason: consent == null
              ? '工作目录授权需要确认云端模型的数据使用范围，请在执行面板中重试。'
              : '用户取消了工作目录授权。',
        );
      }
      final committed = await _commitGrant(
        grant,
        cloudDisclosureConfirmedAt: grant.cloudDisclosureConfirmedAt ?? clock(),
      );
      return WorkFolderRequestResult(
        status: WorkFolderRequestStatus.granted,
        grant: committed,
      );
    } on Object {
      return const WorkFolderRequestResult(
        status: WorkFolderRequestStatus.unavailable,
        reason: '所选工作目录无效。',
      );
    }
  }

  /// Validates a selected directory without persisting a new capability.
  ///
  /// The UI uses this preview to show the exact normalized path and whether
  /// the operating system currently exposes write access before consent is
  /// recorded. Existing callers that intentionally bypass UI consent may
  /// continue using [addDirectory].
  Future<WorkFolderGrant> previewDirectory(String rawPath) async {
    final normalized = normalizePath(rawPath, isWindows: isWindows);
    final existingIndex = _indexOf(normalized);
    if (existingIndex >= 0) {
      return _validatedGrant(_grants[existingIndex]);
    }
    final coveringGrant = _grants.cast<WorkFolderGrant?>().firstWhere(
          (grant) =>
              grant != null &&
              grant.available &&
              _containsPath(grant.path, normalized),
          orElse: () => null,
        );
    if (coveringGrant != null) return coveringGrant;
    final now = clock();
    return _validatedGrant(
      WorkFolderGrant(
        path: normalized,
        displayName: displayNameFor(normalized, isWindows: isWindows),
        addedAt: now,
        lastValidatedAt: now,
        available: false,
        writable: false,
      ),
    );
  }

  /// Persists a previously validated directory after explicit consent.
  Future<WorkFolderGrant?> authorizeDirectory(
    String rawPath, {
    WorkFolderGrantConsent? consent,
  }) async {
    try {
      final preview = await previewDirectory(rawPath);
      if (!preview.available) return null;
      final confirmed = await _confirmCloudDisclosure(preview, consent);
      if (!confirmed) return null;
      return _commitGrant(
        preview,
        cloudDisclosureConfirmedAt:
            preview.cloudDisclosureConfirmedAt ?? clock(),
      );
    } on Object {
      return null;
    }
  }

  Future<WorkModeAgentSettings> loadSettings() async {
    _settings = _decodeSettings(box.get(settingsStorageKey));
    return _settings;
  }

  Future<void> setOrdinaryWriteConfirmation(bool enabled) async {
    _settings = WorkModeAgentSettings(
      ordinaryWriteConfirmation: enabled,
      retentionDays: _settings.retentionDays,
      snapshotLimitBytes: _settings.snapshotLimitBytes,
      actionLimit: _settings.actionLimit,
      timeLimitMinutes: _settings.timeLimitMinutes,
    );
    await box.put(settingsStorageKey, _settings.toMap());
  }

  Future<void> setRetentionDays(int days) => _updateSettings(
        retentionDays: days,
      );

  Future<void> setSnapshotLimitBytes(int bytes) => _updateSettings(
        snapshotLimitBytes: bytes,
      );

  Future<void> _updateSettings({
    int? retentionDays,
    int? snapshotLimitBytes,
  }) async {
    if (retentionDays != null && retentionDays <= 0) {
      throw ArgumentError.value(retentionDays, 'retentionDays');
    }
    if (snapshotLimitBytes != null && snapshotLimitBytes <= 0) {
      throw ArgumentError.value(snapshotLimitBytes, 'snapshotLimitBytes');
    }
    _settings = WorkModeAgentSettings(
      ordinaryWriteConfirmation: _settings.ordinaryWriteConfirmation,
      retentionDays: retentionDays ?? _settings.retentionDays,
      snapshotLimitBytes: snapshotLimitBytes ?? _settings.snapshotLimitBytes,
      actionLimit: _settings.actionLimit,
      timeLimitMinutes: _settings.timeLimitMinutes,
    );
    await box.put(settingsStorageKey, _settings.toMap());
  }

  static String normalizePath(String rawPath, {bool isWindows = false}) {
    var value = rawPath.trim().replaceAll('\\', '/');
    if (value.isEmpty) throw ArgumentError.value(rawPath, 'rawPath');
    if (RegExp(r'[\u0000-\u001f\u007f]').hasMatch(value)) {
      throw ArgumentError.value(rawPath, 'rawPath', '路径包含不允许的字符');
    }
    final isDriveAbsolute = RegExp(r'^[A-Za-z]:/').hasMatch(value);
    final isUnc = value.startsWith('//');
    final isRootAbsolute = value.startsWith('/');
    if (!isDriveAbsolute && !isUnc && !isRootAbsolute) {
      value = Directory(value).absolute.path.replaceAll('\\', '/');
    }
    final normalized = _collapseAbsolute(value, isWindows: isWindows);
    if (normalized.isEmpty) throw ArgumentError.value(rawPath, 'rawPath');
    return normalized;
  }

  static String displayNameFor(String path, {bool isWindows = false}) {
    final normalized = normalizePath(path, isWindows: isWindows);
    if (normalized == '/' || RegExp(r'^[A-Za-z]:/$').hasMatch(normalized)) {
      return normalized;
    }
    final slash = normalized.lastIndexOf('/');
    return slash < 0 ? normalized : normalized.substring(slash + 1);
  }

  Future<WorkFolderGrant> _validatedGrant(WorkFolderGrant grant) async {
    bool available;
    bool writable;
    try {
      available = await _directoryValidator(grant.path);
    } on Object {
      available = false;
    }
    try {
      writable = available && await _writeDirectoryValidator(grant.path);
    } on Object {
      writable = false;
    }
    return grant.copyWith(
      lastValidatedAt: clock(),
      available: available,
      writable: writable,
    );
  }

  Future<WorkFolderGrant?> _resolvedGrantForPath(String rawPath) async {
    final candidate = await _canonicalPath(rawPath);
    if (candidate == null) return null;
    for (final grant in _grants) {
      if (!grant.available || grant.cloudDisclosureConfirmedAt == null) {
        continue;
      }
      if (await _containsPathResolved(grant.path, candidate)) return grant;
    }
    return null;
  }

  WorkFolderGrant? _firstUsableGrant({required bool requireWritable}) {
    for (final grant in _grants) {
      if (grant.available && (!requireWritable || grant.writable)) {
        return grant;
      }
    }
    return null;
  }

  Future<bool> _confirmCloudDisclosure(
    WorkFolderGrant grant,
    WorkFolderGrantConsent? consent,
  ) async {
    if (grant.cloudDisclosureConfirmedAt != null) return true;
    if (consent == null) return false;
    try {
      return await consent(grant);
    } on Object {
      return false;
    }
  }

  Future<bool> _containsPathResolved(String root, String candidate) async {
    final canonicalRoot = await _canonicalPath(root);
    final canonicalCandidate = await _canonicalPath(candidate);
    if (canonicalRoot == null || canonicalCandidate == null) return false;
    return _containsPath(canonicalRoot, canonicalCandidate);
  }

  /// Resolves symlinked ancestors while retaining missing leaf segments.
  /// macOS commonly exposes temporary directories through `/var` while the
  /// real path is `/private/var`; lexical checks alone would reject a valid
  /// child after the path policy resolves it.
  Future<String?> _canonicalPath(String rawPath) async {
    String current;
    try {
      current = normalizePath(rawPath, isWindows: isWindows);
    } on Object {
      return null;
    }
    final missing = <String>[];
    while (true) {
      FileSystemEntityType type;
      try {
        type = await FileSystemEntity.type(current, followLinks: false);
      } on Object {
        return null;
      }
      if (type != FileSystemEntityType.notFound) {
        try {
          final resolved = switch (type) {
            FileSystemEntityType.directory =>
              await Directory(current).resolveSymbolicLinks(),
            FileSystemEntityType.file =>
              await File(current).resolveSymbolicLinks(),
            FileSystemEntityType.link =>
              await Link(current).resolveSymbolicLinks(),
            _ => current,
          };
          var result = normalizePath(resolved, isWindows: isWindows);
          for (final segment in missing.reversed) {
            result = normalizePath('$result/$segment', isWindows: isWindows);
          }
          return result;
        } on Object {
          return null;
        }
      }
      final slash = current.lastIndexOf('/');
      if (slash < 0 ||
          current == '/' ||
          RegExp(r'^[A-Za-z]:/$').hasMatch(current)) {
        return null;
      }
      missing.add(current.substring(slash + 1));
      current = slash == 0
          ? '/'
          : isWindows && slash == 2 && current.length > 2
              ? current.substring(0, 3)
              : current.substring(0, slash);
    }
  }

  Future<WorkFolderGrant> _commitGrant(
    WorkFolderGrant candidate, {
    required DateTime cloudDisclosureConfirmedAt,
  }) async {
    final confirmed = candidate.copyWith(
      cloudDisclosureConfirmedAt: cloudDisclosureConfirmedAt,
    );
    final existingIndex = _indexOf(confirmed.path);
    if (existingIndex >= 0) {
      _grants[existingIndex] = confirmed;
      await _persistGrants();
      _loadFuture = null;
      return confirmed;
    }
    final coveringGrant = _grants.cast<WorkFolderGrant?>().firstWhere(
          (grant) =>
              grant != null &&
              grant.available &&
              _containsPath(grant.path, confirmed.path),
          orElse: () => null,
        );
    if (coveringGrant != null) {
      if (coveringGrant.cloudDisclosureConfirmedAt == null) {
        final confirmedCovering = coveringGrant.copyWith(
          cloudDisclosureConfirmedAt: cloudDisclosureConfirmedAt,
        );
        final index = _indexOf(confirmedCovering.path);
        if (index >= 0) {
          _grants[index] = confirmedCovering;
          await _persistGrants();
          _loadFuture = null;
          return confirmedCovering;
        }
      }
      return coveringGrant;
    }
    _grants = [
      ..._grants.where((grant) => !_containsPath(confirmed.path, grant.path)),
      confirmed,
    ];
    _grants.sort((left, right) => left.path.compareTo(right.path));
    await _persistGrants();
    _loadFuture = null;
    return confirmed;
  }

  Future<void> _persistGrants() => box.put(
        grantsStorageKey,
        _grants.map((grant) => grant.toMap()).toList(growable: false),
      );

  int _indexOf(String path) {
    for (var index = 0; index < _grants.length; index++) {
      if (_samePath(_grants[index].path, path)) return index;
    }
    return -1;
  }

  bool _samePath(String left, String right) =>
      _comparisonKey(left) == _comparisonKey(right);

  bool _containsPath(String root, String candidate) {
    final normalizedRoot = normalizePath(root, isWindows: isWindows);
    final normalizedCandidate = normalizePath(candidate, isWindows: isWindows);
    final rootKey = _comparisonKey(normalizedRoot);
    final candidateKey = _comparisonKey(normalizedCandidate);
    if (rootKey == candidateKey) return true;
    if (rootKey == '/' ||
        (isWindows && RegExp(r'^[a-z]:/$').hasMatch(rootKey))) {
      return candidateKey.startsWith(rootKey);
    }
    return candidateKey.startsWith('$rootKey/');
  }

  String _comparisonKey(String path) {
    final normalized = path.replaceAll('\\', '/');
    return isWindows ? normalized.toLowerCase() : normalized;
  }

  static String _collapseAbsolute(String value, {required bool isWindows}) {
    final driveMatch = RegExp(r'^([A-Za-z]):/').firstMatch(value);
    final drive = driveMatch?.group(1);
    final unc = value.startsWith('//') && drive == null;
    final rooted = value.startsWith('/') && !unc && drive == null;
    final body = drive == null
        ? (unc
            ? value.substring(2)
            : rooted
                ? value.substring(1)
                : value)
        : value.substring(3);
    final segments = <String>[];
    for (final segment in body.split('/')) {
      if (segment.isEmpty || segment == '.') continue;
      if (segment == '..') {
        if (segments.isNotEmpty && segments.last != '..') segments.removeLast();
        continue;
      }
      segments.add(segment);
    }
    if (drive != null) {
      final prefix = '${drive.toUpperCase()}:/';
      return segments.isEmpty ? prefix : '$prefix${segments.join('/')}';
    }
    if (unc) return segments.isEmpty ? '//' : '//${segments.join('/')}';
    if (rooted || !isWindows) {
      return segments.isEmpty ? '/' : '/${segments.join('/')}';
    }
    return segments.join('/');
  }

  static Future<bool> _directoryExists(String path) async {
    try {
      final directory = Directory(path);
      if (!await directory.exists()) return false;
      // One entry checks read access without recursively scanning content.
      await directory.list(followLinks: false).take(1).drain();
      return true;
    } on Object {
      return false;
    }
  }

  static Future<bool> _directoryWritable(String path) async {
    Directory? probe;
    try {
      final directory = Directory(path);
      if (!await directory.exists()) return false;
      // Create a private temporary directory instead of a predictable file.
      // A pre-existing symlink at a predictable probe path could otherwise
      // redirect the write check and overwrite an unrelated file.
      probe = await directory.createTemp('.codex-write-check-');
      return true;
    } on Object {
      return false;
    } finally {
      if (probe != null) {
        try {
          await probe.delete(recursive: true);
        } on Object {
          // A failed cleanup must not turn a valid capability check into a
          // grant failure; the temporary directory is non-sensitive metadata.
        }
      }
    }
  }

  static Box<dynamic> _resolveBox(
    Box<dynamic>? box,
    DatabaseService? db,
  ) =>
      box ?? db!.appSettingsBox;

  static List<WorkFolderGrant> _decodeGrants(Object? raw) {
    if (raw is! List) return <WorkFolderGrant>[];
    final grants = <WorkFolderGrant>[];
    for (final item in raw) {
      if (item is! Map) continue;
      try {
        grants.add(WorkFolderGrant.fromMap(item));
      } on FormatException {
        // Ignore only malformed records; one bad entry must not hide others.
      }
    }
    return grants;
  }

  static WorkModeAgentSettings _decodeSettings(Object? raw) {
    return raw is Map
        ? WorkModeAgentSettings.fromMap(raw)
        : const WorkModeAgentSettings();
  }
}
