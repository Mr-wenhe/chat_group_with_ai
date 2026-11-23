import '../../../core/models/ai_character.dart';

/// 内置圆桌新闻角色的稳定 id。
///
/// 它是不在群里发言的幕后检索器：由编排层显式调用，不参与自主联网，也不参与
/// 任何发言者选择。放在这一层是因为"能不能联网"的三个入口都依赖它。
const roundtableNewsRoleId = 'builtin-roundtable-news';

/// 调用方所在的联网场景。
///
/// 场景必须由入口显式给出，策略本身不认识聊天页、工作模式或圆桌：
/// 过去这条判据挂在聊天层的新闻角色服务上，工作模式要判断联网资格就得反向
/// import 聊天层；而"是不是圆桌回合"还在调用处另算了一遍
/// （`_roundtableModeEnabled && !_isDirectChat`），换个入口就漏。
enum AutonomousWebScene {
  /// 工作模式里的自主联网工具（web.search / web.read / web.download）。
  workMode,

  /// 群聊普通回合。
  groupChat,

  /// 群聊圆桌回合：来源由圆桌检索器统一供给，成员自己不联网。
  roundtable,

  /// 私聊（含主动消息）。
  directChat,
}

/// 「这个角色能不能自主联网」的唯一判据。
///
/// 三个入口（工作模式、群聊 agentic 回合、私聊主动消息）共用这一份，各自只
/// 声明场景。判据本身只有三条，任一条命中都不联网：
/// - 圆桌回合：来源已由检索器统一收集，成员再联网会在同一轮里重复检索；
/// - 内置新闻角色：它是幕后检索器，只被编排层调用；
/// - `zhipuSearchAnswerOnly`：正文由智谱原生搜索回填，不应再挂一层工具循环。
class AutonomousWebPolicy {
  const AutonomousWebPolicy._();

  static bool allows(AICharacter character, AutonomousWebScene scene) {
    if (scene == AutonomousWebScene.roundtable) return false;
    if (character.id == roundtableNewsRoleId) return false;
    return !character.zhipuSearchAnswerOnly;
  }
}
