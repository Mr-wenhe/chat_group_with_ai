// ignore_for_file: avoid_print
import 'dart:io';
import 'package:hive/hive.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';

/// 将所有角色统一指向 xfyun 配置（cfg-6），并同步 provider/key/model，
/// 使合并后的单一数据源真正可用。
Future<void> main() async {
  Hive.registerAdapter(AICharacterAdapter());
  Hive.registerAdapter(ApiConfigAdapter());

  final projectPath = '${Directory.current.path}/data';
  final configBox = await Hive.openBox<ApiConfig>('api_configs', path: projectPath);
  final charBox = await Hive.openBox<AICharacter>('ai_characters', path: projectPath);

  final config = configBox.get('cfg-6');
  if (config == null) {
    print('未找到 cfg-6 配置，退出');
    return;
  }
  print('目标配置: ${config.name} | ${config.provider} | model=${config.modelName}');

  int fixed = 0;
  for (final key in charBox.keys.toList()) {
    final ch = charBox.get(key);
    if (ch == null) continue;
    if (ch.apiConfigId != config.id) {
      ch.apiConfigId = config.id;
      ch.apiProvider = config.provider;
      ch.apiKey = config.apiKey;
      ch.modelName = config.modelName;
      ch.customBaseUrl = config.customBaseUrl;
      await ch.save();
      fixed++;
    }
  }
  print('已统一 $fixed 个角色指向 xfyun 配置');

  await configBox.close();
  await charBox.close();
}
