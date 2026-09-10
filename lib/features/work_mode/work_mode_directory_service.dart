import 'dart:io';

class WorkModeDirectoryService {
  const WorkModeDirectoryService();

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
