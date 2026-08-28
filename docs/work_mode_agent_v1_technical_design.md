# 工作模式 AI Agent V1 技术设计与实施验收计划

状态：Draft，等待用户评审
日期：2026-08-27
需求基线：`docs/work_mode_agent_v1_requirements.md`

## 1. 可行性结论

### 1.1 单 App 结论

核心工作模式可以做到只安装本 App，不需要用户另启本地服务：

- 文件夹选择复用现有 `file_picker`。
- 文件、目录、快照、撤销和进程执行使用 Dart `dart:io`。
- 授权、设置和任务元数据使用现有 Hive。
- PDF、DOCX、XLSX 读取复用现有 `DocumentUnderstandingService`、`syncfusion_flutter_pdf`、`xml` 和 `archive`。
- 图片视觉输入复用现有多模态消息构造与角色模型能力判断。
- 模型请求复用现有 `AiRequestGateway`、凭据解析和 SSE 流。
- 本地工具改为 App 进程内直接调用，不再保留 localhost HTTP bridge，因此没有端口占用、服务未启动或客户端/服务版本不一致问题。

### 1.2 必须诚实说明的 Windows 例外

可见浏览器建议新增 `desktop_webview_window 0.3.0`：它支持 Dart 3.5、macOS 和 Windows，macOS 使用系统 WKWebView；Windows 使用 WebView2。Windows 11 通常内置 WebView2，部分 Windows 10 设备可能缺失。App 必须启动前检测；缺失时按已确认规则展示来源和影响，由用户选择一键安装或放弃浏览器兜底。

因此：macOS 本地安装包可实现真正的“只装一个 App”；Windows 核心 Agent 仍只需本 App，但可见浏览器在旧系统上可能需要由 App 辅助补装微软 WebView2 Runtime。若要求 Windows 也绝对不含任何系统运行时依赖，只能改为内嵌完整 Chromium/CEF，而当前成熟方案要求 Flutter 3.27+，不兼容本项目 Flutter 3.24 fork，不采用。

### 1.3 最小新增依赖

| 依赖 | 用途 | 选择理由 |
|---|---|---|
| `desktop_webview_window: 0.3.0` | macOS/Windows 可见浏览器、执行 JS 提取正文 | 一个包覆盖两个桌面平台，Dart 3.5 可用，可检查 WebView2 可用性 |
| `html: 0.15.6` | 解析无 Key 搜索 HTML 与公开页面正文 | 纯 Dart HTML5 parser，避免继续堆易碎正则；Dart 3.2+ 可用 |

除上述两个候选外，V1 不新增服务端、数据库、进程守护或自定义原生插件。每个依赖必须先做最小 macOS build spike；构建不兼容则停在该阶段重新评审，不偷偷引入替代框架。

参考资料：

- `desktop_webview_window 0.3.0` 支持 macOS/Windows，要求 Dart 3.5；Windows 后端依赖 WebView2，并提供可用性检测：https://pub.dev/packages/desktop_webview_window
- 该包支持 `evaluateJavaScript`，可提取页面正文：https://pub.dev/documentation/desktop_webview_window/latest/desktop_webview_window/Webview-class.html
- `html 0.15.6` 是 Dart HTML5 parser，最低 Dart 3.2：https://pub.dev/packages/html

## 2. 现有实现取舍

### 2.1 直接复用

- `AiRequestGateway`：预算、重试、流式 API、角色自己的凭据。
- `CredentialResolver`：不复制或明文持久化 API Key。
- `DocumentUnderstandingService` / `BinaryDocumentParser`：PDF、DOCX、XLSX 解析。
- `prepareUserMessageContent`：视觉模型图片输入。
- `ConversationController` 的串行思想：保留“同一会话单任务”语义，但状态所有权移到全局服务。
- `WorkspacePathGuard` 的相对路径、目录边界和符号链接检查逻辑：迁移到直接 IO 工具层。
- `SearchProviderChain`、失败分类、审计、Prompt Injection 防护：扩展路由，不重写治理框架。
- 现有 `file_picker`、Hive、`path_provider`、`archive`、`Dio`。

### 2.2 替换或删除

- 删除 App 内 localhost HTTP bridge 的生产调用链：`LocalAgentBridgeClient/Launcher/Server` 不再是工作模式运行依赖。
- 拆除 `AgentRuntime` 中硬编码文件名推断、语言模板、二进制伪降级、多套 XML/正则工具协议和“写完即完成”分支。
- 进度气泡改为独立任务事件流和执行面板；聊天只保存用户请求和最终结论/产物。
- `WorkModeSession` 不再由页面持有；页面只提交任务并订阅状态。
- 旧的“新输入取消待审批任务”规则与测试删除，替换为持久队列。
- `WorkModeWorkspaceService` 的 App 自建会话目录不再作为唯一工作区；授权根目录成为真实工具边界。

这是 `ponytail` 的关键取舍：既然 bridge 与 App 在同一进程，绕 localhost HTTP 只增加端口、鉴权、生命周期和版本错误，直接调用 Dart 服务更短、更可靠。

## 3. 目标架构

```text
聊天页 / 全局任务胶囊 / 设置页
                │
                ▼
        WorkTaskCoordinator（App 级）
        ├─ 每会话 FIFO 队列
        ├─ 全局并发 2
        ├─ 路径/目录写锁
        └─ 崩溃检查点与手动恢复
                │
                ▼
          AgentLoop（单任务）
        ├─ WorkRoleRouter / HandoffPlan
        ├─ WorkContextRepository
        ├─ AgentDecisionParser
        ├─ ApprovalScope
        └─ 100 步 / 60 分钟软上限
                │
                ▼
          WorkToolDispatcher
        ├─ FolderGrantService
        ├─ WorkspaceFileService
        ├─ CommandRunner
        ├─ SnapshotService / UndoService
        ├─ Document / Vision Adapter
        └─ Search / VisibleBrowser Adapter
                │
                ▼
       TaskEventStore（JSONL）→ 执行面板
```

### 3.1 所有权规则

- `WorkTaskCoordinator` 在 `ProviderScope` 下以 App 级 provider/singleton 存活，不依赖任何聊天页面生命周期。
- `ChatRoomPage` 只调用 `submitUserTurn`、`answerQuestion`、`approveScope`、`stopTask`、`resumeTask`、`undoTask`。
- 工具层不依赖 Flutter `BuildContext`；需要系统选择器或弹窗时，任务进入等待态，由 UI 响应事件。
- 同一任务只有 `AgentLoop` 能推进状态；UI 不直接修改任务检查点。

## 4. 持久化设计

### 4.1 App 设置（`app_settings`）

使用小型 JSON Map，不新增 Hive adapter：

- `work_mode.folder_grants.v1`：授权根目录、显示名、规范路径、授权时间、云端外发提示确认时间、最近校验时间、是否有效。
- `work_mode.settings.v1`：普通写入确认开关、并发上限 2、保留 30 天、快照上限 2 GB。
- `work_mode.scheduler.v1`：每会话排队任务 ID、最近活跃任务 ID，仅作崩溃恢复索引。

授权记录不是 OS 权限令牌。首版本地安装包关闭 macOS App Sandbox，因此记录的是用户在系统选择器中的明确 App 级同意；未来 App Store 版另加 security-scoped bookmark。

### 4.2 `AgentTask`

不兼容旧工作任务，允许调整枚举和生成 adapter。保留可查询的最小字段：

- `id/groupId/userRequest/status/createdAt/updatedAt/currentStep/lastError`。
- 新增 `parentTaskId`、`requestMessageId`、`activeCharacterId`、`eventLogPath`、`checkpointJson`、`snapshotManifestPath`、`expiresAt`。
- 状态至少包括：`queued`、`planning`、`running`、`waitingForFolder`、`waitingForWriteApproval`、`waitingForClarification`、`waitingForModelChoice`、`pausedLimit`、`interrupted`、`completed`、`failed`、`cancelled`。

详细步骤、交接计划和批准范围放入有版本号的 `checkpointJson`，避免为每个内部字段增加 Hive schema；查询所需字段仍保持类型化。

### 4.3 事件与快照文件

- 事件：App Support 下 `work_mode/tasks/<taskId>/events.jsonl`，逐条追加，不保存文件全文和密钥。
- 快照：`work_mode/snapshots/<taskId>/`，包含 manifest、被覆盖/删除文件副本和新建文件记录。
- 任务终态后 30 天清理；总量超过 2 GB 时先清理最旧已完成任务。
- 写事件失败不能撤销已发生工具结果，但必须把任务标记为“日志不完整”；写快照失败则在写操作前阻止或要求单独确认无撤销继续。

## 5. Agent 循环

### 5.1 单一决策协议

所有 Provider 先统一使用严格 JSON 决策协议，不在 V1 同时维护多套 XML/Markdown 方言：

```json
{
  "type": "tool | clarify | handoff | final",
  "summary": "展示给用户的当前动作摘要",
  "tool": "workspace.read",
  "args": {},
  "next": []
}
```

解析规则：

1. 流式接收模型输出，面板只展示安全的动作状态，不展示私有思维链。
2. 只解析一个顶层 JSON object；允许外层 JSON code fence，不兼容任意 XML。
3. 解析失败时用同一角色模型做一次短 JSON 修复。
4. 流式通道为空时，对同一请求回退一次非流式调用。
5. 两次均失败则进入可恢复错误态，说明具体原因；不得用硬编码伪产物冒充成功。

标准 function/tool calling 可在后续按 Provider 能力逐个接入，但不是 V1 正确性的前提。DeepSeek、通义、智谱、Moonshot、百度和自定义 OpenAI-compatible 配置都先走这条统一文本 JSON 路径，且比当前多正则协议更容易测试。

### 5.2 循环伪代码

```text
恢复检查点或建立新任务
while 未完成:
  检查停止、100 步、60 分钟、任务所有权
  构造压缩后的会话 + 任务 + 工具结果上下文
  请求当前角色产生一个 AgentDecision
  clarify  -> 持久化问题并等待用户
  handoff  -> 写交接摘要，切换下一角色
  tool     -> 权限/审批/快照/锁校验 -> 执行 -> 记录结果
  final    -> 轻量验证门禁 -> 完成并写聊天结论
```

每次模型决策、文件读取、文件写入、命令、网页访问均计一步。到达 100 步或 60 分钟时进入 `pausedLimit`，用户继续后开启新额度，不丢上下文。

### 5.3 上下文压缩不可丢字段

压缩摘要必须结构化保留：目标、验收条件、用户最新修订、原始产物路径、角色交接、已完成工具、副作用、批准范围、未决问题、验证证据、错误与重试。禁止只保存自然语言聊天摘要。

## 6. 角色路由与接力

### 6.1 路由输入

- 当前用户请求和最近工作上下文。
- 群成员的 `id/name/role/rolePlaySystemPrompt/personalityTags/agenticEnabled/API 可用状态`。
- 显式 `@` 角色。

### 6.2 路由策略

1. 私聊固定为当前角色。
2. `@` 单个角色时固定初始执行者；`@` 多个角色时只在这些角色中规划顺序。
3. 无 `@` 时做一次很短的结构化路由请求，复用群中第一个可用 API，但不以该角色身份发言。
4. 路由器返回阶段列表与 executor ID；返回未知 ID 或不可用角色时本地拒绝并修复一次。
5. 每个阶段结束必须输出交接摘要；调度器释放旧执行权后再授予下一角色。

无需新增“职业标签”字段。若角色资料无法区分能力，Agent 只问用户一个澄清问题，不擅自让所有角色并发尝试。

## 7. 文件夹授权与路径策略

### 7.1 授权

- `file_picker.getDirectoryPath` 负责系统选择。
- 存储 `Directory(path).absolute`，每次使用前解析最近存在祖先的符号链接并重新校验。
- 路径必须位于任一有效授权根；Windows 使用大小写不敏感比较并规范盘符。
- 新路径触发 `waitingForFolder`，UI 打开选择器；用户取消则任务保持可恢复暂停，不直接失败。

### 7.2 敏感文件

`SensitiveFilePolicy` 使用小型内建规则识别 `.env*`、私钥、证书、credential/key/token 文件和本项目本地凭据文件。命中时即使目录已授权也要按具体文件二次确认；确认只在本任务有效。

### 7.3 按需目录读取

`WorkspaceFileService` 使用 Dart IO 实现有界 `list/read/search`：

- 默认跳过 `.git`、build 输出、依赖缓存和隐藏敏感文件。
- 目录遍历有文件数、深度、单文件和总字节上限。
- 先文件名/关键词搜索，再读取少量相关片段；不建立持久语义索引。
- PDF/DOCX/XLSX 转成临时 `MediaAttachment` 复用现有文档解析；图片复用多模态 content builder。

## 8. 写入审批、快照和撤销

### 8.1 变更计划

模型不能直接写。`MutationPlanner` 把写工具或命令规范化为：

- 变更类型。
- 精确文件列表。
- 无法精确时的影响目录。
- 是否删除、覆盖、安装、Git 变更。
- 是否可创建完整快照。

`ApprovalScope` 是任务内一次性能力，只包含已批准规范路径和变更类型；新增路径必须补充批准。

### 8.2 始终确认

即使设置关闭普通写入确认，以下操作仍确认：

- 删除文件或目录。
- 无法创建撤销快照的覆盖。
- 影响范围无法可靠预测的命令。
- 工具安装、Git 提交/推送等外部状态变更。

### 8.3 快照算法

- 直接文件工具：变更前复制旧文件；新文件记为 `created`；重命名记录源和目标；删除复制原文件。
- 命令：对声明的精确文件做同样快照；只有影响目录无法精确时才尝试目录级快照。
- 目录级快照超过剩余配额或磁盘不足时阻止执行，除非用户单独确认“无撤销继续”。
- manifest 记录变更前 hash/mtime/size。撤销前若文件已被用户再次修改，必须展示冲突并逐项选择，不能静默覆盖。
- 一键撤销只撤销该任务记录的变化，不运行 `git reset`，不破坏任务开始前的用户未提交修改。

## 9. 终端执行

### 9.1 结构化命令

命令工具从单个 shell 字符串改为：

```json
{
  "executable": "flutter",
  "args": ["analyze", "lib/foo.dart"],
  "cwd": "/authorized/project",
  "impactPaths": ["/authorized/project/lib/foo.dart"],
  "network": false,
  "mutating": false
}
```

优先 `Process.start(..., runInShell: false)`，避免 shell 注入；确实需要 shell 时必须作为高风险命令单独确认。可执行文件解析、cwd 和路径参数都经过应用级策略校验。

### 9.2 生命周期

- stdout/stderr 分流并实时写 `TaskEvent`。
- 停止任务时先正常终止，短超时后强制 kill；终态记录退出码。
- 出现密码、登录提示或长期无输出且等待 stdin 时暂停并提示外部终端处理。
- 默认轻量检查由语言/文件类型映射到已安装命令；完整测试和 build 只有用户明确要求时加入计划。
- 只有 GET/HEAD、公开搜索等只读网络动作可自动执行；上传、POST、Git push 和其他外部状态变更必须确认。
- 安装工具若涉及授权根之外的系统目录或缓存，把这些路径列入一次性安装批准范围，不把它们静默保存为全局文件夹授权。

## 10. 搜索与可见浏览器

### 10.1 Provider 链调整

在现有 `SearchProviderChain` 中增加两个 route，而不是另建第二套搜索系统：

1. 保持健康的配置 Provider/模型原生搜索为 primary。
2. 新增 `KeylessHtmlSearchProvider`：Dio 请求公开 HTML 搜索页，`package:html` 解析标题、跳转 URL 和摘要；设置严格超时、响应大小、重定向和 URL 安全边界。
3. 新增 `VisibleBrowserSearchProvider`：前两级失败时打开 `desktop_webview_window`，用户可见导航；加载完成后以 JS 读取 title、URL 和正文。
4. 全部失败复用现有失败类型、重试、审计和任务面板。

DuckDuckGo Instant Answer 只保留为稳定百科补充，不再承担通用无 Key 搜索。

### 10.2 浏览器安全

- 只允许 `http/https` 公网 URL，继续使用现有 DNS/URL 校验阻止本机与私网 SSRF。
- 页面文本标记为不可信资料，过滤脚本、样式、隐藏元素并限制长度。
- 遇到登录、验证码或付费墙进入等待用户态；不读取密码框、cookie 或账号凭据。
- 默认只把访问记录写审计；最终回答仅在用户要求时附链接。

## 11. 执行面板设计

### 11.1 UI 组成

- App 根层 `WorkTaskOverlayHost`：展示全局任务胶囊和非模态 bottom sheet。
- 面板头部：任务标题、会话、当前角色、状态、耗时、步骤 `n/100`。
- 事件列表：规划、角色切换、读取、写入、命令输出、网页、验证、错误。
- 等待卡片：文件夹授权、写入范围、澄清问题、模型选择、软上限继续。
- 终态卡片：结论、文件差异、验证证据、风险、撤销。
- 操作：最小化、隐藏、停止、重试、继续、打开会话、撤销。

### 11.2 流式语义

“流式”包含两类：

- 事件流：每个 Agent 动作开始/进度/结束立即更新。
- 文本流：最终结论可复用 SSE token 流逐字展示。

不得显示模型隐藏推理。工具参数只显示对用户安全且必要的范围；敏感值统一脱敏。

## 12. 分阶段实施

### Stage 01：全局任务内核与面板骨架

范围：

- App 级 `WorkTaskCoordinator`、每会话队列、全局并发 2。
- 新 `AgentTask` 状态与检查点、JSONL 事件。
- 面板展开/最小化/隐藏/停止/恢复骨架。
- 页面仅提交/订阅；离开页面任务继续。
- 100 步/60 分钟软上限。

验收：同会话 FIFO、不丢追加输入；两个会话并行；第三个排队；切页继续；关 App 后重开只手动恢复。

### Stage 02：全局文件夹、文件工具、审批与撤销

范围：

- 多文件夹授权与设置管理。
- 直接 Dart IO 的 list/read/search/write/patch/rename/delete。
- 敏感文件二次确认、任务级写范围、补充确认。
- 快照、差异、2 GB/30 天清理、一键撤销、路径冲突锁。
- 删除生产 bridge 调用链。

验收：重启后授权仍可用；越界/符号链接被拦截；普通写设置生效但删除仍确认；新建/修改/删除均可撤销；磁盘不足路径可验证。

### Stage 03：连续 Agent、终端与多角色接力

范围：

- 精简 AgentLoop 与单一 JSON 协议。
- 格式修复、空流非流式回退、分类错误与重试。
- 持久上下文、原文件修订、澄清后续跑。
- 角色路由、产品/开发/测试顺序接力。
- 结构化命令、流式输出、取消、轻量检查、缺失工具安装提示。

验收：追问修改同一路径；群角色自动分工且不并发执行；命令流可见、停止可用；模型失败不自动切换；默认不跑完整测试/build。

### Stage 04：文档、视觉、无 Key 搜索与可见浏览器

范围：

- 授权目录中的文本、PDF、DOCX、XLSX 按需分析。
- 图片送视觉角色，不支持时让用户选角色。
- 搜索优先级调整、HTML Provider、可见浏览器、访问审计。
- WebView2 检测与用户确认安装路径。

验收：无搜索 Key 也能得到真实公开网页结果；后台失败时自动打开可见浏览器；登录/验证码暂停；访问 URL 记日志但默认答复不附链接。

### Stage 05：硬化、清理与 macOS 完整验收

范围：

- 30 天保留、2 GB 配额、孤儿任务/快照回收。
- 并发文件冲突、外部修改、崩溃恢复和错误注入。
- 普通聊天全量回归。
- macOS debug/release 构建与真实 UI walkthrough。
- Windows 自动化与构建级检查；真实 UI 等 Windows 环境。

每个 Stage 单独提交文档状态与测试证据；上一阶段未通过不得宣称后续整体完成。

## 13. 测试矩阵

### 13.1 单元/集成测试

| 领域 | 必测项 |
|---|---|
| 路径 | macOS/Windows 规范化、大小写、`..`、绝对路径、符号链接越界、失效授权 |
| 权限 | 读/联网自动，首次写批量确认，新增范围补充确认，删除始终确认，设置开关 |
| 敏感文件 | `.env`、PEM、证书、凭据文件拦截与任务级确认 |
| 调度 | 同会话 FIFO、全局 2、第三任务排队、停止/失败释放槽位、目录锁 |
| 持久化 | 崩溃检查点、重启手动恢复、30 天清理、损坏 JSONL/检查点降级 |
| Agent 协议 | 合法 JSON、code fence、非法格式修复、空流回退、两路为空失败 |
| 上下文 | 群共享、私聊隔离、修订原路径、压缩后保留批准范围与副作用 |
| 角色 | @ 指定、无 @ 自动选择、多阶段接力、角色 API 不可用、未知角色 ID |
| 文件 | 新建/修改/补丁/重命名/删除、外部修改冲突、读回验证 |
| 快照 | 新文件撤销、覆盖恢复、删除恢复、配额、磁盘不足、二次修改冲突 |
| 命令 | 参数化执行、stdout/stderr 流、退出码、超时/停止、交互检测、影响范围 |
| 文档/视觉 | PDF/DOCX/XLSX、过大/加密/损坏文件、视觉支持/不支持选择 |
| 搜索 | API → HTML → browser 顺序、HTML 变化、无结果、超时、SSRF、验证码 |
| 普通聊天 | 工作模式关闭时不创建任务、不触发工具，自动聊天/主动私聊不回归 |

### 13.2 Widget 测试

- 执行面板非模态，最小化/隐藏后任务状态不变。
- 全局胶囊跨路由可见并可重新打开。
- 文件夹授权、写入范围、补充范围、删除、无撤销确认卡片。
- 澄清、模型选择、软上限、停止、恢复、撤销按钮。
- 设置页授权列表、确认开关、空间占用和清理。
- 最终差异、验证结果、风险和错误详情。

### 13.3 macOS 真实 App walkthrough（必须逐项留证）

实现完成后使用真实 App，可用 computer-use 操作并记录每项结果：

1. 添加两个临时目录，重启 App 后仍可读取。
2. 请求未授权目录，任务暂停；授权后原步骤继续。
3. 读取代码、PDF、DOCX、XLSX；视觉角色分析图片。
4. 首次写入汇总确认；新增路径触发补充确认。
5. 关闭普通写确认后创建/修改直行，但删除仍确认。
6. 新建、覆盖、重命名、删除后分别一键撤销并核对字节/hash。
7. “修改刚才文件”覆盖原路径，不产生 `_2` 副本。
8. 同一会话连续发两条请求，第二条排队并自动继承上下文。
9. 群聊请求“写需求、开发、测试”，观察角色按顺序接力且一次只有一人执行。
10. 运行非交互命令，观察 stdout/stderr；停止后子进程结束且修改可撤销。
11. 默认代码任务只做轻量检查；明确要求后才运行测试或构建。
12. 模拟流式空响应、非法 JSON、网络断开、命令失败，核对重试和具体原因。
13. 模型连续失败后只提示用户选模型，不自动切换。
14. 切换页面/会话后任务继续；隐藏面板后从胶囊恢复。
15. 任务中关闭 App，重开后手动继续，不自动发起 API 请求。
16. 同时启动两个无冲突任务；第三个排队；同路径任务被锁等待。
17. 无搜索 Key 搜索时效问题，验证后台 HTML；让后台失败后验证可见浏览器。
18. 打开登录页/验证码页，验证暂停且不读取凭据。
19. 调整 2 GB 配额的测试替代小阈值，验证最旧快照清理和无快照阻断。
20. 关闭工作模式，验证普通群聊、自动聊天、私聊、附件和搜索行为未改变。

Windows 当前没有真实环境：必须完成平台条件分支单测、路径/命令策略测试和可构建性检查；真实 UI 结果明确标记为“待 Windows 环境验证”。

## 14. 完成定义

只有同时满足以下条件，V1 才可标记完成：

- 两份设计文档获用户批准，重大实现偏差已回写。
- Stage 01–05 的代码审查清单逐项完成。
- `flutter analyze`、全量 `flutter test`、macOS 构建全部通过。
- 上述 20 项 macOS walkthrough 全部执行并留有结果；失败项修复后重新验证。
- 无 P0/P1，所有 P2 都有明确结论；Windows 真实 UI 是唯一已获用户同意的暂缓项。
- 最终报告集中列出：改动、测试命令、通过项、失败项、未检查项及原因。

## 15. 后续优化项

- 内置交互式终端，安全处理密码、登录和菜单输入。
- Provider 原生 function/tool calling，逐步替代 JSON 文本协议。
- Mac App Store security-scoped bookmark。
- Windows OS 级沙箱与完整真实 UI 验收。
- 大型工作区的可选增量语义索引。
