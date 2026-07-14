# 工作模式（Work Mode）实现说明

## 产品行为

群聊和私聊都提供按会话持久化的“工作模式”开关。

- 关闭：仅走普通流式对话，不进入 `AgentRuntime`，不调用 Skill/工具，不从模型文本中恢复或生成文件。
- 开启：用户每条非空输入都是工作指令或补充。不使用关键词或语义分类器判断是否进入工具链路。
- 群聊执行者：优先使用被 `@` 的第一个活跃且已开启 Agentic 的角色，否则使用第一个符合条件的角色。
- 自动发言始终走普通聊天，不会启动工作流；工作模式开启期间自动发言完全暂停。

## 执行闭环

1. `WorkModePolicy` 负责显式路由、执行者选择、技能合并和权限分类。
2. `CharacterSkillResolver.resolveFor` 根据角色与当前指令解析默认技能，并合并该角色全部已安装 Skill。
3. 规划上下文显式注入 `role/systemPrompt/memorySummary/skillIds`。
4. `AgentRuntime.onProgress` 将初始规划、待批准操作和已完成工具操作持久化到固定进度气泡。
5. 通过 `workspace.patch` 成功生成的文件会复制到 AI 媒体目录，并以 `MediaAttachment` 贴回当前会话。
6. 快速连续输入会按会话排队，不会并发启动第二个运行时。

## 安全边界

工作模式的每个会话拥有独立工作目录。不继承旧自治开关，不继承旧的整个项目目录授权，不永久放大 `AICharacter.toolPermissions`。持久化工作区路径若与当前会话目录不一致会被重建，运行时不会回退到共享处理根目录；服务端同时拒绝 `..`、绝对命令路径和通过符号链接逃逸工作区。

以下操作必须在执行前暂停，并在弹窗/进度气泡中显示精确范围：

- `workspace.list` / `workspace.read`：显示目录或文件路径。
- `workspace.patch`：显示待写入路径，不在批准弹窗泄露文件正文。
- `command.run`：显示完整命令，并且服务端仅接受固定白名单命令。
- `browser.context`：明确说明将读取当前页面上下文。

`skill.create` / `skill.download` 仅写入应用内技能元数据，可直接运行；安装 Skill 不会永久扩大角色工具权限。

用户拒绝敏感操作时，该操作被标记为已跳过，运行时重新规划其余安全步骤。用户中途关闭工作模式时，会立即取消当前 Agent HTTP 请求，并在工具边界安全收尾；已完成的操作不伪造回滚。

## 持久化

- 开关：Hive `app_settings` 中的 `work_mode_enabled:<conversationId>`。
- 会话工作区：`work_mode_workspaces` box。
- 任务检查点：`AgentTask.workModeTask == true` 才允许在工作模式中恢复；历史关键词触发任务不会被自动恢复。

## 验证

```bash
dart run build_runner build --delete-conflicting-outputs
flutter analyze
flutter test
```

工作模式的定向测试位于 `test/work_mode/`，包括开关持久化、显式路由、执行者选择、Skill 合并、敏感操作批准、拒绝后继续、关闭中止、会话目录隔离、异常持久化路径修复和历史任务恢复隔离。桥接服务测试还覆盖目录穿越、符号链接逃逸、命令注入和跨平台绝对路径。

---

## 代码审查修复记录

2026-07-14 已完成严重项和中危项收敛：

- 当前执行轮结束（含 `completed/failed/cancelled/partiallyCompleted`）会同时删除 Hive 消息、消息索引和页面内的临时进度气泡；`partiallyCompleted` 只保留任务检查点供恢复。
- 工作模式与 auto-chat 强互斥；开启时停止计时器、取消正在生成的自动发言并丢弃其临时内容，工作期间不更新自动聊天记忆。
- 首次、恢复和多步审批统一经过 `WorkModeTaskLifecycle`；弹窗返回 `null` 会取消任务并清除检查点。
- 审批等待期间收到新指令时，先将旧任务持久化为 `cancelled` 并删除进度消息，再处理新指令。
- `WorkModeSession` 集中持有开关、停止信号、取消令牌和待审批所有权，避免旧异步分支清理新任务状态。
- 关闭工作模式会通过 Dio `CancelToken` 立即取消当前 Agent 请求；运行时在规划完成、工具完成和结果整理后均再次检查停止信号。
- 本地桥接同工作区重复 `restart` 已恢复幂等；切换工作区仍会安全重启。
- 工具步骤预算提升到 12 并附有边界注释；120 秒超时统一引用 `AgentRuntime.completionTimeout`。
- 页面销毁时取消 `_streamSub`、完成等待器并取消 Agent 请求，不再让后台订阅继续落库。

### 复核验证（2026-07-14）

- `flutter analyze`：No issues found（2.8s）。
- `flutter test test/work_mode/`：24 项全部通过，直接覆盖上述严重项（terminal tasks remove progress / dismissed approval cancels / new input cancels old approval / closing work mode stops before planning）。
- 代码读取核实：4 个严重 bug 均已在 `WorkModeTaskLifecycle` / `WorkModeSession` 重构中修复，无需额外改动；中危 `restart` 抖动经核实为旧版本误报（当前 `restart` 即 `start` 薄封装、含幂等快路径），`_streamSub` dispose 已修复。
- 结论：严重项全部收敛，代码绿灯、测试全绿，本轮未做代码改动。

---

## 新代码基础规范（Code Review 要求）

> 工作模式相关的新增/修改代码，除功能正确外，必须过以下基础规范（对齐 Code Review 关注点与项目既有约定）。

### 封装与单一职责
- 每个类/方法只做一件事。编排逻辑（路由、执行者选择、审批、进度、落盘）应落在 `lib/features/work_mode/` 对应服务类，而非塞进 `ChatRoomPage` 的巨型 State。
- 跨会话状态（运行标志、待批请求、排队消息）优先抽到 `WorkModeSession` 之类的独立对象，避免 `_ChatRoomPageState` 内多个散落字段互相耦合。
- 敏感逻辑（权限判定、路径安全、命令白名单）封装在服务/Policy 内，UI 层只调用、不重写规则。

### 模块解耦
- 保持已建立的层次：`WorkModePolicy`（纯策略，无副作用）→ `work_mode_*_service`（副作用/IO）→ `ChatRoomPage`（UI 接线）。新增能力时优先扩展 service，不要为了省事直接在页面里写逻辑。
- 工作模式与"自动发言（auto-chat）""普通流式"三套路径通过显式开关/标志隔离，互不直接调用对方内部方法。
- 桥接服务（`local_agent_bridge_server`）的路径/命令校验逻辑集中实现，业务侧复用，避免重复校验。

### 中文注释（详细清晰）
- 公共类、关键方法、非常规分支、并发/时序边界必须有中文注释说明"为什么"（不是复述"做了什么"）。
- 例如 `WorkModeSession.requestStop` 与 Dio 取消令牌的配合、auto-chat 与工作模式的互斥关系、进度气泡的生命周期，都应注释清楚，降低后续误改风险。

### 体积控制与方法拆分
- 单方法超过 ~80 行或嵌套超过 3 层应拆分（如 `_tryAutoChatRound`、`_generateAgenticReply` 内的编排可拆为"选执行者 / 构建规划上下文 / 启动运行时 / 收尾"等小方法）。
- 避免"上帝 Widget"：页面只负责渲染与事件转发，重逻辑下沉到 service/controller。

### 常量、命名与可测性
- 魔法值（轮次上限、步骤上限、超时、各类 key 前缀如 `agent-progress:`、`work_mode_enabled:`）集中在常量区并加注释。
- 命名自解释；布尔态用 `is/has/enabled` 前缀，避免否定命名。
- 新增逻辑默认附带单测（见上方"验证"）：状态类用纯函数/Policy 便于单测，副作用类用 mock 验证调用而非真实 IO。

### 回归安全
- 改动 `WorkModePolicy`、审批流、进度消息、auto-chat 互斥任意一点时，必须跑 `flutter analyze` + `flutter test`（含 `test/work_mode/`），确保普通聊天零回归、工作模式既有测试不红。
