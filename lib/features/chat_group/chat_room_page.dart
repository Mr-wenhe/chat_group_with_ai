import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:chat_group/core/database/data_lifecycle_service.dart';
import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/models/character_memory.dart';
import 'package:chat_group/core/models/character_skill.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/direct_chat_source.dart';
import 'package:chat_group/core/models/group_memory.dart';
import 'package:chat_group/core/models/media_attachment.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/core/models/tool_permission.dart';
import 'package:chat_group/core/models/user_profile.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/core/theme/app_theme.dart';
import 'package:chat_group/core/widgets/top_toast.dart';
import 'package:chat_group/features/agentic/agent_attachment_context.dart';
import 'package:chat_group/features/agentic/agent_runtime.dart';
import 'package:chat_group/features/agentic/agent_task_recovery_dialog.dart';
import 'package:chat_group/features/agentic/character_skill_resolver.dart';
import 'package:chat_group/features/agentic/context_window_manager.dart';
import 'package:chat_group/features/agentic/expert_skill_catalog.dart';
import 'package:chat_group/features/agentic/skill_download_service.dart';
import 'package:chat_group/features/agentic/tool_request.dart';
import 'package:chat_group/features/agentic/tools/browser_context_tool.dart';
import 'package:chat_group/features/agentic/tools/local_agent_bridge_client.dart';
import 'package:chat_group/features/agentic/tools/local_agent_bridge_launcher.dart';
import 'package:chat_group/features/agentic/tools/workspace_file_tool.dart';
import 'package:chat_group/features/ai_character/ai_character_form_page.dart';
import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/ai_governance/ai_governance_store.dart';
import 'package:chat_group/features/ai_governance/ai_request_gateway.dart';
import 'package:chat_group/features/ai_governance/search_coordinator.dart';
import 'package:chat_group/features/chat_group/chat_room_search_runtime.dart';
import 'package:chat_group/features/web_search/application/search_turn_context.dart';
import 'package:chat_group/features/web_search/models/search_models.dart'
    as web_search;
import 'package:chat_group/features/web_search/models/search_runtime_settings.dart';
import 'package:chat_group/features/web_search/presentation/web_search_sources_dialog.dart';
import 'package:chat_group/features/chat_group/agentic_reply_utils.dart';
import 'package:chat_group/features/chat_group/attachment_utils.dart';
import 'package:chat_group/features/chat_group/auto_chat_scheduler.dart';
import 'package:chat_group/features/chat_group/chat_activity_policy.dart';
import 'package:chat_group/features/chat_group/chat_group_form_page.dart';
import 'package:chat_group/features/chat_group/chat_orchestrator.dart';
import 'package:chat_group/features/chat_group/chat_room_loader.dart';
import 'package:chat_group/features/chat_group/chat_room_repository.dart';
import 'package:chat_group/features/chat_group/chat_room_utils.dart';
import 'package:chat_group/features/chat_group/chat_scroll_utils.dart';
import 'package:chat_group/features/chat_group/conversation_controller.dart';
import 'package:chat_group/features/chat_group/direct_read_receipt_policy.dart';
import 'package:chat_group/features/chat_group/humanized_chat_orchestrator.dart';
import 'package:chat_group/features/chat_group/humanized_prompt_builder.dart';
import 'package:chat_group/features/memory/memory_context_selector.dart';
import 'package:chat_group/features/memory/observation_entry.dart';
import 'package:chat_group/features/memory/relationship_event_service.dart';
import 'package:chat_group/features/chat_group/user_message_sentiment.dart';
import 'package:chat_group/features/chat_group/models/chat_room_models.dart';
import 'package:chat_group/features/chat_group/multimodal_content.dart';
import 'package:chat_group/features/chat_group/picked_attachment_payload.dart';
import 'package:chat_group/features/chat_group/reply_eligibility_policy.dart';
import 'package:chat_group/features/chat_group/scene_behavior.dart';
import 'package:chat_group/features/chat_group/streaming_reply_session.dart';
import 'package:chat_group/features/chat_group/streaming_reply_commit_policy.dart';
import 'package:chat_group/features/chat_group/widgets/chat_message_list.dart';
import 'package:chat_group/features/chat_group/widgets/chat_room_app_bar.dart';
import 'package:chat_group/features/chat_group/widgets/chat_room_banners.dart';
import 'package:chat_group/features/chat_group/widgets/chat_room_composer.dart';
import 'package:chat_group/features/chat_group/widgets/chat_room_search_status.dart';
import 'package:chat_group/features/chat_group/widgets/compact_conversation_controls.dart';
import 'package:chat_group/core/widgets/data_lifecycle_result_dialog.dart';
import 'package:chat_group/features/chat_group/widgets/hint_chip.dart';
import 'package:chat_group/features/chat_group/widgets/member_sheet.dart';
import 'package:chat_group/features/chat_group/widgets/sheet_button.dart';
import 'package:chat_group/features/chat_group/widgets/wecom_chat_components.dart';
import 'package:chat_group/features/direct_chat/direct_chat_session.dart';
import 'package:chat_group/features/document/document_understanding_service.dart';
import 'package:chat_group/features/memory/memory_controls.dart';
import 'package:chat_group/features/memory/memory_audit_filter.dart';
import 'package:chat_group/features/memory/memory_management_page.dart';
import 'package:chat_group/features/memory/relationship_audit_page.dart';
import 'package:chat_group/features/memory/relationship_private_detail_page.dart';
import 'package:chat_group/features/settings/export_page.dart';
import 'package:chat_group/features/work_mode/work_mode_config_service.dart';
import 'package:chat_group/features/work_mode/work_mode_memory_runner.dart';
import 'package:chat_group/features/work_mode/work_mode_policy.dart';
import 'package:chat_group/features/work_mode/work_mode_session.dart';
import 'package:chat_group/features/work_mode/work_mode_task_lifecycle.dart';
import 'package:chat_group/features/work_mode/work_mode_workspace_service.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:chat_group/services/conversation_presence_service.dart';
import 'package:chat_group/services/chat_api_service.dart';
import 'package:chat_group/services/message_speech_service.dart';
import 'package:chat_group/services/wecom_push_service.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:url_launcher/url_launcher.dart';

part 'chat_room_search_support.dart';
part 'chat_room_agentic_support.dart';
part 'chat_room_agentic_input_support.dart';
part 'chat_room_agentic_round_support.dart';
part 'chat_room_agentic_round_execution_support.dart';
part 'chat_room_agentic_generation_support.dart';
part 'chat_room_agentic_persistence_support.dart';
part 'chat_room_agentic_approval_support.dart';
part 'chat_room_message_context_support.dart';
part 'chat_room_message_context_documents_support.dart';
part 'chat_room_conversation_support.dart';
part 'chat_room_conversation_mention_support.dart';
part 'chat_room_ui_support.dart';
part 'chat_room_input_support.dart';
part 'chat_room_input_attachments_support.dart';
part 'chat_room_interaction_support.dart';
part 'chat_room_page_state.dart';
part 'chat_room_page_lifecycle_support.dart';
part 'chat_room_page_session_support.dart';
part 'chat_room_page_build_support.dart';

/// 空闲自动聊天（idle auto-chat）的对外可见状态，用于顶部状态条展示。
///
/// - [idle]：未启动 / 已停止
/// - [waiting]：已启动，正在等待下一次触发的间隔
/// - [generating]：本轮正在调用 LLM 生成回复
/// - [paused]：一个 burst 达到上限后的冷却期
/// - [unavailable]：没有任何配置了 API Key 的角色，功能不可用
/// - [error]：上一轮生成失败
enum AutoChatStatus { idle, waiting, generating, paused, unavailable, error }

/// 构建群成员面板的性别、职业、年龄、回复状态和限额文案。
String formatMemberStatus(
  AICharacter character,
  ReplyBlockReason? blockReason,
) {
  final usage =
      '${character.hourlyReplyCount}/${character.hourlyReplyLimit} 次/小时';
  final status = switch (blockReason) {
    null => '可回复',
    ReplyBlockReason.noApiConfig => '未配置 API',
    ReplyBlockReason.inactive => '已停用',
    ReplyBlockReason.hourlyLimit => '达到上限',
    ReplyBlockReason.alreadyGenerating => '生成中',
    ReplyBlockReason.networkError => '网络异常',
  };
  return '${character.displayGenderLabel} · ${character.role} · ${character.age}岁 · '
      '$status · $usage';
}

/// 聊天页面（群聊 + 私聊共用）。
///
/// 路由既可以是 `/chat/{groupId}`（群聊），也可以是 `/dm/{characterId}`（私聊）；
/// 私聊场景下 [groupId] 传入的是 `dm:{characterId}` 形式的会话键，
/// 由 [DirectChatSession] 负责识别与解析。
class ChatRoomPage extends ConsumerStatefulWidget {
  /// 会话 id：群聊为 ChatGroup.id，私聊为 `dm:{characterId}`。
  final String groupId;

  /// 可选的定位目标消息 id（例如从搜索结果 / 通知跳转进来时），
  /// 打开后会加载该消息所在分页并高亮滚动定位。
  final String? initialMessageId;

  /// 测试或嵌入场景可替换 API client，不改变生产默认网关。
  final ChatApiService? chatApi;

  /// 测试或嵌入场景可替换凭据解析器，不改变生产安全边界。
  final ApiCredentialResolver? credentialResolver;

  const ChatRoomPage({
    super.key,
    required this.groupId,
    this.initialMessageId,
    this.chatApi,
    this.credentialResolver,
  });

  @override
  ConsumerState<ChatRoomPage> createState() => _ChatRoomPageState();
}

/// 聊天页面状态。
///
/// 混入 [WidgetsBindingObserver] 以监听 App 前后台切换：回到前台时重新登记
/// 当前会话的"在场状态"并把消息标记为已读。
