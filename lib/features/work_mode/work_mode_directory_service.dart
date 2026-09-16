import 'dart:io';

class WorkModeDirectoryService {
  const WorkModeDirectoryService();

  /// Resolves the workspace explicitly named in a request before falling
  /// back to the legacy desktop destination rule. A project path is a
  /// capability request, not prose for the model: keeping it at the runner's
  /// workspace boundary prevents relative reads from landing in Desktop.
  String? requestedWorkspacePath(String request, {String? homePath}) {
    return requestedLocalPath(request) ??
        requestedDesktopPath(request, homePath: homePath);
  }

  /// Extracts one absolute local path that the user explicitly supplied.
  /// Only common local roots are accepted; the folder grant service remains
  /// the authority that decides whether the path may actually be used.
  String? requestedLocalPath(String request) {
    final match = RegExp(
      r'(?<![A-Za-z0-9_/:])((?:/Volumes|/Users|/home|/tmp|/var)/[^\s，。；、]+)',
    ).firstMatch(request);
    return match?.group(1)?.trim();
  }

  /// Returns whether the request explicitly names the user's desktop as the
  /// destination. This is intentionally narrow so a generic mention of a
  /// desktop application does not change the workspace boundary.
  static bool requestTargetsDesktop(String request) {
    return RegExp(
      r'桌面(?!端)|(?<![A-Za-z])desktop(?![A-Za-z])',
      caseSensitive: false,
    ).hasMatch(request);
  }

  /// Resolves the platform desktop directory only for an explicit desktop
  /// destination. Returning `null` keeps ordinary work-mode tasks isolated
  /// in their per-conversation directories.
  String? requestedDesktopPath(String request, {String? homePath}) {
    if (!requestTargetsDesktop(request)) return null;
    final home = homePath?.trim().isNotEmpty == true
        ? homePath!.trim()
        : _platformHomePath();
    if (home == null || home.isEmpty) return null;
    return Directory('$home/Desktop').absolute.path;
  }

  String conversationFolderName({
    required String conversationId,
    required bool isDirectChat,
  }) {
    if (isDirectChat && conversationId.startsWith('dm:')) {
      return 'dm_${_safeSegment(conversationId.substring(3))}';
    }
    return 'group_${_safeSegment(conversationId)}';
  }

  Future<Directory> conversationDir({
    required Directory root,
    required String conversationId,
    required bool isDirectChat,
  }) async {
    final dir = Directory(
      '${root.path}/conversations/${conversationFolderName(
        conversationId: conversationId,
        isDirectChat: isDirectChat,
      )}',
    );
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static String _safeSegment(String value) {
    final normalized = value
        .trim()
        .replaceAll(RegExp(r'[^a-zA-Z0-9._-]+'), '_')
        .replaceAll('..', '_')
        .replaceAll(RegExp(r'_+'), '_');
    if (normalized.isEmpty || normalized == '.' || normalized == '..') {
      return 'conversation';
    }
    return normalized.length <= 80 ? normalized : normalized.substring(0, 80);
  }

  static String? _platformHomePath() {
    for (final key in const ['HOME', 'USERPROFILE']) {
      final value = Platform.environment[key]?.trim();
      if (value != null && value.isNotEmpty) return value;
    }
    final drive = Platform.environment['HOMEDRIVE']?.trim();
    final path = Platform.environment['HOMEPATH']?.trim();
    if (drive != null && drive.isNotEmpty && path != null && path.isNotEmpty) {
      return '$drive$path';
    }
    return null;
  }
}
