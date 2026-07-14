# 阶段 03 技术方案：聊天核心架构与性能

状态：提议  
对应需求：`03-chat-architecture-performance.requirements.md`

## 1. 设计原则

- 先建立行为测试，再迁移控制权；不做“重写式重构”。
- 以垂直切片拆出发送、流式、自动聊天和工作模式，每一步保持 APP 可运行。
- UI 只订阅可展示状态并发送 intent，不直接编排 Timer/Stream/DB。
- 索引是可重建缓存，消息 Box 仍是事实来源。

## 2. 目标架构

### 2.1 ConversationController

建议使用 Riverpod Notifier/AsyncNotifier，维护：

- `ConversationViewState`
- 当前 `ConversationRun`（type、id、cancel token、startedAt）
- 待处理用户消息队列
- 当前分页窗口和游标
- streaming draft
- error/retry 状态

公开 intent：`load`、`send`、`stop`、`loadOlder`、`startAutoChat`、`setWorkMode`、`approveTool`、`retry`。

### 2.2 协调器边界

- `NormalChatCoordinator`：角色选择、顺序回复、记忆触发。
- `AutoChatScheduler`：随机间隔、burst/cooldown、前后台生命周期。
- `WorkModeCoordinator`：任务、审批、桥接和恢复。
- `StreamingReplySession`：SSE、取消、节流、完成持久化。
- `ConversationRepository`：分页查询、追加、更新、摘要索引。

### 2.3 AgentRuntime 拆分

- `AgentProtocolParser`
- `AgentStepPlanner`（若启用）
- `AgentToolExecutor`
- `AgentTaskStore`
- `AgentResultPresenter`

保留一个薄 `AgentRuntime` facade，避免一次性修改所有调用方。

### 2.4 消息分页与摘要

建立可重建的 `ConversationSummary`：

- conversationId/type
- lastMessageId/preview/timestamp
- unreadCount/mentionCount
- lastReadAt
- updatedAt

消息索引按会话保存有序 ID 或时间游标，提供 `loadLatest(limit)`、`loadBefore(cursor, limit)`、`loadAround(messageId)`。写消息和删除消息时增量维护；启动检测不一致时后台重建。

### 2.5 UI 性能

- streaming draft 只更新当前气泡对应的细粒度状态。
- 节流间隔保留，但避免父 Scaffold 全量 rebuild。
- 图片读取/压缩/Base64 放入异步服务；大计算可使用 isolate。
- 头像、附件 data URI 解码和发送者映射使用有界缓存。

## 3. 实施任务

### Task 03-1：建立现有行为特征测试和性能 fixture

**验收：** 关键状态转换和大数据基线可重复测量。  
**验证：** 新增 coordinator/state 测试和 benchmark harness。  
**依赖：** 阶段 02。  
**预计范围：** M。

### Task 03-2：抽出 StreamingReplySession

**验收：** 开始、token、停止、失败、完成落库行为不变。  
**验证：** fake SSE 流测试；页面关闭测试。  
**依赖：** Task 03-1。  
**预计范围：** M。

### Task 03-3：抽出 AutoChatScheduler

**验收：** work mode/输入/生成中互斥，Timer 生命周期可测试。  
**验证：** fake clock/random 测试。  
**依赖：** Task 03-1，可与 03-2 顺序实施以减少冲突。  
**预计范围：** M。

### Task 03-4：引入 ConversationController

**验收：** 页面只渲染状态和发送 intent，队列/状态转换移出 Widget。  
**验证：** provider/controller 测试和现有 Widget 测试。  
**依赖：** Task 03-2、03-3。  
**预计范围：** 拆为多个 M 提交。

### Task 03-5：消息分页和摘要索引

**验收：** 首屏窗口加载、向上分页、跳转、追加和索引重建通过。  
**验证：** 1 万/5 万消息 fixture，数据库集成测试。  
**依赖：** Task 03-1；接 UI 时依赖 03-4。  
**预计范围：** 多个 M 切片。

### Task 03-6：拆分 AgentRuntime facade

**验收：** 协议解析、工具执行、持久化可独立测试，外部行为不变。  
**验证：** 现有 agentic/work_mode 全套测试。  
**依赖：** 03-4 后实施更稳妥。  
**预计范围：** 多个 M 切片。

### Task 03-7：附件异步处理和限制

**验收：** UI 无同步大文件读取，原生/Web 统一给出限制反馈。  
**验证：** 大图片 fake 测试、帧性能人工检查。  
**依赖：** 可在 03-4 后独立实施。  
**预计范围：** M。

## 4. 检查点

- Checkpoint A：03-2/03-3 后，现有聊天全绿且状态组件可独立测试。
- Checkpoint B：03-4 后，ChatRoomPage 明显变薄且普通/自动/work mode 互斥回归通过。
- Checkpoint C：03-5 后，大数据性能目标通过。
- Checkpoint D：03-6/03-7 后，全量回归和手工体验验收。

## 5. 风险与缓解

| 风险 | 影响 | 缓解 |
|---|---|---|
| 重构期间出现双重状态源 | 高 | 每个切片完成后删除旧控制权；禁止长期双写 |
| Hive 索引与消息事实不一致 | 高 | 索引可重建；启动/写入做轻量一致性检查 |
| 分页破坏引用跳转和滚动位置 | 中 | 提供 `loadAround`；记录插入前后 scroll extent 差值 |
| 过度抽象降低开发速度 | 中 | facade 保持简单，只抽有独立生命周期和测试价值的组件 |

## 6. 开放问题

- Riverpod 继续使用 StateNotifier 还是在本阶段迁移到 Notifier/AsyncNotifier？
- Hive 普通 Box 能否满足分页索引，还是消息应转为 LazyBox/分会话 Box？
- 是否在此阶段引入性能自动门禁，还是先记录基线和手工对比？
