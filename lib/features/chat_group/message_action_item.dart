import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:flutter/material.dart';

/// 一条消息可执行的一个操作。
///
/// 长按弹窗与右键菜单渲染同一份清单：两份各写一遍时，新增的入口只会在其中
/// 一边出现（右键菜单长期只有原生的「复制」，就是这么落下的）。
class MessageActionItem {
  const MessageActionItem({
    required this.icon,
    required this.label,
    required this.onSelected,
    this.destructive = false,
  });

  final IconData icon;
  final String label;

  /// 纯动作，不含关闭自身的逻辑：宿主才知道自己是底部弹窗（`Navigator.pop`）
  /// 还是浮层（`hideToolbar`），关闭由宿主在调用本回调**之前**完成。
  final VoidCallback onSelected;

  /// 破坏性操作（删除）用 error 色渲染，与普通项区分开。
  final bool destructive;
}

/// 按消息与发送者产出操作清单。
///
/// [sender] 为 null 表示这条消息没有可操作的角色（真人成员或系统提示），
/// 生成类入口据此隐藏。
typedef MessageActionItemBuilder = List<MessageActionItem> Function(
  Message message,
  AICharacter? sender,
);

