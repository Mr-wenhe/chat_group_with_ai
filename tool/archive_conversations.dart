import 'dart:convert';
import 'dart:io';

import 'package:hive/hive.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/media_attachment.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/tool_permission.dart';

/// Export every stored conversation from the development Hive dataset.
///
/// The archive intentionally avoids opening api_configs.hive and removes
/// structured secrets, provider configuration, and absolute attachment paths.
/// Message text is retained for conversation fidelity, with common inline
/// secret patterns redacted by default.
Future<void> main(List<String> args) async {
  final dataDir = Directory(_argument(args, '--data-dir') ?? 'data').absolute;
  final outputDir =
      Directory(_argument(args, '--output-dir') ?? 'docs/archive/conversations')
          .absolute;
  final redactSecrets = !_hasFlag(args, '--no-redact');

  if (!await dataDir.exists()) {
    stderr.writeln('Hive data directory does not exist: ${dataDir.path}');
    exitCode = 2;
    return;
  }
  await outputDir.create(recursive: true);

  Hive.init(dataDir.path);
  Hive.registerAdapter(AICharacterAdapter());
  Hive.registerAdapter(ChatGroupAdapter());
  Hive.registerAdapter(MessageAdapter());
  Hive.registerAdapter(MediaAttachmentAdapter());
  Hive.registerAdapter(ToolPermissionAdapter());

  final characters = await Hive.openBox<AICharacter>('ai_characters');
  final groups = await Hive.openBox<ChatGroup>('chat_groups');
  final messages = await Hive.openBox<Message>('messages');

  final charactersById = <String, AICharacter>{
    for (final character in characters.values) character.id: character,
  };
  final groupsById = <String, ChatGroup>{
    for (final group in groups.values) group.id: group,
  };
  final messagesByConversation = <String, List<Message>>{};
  for (final message in messages.values) {
    messagesByConversation.putIfAbsent(message.groupId, () => []).add(message);
  }
  for (final values in messagesByConversation.values) {
    values.sort((a, b) {
      final byTime = a.timestamp.compareTo(b.timestamp);
      return byTime != 0 ? byTime : a.id.compareTo(b.id);
    });
  }

  final conversationIds = <String>{
    ...groupsById.keys,
    ...messagesByConversation.keys,
  }.toList()
    ..sort((a, b) => _conversationLabel(a, groupsById, charactersById)
        .compareTo(_conversationLabel(b, groupsById, charactersById)));

  final conversations = <Map<String, dynamic>>[];
  for (final conversationId in conversationIds) {
    final group = groupsById[conversationId];
    final messagesForConversation =
        messagesByConversation[conversationId] ?? const <Message>[];
    final conversation = _conversationJson(
      conversationId: conversationId,
      group: group,
      messages: messagesForConversation,
      charactersById: charactersById,
      redactSecrets: redactSecrets,
    );
    conversations.add(conversation);

    final fileName = _fileName(conversationId, group, charactersById);
    await File('${outputDir.path}/$fileName').writeAsString(
      _conversationMarkdown(conversation),
      flush: true,
    );
  }

  final allMessages = messagesByConversation.values
      .expand((value) => value)
      .toList(growable: false);
  final archive = <String, dynamic>{
    'schemaVersion': 1,
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'source': 'data/messages.hive + data/chat_groups.hive + '
        'data/ai_characters.hive',
    'privacy': {
      'secretRedactionEnabled': redactSecrets,
      'excludedBoxes': ['api_configs', 'app_settings'],
      'excludedFields': [
        'apiKey',
        'apiProvider',
        'modelName',
        'apiConfigId',
        'customBaseUrl',
        'media.localPath',
        'AICharacter.systemPrompt',
      ],
      'note': 'Message正文保留用于对话归档；默认会遮盖常见的内联密钥模式。',
    },
    'stats': {
      'characterCount': characters.length,
      'groupCount': groups.length,
      'messageCount': allMessages.length,
      'conversationCount': conversations.length,
      'directConversationCount':
          conversations.where((value) => value['type'] == 'direct').length,
      'groupConversationCount':
          conversations.where((value) => value['type'] == 'group').length,
      'orphanConversationCount':
          conversations.where((value) => value['type'] == 'orphan').length,
      'firstMessageAt': _minTime(allMessages)?.toUtc().toIso8601String(),
      'lastMessageAt': _maxTime(allMessages)?.toUtc().toIso8601String(),
    },
    'conversations': conversations,
  };

  const encoder = JsonEncoder.withIndent('  ');
  await File('${outputDir.path}/archive.json')
      .writeAsString('${encoder.convert(archive)}\n', flush: true);
  await File('${outputDir.path}/README.md').writeAsString(
    _indexMarkdown(archive, conversations),
    flush: true,
  );

  await Hive.close();
  stdout.writeln(
    'Archived ${allMessages.length} messages across '
    '${conversations.length} conversations to ${outputDir.path}',
  );
}

Map<String, dynamic> _conversationJson({
  required String conversationId,
  required ChatGroup? group,
  required List<Message> messages,
  required Map<String, AICharacter> charactersById,
  required bool redactSecrets,
}) {
  final type = group != null
      ? 'group'
      : conversationId.startsWith('dm:')
          ? 'direct'
          : 'orphan';
  final characterId =
      conversationId.startsWith('dm:') ? conversationId.substring(3) : null;
  final participantIds = <String>{
    ...messages.where((message) => message.senderType == 'ai').map(
          (message) => message.senderId,
        ),
    if (characterId != null) characterId,
    if (group != null) ...group.aiCharacterIds,
  };

  return {
    'id': conversationId,
    'type': type,
    'name': group?.name ??
        (characterId == null
            ? '未归属对话'
            : charactersById[characterId]?.name ?? characterId),
    if (group != null)
      'group': {
        'name': group.name,
        'theme': group.theme,
        'description': group.description,
        'ownerName': group.ownerName,
        'announcement': group.announcement,
      },
    if (characterId != null) 'directCharacterId': characterId,
    'participants': participantIds.toList()..sort(),
    'participantProfiles': participantIds
        .map((id) => _characterJson(charactersById[id]))
        .whereType<Map<String, dynamic>>()
        .toList(),
    'messageCount': messages.length,
    'firstMessageAt': _minTime(messages)?.toUtc().toIso8601String(),
    'lastMessageAt': _maxTime(messages)?.toUtc().toIso8601String(),
    'messages': messages
        .map((message) => _messageJson(message, charactersById, redactSecrets))
        .toList(),
  };
}

Map<String, dynamic>? _characterJson(AICharacter? character) {
  if (character == null) return null;
  return {
    'id': character.id,
    'name': character.name,
    'role': character.role,
    'age': character.age,
    'avatar': character.avatar,
    'personalityTags': character.personalityTags,
  };
}

Map<String, dynamic> _messageJson(
  Message message,
  Map<String, AICharacter> charactersById,
  bool redactSecrets,
) {
  final character = charactersById[message.senderId];
  final content =
      redactSecrets ? _redactSecrets(message.content) : message.content;
  return {
    'id': message.id,
    'senderId': message.senderId,
    'senderType': message.senderType,
    'senderName': message.senderType == 'user'
        ? '用户'
        : character?.name ?? message.senderId,
    'senderRole': message.senderType == 'user' ? '用户' : character?.role ?? '',
    'content': content,
    'contentRedacted': content != message.content,
    'timestamp': message.timestamp.toUtc().toIso8601String(),
    'replyToMessageId': message.replyToMessageId,
    'isMention': message.isMention,
    'mentionedAiIds': message.mentionedAiIds,
    'media': (message.media ?? const <MediaAttachment>[])
        .map(
          (attachment) => {
            'id': attachment.id,
            'type': attachment.type,
            'fileName': attachment.fileName,
            'fileSize': attachment.fileSize,
            'mimeType': attachment.mimeType,
            'durationMs': attachment.durationMs,
          },
        )
        .toList(),
  };
}

String _conversationMarkdown(Map<String, dynamic> conversation) {
  final buffer = StringBuffer()
    ..writeln('# ${conversation['name']}')
    ..writeln()
    ..writeln('- 类型：${_typeLabel(conversation['type'] as String)}')
    ..writeln('- 对话 ID：`${conversation['id']}`')
    ..writeln('- 消息数：${conversation['messageCount']}')
    ..writeln('- 时间范围：${conversation['firstMessageAt'] ?? '无'} → '
        '${conversation['lastMessageAt'] ?? '无'}');
  final group = conversation['group'];
  if (group is Map) {
    buffer
      ..writeln('- 主题：${group['theme'] ?? ''}')
      ..writeln('- 群主：${group['ownerName'] ?? ''}');
  }
  buffer
    ..writeln()
    ..writeln('---')
    ..writeln();
  final messages = conversation['messages'] as List<dynamic>;
  for (final raw in messages) {
    final message = raw as Map<String, dynamic>;
    final sender = message['senderName'] ?? message['senderId'];
    final role = (message['senderRole'] as String?) ?? '';
    final who = role.isEmpty ? sender : '$sender（$role）';
    buffer
      ..writeln('## $who · ${message['timestamp']}')
      ..writeln()
      ..writeln(message['content'] as String? ?? '')
      ..writeln();
    final media = message['media'] as List<dynamic>;
    if (media.isNotEmpty) {
      buffer.writeln('附件：${media.map((item) {
        final value = item as Map<String, dynamic>;
        return '${value['fileName'] ?? '未命名'} (${value['type']})';
      }).join('、')}');
      buffer.writeln();
    }
  }
  return buffer.toString();
}

String _indexMarkdown(
  Map<String, dynamic> archive,
  List<Map<String, dynamic>> conversations,
) {
  final stats = archive['stats'] as Map<String, dynamic>;
  final buffer = StringBuffer()
    ..writeln('# 项目全量对话归档')
    ..writeln()
    ..writeln('本目录由 `dart run tool/archive_conversations.dart` 生成。')
    ..writeln()
    ..writeln('## 覆盖范围')
    ..writeln()
    ..writeln('- 消息：${stats['messageCount']} 条')
    ..writeln('- 对话：${stats['conversationCount']} 个')
    ..writeln('- 群聊：${stats['groupConversationCount']} 个')
    ..writeln('- 私聊：${stats['directConversationCount']} 个')
    ..writeln('- 未归属对话：${stats['orphanConversationCount']} 个')
    ..writeln('- 时间：${stats['firstMessageAt'] ?? '无'} → '
        '${stats['lastMessageAt'] ?? '无'}')
    ..writeln()
    ..writeln('## 隐私处理')
    ..writeln()
    ..writeln('- 未打开或读取 `api_configs.hive` 与 `app_settings.hive`。')
    ..writeln('- 不导出 API key、模型/供应商配置、配置 ID、系统提示词。')
    ..writeln('- 附件只保留类型、文件名、大小和 MIME 元数据，不保留本机绝对路径。')
    ..writeln('- 消息正文默认遮盖常见密钥模式；如需精确副本，可使用 `--no-redact`。')
    ..writeln()
    ..writeln('## 对话索引')
    ..writeln();
  for (final conversation in conversations) {
    final name = conversation['name'];
    final fileName = _fileNameFromConversation(conversation);
    buffer.writeln(
      '- [$name]($fileName) · ${_typeLabel(conversation['type'] as String)} · '
      '${conversation['messageCount']} 条 · `${conversation['id']}`',
    );
  }
  buffer
    ..writeln()
    ..writeln('完整结构化数据见 [`archive.json`](archive.json)。');
  return buffer.toString();
}

String _fileName(
  String conversationId,
  ChatGroup? group,
  Map<String, AICharacter> charactersById,
) {
  final conversation = {
    'id': conversationId,
    'name': group?.name ??
        (conversationId.startsWith('dm:')
            ? charactersById[conversationId.substring(3)]?.name ??
                conversationId.substring(3)
            : '未归属对话'),
    'type': group != null
        ? 'group'
        : conversationId.startsWith('dm:')
            ? 'direct'
            : 'orphan',
  };
  return _fileNameFromConversation(conversation);
}

String _fileNameFromConversation(Map<String, dynamic> conversation) {
  final type = conversation['type'] as String;
  final id = conversation['id'] as String;
  final name = conversation['name'] as String;
  final prefix = switch (type) {
    'direct' => 'dm',
    'group' => 'group',
    _ => 'orphan',
  };
  final idSlug = _slug(id);
  final suffix = idSlug.substring(0, idSlug.length < 12 ? idSlug.length : 12);
  return '${prefix}_${_slug(name)}_$suffix.md';
}

String _conversationLabel(
  String id,
  Map<String, ChatGroup> groupsById,
  Map<String, AICharacter> charactersById,
) {
  final group = groupsById[id];
  if (group != null) return group.name;
  if (id.startsWith('dm:')) {
    return charactersById[id.substring(3)]?.name ?? id;
  }
  return id;
}

String _typeLabel(String type) => switch (type) {
      'group' => '群聊',
      'direct' => '私聊',
      _ => '未归属',
    };

String _slug(String value) {
  final normalized = value
      .trim()
      .replaceAll(RegExp(r'[^a-zA-Z0-9\u4e00-\u9fff._-]+'), '_')
      .replaceAll(RegExp(r'_+'), '_');
  final result = normalized.isEmpty ? 'conversation' : normalized;
  return result.length <= 80 ? result : result.substring(0, 80);
}

String _redactSecrets(String value) {
  var result = value;
  result = result.replaceAll(
    RegExp(
      r'(api[_ -]?key|access[_ -]?token|secret|password|authorization|bearer)'
      r'\s*[:=]\s*[^\s,;]+',
      caseSensitive: false,
    ),
    r'\$1=[REDACTED]',
  );
  result = result.replaceAll(
    RegExp(r'\b(?:sk-[A-Za-z0-9_-]{12,}|AIza[A-Za-z0-9_-]{20,}|'
        r'ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b'),
    '[REDACTED_API_KEY]',
  );
  return result;
}

DateTime? _minTime(Iterable<Message> messages) {
  DateTime? result;
  for (final message in messages) {
    if (result == null || message.timestamp.isBefore(result)) {
      result = message.timestamp;
    }
  }
  return result;
}

DateTime? _maxTime(Iterable<Message> messages) {
  DateTime? result;
  for (final message in messages) {
    if (result == null || message.timestamp.isAfter(result)) {
      result = message.timestamp;
    }
  }
  return result;
}

String? _argument(List<String> args, String name) {
  final index = args.indexOf(name);
  if (index == -1 || index + 1 >= args.length) return null;
  return args[index + 1];
}

bool _hasFlag(List<String> args, String flag) => args.contains(flag);
