import 'dart:convert';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/services/chat_api_service.dart';

/// Gives legacy characters one immutable gender value, once.
class CharacterGenderMigrator {
  static const migrationKey = 'character_gender_migration_v1';
  static const maxNameLength = 80;
  static const maxRoleLength = 160;
  static const maxSystemPromptLength = 600;
  static const maxReplyLength = 240;
  static const maxRecentReplies = 8;

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

    final replies = _repliesByCharacter(characters, db.messageBox.values);

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
    final entries = _buildInferenceEntries(characters, replies);

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
      return parseLlmResult(
        result['message']?.toString() ?? '',
        knownCharacterIds: characters.map((character) => character.id).toSet(),
      );
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
      ...db.apiConfigBox.values
          .where((config) => preferredIds.contains(config.id)),
      ...db.apiConfigBox.values
          .where((config) => !preferredIds.contains(config.id)),
    ];
    for (final config in configs) {
      final key = await credentials.resolve(config);
      if (key != null && key.isNotEmpty) return (config: config, apiKey: key);
    }
    return null;
  }

  /// Builds bounded, deterministic evidence for remote gender inference.
  static List<Map<String, dynamic>> buildInferenceEntries(
    List<AICharacter> characters,
    Iterable<Message> messages,
  ) =>
      _buildInferenceEntries(
          characters, _repliesByCharacter(characters, messages));

  static List<Map<String, dynamic>> _buildInferenceEntries(
    List<AICharacter> characters,
    Map<String, List<String>> replies,
  ) =>
      characters
          .map(
            (character) => <String, dynamic>{
              'id': character.id,
              'name': _limit(character.name, maxNameLength),
              'role': _limit(character.role, maxRoleLength),
              'systemPrompt': _limit(
                character.systemPrompt,
                maxSystemPromptLength,
              ),
              'recentReplies': (replies[character.id] ?? const <String>[])
                  .take(maxRecentReplies)
                  .map((text) => _limit(text, maxReplyLength))
                  .toList(growable: false),
            },
          )
          .toList(growable: false);

  static Map<String, List<String>> _repliesByCharacter(
    List<AICharacter> characters,
    Iterable<Message> messages,
  ) {
    final knownIds = characters.map((character) => character.id).toSet();
    final replies = <String, List<Message>>{
      for (final id in knownIds) id: <Message>[],
    };
    for (final message in messages) {
      if (message.senderType == 'ai' && knownIds.contains(message.senderId)) {
        replies[message.senderId]!.add(message);
      }
    }
    return {
      for (final entry in replies.entries)
        entry.key: (entry.value..sort(_compareMessages))
            .reversed
            .map((message) => message.content)
            .toList(growable: false),
    };
  }

  static int _compareMessages(Message left, Message right) {
    final byTimestamp = left.timestamp.compareTo(right.timestamp);
    return byTimestamp != 0 ? byTimestamp : left.id.compareTo(right.id);
  }

  /// Parses a partially valid LLM response without allowing unknown IDs through.
  static Map<String, CharacterGender> parseLlmResult(
    String raw, {
    required Set<String> knownCharacterIds,
  }) {
    final fencedSources = RegExp(
      r'```(?:json)?\s*([\s\S]*?)```',
      caseSensitive: false,
    ).allMatches(raw).map((match) => match.group(1) ?? '');
    for (final source in [...fencedSources, raw]) {
      final decoded = _decodeFirstJsonArray(source);
      if (decoded == null) continue;
      final result = <String, CharacterGender>{};
      for (final item in decoded.whereType<Map>()) {
        final id = item['id']?.toString();
        final gender = item['gender'];
        if (id == null ||
            !knownCharacterIds.contains(id) ||
            result.containsKey(id) ||
            (gender != '男' && gender != '女')) {
          continue;
        }
        result[id] =
            gender == '男' ? CharacterGender.male : CharacterGender.female;
      }
      return result;
    }
    return const {};
  }

  static List<dynamic>? _decodeFirstJsonArray(String source) {
    for (final candidate in _jsonArrayCandidates(source)) {
      try {
        final decoded = jsonDecode(candidate);
        if (decoded is List) return decoded;
      } on Object {
        continue;
      }
    }
    return null;
  }

  static Iterable<String> _jsonArrayCandidates(String source) sync* {
    // ponytail: migration responses are small; a dependency-free bracket scan
    // is enough and avoids treating explanatory brackets as JSON.
    for (var start = 0; start < source.length; start++) {
      if (source[start] != '[') continue;
      var depth = 0;
      var inString = false;
      var escaped = false;
      for (var end = start; end < source.length; end++) {
        final character = source[end];
        if (inString) {
          if (escaped) {
            escaped = false;
          } else if (character == '\\') {
            escaped = true;
          } else if (character == '"') {
            inString = false;
          }
          continue;
        }
        if (character == '"') {
          inString = true;
        } else if (character == '[') {
          depth++;
        } else if (character == ']') {
          depth--;
          if (depth == 0) {
            yield source.substring(start, end + 1);
            break;
          }
        }
      }
    }
  }

  static CharacterGender inferLocally(
    AICharacter character,
    List<String> replies,
  ) {
    final evidence = _genderEvidenceCounts(
      character.role,
      character.systemPrompt,
      replies.take(maxRecentReplies),
    );
    if (evidence.male != 0 || evidence.female != 0) {
      return evidence.male > evidence.female
          ? CharacterGender.male
          : CharacterGender.female;
    }
    return _genderFromMarkers(
            character.name, _maleNameMarkers, _femaleNameMarkers) ??
        CharacterGender.female;
  }

  static CharacterGender? _genderFromMarkers(
    String text,
    List<String> maleMarkers,
    List<String> femaleMarkers,
  ) {
    final male = maleMarkers.where(text.contains).length;
    final female = femaleMarkers.where(text.contains).length;
    if (male == female) return null;
    return male > female ? CharacterGender.male : CharacterGender.female;
  }

  static ({int male, int female}) _genderEvidenceCounts(
    String role,
    String systemPrompt,
    Iterable<String> replies,
  ) {
    final male = _countRoleMarkers(role, _maleMarkers) +
        _countIdentityMarkers(
          systemPrompt,
          _maleMarkers,
          _definitionIdentityPrefixes,
        ) +
        replies.fold<int>(
          0,
          (count, reply) =>
              count + _countIdentityMarkers(reply, _maleMarkers, _selfPrefixes),
        );
    final female = _countRoleMarkers(role, _femaleMarkers) +
        _countIdentityMarkers(
          systemPrompt,
          _femaleMarkers,
          _definitionIdentityPrefixes,
        ) +
        replies.fold<int>(
          0,
          (count, reply) =>
              count +
              _countIdentityMarkers(reply, _femaleMarkers, _selfPrefixes),
        );
    return (male: male, female: female);
  }

  static int _countRoleMarkers(String role, List<String> markers) {
    final markerPattern = markers.map(RegExp.escape).join('|');
    final suffixPattern = _identitySuffixes.map(RegExp.escape).join('|');
    return RegExp(
      '(?:$markerPattern)(?:(?:$suffixPattern))?\$',
    ).allMatches(role.trim()).length;
  }

  static int _countIdentityMarkers(
    String text,
    List<String> markers,
    List<String> prefixes,
  ) {
    final markerPattern = markers.map(RegExp.escape).join('|');
    final prefixPattern = prefixes.map(RegExp.escape).join('|');
    return RegExp(
      '(?:$prefixPattern)[^。；，,]{0,16}'
      '(?:$markerPattern)(?:(?:$_identitySuffixesPattern))?'
      '(?=[。；，,\\s]|\$)',
    ).allMatches(text).length;
  }

  static final _identitySuffixesPattern =
      _identitySuffixes.map(RegExp.escape).join('|');

  static const _identitySuffixes = [
    '瑜伽教练',
    '医生',
    '教练',
    '工程师',
    '教师',
    '老师',
    '护士',
    '程序员',
    '学生',
    '顾问',
    '用户',
    '角色',
  ];

  static const _definitionIdentityPrefixes = [
    '我是',
    '我作为',
    '作为',
    '你是',
    '角色是',
  ];
  static const _selfPrefixes = ['我是', '我作为'];

  static String _limit(String text, int maxLength) =>
      text.length <= maxLength ? text : text.substring(0, maxLength);

  static const _maleMarkers = [
    '男性',
    '男人',
    '男生',
    '男士',
    '爸爸',
    '父亲',
    '老公',
    '丈夫',
    '哥哥',
    '弟弟',
    '大叔',
  ];
  static const _femaleMarkers = [
    '女性',
    '女人',
    '女生',
    '女士',
    '妈妈',
    '母亲',
    '老婆',
    '妻子',
    '姐姐',
    '妹妹',
    '小姐姐',
    '阿姨',
    '宝妈',
  ];
  static const _maleNameMarkers = [
    '建国',
    '明达',
    '晓峰',
    '志豪',
    '书豪',
    '鹏飞',
    '小明',
    '阿杰',
  ];
  static const _femaleNameMarkers = [
    '雨薇',
    '若晴',
    '静怡',
    '晓燕',
    '姚芳',
    '苏菲',
    'Amy',
  ];
}
