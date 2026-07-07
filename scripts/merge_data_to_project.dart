// ignore_for_file: avoid_print
import 'dart:io';
import 'package:hive/hive.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/group_memory.dart';

/// 将沙箱（运行时）数据与工程 data/ 源数据合并，结果写入工程 data/（git 托管）。
/// 规则：按 key 合并，沙箱优先（保留运行期新增/修改）。
/// 用法: dart run scripts/merge_data_to_project.dart
Future<void> main() async {
  Hive.registerAdapter(AICharacterAdapter());
  Hive.registerAdapter(ApiConfigAdapter());
  Hive.registerAdapter(ChatGroupAdapter());
  Hive.registerAdapter(MessageAdapter());
  Hive.registerAdapter(GroupMemoryAdapter());

  final sandboxPath = '/tmp/sandbox_data';
  final projectPath = '${Directory.current.path}/data';

  final boxes = [
    'ai_characters',
    'api_configs',
    'chat_groups',
    'messages',
    'group_memories',
  ];

  for (final name in boxes) {
    final sandboxBox = await Hive.openBox(name, path: sandboxPath);
    final projectBox = await Hive.openBox(name, path: projectPath);

    // 合并到 map：先放工程，再用沙箱覆盖（沙箱优先）
    // 读取后从原 box delete 以 detach HiveObject，避免「同一实例不能存入两个 box」
    final merged = <dynamic, dynamic>{};
    for (final key in projectBox.keys.toList()) {
      final v = projectBox.get(key);
      if (v is HiveObject) await projectBox.delete(key);
      merged[key] = v;
    }
    for (final key in sandboxBox.keys.toList()) {
      final v = sandboxBox.get(key);
      if (v is HiveObject) await sandboxBox.delete(key);
      merged[key] = v; // 沙箱覆盖（优先）
    }

    final sCount = sandboxBox.length;
    final pCount = projectBox.length;
    final mCount = merged.length;

    await sandboxBox.close();
    await projectBox.close();

    // 重建工程 box 并写入合并结果
    await Hive.deleteBoxFromDisk(name, path: projectPath);
    final outBox = await Hive.openBox(name, path: projectPath);
    for (final entry in merged.entries) {
      await outBox.put(entry.key, entry.value);
    }
    await outBox.close();

    print('$name: 工程 $pCount + 沙箱 $sCount → 合并 $mCount（沙箱优先）');
  }

  print('合并完成，已写入 $projectPath');
}
