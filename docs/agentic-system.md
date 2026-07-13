# Agentic 系统技术文档

> 本文档面向开发者和 AI 角色配置者，完整描述 Agentic 模式的设计原理、触发条件、
> 文件生成链路、附件回贴机制和排障方法。

---

## 目录

1. [系统概述](#1-系统概述)
2. [触发机制：哪些提示词会进入 Agentic 模式](#2-触发机制哪些提示词会进入-agentic-模式)
3. [完整执行流程](#3-完整执行流程)
4. [核心组件详解](#4-核心组件详解)
5. [附件回贴机制](#5-附件回贴机制)
6. [权限与审批](#6-权限与审批)
7. [容错与兜底策略](#7-容错与兜底策略)
8. [排障指南](#8-排障指南)

---

## 1. 系统概述

### 1.1 什么是 Agentic 模式

Agentic 模式是 AI 角色超越"纯文本对话"、进入**工具执行**状态的机制。在此模式下，AI 角色可以：

- **读写本地文件**（`workspace.patch`）：生成 HTML、Markdown、Dart、Python 等文件
- **运行命令**（`command.run`）：执行 `flutter analyze`、`flutter test` 等受控命令
- **获取浏览器上下文**（`browser.context`）：读取当前浏览器标签页内容
- **创建/下载技能**（`skill.create` / `skill.download`）：生成可复用的工作流脚本

### 1.2 与普通对话的区别

| 维度 | 普通流式对话 | Agentic 模式 |
|------|------------|-------------|
| 入口 | `_generateAiReply` → `streamChatMessage` | `_generateAiReply` → `_generateAgenticReply` → `AgentRuntime.run()` |
| LLM 调用次数 | 1 次（流式返回） | 2–4 次（规划 → 执行 → 结果整理，可能包含 re-prompt） |
| 文件操作 | 无 | 通过桥接服务读写本地文件 |
| 输出形式 | 纯文本消息 | 文本 + 附件卡片（`MediaAttachment`） |
| 用户审批 | 不需要 | `workspace.patch` / `command.run` 等需要用户批准 |
| 超时保护 | 流式自然结束 | 120 秒硬超时 + 6 步工具调用上限 |

### 1.3 架构位置

```
用户输入消息
    │
    ▼
_generateAiReply()                     ← chat_room_page.dart:1326
    │
    ├─ 条件判断：!isAutoChat && userMessage != null
    │           && AgenticTaskClassifier.requiresAgenticWork(userMessage)
    │           │
    │           ├─ true  → _generateAgenticReply()  ← Agentic 模式
    │           │            │
    │           │            ▼
    │           │         AgentRuntime.run()        ← agent_runtime.dart:604
    │           │            │
    │           │            ├─ LLM 规划 → ToolRequest
    │           │            ├─ 执行工具（写文件/运行命令等）
    │           │            ├─ LLM 整理结果
    │           │            └─ AgentRuntimeResult(message, toolResult, attachments)
    │           │
    │           └─ false → streamChatMessage()      ← 普通 LLM 对话
    │
    ▼
_appendMessage(Message)                 ← 消息落库 + UI 刷新
```

---

## 2. 触发机制：哪些提示词会进入 Agentic 模式

触发入口在 `AgenticTaskClassifier.requiresAgenticWork()`（`agentic_task_classifier.dart:56`）。

### 2.1 第一层：精确关键词列表（33 个）

只要消息中包含以下任意一个子串，**直接返回 `true`**，无需后续判断：

| 类别 | 关键词 |
|------|--------|
| **编码** | `写代码`、`review`、`代码审查`、`修复`、`bug` |
| **测试/命令** | `运行测试`、`运行命令`、`flutter analyze`、`flutter test` |
| **浏览器** | `当前浏览器`、`浏览器页面`、`网页内容`、`选中的网页` |
| **技能管理** | `生成skill`、`创建skill`、`下载skill`、`安装skill`、`专家skill` |
| **文档审核** | `审核这份`、`审查这份` |
| **规划/进度** | `任务计划`、`实施计划`、`进度保存`、`进度文件`、`总结文件`、`总结文档` |

> 注意：不区分大小写。`"Review"`、`"BUG"`、`"FLUTTER ANALYZE"` 均命中。

### 2.2 第二层：动作意图 + 产物意图双命中

如果第一层未命中，则检查两个正则是否**同时**匹配：

**动作意图**（`_createOrEditIntent`）：

```
生成 | 创建 | 写 | 设计 | 制作 | 做一个 | 做个 | 帮我做 | 给我做 | 实现 | 开发 |
输出 | 导出 | 修改 | 改一下 | 改写 | 编辑 | 整理 | 总结 | 转换 | 撰写 | 审核 |
审查 | 保存 | create | write | build | make | generate | edit | audit
```

**产物意图**（`_artifactIntent`）：

```
代码 | 脚本 | script | 特效 | html? | 网页 | 首页 | 主页 | 个人页 | 介绍页 |
页面 | 网站 | 落地页 | landing | app | 应用 | 小程序 | 小游戏 | 文件 | 文件夹 |
路径 | markdown | md | 文档 | 报告 | 简历 | 工作流 | dart | flutter | json |
ya?ml | css | javascript | js | python | py
```

**命中示例**：

| 用户消息 | 动作意图 | 产物意图 | 结果 |
|---------|---------|---------|------|
| `帮我生成一个 HTML 页面` | 生成 ✓ | html ✓ | ✅ 进入 Agentic |
| `写一份报告.md` | 写 ✓ | 报告 + md ✓ | ✅ 进入 Agentic |
| `创建一个 Python 脚本` | 创建 ✓ | py ✓ | ✅ 进入 Agentic |
| `帮我想想周末去哪玩` | — | — | ❌ 普通对话 |
| `讲个笑话吧` | — | — | ❌ 普通对话 |

### 2.3 第三层：显式文件路径

如果前两层均未命中，但消息中包含**带已知扩展名的文件路径**，则触发：

```regex
[\w][\w./\\-]*\.(html?|md|markdown|dart|txt|json|yaml|yml|svg|css|js|ts|py|sh|bash|c|cc|cpp|h|hpp)
```

**命中示例**：

- `把这段内容写到 page.html 里` → 匹配 `page.html` ✅
- `请保存为 config.json` → 匹配 `config.json` ✅
- `生成 main.dart` → 匹配 `main.dart` ✅

### 2.4 不触发的场景

以下条件**任一不满足**都会跳过 Agentic 模式，进入普通对话：

1. `isAutoChat == true` — 自动闲聊（idle auto-chat loop）永不进入 Agentic
2. `userMessage == null` — 无用户输入不触发
3. 三个检测层均未命中 — 关键词、双意图、文件路径都不匹配

### 2.5 触发概率总结

```
用户发消息
  │
  ├─ 含 33 个精确关键词之一？─────────────── YES → ✅ Agentic
  │                                         NO → 继续
  │
  ├─ 动作词 + 产物词同时命中？─────────────── YES → ✅ Agentic
  │                                         NO → 继续
  │
  ├─ 含显式文件路径（带扩展名）？─────────── YES → ✅ Agentic
  │                                         NO → 继续
  │
  └─ 以上都不命中 → ❌ 普通 LLM 对话
```

---

## 3. 完整执行流程

### 3.1 高层流程

```
用户输入
  │
  ▼
[1] _generateAiReply()
  │  检查 AgenticTaskClassifier.requiresAgenticWork()
  │
  ├─ false ──────────────────────────────────► [普通流式对话]
  │                                           streamChatMessage()
  │                                           流式渲染 token-by-token
  │                                           落库 → UI 显示
  │
  └─ true ──────────────────────────────────► [Agentic 模式]
      │
      ▼
  [2] _generateAgenticReply()
      │  创建 AgentTask（持久化到 Hive）
      │  调用 _ensureAgenticTaskPermissions() 动态授予权限
      │  解析技能 → 构建 AgentRuntime
      │
      ▼
  [3] AgentRuntime.run()
      │
      ├─ [3a] forceSkillCreation?
      │        YES → 先创建技能，再继续
      │
      ├─ [3b] 主路径：LLM 规划
      │        │  发送 tool planning prompt 给 LLM
      │        │  System: "你是一个工具调用助手...可用工具: workspace.patch..."
      │        │  User: 原始用户请求
      │        │
      │        ├─ LLM 返回 tool plan → ToolRequest.tryParse()
      │        │   ├─ 成功解析 → 继续 [4]
      │        │   └─ 解析失败 → 检查是否有工具调用痕迹
      │        │       ├─ 有痕迹 → re-prompt（最多 3 次）
      │        │       │   └─ 仍失败 → 兜底文件请求
      │        │       └─ 无痕迹 → 模型不需要工具，返回纯文本
      │        │
      │        └─ 超时（120s）→ 兜底文件请求
      │
      ▼
  [4] _handleToolRequest()
      │  检查权限
      │  检查是否需要审批（workspace.patch / command.run 需要）
      │  执行工具 → _execute()
      │
      ├─ workspace.patch → _executeWorkspacePatch()
      │    │  1. 路径安全校验（WorkspacePathGuard）
      │    │  2. 文件存在检查 → 自动递增后缀（page.html → page_2.html）
      │    │  3. 写入文件（/workspace/write）
      │    │  4. 读回验证（/workspace/read）
      │    │  5. 文件校验（FileValidator.validate）
      │    │  6. 返回 {ok, path, readbackContent, validation}
      │
      ├─ command.run → 执行受控命令
      │
      ├─ browser.context → 获取浏览器快照
      │
      ├─ skill.create → 创建角色技能
      │
      └─ skill.download → 下载预设技能
      │
      ▼
  [5] _continueAfterToolResult()
      │  发送 tool result prompt 给 LLM
      │  System: "工具已执行完毕。结果：{ok, path, readbackContent}。
      │          请用简洁语言总结结果，不要把文件内容贴进回复。"
      │
      ├─ LLM 返回整理结果
      │   ├─ 包含新的工具请求 → 递归 [4]（最多 6 步）
      │   ├─ 裸代码/文件全文泄漏 → _guardFinalMessage() 替换为简洁语
      │   └─ 正常文本 → 追加文件预览信息
      │
      └─ 返回 AgentRuntimeResult
          {status: completed, message, toolResult, executedToolRequests}
      │
      ▼
  [6] _attachmentsForAgentToolResult()
      │  从 executedToolRequests 提取文件路径
      │  从 toolResult 获取 readbackContent
      │  将文件内容写入 AI 角色媒体目录
      │  生成 MediaAttachment 列表
      │
      ▼
  [7] 创建消息并落库
      Message(
        groupId: ...,
        senderId: character.id,
        senderType: 'ai',
        content: "文件已生成，请查看附件。",
        media: [MediaAttachment(...)],  ← 附件卡片
      )
      │
      ▼
  [8] UI 渲染
      _MessageBubble
      ├─ _buildMediaContent() → _buildFileAttachment()  文件卡片
      └─ _buildContent()      → 文本 + "✅ 文件已生成" 底部信息
```

### 3.2 LLM 交互时序

```
┌──────────┐    ① tool planning prompt      ┌──────────┐
│   App    │───────────────────────────────▶│   LLM    │
│ (Runtime)│◀──────────────────────────────│          │
│          │  ② tool plan (agent_tool块)    │          │
└────┬─────┘                                 └──────────┘
     │
     │  ③ /workspace/write
     ▼
┌──────────┐    ④ tool result prompt       ┌──────────┐
│   App    │───────────────────────────────▶│   LLM    │
│ (Runtime)│◀──────────────────────────────│          │
│          │  ⑤ 简洁确认语                  │          │
└──────────┘                                 └──────────┘
```

正常情况下是 **2 次 LLM 调用**。某些场景下会更多：

| 场景 | LLM 调用次数 | 原因 |
|------|-------------|------|
| 正常文件生成 | 2 | 规划 + 整理 |
| 模型输出格式不对 | 3–5 | re-prompt 最多 3 次 |
| 多步骤任务（先创建技能再执行） | 3+ | 额外的 skill.create 调用 |
| 超时后兜底 | 3 | 规划失败 → 兜底生成内容请求 → 整理 |

---

## 4. 核心组件详解

### 4.1 AgenticTaskClassifier（门卫）

**文件**：`lib/features/agentic/agentic_task_classifier.dart`

静态类，纯函数判断，不依赖外部状态。

```dart
static bool requiresAgenticWork(String message)
```

- **输入**：用户消息原文
- **输出**：`true` — 进入 Agentic；`false` — 普通对话
- **调用位置**：
  - `chat_room_page.dart:1204` — 选角收敛判断
  - `chat_room_page.dart:1370` — 实际路由分支
  - `chat_room_page.dart:1896` — 动态权限授予前置检查
  - `chat_orchestrator.dart:63` — 意图选择辅助

### 4.2 AgentRuntime（执行引擎）

**文件**：`lib/features/agentic/agent_runtime.dart`

核心类，管理完整的工具调用生命周期。

**关键常量**：

| 常量 | 值 | 含义 |
|------|---|------|
| `maxToolSteps` | 6 | 单次任务最多执行 6 步工具调用 |
| `completionTimeout` | 120s | 单次 LLM 调用的硬超时 |
| `completionMaxRetries` | 3 | LLM 调用失败时的重试次数（默认值，通过 `RetryHandler`） |

**关键方法**：

| 方法 | 作用 |
|------|------|
| `run()` | 主入口：规划 → 执行 → 整理 → 返回结果 |
| `_handleToolRequest()` | 权限检查 → 审批判断 → 执行工具 → 递归下一步 |
| `_executeWorkspacePatch()` | 写文件：路径安全 → 写入 → 读回 → 校验 |
| `_continueAfterToolResult()` | 工具执行后调用 LLM 整理结果 |
| `_recoverGeneratedFileRequest()` | 从 LLM 裸输出中提取文件内容，转为工具请求 |
| `_repromptForToolFormat()` | 模型格式不对时重新提示（最多 3 次） |
| `_fallbackFileRequestAfterPlanningFailure()` | 规划阶段超时/失败后的兜底 |
| `executeApprovedTool()` | 用户批准后执行待审批的工具 |

### 4.3 ToolRequest（工具请求模型）

**文件**：`lib/features/agentic/tool_request.dart`

```dart
class ToolRequest {
  final AgentToolName tool;      // 工具名称
  final String reason;           // 调用原因（展示给用户）
  final Map<String, dynamic> args; // 工具参数
}
```

支持的工具（`AgentToolName`）：

| 工具名 | 权限 | 需要审批 | 作用 |
|--------|------|---------|------|
| `workspace.list` | `workspaceRead` | 否 | 列出目录文件 |
| `workspace.read` | `workspaceRead` | 否 | 读取文件内容 |
| `workspace.patch` | `workspacePatch` | **是** | 写入/修改文件 |
| `command.run` | `commandRun` | **是** | 运行受控命令 |
| `browser.context` | `browserContext` | **是** | 获取浏览器内容 |
| `skill.create` | `skillCreate` | **是** | 创建角色技能 |
| `skill.download` | `skillDownload` | **是** | 下载预设技能 |

### 4.4 AgentPromptBuilder（提示词构建器）

**文件**：`lib/features/agentic/agent_prompt_builder.dart`

构建两类 System Prompt：

**工具规划 Prompt**（`buildToolPlanningPrompt`）：

```
你是 {characterName}。你是一个工具调用助手。

可用工具：
1. workspace.patch - 写入文件（需要审批）
2. workspace.read - 读取文件
3. workspace.list - 列出目录
4. command.run - 运行命令（需要审批）
5. browser.context - 获取浏览器内容（需要审批）
6. skill.create - 创建技能
7. skill.download - 下载技能

请按以下格式输出工具请求：
```agent_tool
{"tool":"工具名","reason":"原因","args":{...}}
```

注意：
- 写入文件时，args 必须包含 path 和 content
- content 必须是文件的完整内容
- 如果需要运行多个步骤，每次只输出一个工具请求
```

**结果整理 Prompt**（`buildToolResultPrompt`）：

```
工具已执行完毕。结果如下：
{工具名}: {结果详情}

请用简洁的语言向用户总结结果。
重要：不要把文件内容贴进回复——文件已通过附件展示。
```

### 4.5 WorkspaceFileTool（文件操作）

**文件**：`lib/features/agentic/tools/workspace_file_tool.dart`

封装对本地桥接服务的文件操作调用：

```dart
class WorkspaceFileTool {
  Future<Map<String, dynamic>> list({String path = '.'});
  Future<Map<String, dynamic>> read(String path);
  Future<Map<String, dynamic>> write(String path, String content);
  Future<Map<String, dynamic>> applyPatch(String path, String patch);
  Future<Map<String, dynamic>> runCommand(String command);
}
```

实际通过 `LocalAgentBridgeClient`（Dio HTTP 客户端）向本地桥接服务（端口 54263）发送请求。

### 4.6 LocalAgentBridgeServer（本地桥接服务）

**文件**：`lib/features/agentic/tools/local_agent_bridge_server.dart`

在桌面端随 App 启动的内嵌 HTTP 服务：

| 端点 | 方法 | 作用 |
|------|------|------|
| `/health` | GET | 健康检查 |
| `/workspace/list` | POST | 目录列表 |
| `/workspace/read` | POST | 读取文件 |
| `/workspace/write` | POST | 写入文件 |
| `/workspace/apply-patch` | POST | 应用 git diff |
| `/command/run` | POST | 执行命令（白名单限制） |
| `/browser/current-tab` | GET | 浏览器快照 |

**安全限制**：
- 路径不能包含 `..` 或 `/`
- 不能写入绝对路径
- 不能以 `/` 结尾
- 命令只允许白名单内的命令

### 4.7 CharacterSkillResolver（技能解析）

**文件**：`lib/features/agentic/character_skill_resolver.dart`

根据用户请求和角色特征，自动匹配并注入相关技能：

| 角色关键词 | 自动注入技能 | 所需权限 |
|-----------|------------|---------|
| 代码相关角色 | Code Review、Bug Fix | workspaceRead, workspacePatch, commandRun |
| 研究类角色 | Browser Research | browserContext |
| 产品类角色 | Product Strategy | skillCreate |
| 写作类角色 | Writing Partner | skillCreate |
| 默认 | General Workflow Builder | skillCreate |

---

## 5. 附件回贴机制

### 5.1 从工具结果到附件的完整链路

```
workspace.patch 执行成功
  │
  ├─ toolResult = {ok: true, path: "page.html", readbackContent: "<!doctype html>..."}
  │
  ▼
_attachmentsForAgentToolResult()                    ← chat_room_page.dart:1943
  │
  │  ① 收集文件路径
  │     - 从 executedToolRequests[].args['path']
  │     - 从 executedToolRequests[].args['patch'] 解析
  │     - 从 result.toolResult['path']
  │     - 去重，最多 6 个
  │
  │  ② 获取文件内容（优先级从高到低）
  │     a) result.toolResult['readbackContent']  ← 写回后的读回内容
  │     b) lastPatchRequest.args['content']      ← 请求中的原始内容
  │     c) workspaceTool.read(path)              ← 重新读取桥接服务
  │
  │  ③ 写入 AI 角色媒体目录
  │     db.writeBytesToAiCharacterDir(
  │       bytes: utf8.encode(content),
  │       fileName: _fileNameFromPath(path),     // e.g., "page.html"
  │       characterId: character.id,
  │       characterName: character.name,
  │       type: _attachmentTypeForPath(path),    // "file"
  │     )
  │     │
  │     ▼
  │   MediaAttachment(
  │     id: uuid,
  │     type: "file",
  │     localPath: "/path/to/media/角色名_id/20260712_page.html",
  │     fileName: "page.html",
  │     fileSize: 2048,
  │     mimeType: "text/html",
  │   )
  │
  ▼
Message(
  content: "文件已生成，请查看附件。\n\n交付物：✅ 文件已生成：`page.html`（2.0 KB）...",
  media: [MediaAttachment(...)],
)
```

### 5.2 文件类型到附件类型的映射

`_attachmentTypeForPath()` 根据扩展名决定附件类型：

| 扩展名 | 附件类型 | UI 表现 |
|--------|---------|---------|
| `.jpg`, `.jpeg`, `.png`, `.gif`, `.webp`, `.bmp` | `image` | 内联图片预览 |
| `.mp4`, `.mov`, `.avi` | `video` | 视频播放器 |
| 其他所有类型 | `file` | 文件卡片（图标 + 文件名 + 大小） |

### 5.3 文件卡片的 UI 展示

文件卡片（`_buildFileAttachment`）是一个可点击的容器：

```
┌──────────────────────────┐
│ 📄  page.html            │  ← 文件类型图标 + 文件名
│        1,024 B           │  ← 文件大小
│                        → │  ← 打开箭头
└──────────────────────────┘
```

点击卡片 → `OpenFilex.open(localPath, type: mimeType)` 调用系统默认应用打开文件。

### 5.4 文件图标映射

`_fileIconFor()` 根据扩展名选择图标：

| 扩展名 | 图标 |
|--------|------|
| `.pdf` | `picture_as_pdf` |
| `.zip`, `.rar`, `.7z` | `folder_zip` |
| `.doc`, `.docx` | `description` |
| `.xls`, `.xlsx`, `.csv` | `table_chart` |
| `.ppt`, `.pptx` | `slideshow` |
| `.txt`, `.md`, `.json`, `.yaml`, `.dart` | `article` |
| 其他 | `insert_drive_file` |

---

## 6. 权限与审批

### 6.1 权限模型

每个 `AICharacter` 有一个 `toolPermissions` 列表，决定该角色可以使用哪些工具。

| 权限 | 对应工具 | 默认值 |
|------|---------|--------|
| `workspaceRead` | `workspace.list`, `workspace.read` | 通常授予 |
| `workspacePatch` | `workspace.patch` | 需明确请求 |
| `commandRun` | `command.run` | 需明确请求 |
| `browserContext` | `browser.context` | 需明确请求 |
| `skillCreate` | `skill.create` | Agentic 任务自动添加 |
| `skillDownload` | `skill.download` | Agentic 任务自动添加 |

### 6.2 动态权限授予

`_ensureAgenticTaskPermissions()`（`chat_room_page.dart:1892`）在每次 Agentic 任务开始时：

1. 基于 `AgenticTaskClassifier` 的检测结果
2. 基于 `CharacterSkillResolver` 的技能权限需求
3. 自动添加缺失的权限（如消息含"文件"/"代码" → 自动加 `workspaceRead` + `workspacePatch`）
4. 持久化到 Hive（`_db.aiCharacterBox.put`）

### 6.3 审批流程

`workspace.patch`、`command.run`、`browser.context`、`skill.create`、`skill.download` 需要用户审批：

```
AI 角色想写文件
  │
  ▼
_showAgentApprovalDialog()                    ← AlertDialog
  │
  ├─ "XXX 想使用工具 workspace.patch：生成 page.html"
  │   [批准]  [拒绝]
  │
  ├─ 批准 → _handlePendingAgentApproval('批准')
  │         → executeApprovedTool() → 执行工具
  │
  └─ 拒绝 → 任务标记为 cancelled
           → 返回取消消息
```

**例外**：私聊中明确的文件任务可通过 `autoApproveWriteTools` 自动批准（见 `shouldAutoApproveDirectFileTask`）。

---

## 7. 容错与兜底策略

### 7.1 LLM 规划失败的多层兜底

```
LLM 规划阶段
  │
  ├─ 超时（120s）
  │   └─ _fallbackFileRequestAfterPlanningFailure()
  │       ├─ 检查 _canGenerateNewFileDirectly() — 排除修改/运行/测试类请求
  │       ├─ _inferGeneratedFilePath() — 推断文件名
  │       ├─ _generateFileContentRequest() — 第二次 LLM 调用，直接要文件内容
  │       └─ _safeLocalFallbackFileRequest() — 本地模板兜底
  │
  ├─ 返回失败（success != true）
  │   └─ 同上兜底流程
  │
  ├─ 返回了工具调用痕迹但解析失败
  │   ├─ _looseParseToolRequest() — 宽松格式解析
  │   ├─ _repromptForToolFormat() — 重新提示 LLM（最多 3 次）
  │   └─ 仍失败 → 友好提示（不泄露原始规划文本）
  │
  └─ 没有工具意图（正常文本回复）
      └─ _sanitizeToolProtocolLeak() — 清理协议标记
          └─ 返回为普通聊天消息
```

### 7.2 文件内容泄漏防护

三层防护防止 LLM 把文件全文贴进聊天文字：

| 层级 | 机制 | 位置 |
|------|------|------|
| 1 | Prompt 明确要求"不要把文件内容贴进回复" | `buildToolResultPrompt` |
| 2 | `_guardFinalMessage()` — 检测代码围栏/HTML 标签/缩进代码块 | `agent_runtime.dart:220` |
| 3 | `_sanitizeToolProtocolLeak()` — 清理残留的工具协议标记 | `agent_runtime.dart:137` |

`_guardFinalMessage` 的检测规则：

- 闭合的 ` ```...``` ` 围栏且内部 > 80 字符
- 未闭合的围栏（LLM 输出被截断）
- 含 `<!doctype` 或 `<html>...</html>`
- 出现 4+ 个不同 HTML 标签
- 含 `import 'package:` / `void main(` 等源码特征
- ≥3 行以 ≥2 空格缩进且含代码符号

### 7.3 文件覆盖保护

- 写入前检查文件是否存在
- 已存在则自动递增后缀：`page.html` → `page_2.html` → `page_3.html` ...
- 最多尝试 999 次，超出则返回错误

### 7.4 重复写文件防御

```
_continueAfterToolResult()
  │
  ├─ 检测 executedRequests 中是否已有 workspace.patch
  │   └─ 是 → LLM 再次发起 workspace.patch → 静默吞掉，返回已完成
  │
  └─ 否 → 正常执行
```

### 7.5 路径安全

`WorkspacePathGuard` 强制校验：

- 必须是相对路径（不能以 `/` 开头）
- 不能包含 `..` 路径穿越
- 不能以 `/` 结尾
- 白名单扩展名之外的文件不自动推断路径

---

## 8. 排障指南

### 8.1 AI 没有进入 Agentic 模式

**症状**：用户要求生成文件，但 AI 只回了段文字，没有附件。

**排查步骤**：

1. 检查消息是否命中触发关键词（见第 2 节）
2. 检查 `character.agenticEnabled` 是否为 `true`
3. 检查角色是否有 `workspaceRead` / `workspacePatch` 权限
4. 检查桥接服务是否运行（桌面端端口 54263）
5. 查看 debug 输出：`[AI Reply] {characterName} apiMessages count=...`

### 8.2 Agentic 任务执行失败

**症状**：AI 返回 "工具任务失败"。

**排查步骤**：

1. 查看错误类型（连接级 vs HTTP 错误）
   - 连接级：检查端口 54263 是否被占用，尝试重启 App
   - HTTP 404：客户端与服务端版本不一致，重启 App
   - 其他 HTTP 错误：检查工具参数
2. 检查 LLM 返回的工具请求格式是否正确
3. 检查文件路径是否安全（无 `..`、无绝对路径）
4. 检查文件大小是否超过限制（5MB）

### 8.3 附件未显示

**症状**：工具执行成功，但没有文件卡片。

**排查步骤**：

1. 检查 `result.executedToolRequests` 中是否有 `workspace.patch`
2. 检查 `toolResult['ok']` 是否为 `true`
3. 检查 `result.toolResult['path']` 是否有值
4. 检查 `_attachmentsForAgentToolResult` 是否生成了 `MediaAttachment`

### 8.4 文件内容泄漏到聊天文字

**症状**：文件全文被贴进了聊天气泡。

**排查步骤**：

1. 这是已知防护机制（`_guardFinalMessage`）拦截失败的情况
2. 检查 `_looksLikeFileContentLeak()` 的检测规则是否覆盖了该类型
3. 考虑是否需要新增检测规则

### 8.5 审批对话框不出现

**症状**：AI 直接执行了写文件操作，没有弹出审批。

**排查步骤**：

1. 检查 `autoApproveWriteTools` 是否为 `true`（私聊中明确文件任务会自动批准）
2. 检查 `character.toolPermissions` 是否包含 `workspacePatch`
3. 检查审批判断逻辑：`requiresApproval(workspacePatch)` 返回 `true`，若 `approved || autoApproveWriteTools` 为 `true` 则跳过审批

---

## 附录 A：完整提示词示例

### A.1 触发 Agentic 模式的用户消息

**生成文件类**：

```
生成一份项目报告
创建一个 HTML 页面展示我的作品集
写一个 Python 脚本来批量重命名文件
帮我生成一个 Flutter 应用的主页
输出一份 JSON 配置文件
做一个 markdown 格式的会议纪要
设计一个 SVG 图标
```

**代码审查/修复类**：

```
审查 main.dart 的代码
修复这段代码中的 bug
review 一下这个函数
代码审查：帮我看看有什么问题
```

**运行测试/命令类**：

```
运行 flutter test
执行 flutter analyze
运行测试看看有没有问题
```

**浏览器类**：

```
当前浏览器页面是什么
读取浏览器选中的内容
总结一下这个网页
```

**技能管理类**：

```
生成一个技能来处理文件批量重命名
创建一个 skill 用于自动生成报告
下载专家 skill
```

### A.2 不触发 Agentic 的日常对话

```
今天天气怎么样        → 无关键词命中
帮我分析一下这段代码   → 有"分析"，但不在动作词列表中
讲个笑话              → 无关键词命中
你好啊                → 无关键词命中
```

要让"帮我分析一下这段代码"触发，需要改为：
- `帮我审查这段代码`（命中"审查"）
- `review 这段代码`（命中 "review"）
- `写一份代码审查报告`（动作词"写" + 产物词"代码/报告"）

### A.3 自动批准条件

以下条件**全部满足**时，写文件工具会自动批准（不弹审批框）：

1. 当前是**私聊**（`_isDirectChat == true`）
2. 用户消息明确是文件生成任务（通过 `shouldAutoApproveDirectFileTask` 判断）
3. `autoApproveTools` 参数为 `true`

判断逻辑（简化）：

```dart
static bool shouldAutoApproveDirectFileTask({
  required bool isDirectChat,
  required String userMessage,
}) {
  if (!isDirectChat) return false;
  return AgenticTaskClassifier.requiresAgenticWork(userMessage);
}
```

---

## 附录 B：文件命名推断规则

当用户没有明确指定文件名时，`_inferGeneratedFilePath()` 会根据内容推断：

| 消息关键词 | 推断文件名 |
|-----------|-----------|
| html / 页面 / 网页 / 网站 / 首页 / 主页 | `page.html` |
| 流星 / 夜空 / 星空 | `meteor_shower.html` |
| 湖 / 划船 / star / night / scene | `star_scene.html` |
| markdown / 报告 / 总结 / 简历 / readme | `report.md` |
| 技术文档 / 项目文档 / 工程目录 | `technical_documentation.md` |
| dart / flutter / app | `main.dart` |
| python / py | `script.py` |
| javascript / js | `app.js` |
| c++ / cpp / c语言 | `main.cpp` |
| 系统信息 / CPU / 内存 | `system_resource_monitor.cpp` |

---

## 附录 C：文件类型 MIME 映射

写入媒体目录时，根据扩展名自动设置 MIME 类型：

| 扩展名 | MIME 类型 |
|--------|----------|
| `.html` / `.htm` | `text/html` |
| `.md` / `.markdown` | `text/markdown` |
| `.json` | `application/json` |
| `.yaml` / `.yml` | `text/yaml` |
| `.dart` | `application/dart` |
| `.py` | `text/x-python` |
| `.js` / `.ts` | `text/javascript` |
| `.css` | `text/css` |
| `.svg` | `image/svg+xml` |
| `.cpp` / `.cc` / `.c` / `.h` / `.hpp` | `text/plain` |
| `.txt` | `text/plain` |

---

*文档生成时间：2026-07-12*
