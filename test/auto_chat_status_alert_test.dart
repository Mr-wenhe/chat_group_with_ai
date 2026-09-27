import 'package:chat_group/features/chat_group/chat_room_page.dart';
import 'package:chat_group/features/chat_group/widgets/compact_conversation_controls.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// 控制条"例外态提示"的映射规则。
///
/// 关键约束：正常态必须返回 null——提示条会常驻占据消息空间，而控制条的原始
/// 设计注释明确要避免这一点。所以这里逐状态钉住。
void main() {
  ConversationStatusAlert? map({
    bool workMode = false,
    bool autoEnabled = true,
    AutoChatStatus status = AutoChatStatus.waiting,
    bool allMuted = false,
    bool needsApiConfig = false,
    String blockedText = '暂时没有可以回复的角色',
    VoidCallback? onConfigureApi,
  }) =>
      autoChatStatusAlert(
        workModeEnabled: workMode,
        autoChatEnabled: autoEnabled,
        status: status,
        allMembersMuted: allMuted,
        blockedText: blockedText,
        needsApiConfig: needsApiConfig,
        onConfigureApi: onConfigureApi,
      );

  test('正常态一律不产生提示', () {
    for (final status in const [
      AutoChatStatus.idle,
      AutoChatStatus.waiting,
      AutoChatStatus.generating,
      AutoChatStatus.paused,
    ]) {
      expect(map(status: status), isNull, reason: '$status 属正常态');
    }
  });

  test('用户自己关掉总开关时不提示', () {
    expect(map(autoEnabled: false, status: AutoChatStatus.paused), isNull);
  });

  test('工作模式优先于运行状态，且用中性样式', () {
    final alert = map(workMode: true, status: AutoChatStatus.error);

    expect(alert?.message, '工作模式中，自动发言已暂停');
    expect(alert?.isWarning, isFalse);
  });

  test('异常态用警示样式', () {
    final alert = map(status: AutoChatStatus.error);

    expect(alert?.message, '自动发言异常，请检查网络或 API 配置');
    expect(alert?.isWarning, isTrue);
  });

  test('无人可发言：带出阻塞原因，未配置 API 时提供去设置', () {
    var tapped = 0;
    final alert = map(
      status: AutoChatStatus.unavailable,
      blockedText: '角色未配置 API Key',
      needsApiConfig: true,
      onConfigureApi: () => tapped++,
    );

    expect(alert?.message, '角色未配置 API Key');
    expect(alert?.actionLabel, '去设置');
    alert!.onAction!();
    expect(tapped, 1);
  });

  test('无人可发言但不是配置问题时不提供操作', () {
    final alert = map(status: AutoChatStatus.unavailable);

    expect(alert?.actionLabel, isNull);
    expect(alert?.onAction, isNull);
  });

  test('禁言立即覆盖等待态，无需等待调度器运行', () {
    expect(map(allMuted: true)?.message, '全部成员已禁言：只有 @ 点名才会回复');
    expect(map(allMuted: true, autoEnabled: false), isNull);
  });

  test('全员禁言给出专门文案，而不是通用兜底', () {
    final alert = map(
      status: AutoChatStatus.unavailable,
      allMuted: true,
      blockedText: '暂时没有可以回复的角色',
    );

    expect(alert?.message, '全部成员已禁言：只有 @ 点名才会回复');
    expect(alert?.isWarning, isFalse);
  });
}
