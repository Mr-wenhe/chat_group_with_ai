import 'dart:convert';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/services/chat_api_service.dart';

/// Gives legacy characters one immutable gender value, once.
class CharacterGenderMigrator {
  static const migrationKey = 'character_gender_migration_v1';

  final DatabaseService db;
  final ChatApiService api;
  final ApiCredentialResolver credentials;

  CharacterGenderMigrator(
    this.db, {
    ChatApiService? api,
    ApiCredentialResolver? credentials,
  })  : api = api ?? ChatApiService(),
        credentials = credentials ?? SecureApiCredentialResolver();

  Future<int> migrate() async {
    if (db.appSettingsBox.get(migrationKey) == true) return 0;
    final characters = db.aiCharacterBox.values.toList(growable: false);
    if (characters.isEmpty) {
      await db.appSettingsBox.put(migrationKey, true);
      return 0;
    }

    final replies = <String, List<String>>{
      for (final character in characters) character.id: <String>[],
    };
    for (final message in db.messageBox.values) {
      final bucket = replies[message.senderId];
      if (bucket != null && message.senderType != 'user') {
        bucket.add(message.content);
      }
    }

    final remote = await _inferWithLlm(characters, replies);
    for (final character in characters) {
      character.gender = remote[character.id] ??
          inferLocally(character, replies[character.id] ?? const []);
      await db.aiCharacterBox.put(character.id, character);
    }
    await db.appSettingsBox.put(migrationKey, true);
    return characters.length;
  }

  Future<Map<String, CharacterGender>> _inferWithLlm(
    List<AICharacter> characters,
    Map<String, List<String>> replies,
  ) async {
    final resolved = await _firstUsableConfig(characters);
    if (resolved == null) return const {};
    final entries = characters.map((character) {
      final recentReplies = (replies[character.id] ?? const <String>[])
          .reversed
          .take(6)
          .map((text) => _limit(text, 240))
          .toList(growable: false);
      return {
        'id': character.id,
        'name': character.name,
        'role': character.role,
        'systemPrompt': _limit(character.systemPrompt, 600),
        'recentReplies': recentReplies,
      };
    }).toList(growable: false);

    try {
      final result = await api.sendChatMessage(
        apiKey: resolved.apiKey,
        provider: ApiProvider.values.firstWhere(
          (provider) => provider.name == resolved.config.provider,
          orElse: () => ApiProvider.custom,
        ),
        customBaseUrl: resolved.config.customBaseUrl,
        model: resolved.config.modelName,
        temperature: 0,
        maxTokens: 2048,
        maxRetries: 0,
        receiveTimeout: const Duration(seconds: 20),
        messages: [
          {
            'role': 'system',
            'content': '判断每个虚拟角色的性别，只允许男或女。综合名字、职业、人设和历史回复。'
                '只输出 JSON 数组，格式为 [{"id":"角色ID","gender":"男或女"}]。',
          },
          {'role': 'user', 'content': jsonEncode(entries)},
        ],
      );
      if (result['success'] != true) return const {};
      return _parseLlmResult(result['message']?.toString() ?? '');
    } on Object {
      return const {};
    }
  }

  Future<({ApiConfig config, String apiKey})?> _firstUsableConfig(
    List<AICharacter> characters,
  ) async {
    final preferredIds = characters
        .map((character) => character.apiConfigId)
        .where((id) => id.isNotEmpty)
        .toSet();
    final configs = [
      ...db.apiConfigBox.values.where((config) => preferredIds.contains(config.id)),
      ...db.apiConfigBox.values.where((config) => !preferredIds.contains(config.id)),
    ];
    for (final config in configs) {
      final key = await credentials.resolve(config);
      if (key != null && key.isNotEmpty) return (config: config, apiKey: key);
    }
    return null;
  }

  static Map<String, CharacterGender> _parseLlmResult(String raw) {
    final start = raw.indexOf('[');
    final end = raw.lastIndexOf(']');
    if (start < 0 || end <= start) return const {};
    try {
      final decoded = jsonDecode(raw.substring(start, end + 1));
      if (decoded is! List) return const {};
      return {
        for (final item in decoded.whereType<Map>())
          if (item['id']?.toString().isNotEmpty == true &&
              (item['gender'] == '男' || item['gender'] == '女'))
            item['id'].toString(): item['gender'] == '男'
                ? CharacterGender.male
                : CharacterGender.female,
      };
    } on Object {
      return const {};
    }
  }

  static CharacterGender inferLocally(
    AICharacter character,
    List<String> replies,
  ) {
    final text = [
      character.name,
      character.role,
      character.systemPrompt,
      ...replies.take(20),
    ].join(' ');
    var male = 0;
    var female = 0;
    for (final marker in _maleMarkers) {
      if (text.contains(marker)) male++;
    }
    for (final marker in _femaleMarkers) {
      if (text.contains(marker)) female++;
    }
    return male > female ? CharacterGender.male : CharacterGender.female;
  }

  static String _limit(String text, int maxLength) =>
      text.length <= maxLength ? text : text.substring(0, maxLength);

  static const _maleMarkers = [
    '男性', '男人', '男生', '男士', '爸爸', '父亲', '老公', '丈夫', '哥哥', '弟弟',
    '大叔', '码农', '建国', '明达', '晓峰', '志豪', '书豪', '鹏飞', '小明', '阿杰',
  ];
  static const _femaleMarkers = [
    '女性', '女人', '女生', '女士', '妈妈', '母亲', '老婆', '妻子', '姐姐', '妹妹',
    '小姐姐', '阿姨', '雨薇', '若晴', '静怡', '晓燕', '姚芳', '苏菲', 'Amy', '宝妈',
  ];
}
