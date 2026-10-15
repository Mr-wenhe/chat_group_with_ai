import 'dart:async';
import 'dart:io';

import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/attachment_data_uri.dart';
import 'package:chat_group/core/models/media_attachment.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/text/entity_labels.dart';
import 'package:chat_group/core/widgets/character_avatar.dart';
import 'package:chat_group/core/widgets/readable_json_dialog.dart';
import 'package:chat_group/core/widgets/top_toast.dart';
import 'package:chat_group/features/chat_group/attachment_opener.dart';
import 'package:chat_group/features/chat_group/attachment_path_actions.dart';
import 'package:chat_group/features/chat_group/attachment_utils.dart';
import 'package:chat_group/features/agentic/agent_progress_meta.dart';
import 'package:chat_group/features/chat_group/message_action_item.dart';
import 'package:chat_group/features/chat_group/widgets/blinking_cursor.dart';
import 'package:chat_group/features/chat_group/widgets/message_selectable_text.dart';
import 'package:chat_group/features/chat_group/widgets/video_bubble.dart';
import 'package:chat_group/features/chat_group/widgets/wecom_chat_components.dart';
import 'package:chat_group/features/document/document_understanding_service.dart';
import 'package:chat_group/features/work_mode/work_detail_attachment.dart';
import 'package:chat_group/features/work_mode/work_mode_task_lifecycle.dart';
import 'package:chat_group/features/work_mode/work_task_user_action.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';

part 'chat_message_media.dart';
part 'progress_log_bubble.dart';

/// 系统提示的居中窄条宽度。
///
/// 比 AI 气泡（屏宽 72%，上限 640）窄，配合居中排版一眼能看出这不是某个角色
/// 的发言；系统提示没有头像和昵称，靠左时会被读成"一个不署名的人在说话"。
const double _systemNoticeMaxWidth = 560;

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

  /// 本条消息的操作项清单，长按弹窗与右键菜单共用同一份。
  ///
  /// 为 null 表示调用方不提供操作（如无宿主页面）。
  final MessageActionItemBuilder? messageActions;

  /// 点「我」自己的头像时的入口（打开资料页）。
  ///
  /// 不能复用 [onSenderTap]：那个回调只对可编辑的 AI 角色有值，用户消息恒为
  /// null，绑上去就是一块点不动的头像。
  final VoidCallback? onUserAvatarTap;
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

  /// 反显期把实体 id 换成人话标签；null 表示调用方不提供，正文原样显示。
  ///
  /// 与 [senderColor]、[senderAvatarImage] 同构：本类不碰 DatabaseService。
  final EntityLabels? entityLabels;

  /// 多选进行中：正文交出选择手势，让整行的点击用于勾选。
  final bool selectionMode;

  /// 点气泡正文。多选时用来切换勾选，其余时候为 null。
  final VoidCallback? onTap;

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
    this.onUserAvatarTap,
    this.messageActions,
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
    this.selectionMode = false,
    this.onTap,
    this.entityLabels,
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

    // 系统提示统一走居中窄条：它不代表任何角色发言，不能和左侧带头像与昵称的
    // AI 气泡共用一套排版。带任务按钮的提醒只是在这一条上多挂一个动作。
    if (isSystem) {
      return GestureDetector(
        onLongPress: onLongPress,
        onSecondaryTap: onLongPress,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Center(
            child: ConstrainedBox(
              constraints:
                  const BoxConstraints(maxWidth: _systemNoticeMaxWidth),
              child: WeComBubbleSurface(
                isUser: false,
                isHighlighted: isHighlightedMention,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildContent(context, message),
                    if (taskAction != null)
                      _buildTaskAction(context, taskAction),
                  ],
                ),
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
              // 与左侧 AI 头像同构：点自己的头像进资料页。中间的 SizedBox 留在
              // 外面，点击热区不能包含气泡的间距。
              InkWell(
                onTap: onUserAvatarTap,
                borderRadius: BorderRadius.circular(4),
                child: _buildAvatar(
                  fallbackText: avatarText,
                  image: userAvatarImage,
                  accent: cs.primary,
                ),
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

  /// 被引用的消息已被删除时的引用条。
  ///
  /// 不做成可点：目标已经不存在，点了无处可跳。左键条改用中性色，与真实引用
  /// 的强调色区分——同一条占位在群里可能同时出现好几个，别看着像在指向什么。
  Widget _buildDeletedQuotedRef(BuildContext context, bool isUser) {
    return Container(
      margin: const EdgeInsets.only(bottom: 7),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: isUser
            ? WeComChatTokens.lightText.withValues(alpha: 0.08)
            : WeComChatTokens.lightChatBackground.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 2,
            height: 18,
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
          const SizedBox(width: 7),
          Text(
            '原消息已删除',
            style: TextStyle(
              fontSize: 12,
              fontStyle: FontStyle.italic,
              color: WeComChatTokens.text(context).withValues(alpha: 0.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuotedRef(
    BuildContext context,
    Message? quoted,
    String? senderName,
    bool isUser,
  ) {
    // 调用方只在本条 `replyToMessageId` 非空时才进来，所以查不到就等于被引用的
    // 那条已被删除（滑出分页窗口的由父页回库补齐，见 `chat_room_page_build_support`）。
    if (quoted == null) return _buildDeletedQuotedRef(context, isUser);
    // 与正文同一条判据：只清洗 AI/系统消息；人话替换必须在截断之前——先截断会把
    // id 切掉一半，那时再没有可解析的 id，残缺 UUID 就留在气泡上方了。
    final quotedContent = entityLabels != null &&
            (quoted.senderType == Message.senderTypeAi ||
                quoted.senderType == Message.senderTypeSystem)
        ? entityLabels!.humanize(quoted.content)
        : quoted.content;
    final snippet = quotedContent.length > 50
        ? '${quotedContent.substring(0, 50)}...'
        : quotedContent;
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
    final labels = entityLabels;
    // 只清洗 AI 与系统消息：真人原话（user / member）一个字都不改。
    final rawContent = message.content.replaceAll('\\n', '\n');
    final shouldLocalize = labels != null &&
        (message.senderType == Message.senderTypeAi ||
            message.senderType == Message.senderTypeSystem);
    final content = shouldLocalize ? labels.humanize(rawContent) : rawContent;
    final mentionNames = <String>{
      ownerName,
      ...characters.map((character) => character.name),
    };
    final textStyle = TextStyle(fontSize: 15, color: textColor, height: 1.45);

    final actions = messageActions;
    final base = MessageSelectableText(
      content: content,
      style: textStyle,
      messageActions: actions == null ? null : () => actions(message, sender),
      enableSelection: !selectionMode,
      onTap: onTap,
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
