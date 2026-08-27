part of 'settings_page.dart';

extension _SettingsPageProfileSupport on _SettingsPageState {
  String _buildProfileTitle(ColorScheme cs) {
    try {
      final name = ref
          .read(databaseServiceProvider)
          .userProfileBox
          .get('me')
          ?.displayName
          .trim();
      if (name != null && name.isNotEmpty) return name;
    } on Object {
      // Box not yet opened in test environments.
    }
    return '我';
  }

  String _buildProfileSubtitle(ColorScheme cs) {
    try {
      final profile =
          ref.read(databaseServiceProvider).userProfileBox.get('me');
      if (profile == null) return '尚未设置人物信息卡';
      final parts = <String>[];
      if (profile.preferredAddress.trim().isNotEmpty) {
        parts.add('称呼：${profile.preferredAddress.trim()}');
      }
      if (profile.bio.trim().isNotEmpty) {
        parts.add(profile.bio.trim());
      }
      if (profile.interests.isNotEmpty) {
        parts.add('兴趣：${profile.interests.join('、')}');
      }
      if (parts.isEmpty) return '点击编辑你的资料';
      return parts.join(' · ');
    } on Object {
      return '尚未设置人物信息卡';
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
