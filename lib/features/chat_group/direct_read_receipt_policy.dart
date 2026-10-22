import 'package:chat_group/core/models/message.dart';

/// Computes private-chat user messages that have evidence of being read:
/// a later AI message exists in the same ordered conversation.
Set<String> directReadUserMessageIds(List<Message> messages,
    {String? streamingMessageId}) {
  final result = <String>{};
  var hasLaterAiMessage = false;
  for (var index = messages.length - 1; index >= 0; index--) {
    final message = messages[index];
    if (message.senderType == 'ai' &&
        message.id != streamingMessageId &&
        (message.content.trim().isNotEmpty ||
            message.media?.isNotEmpty == true)) {
      hasLaterAiMessage = true;
    } else if (message.senderType == 'user' && hasLaterAiMessage) {
      result.add(message.id);
    }
  }
  return result;
}
