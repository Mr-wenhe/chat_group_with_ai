// ignore_for_file: avoid_print
import 'dart:io';
import 'package:hive/hive.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';

Future<void> main() async {
  Hive.registerAdapter(AICharacterAdapter());
  Hive.registerAdapter(ApiConfigAdapter());

  final projectPath = '${Directory.current.path}/data';
  final chars = await Hive.openBox<AICharacter>('ai_characters', path: projectPath);
  final configs = await Hive.openBox<ApiConfig>('api_configs', path: projectPath);
  print('角色数: ${chars.length}');
  print('配置数: ${configs.length}');
  print('配置列表:');
  for (final c in configs.values) {
    print('  - ${c.id} | ${c.name} | ${c.provider} | key=${c.apiKey.isEmpty ? "空" : "已填"}');
  }
  final configIds = configs.keys.toSet();
  int missing = 0;
  for (final ch in chars.values) {
    if (ch.apiConfigId.isNotEmpty && !configIds.contains(ch.apiConfigId)) missing++;
  }
  print('引用缺失配置的角色数: $missing');
  await chars.close();
  await configs.close();
}
