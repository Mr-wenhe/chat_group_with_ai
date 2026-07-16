import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/features/chat_group/widgets/chat_message_bubble.dart';
import 'package:chat_group/features/chat_group/widgets/wecom_chat_components.dart';
import 'package:flutter/material.dart';

class ChatMessageListController {
  final Object _scope = Object();

  GlobalKey keyFor(String messageId) => GlobalObjectKey((_scope, messageId));

  BuildContext? contextFor(String messageId) =>
      keyFor(messageId).currentContext;
}

class ChatMessageList extends StatelessWidget {
  final List<Message> messages;
  final List<AICharacter> characters;
  final Map<String, Message> messageIndex;
  final Map<String, AICharacter> characterIndex;
  final ScrollController scrollController;
  final ChatMessageListController controller;
  final String? streamingMessageId;
  final String? regeneratingMessageId;
  final String? highlightedMentionMessageId;
  final bool isDirectChat;
  final Set<String> readUserMessageIds;
  final String ownerName;
  final AICharacter unknownCharacter;
  final Color Function(AICharacter character) senderColor;
  final String Function(String senderId) senderNameById;
  final void Function(Message message, AICharacter? sender) onLongPress;
  final void Function(AICharacter sender) onSenderTap;
  final void Function(AICharacter sender) onMentionSender;
  final void Function(Message message) onQuotedTap;

  /// P2：进度气泡总耗时起点查表，key=task.id，value=runStartedAtMs；
  /// 为 null 时进度气泡不展示实时耗时。
  final Map<String, int>? progressStartTimes;

  const ChatMessageList({
    super.key,
    required this.messages,
    required this.characters,
    required this.messageIndex,
    required this.characterIndex,
    required this.scrollController,
    required this.controller,
    required this.streamingMessageId,
    required this.regeneratingMessageId,
    required this.highlightedMentionMessageId,
    required this.isDirectChat,
    required this.readUserMessageIds,
    required this.ownerName,
    required this.unknownCharacter,
    required this.senderColor,
    required this.senderNameById,
    required this.onLongPress,
    required this.onSenderTap,
    required this.onMentionSender,
    required this.onQuotedTap,
    this.progressStartTimes,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ListView.builder(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final message = messages[index];
        final sender = message.senderType == 'user'
            ? null
            : characterIndex[message.senderId] ?? unknownCharacter;
        final quotedMessage = message.replyToMessageId == null
            ? null
            : messageIndex[message.replyToMessageId];
        final showDate = shouldShowWeComTimeDivider(
          message.timestamp,
          index == 0 ? null : messages[index - 1].timestamp,
        );

        // P2：进度消息解析 taskId（去 "agent-progress:" 前缀）查表得到
        // runStartedAtMs，传入气泡以展示实时总耗时；非进度消息为 null。
        final isProgressMessage = message.id.startsWith('agent-progress:');
        final taskId = isProgressMessage
            ? message.id.substring('agent-progress:'.length)
            : message.id;
        final startTimes = progressStartTimes;
        final runStartedAtMs = startTimes == null ? null : startTimes[taskId];

        return KeyedSubtree(
          key: controller.keyFor(message.id),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (showDate) _DateDivider(timestamp: message.timestamp),
              ChatMessageBubble(
                message: message,
                sender: sender,
                characters: characters,
                cs: colorScheme,
                isStreaming: streamingMessageId == message.id,
                isRegenerating: regeneratingMessageId == message.id,
                isHighlightedMention: highlightedMentionMessageId == message.id,
                onLongPress: () => onLongPress(message, sender),
                senderColor: senderColor,
                onSenderTap: sender == null ? null : () => onSenderTap(sender),
                onMentionSender:
                    sender == null ? null : () => onMentionSender(sender),
                quotedMessage: quotedMessage,
                quotedSenderName: quotedMessage == null
                    ? null
                    : senderNameById(quotedMessage.senderId),
                onQuotedTap: quotedMessage == null
                    ? null
                    : () => onQuotedTap(quotedMessage),
                ownerName: ownerName,
                readReceiptText: isDirectChat && message.senderType == 'user'
                    ? (readUserMessageIds.contains(message.id) ? '已读' : '未读')
                    : null,
                // P2：进度消息携带 runStartedAtMs，其它消息为 null（旧调用兼容）。
                runStartedAtMs: runStartedAtMs,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _DateDivider extends StatelessWidget {
  final DateTime timestamp;

  const _DateDivider({required this.timestamp});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: WeComChatTokens.timePill(context).withOpacity(0.92),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            _dateLabel(timestamp),
            style: const TextStyle(fontSize: 11, color: Colors.white),
          ),
        ),
      ),
    );
  }

  static String _dateLabel(DateTime timestamp) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final target = DateTime(timestamp.year, timestamp.month, timestamp.day);
    final difference = today.difference(target).inDays;
    final minute = timestamp.minute.toString().padLeft(2, '0');
    final time = '${timestamp.hour.toString().padLeft(2, '0')}:$minute';
    if (difference == 0) return time;
    if (difference == 1) return '昨天 $time';
    if (difference < 7) return '$difference 天前 $time';
    return '${timestamp.year}/${timestamp.month}/${timestamp.day} $time';
  }
}
