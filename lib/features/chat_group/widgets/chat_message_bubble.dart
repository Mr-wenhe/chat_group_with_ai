import 'dart:async';
import 'dart:io';

import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/attachment_data_uri.dart';
import 'package:chat_group/core/models/media_attachment.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/widgets/character_avatar.dart';
import 'package:chat_group/core/widgets/top_toast.dart';
import 'package:chat_group/features/chat_group/attachment_opener.dart';
import 'package:chat_group/features/chat_group/attachment_path_actions.dart';
import 'package:chat_group/features/chat_group/attachment_utils.dart';
import 'package:chat_group/features/agentic/agent_progress_meta.dart';
import 'package:chat_group/features/chat_group/widgets/blinking_cursor.dart';
import 'package:chat_group/features/chat_group/widgets/message_selectable_text.dart';
import 'package:chat_group/features/chat_group/widgets/video_bubble.dart';
import 'package:chat_group/features/chat_group/widgets/wecom_chat_components.dart';
import 'package:chat_group/features/document/document_understanding_service.dart';
import 'package:chat_group/features/work_mode/work_mode_task_lifecycle.dart';
import 'package:chat_group/features/work_mode/work_task_user_action.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';

part 'chat_message_media.dart';
part 'progress_log_bubble.dart';

/// 头像占位字：取昵称的第一个字形。
///
/// 用 `runes` 而不是 `name[0]`，否则 emoji 昵称会被截成半个代理对，
/// 渲染出乱码方块。
String _firstDisplayGlyph(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return '?';
  return String.fromCharCode(trimmed.runes.first);
}

/// 头像的文本形态：`avatar` 字段（emoji / 单字）优先，空则取名字首字。
///
/// AI 与「我」两侧**必须**共用这一条回落，否则资料页显示 emoji、
/// 群里气泡却只显示首字，同一个人两个样。
String _avatarTextFrom(String? avatar, String? name) {
  final glyph = avatar?.trim() ?? '';
  if (glyph.isNotEmpty) return glyph;
  return _firstDisplayGlyph(name ?? '');
}

/// A single chat message bubble — user or AI.
///
/// Displays avatar, sender name, quoted reference, media attachments,
/// text content with mention highlighting, read receipts, and a streaming
/// cursor. All state is passed via constructor parameters (pure data/callback),
/// with no dependency on `_ChatRoomPageState`.
class ChatMessageBubble extends StatelessWidget {
  final Message message;
  final AICharacter? sender;
  final List<AICharacter> characters;
  final ColorScheme cs;
  final bool isStreaming;
  final bool isRegenerating;
  final bool isHighlightedMention;
  final VoidCallback? onLongPress;
  final VoidCallback? onSenderTap;
  final VoidCallback? onMentionSender;
  final Color Function(AICharacter) senderColor;
  final Message? quotedMessage;
  final String? quotedSenderName;
  final VoidCallback? onQuotedTap;
  final String ownerName;
  final String? readReceiptText;
  final FutureOr<void> Function(WorkTaskUserAction action)? onTaskAction;

  /// P2：进度气泡总耗时起点（ms 时间戳），来自 [_progressStartTimes] 查表；
  /// 仅进度消息使用，其它消息传 null 以保持旧调用兼容。
  final int? runStartedAtMs;

  /// 发送者的已解析 IP 形象图；null → 回落文本头像。
  /// 纯 data/callback 契约的一部分：本类不碰 DatabaseService。
  final ImageProvider? senderAvatarImage;

  /// 「我」的已解析 IP 形象图；null → 回落文本头像。
  ///
  /// 只有用户消息使用。头像在气泡**右侧**（微信/企微风格），与 AI 的左侧相对。
  final ImageProvider? userAvatarImage;

  /// 「我」的文本头像（`UserProfile.avatar`，一般是 emoji）。
  ///
  /// 与 AI 侧的 `sender.avatar` 对位：图缺失时先取它，再退回名字首字。
  /// 漏传就会退回首字，于是资料页显示 emoji、气泡里显示「我」。
  final String userAvatarText;

  /// 群里的其他真人成员昵称，仅 `Message.senderTypeMember` 的消息传入。
  ///
  /// 真人没有 [AICharacter]，不能塞进 [sender] 冒充角色——那会让
  /// `onSenderTap` 打开一个根本不存在的角色详情页，也会把真人错算进
  /// 角色配色和 @ 提及里。单独开一个入口，让他们只借用"别人的消息"的排版。
  final String? memberName;

  const ChatMessageBubble({
    super.key,
    required this.message,
    this.sender,
    this.memberName,
    required this.characters,
    required this.cs,
    this.isStreaming = false,
    this.isRegenerating = false,
    this.isHighlightedMention = false,
    this.onLongPress,
    this.onSenderTap,
    this.onMentionSender,
    required this.senderColor,
    this.quotedMessage,
    this.quotedSenderName,
    this.onQuotedTap,
    required this.ownerName,
    this.readReceiptText,
    this.onTaskAction,
    this.runStartedAtMs,
    this.senderAvatarImage,
    this.userAvatarImage,
    this.userAvatarText = '',
  });

  @override
  Widget build(BuildContext context) {
    final isUser = message.senderType == 'user';
    // 昵称有两种来源：AI 角色走 sender，真人成员走 memberName。
    final displayName = sender?.name ?? memberName;
    // 头像与昵称分开判：用户消息**有头像无昵称**（自己的气泡不需要署名），
    // AI/成员消息两者都有。用户头像落在气泡右侧，见下方 `if (isUser)` 分支。
    final hasSender = !isUser && displayName != null;
    // 角色按 id 取稳定配色；真人成员没有角色配色，统一用主题色
    // （微信里其他人的昵称也是同一个颜色，不做人各一色）。
    final accent = sender != null ? senderColor(sender!) : cs.primary;
    final avatarText = hasSender
        ? _avatarTextFrom(sender?.avatar, displayName)
        : (isUser ? _avatarTextFrom(userAvatarText, ownerName) : '');
    final isSystem = message.senderType == 'system';
    final taskAction = message.senderType == 'ai' || isSystem
        ? WorkTaskUserAction.fromMessageId(message.id)
        : null;

    if (isSystem && taskAction != null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: WeComBubbleSurface(
              isUser: false,
              isHighlighted: isHighlightedMention,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildContent(context, message),
                  _buildTaskAction(context, taskAction),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return GestureDetector(
      onLongPress: onLongPress,
      onSecondaryTap: onLongPress,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Row(
          mainAxisAlignment:
              isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (hasSender) ...[
              InkWell(
                onTap: onSenderTap,
                borderRadius: BorderRadius.circular(4),
                child: _buildAvatar(
                  fallbackText: avatarText,
                  // 真人在本机没有档案，只有 AI 角色才有 IP 形象图。
                  image: sender == null ? null : senderAvatarImage,
                  accent: accent,
                ),
              ),
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Column(
                crossAxisAlignment:
                    isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                children: [
                  if (hasSender)
                    Padding(
                      padding: const EdgeInsets.only(left: 4, bottom: 4),
                      child: Row(
                        children: [
                          GestureDetector(
                            onTap: onSenderTap,
                            onSecondaryTap: onMentionSender,
                            onLongPress: onMentionSender,
                            child: Text(displayName,
                                style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: accent)),
                          ),
                          if (isRegenerating)
                            Padding(
                              padding: const EdgeInsets.only(left: 8),
                              child: SizedBox(
                                  width: 12,
                                  height: 12,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 1.5, color: cs.primary)),
                            ),
                        ],
                      ),
                    ),
                  WeComBubbleSurface(
                    isUser: isUser,
                    isHighlighted: isHighlightedMention,
                    child: Column(
                      crossAxisAlignment: isUser
                          ? CrossAxisAlignment.end
                          : CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (message.replyToMessageId != null)
                          _buildQuotedRef(
                            context,
                            quotedMessage,
                            quotedSenderName,
                            isUser,
                          ),
                        // 媒体渲染见 `chat_message_media.dart`：图片网格 / 视频 /
                        // 文件卡片自成一块，与气泡排版分开。
                        ChatMessageMedia(
                          message: message,
                          isUser: isUser,
                          cs: cs,
                        ),
                        _buildContent(context, message),
                        if (taskAction != null)
                          _buildTaskAction(context, taskAction),
                      ],
                    ),
                  ),
                  if (readReceiptText != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 3, right: 2),
                      child: Text(
                        readReceiptText!,
                        style: TextStyle(
                          fontSize: 10,
                          color: WeComChatTokens.nickname(context),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (isUser) ...[
              const SizedBox(width: 8),
              _buildAvatar(
                fallbackText: avatarText,
                image: userAvatarImage,
                accent: cs.primary,
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 气泡两侧共用的头像块。AI 在左、用户在右，尺寸与圆角保持一致。
  Widget _buildAvatar({
    required String fallbackText,
    required ImageProvider? image,
    required Color accent,
  }) {
    return CharacterAvatar(
      fallbackText: fallbackText,
      size: 40,
      image: image,
      shape: BoxShape.rectangle,
      borderRadius: const BorderRadius.all(Radius.circular(4)),
      background: accent.withValues(alpha: 0.14),
      textStyle: TextStyle(
          fontSize: 14, fontWeight: FontWeight.w600, color: accent),
    );
  }

  Widget _buildTaskAction(BuildContext context, WorkTaskUserAction action) {
    final callback = onTaskAction;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Semantics(
        button: true,
        label: action.semanticLabel,
        onTap: callback == null ? null : () => callback(action),
        child: ExcludeSemantics(
          child: OutlinedButton.icon(
            key: ValueKey<String>(action.messageId),
            onPressed: callback == null ? null : () => callback(action),
            icon: const Icon(Icons.open_in_new_rounded, size: 17),
            label: Text(action.label),
          ),
        ),
      ),
    );
  }

  Widget _buildQuotedRef(
    BuildContext context,
    Message? quoted,
    String? senderName,
    bool isUser,
  ) {
    if (quoted == null) return const SizedBox.shrink();
    final snippet = quoted.content.length > 50
        ? '${quoted.content.substring(0, 50)}...'
        : quoted.content;
    return GestureDetector(
      onTap: onQuotedTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 7),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: isUser
              ? WeComChatTokens.lightText.withValues(alpha: 0.08)
              : WeComChatTokens.lightChatBackground.withValues(alpha: 0.8),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Row(
          children: [
            Container(
              width: 2,
              height: 28,
              color: WeComChatTokens.mention,
            ),
            const SizedBox(width: 7),
            if (senderName != null)
              Text(senderName,
                  style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: WeComChatTokens.mention)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(snippet,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color:
                        WeComChatTokens.text(context).withValues(alpha: 0.68),
                  )),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context, Message message) {
    final textColor = WeComChatTokens.text(context);
    final content = message.content.replaceAll('\\n', '\n');
    final mentionNames = <String>{
      ownerName,
      ...characters.map((character) => character.name),
    };
    final textStyle = TextStyle(fontSize: 15, color: textColor, height: 1.45);

    final base = MessageSelectableText(
      content: content,
      style: textStyle,
      spans: buildWeComMentionSpans(
        content,
        mentionNames: mentionNames,
        baseStyle: textStyle,
      ),
    );

    // 流式回复末尾追加闪烁光标（打字机效果）。
    if (isStreaming) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Flexible(child: base),
          const SizedBox(width: 2),
          BlinkingCursor(color: textColor),
        ],
      );
    }

    // 工作模式进度气泡：统一交由 [ProgressLogBubble] 渲染（可折叠 + 实时耗时）。
    // 通过 ValueKey(message.id) 保持稳定实例，content 整体替换不重置折叠态。
    if (WorkModeTaskLifecycle.isProgressMessageId(message.id)) {
      return ProgressLogBubble(
        key: ValueKey(message.id),
        message: message,
        runStartedAtMs: runStartedAtMs,
      );
    }
    return base;
  }
}
