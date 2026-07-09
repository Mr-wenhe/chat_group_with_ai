import 'dart:io';

class AutonomousDirectoryService {
  const AutonomousDirectoryService();

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
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<Directory> taskDir({
    required Directory root,
    required String conversationId,
    required bool isDirectChat,
    required String taskId,
  }) async {
    final conversation = await conversationDir(
      root: root,
      conversationId: conversationId,
      isDirectChat: isDirectChat,
    );
    final dir = Directory('${conversation.path}/task_${_safeSegment(taskId)}');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final artifacts = Directory('${dir.path}/artifacts');
    if (!await artifacts.exists()) {
      await artifacts.create(recursive: true);
    }
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
}
