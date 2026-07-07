// ignore_for_file: avoid_print
import 'dart:io';
import 'package:hive/hive.dart';
import 'package:chat_group/core/models/ai_character.dart';

/// 一次性迁移脚本：将所有角色的每小时回复上限改为 60。
/// 用法: dart run scripts/update_reply_limit.dart
Future<void> main() async {
  Hive.registerAdapter(AICharacterAdapter());

  final paths = [
    // 运行时实际数据（macOS 沙箱）
    '/Users/fengye/Library/Containers/com.example.chatGroup/Data/Documents/data',
    // 项目内 git 托管的源数据
    '${Directory.current.path}/data',
  ];

  for (final path in paths) {
    final dir = Directory(path);
    if (!await dir.exists() ||
        !await File('$path/ai_characters.hive').exists()) {
      print('跳过（不存在）: $path');
      continue;
    }

    final box = await Hive.openBox<AICharacter>('ai_characters',
        path: path);
    var updated = 0;
    for (final key in box.keys) {
      final c = box.get(key);
      if (c == null) continue;
      if (c.hourlyReplyLimit != 60) {
        c.hourlyReplyLimit = 60;
        await c.save();
        updated++;
      }
    }
    await box.close();
    print('已更新 $updated 个角色 -> $path');
  }

  print('完成');
}
