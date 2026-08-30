/// 工作模式 AI 角色流式进度日志 —— 共享协议层。
///
/// 集中定义进度步骤前缀、stage → 兜底文案映射、label 公式辅助、
/// 已完成步骤标签推导与头部状态文案。仅承载纯函数与常量，不依赖任何
/// Flutter / Hive / 运行时状态，便于单测直接覆盖。
library;

import 'package:chat_group/features/agentic/agent_runtime.dart';
import 'package:chat_group/features/agentic/tool_request.dart';

// ---------------------------------------------------------------------------
// 进度步骤前缀常量
// ---------------------------------------------------------------------------

/// 已完成步骤行前缀（✅）。
const String stepPrefixDone = '✅';

/// 当前进行中步骤行前缀（⏳）。
const String stepPrefixActive = '⏳';

// ---------------------------------------------------------------------------
// stage → 兜底文案映射
// ---------------------------------------------------------------------------

/// 各 [AgentRuntimeProgressStage] 在人类可读日志中的兜底文案。
///
/// 当 [AgentRuntimeProgress.currentStepLabel] 为空时回退到此表；
/// [AgentRuntimeProgressStage.toolCompleted] 为聚合刷新，不单独成行。
const Map<AgentRuntimeProgressStage, String> stageLabelFallback = {
  AgentRuntimeProgressStage.planning: '规划中',
  AgentRuntimeProgressStage.thinking: '思考中',
  AgentRuntimeProgressStage.readingFile: '读取文件中',
  AgentRuntimeProgressStage.callingTool: '调用工具中',
  AgentRuntimeProgressStage.writingFile: '写入文件中',
  AgentRuntimeProgressStage.fileCreated: '已创建文件',
  AgentRuntimeProgressStage.validating: '校验结果中',
  AgentRuntimeProgressStage.waitingForApproval: '等待批准',
  // 注：[AgentRuntimeProgressStage.toolCompleted] 为聚合刷新阶段，不单独渲染当前行（见
  // chat_room_utils.dart 的 `!isToolCompleted` 守卫），故无兜底文案。
  AgentRuntimeProgressStage.stepFailed: '步骤失败',
  AgentRuntimeProgressStage.stepRejected: '步骤已取消',
};

// ---------------------------------------------------------------------------
// label 公式辅助（供 AgentRuntime 埋点调用）
// ---------------------------------------------------------------------------

/// 思考 / 生成中步骤文案。
String thinkingLabel(String intent) => '正在$intent';

/// 调用工具前步骤文案。
String callingToolLabel(String name) => '正在调用工具：$name';

/// 读取文件步骤文案。
String readingFileLabel(String path) => '正在读取文件：$path';

/// 写入文件步骤文案。
String writingFileLabel(String path) => '正在写入文件：$path';

/// 文件写入成功步骤文案。
String fileCreatedLabel(String path) => '已创建文件：$path';

/// 校验结果步骤文案。
String validatingLabel(String path) => '正在校验结果：$path';

/// 步骤失败文案（reason 为异常信息或简短中文）。
String stepFailedLabel(String reason) => '步骤失败：$reason';

/// 用户拒绝 / 取消步骤文案。
String stepRejectedLabel(String name) => '已取消：$name';

/// 等待用户批准步骤文案。
///
/// [path] 可选，非空时追加「（path）」以展示等待批准的具体目标。
String waitingApprovalLabel(String name, [String? path]) =>
    '等待批准：$name${path == null || path.isEmpty ? '' : '（$path）'}';

// ---------------------------------------------------------------------------
// 已完成步骤标签（由 ToolRequest 派生 ✅ 行）
// ---------------------------------------------------------------------------

/// 由已完成工具请求派生一条「已完成步骤」标签。
///
/// 依据工具类型选择动词（读取 / 已创建 / 列出 / 执行命令 等），并以
/// [ToolRequest.args] 中的 `path` 或 `command` 作为目标说明。
String completedStepLabel(ToolRequest request) {
  final path = request.args['path']?.toString();
  final command = request.args['command']?.toString();
  final target = (path ?? command ?? '').trim();
  final subject = target.isNotEmpty ? target : request.tool.wireName;

  switch (request.tool) {
    case AgentToolName.workspaceRead:
      return '读取文件：$subject';
    case AgentToolName.workspaceSearch:
      return '搜索工作区：$subject';
    case AgentToolName.workspacePatch:
      return '已创建文件：$subject';
    case AgentToolName.workspaceRename:
      return '重命名文件：$subject';
    case AgentToolName.workspaceDelete:
      return '删除文件：$subject';
    case AgentToolName.workspaceList:
      return '列出工作区：$subject';
    case AgentToolName.commandRun:
      return '执行命令：$subject';
    case AgentToolName.browserContext:
      return '抓取浏览器上下文';
    case AgentToolName.skillCreate:
      return '创建技能：$subject';
    case AgentToolName.skillDownload:
      return '下载技能：$subject';
  }
}

// ---------------------------------------------------------------------------
// 头部状态文案
// ---------------------------------------------------------------------------

/// 进度气泡首行头部文案。
///
/// - 执行中：`🧭 {name} · 工作模式 ｜ 执行中`
/// - 终态成功：`🧭 {name} · 工作模式 ｜ 已完成`
/// - 终态失败：`🧭 {name} · 工作模式 ｜ 失败`
String statusHeader(
  String characterName, {
  required bool isFinal,
  required bool failed,
}) {
  final tail = isFinal ? (failed ? ' ｜ 失败' : ' ｜ 已完成') : ' ｜ 执行中';
  return '🧭 $characterName · 工作模式$tail';
}

// ---------------------------------------------------------------------------
// P2 批准态文案 + 总耗时格式化
// ---------------------------------------------------------------------------

/// 批准态文案：✅ 行尾追加，表示该步需要人工批准（如 workspacePatch / commandRun）。
const String approvalTag = ' · 需批准';

/// 批准态文案：✅ 行尾追加，表示该步自动执行、无需批准（如 workspaceRead / workspaceList）。
const String autoTag = ' · 自动';

/// 总耗时格式化（进度气泡头部实时跳动展示「总耗时」）。
///
/// - <60s → "Ns"（如 `42s`）
/// - ≥60s → "Nm分ss秒"（秒补零两位，如 `2分05秒`）
String formatElapsed(int totalSeconds) {
  if (totalSeconds < 60) return '${totalSeconds}s';
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  return '$minutes分${seconds.toString().padLeft(2, '0')}秒';
}
