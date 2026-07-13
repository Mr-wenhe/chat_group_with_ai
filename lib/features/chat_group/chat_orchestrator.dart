import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/features/autonomous/evidence_memory_prompt.dart';
import 'package:chat_group/features/agentic/agentic_task_classifier.dart';

/// Pure orchestration helpers for chat room logic.
/// Extracted from _ChatRoomPageState so they can be unit-tested without Flutter.
class ChatOrchestrator {
  static const Duration defaultGroupMemoryUpdateInterval =
      Duration(minutes: 10);

  static bool isEligibleToReply(AICharacter character) {
    if (!character.isActive) return false;
    if (character.apiKey.isEmpty) return false;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final last = character.lastReplyTimestamp;
    if (last == null) return true;
    final lastDay = DateTime(last.year, last.month, last.day);
    if (lastDay != today) return true;
    final diff = now.difference(last).inMinutes;
    if (diff >= 60) return true;
    return character.hourlyReplyCount < character.hourlyReplyLimit;
  }

  static String? blockReasonFor(AICharacter character) {
    if (!character.isActive) return 'inactive';
    if (character.apiKey.isEmpty) return 'noApiConfig';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final last = character.lastReplyTimestamp;
    if (last == null) return null;
    final lastDay = DateTime(last.year, last.month, last.day);
    if (lastDay != today) return null;
    final diff = now.difference(last).inMinutes;
    if (diff >= 60) return null;
    return character.hourlyReplyCount < character.hourlyReplyLimit
        ? null
        : 'hourlyLimit';
  }

  static void recordReplyUsage(AICharacter character) {
    final now = DateTime.now();
    final last = character.lastReplyTimestamp;
    final sameDay = last != null &&
        last.year == now.year &&
        last.month == now.month &&
        last.day == now.day;
    final withinHour = last != null && now.difference(last).inMinutes < 60;
    if (!sameDay || !withinHour) {
      character.hourlyReplyCount = 1;
    } else {
      character.hourlyReplyCount += 1;
    }
    character.lastReplyTimestamp = now;
  }

  static bool shouldUseAgenticRuntime({
    required AICharacter character,
    required String message,
  }) {
    return character.agenticEnabled &&
        AgenticTaskClassifier.requiresAgenticWork(message);
  }

  static String extractRecentFocus(List<Message> messages) {
    if (messages.isEmpty) return '';
    final recent =
        messages.length > 3 ? messages.sublist(messages.length - 3) : messages;
    final joined = recent.map((m) => m.content).join(' → ');
    if (joined.length > 200) {
      return '\n\n【当前对话焦点】最近大家在聊：${joined.substring(0, 200)}...';
    }
    return '\n\n【当前对话焦点】最近大家在聊：$joined';
  }

  static String recentDialogueTranscript({
    required List<Message> messages,
    required Map<String, String> senderNames,
    int maxMessages = 14,
    int maxChars = 1400,
  }) {
    if (messages.isEmpty) return '';
    final recent = messages.length > maxMessages
        ? messages.sublist(messages.length - maxMessages)
        : messages;
    final lines = recent.map((m) {
      final speaker = m.senderType == 'user'
          ? (senderNames[m.senderId] ?? '我')
          : (senderNames[m.senderId] ?? '一位AI成员');
      return '$speaker：${m.content.replaceAll(RegExp(r'\s+'), ' ').trim()}';
    }).where((line) => line.trim().isNotEmpty);
    final transcript = lines.join('\n');
    if (transcript.length <= maxChars) return transcript;
    return transcript.substring(transcript.length - maxChars);
  }

  static List<Map<String, dynamic>> agenticConversationHistory({
    required List<Message> messages,
    required String currentUserRequest,
    int maxMessages = 12,
  }) {
    if (messages.isEmpty) return const [];
    final source = List<Message>.from(messages);
    final normalizedRequest = currentUserRequest.trim();
    var removedCurrentRequest = false;
    for (var i = source.length - 1; i >= 0; i--) {
      final message = source[i];
      if (message.senderType == 'user' &&
          message.content.trim() == normalizedRequest) {
        source.removeAt(i);
        removedCurrentRequest = true;
        break;
      }
    }
    if (!removedCurrentRequest &&
        source.isNotEmpty &&
        source.last.senderType == 'user') {
      source.removeLast();
    }
    final trimmed = source.length > maxMessages
        ? source.sublist(source.length - maxMessages)
        : source;
    final out = <Map<String, dynamic>>[];
    for (final message in trimmed) {
      final content = message.content.trim();
      if (content.isEmpty) continue;
      if (message.senderType == 'user') {
        out.add({'role': 'user', 'content': content});
      } else if (message.senderType == 'ai') {
        out.add({'role': 'assistant', 'content': content});
      }
    }
    return out;
  }

  static String memoryPeriodKey(DateTime date) {
    final weekYear = _isoWeekYear(date);
    final week = _isoWeekNumber(date);
    return '${weekYear}_W${week.toString().padLeft(2, '0')}';
  }

  /// Legacy key format (before ISO week adoption): no zero-padding, custom week-of-year.
  static String legacyMemoryPeriodKey(DateTime date) {
    final firstDay = DateTime(date.year, 1, 1);
    final dayOfYear = date.difference(firstDay).inDays + 1;
    final firstDayOfWeek = firstDay.weekday;
    final offset = firstDayOfWeek <= DateTime.thursday ? 1 : 0;
    final week = ((dayOfYear + firstDayOfWeek - 1 - 4) / 7).floor() + offset;
    return '${date.year}_W$week';
  }

  static bool shouldUpdateGroupMemory({
    required int messageCount,
    required bool hasExistingSummary,
    DateTime? lastSummaryAt,
    DateTime? now,
    int minMessages = 8,
    Duration minInterval = defaultGroupMemoryUpdateInterval,
  }) {
    if (messageCount < minMessages) return false;
    if (!hasExistingSummary) return true;
    if (lastSummaryAt == null) return true;
    return (now ?? DateTime.now()).difference(lastSummaryAt) >= minInterval;
  }

  static bool shouldEvolveCharacterMemory({
    required int messageCount,
    required bool hasUserMessage,
  }) {
    return messageCount >= 2 && hasUserMessage;
  }

  static int _isoWeekYear(DateTime date) {
    final thursday = date.add(Duration(days: DateTime.thursday - date.weekday));
    return thursday.year;
  }

  static int _isoWeekNumber(DateTime date) {
    final thursday = date.add(Duration(days: DateTime.thursday - date.weekday));
    final firstThursday = DateTime(_isoWeekYear(date), 1, 4);
    final firstWeekThursday = firstThursday
        .add(Duration(days: DateTime.thursday - firstThursday.weekday));
    return thursday.difference(firstWeekThursday).inDays ~/ 7 + 1;
  }

  static String buildPersonaGrowthContext({
    required AICharacter character,
    required String groupName,
    required String groupTheme,
    required String groupDescription,
    required String groupMemory,
  }) {
    final tags = character.personalityTags.isEmpty
        ? '暂无显式标签'
        : character.personalityTags.join('、');
    final desc =
        groupDescription.trim().isEmpty ? '' : '\n群说明：$groupDescription';
    final memory = groupMemory.trim().isEmpty ? '暂无稳定群体记忆' : groupMemory;
    return '${EvidenceMemoryPrompt.factDiscipline}\n'
        '【人格成长规则】'
        '\n你是 ${character.name}，年龄 ${character.age}，职业/身份是「${character.role}」。'
        '\n初始性格标签：$tags。'
        '\n你所在的群是「$groupName」，主题「$groupTheme」。$desc'
        '\n群体记忆：$memory'
        '\n请把职业知识、群氛围、初始设定和已经形成的记忆融合成稳定个性：'
        '说话要有自己的偏好、关系感、情绪余温、表达习惯和边界感；'
        '允许缓慢形成口头禅、立场、喜恶、对其他成员的亲疏和长期关注点。'
        '不要突然换人格，不要机械复述设定，不要声称自己是AI模型。'
        '每次回复都像一个真实群友：短中句为主，有时追问，有时接梗，有时沉默式收束。';
  }

  static String buildMemoryEvolutionPrompt({
    required AICharacter character,
    required String groupName,
    required String groupTheme,
    required String currentMemory,
    required String recentTranscript,
    required String latestReply,
  }) {
    final tags = character.personalityTags.isEmpty
        ? '无'
        : character.personalityTags.join('、');
    return '${EvidenceMemoryPrompt.factDiscipline}\n'
        '你是角色长期记忆与人格成长记录员。'
        '\n角色：${character.name}；职业/身份：${character.role}；初始标签：$tags；所在群：$groupName；群主题：$groupTheme。'
        '\n\n已有角色记忆：${currentMemory.trim().isEmpty ? '暂无' : currentMemory.trim()}'
        '\n\n最近群聊：\n$recentTranscript'
        '\n\n${character.name}刚刚说：$latestReply'
        '\n\n请输出更新后的「角色自我记忆」，要求：'
        '\n1. 用第一人称或贴近角色内心的第三人称均可，但必须服务于后续扮演。'
        '\n2. 保留稳定事实、偏好、关系、表达习惯、职业视角、在这个群里的立场。'
        '\n3. 从最近对话中只吸收真正会改变角色的东西，不要编造未发生的经历。'
        '\n4. 让变化是渐进的：可以新增一点口头禅、关注点、亲疏关系或小情绪。'
        '\n5. 只输出记忆正文，控制在 500 字以内。';
  }

  static String stripNamePrefix(String content, String characterName) {
    final prefixes = [
      '【$characterName】：',
      '$characterName：',
      '$characterName: ',
      '$characterName:',
      '【$characterName】',
      '[$characterName]',
    ];
    for (final p in prefixes) {
      if (content.startsWith(p)) {
        return content.substring(p.length).trimLeft();
      }
    }
    return content;
  }
}
