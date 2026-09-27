# S4 校验复审记录

日期：2026-09-13
范围：`03-implementation-plan.md` 的 S4——讨论中的补充合并、同一任务的执行 FIFO、澄清回答、附件顺序、同一产物修订、完成后的新任务分流，以及重新讨论/重新选人的门禁。S5 的可操作 `@` 提醒、S6 的真实 DOCX 交付、S7 的恢复闭环和 S8 的真实 UI/产物验收不计入本次放行。

## 结论

本次完成了一轮“发现问题 → 修复 → 再次复审”。首轮发现的 3 个 S4 行为阻塞和 2 个边界语义问题（共 4 项）已修复；第二轮沿完整调用链复查，未再发现本范围内的 P1/P2 问题。专项测试、静态分析、格式检查、diff 检查和全量测试均通过，**可以进入 S5**。

## 复审方法

按 Ponytail full 读取并检查了以下调用链，而不是只检查单个方法：

```text
群聊输入
  → ChatRoomPage._runWorkModeTask
  → WorkTaskCoordinator.taskForConversation / follow-up policy
  → 新任务路由或 enqueueFollowUp
  → 讨论版本、FIFO、附件与新旧 task 分流
  → WorkDiscussionRunner 多成员讨论和执行人汇总
  → WorkDiscussionState ready 门禁
  → DefaultWorkTaskRunner / WorkAgentLoop
```

同时检查了取消、迟到回调、跨群状态、私聊隔离、模型澄清、审批范围失效、任务面板恢复、旧任务兼容、凭据和工具门禁。检查维度覆盖需求符合性、正确性与边界、失败路径、测试有效性、可读性、架构、安全、性能、新老兼容，以及仓库代码质量清单中的注释、命名、常量、函数/文件规模、封装和模块化。

## 首轮发现与修复

| 级别 | 文件与证据 | 影响 | 修复与回归 |
| --- | --- | --- | --- |
| P1 | `lib/features/work_mode/work_discussion_runner.dart:552-565`、`lib/features/work_mode/work_discussion_state.dart:805-836` | 群内推举出的执行人会被误记成用户显式指定的人；后续修订可能沿用旧 owner，或因显式执行人校验不一致而无法进入执行。 | 群选结果只写 `executorId/coordinatorId`，合同的 `explicitExecutorId` 保持为空；`ready` 合同允许“非空执行人 + 显式执行人为空”这一持久群选状态。`work_s4_boundaries_test.dart:428-478` 覆盖修订后重新选人。 |
| P1 | `lib/features/work_mode/work_task_coordinator.dart:760-797` | 回答模型澄清时直接覆盖已有 `queuedUserRequests`，后续请求及其附件会丢失或错位。 | 澄清回答插入 FIFO 头部，后续请求和 `queuedAttachmentMessageIds` 原序保留。`work_s4_boundaries_test.dart:520-568` 验证答案附件与后续附件分别对应。 |
| P1 | `lib/features/work_mode/work_discussion_runner.dart:1003-1060` | 协调器直接晋级“完成后新建产物”时没有重新解析显式 `@`，模型推荐的另一位同职业角色可能覆盖用户最终指定人。 | 新 task 的空执行人/候选状态先用完整群成员和 Skill 重新走 `WorkRoleRouter`；显式 `@` 形成合同并保持权威。`work_discussion_runner_test.dart:275-392` 验证模型故意推荐前端甲时仍由 `@前端乙` 执行。 |
| P2 | `lib/features/work_mode/work_follow_up_policy.dart:273-286,312-316` | 中文文件名的绝对路径无法作为修订目标；“重新生成”可能被误判为新建文件，破坏同一产物语义。 | 路径边界支持中文字符；新建意图的“生成”排除“重新生成”。`work_follow_up_policy_test.dart:58-60,108-110` 覆盖两种边界。 |

## 第二轮复审结果

### 补充、修订和新任务分流

- 讨论未完成或讨论刚完成时，补充要求提升 `requestRevision`，取消旧讨论并持久化最新合同/上下文；旧版本的完成回调不能启动执行。
- 执行中的输入只进入持久 FIFO，不取消当前执行；每条输入的附件 ID 与队列位置一一对应。影响方案或产物的修订会在下一次执行前重新经过讨论门禁。
- 模型澄清回答只合并到当前 FIFO 头部；不会清空后续请求，也不会把一个回答误当成独立新任务。
- 已完成任务收到明确新建产物请求时建立新的 task lineage，清空旧执行人、计划、权限和路径，再从完整群成员重新路由；“继续/修改同一文件”保留原路径和上下文。

### 执行人、合同和门禁

- 没有显式执行人时，协调人只汇总意见；最终执行人必须来自当前群、启用、具备 Agentic 能力、满足产物职业/Skill 资格并拥有可解析凭据。
- 显式 `@角色` 经过路由、讨论状态和执行器三次检查；角色不可用时保留原身份并 `@` 用户，不自动换备用角色。
- 成员建议只能作为公开意见；合同字段和最终执行人由本地规则保护。只有 `ready`、合同版本匹配、理解进度达到门槛、问题/阻塞清空且证据充分时，才进入现有执行器。
- 讨论 runner 不调用工具、不写文件、不安装转换程序；审批、目录授权和安装仍由后续既有门禁处理，不能靠追问绕过。

### 并发、恢复与安全

- 状态更新检查 task、群组、请求版本、状态版本和终态；取消令牌、串行协调器和资源锁共同阻止迟到回调复活旧任务。
- 讨论状态、FIFO、附件来源和合同写入 `AgentTask.executionStateJson`，采用白名单、边界和版本校验；不保存私有推理或 API Key。
- 群与私聊仍隔离；没有讨论标记的旧记录不会被伪装成“已讨论”。执行器在真正运行前再次验证群成员、角色资格、模型配置和凭据。
- 任务面板和聊天入口只观察协调器状态；不会因页面重建、旧 task 排序或重复提交改变任务归属。

以上检查未发现新的 P1/P2；保留的限制均属于 S5–S8 的阶段边界，而不是 S4 的阻塞。

## 验证结果

| 检查 | 结果 |
| --- | --- |
| `flutter test --no-pub --reporter compact test/work_mode/work_discussion_runner_test.dart test/work_mode/work_s4_boundaries_test.dart test/work_mode/work_discussion_state_test.dart test/work_mode/work_follow_up_policy_test.dart` | 54 项通过 |
| `flutter analyze --no-pub` | 通过，`No issues found!` |
| `dart format --set-exit-if-changed`（S4 生产代码与回归测试） | 通过，无格式变更 |
| `git diff --check` | 通过 |
| `flutter test --no-pub --reporter compact` | 2189 项全部通过，输出 `All tests passed!` |

本阶段没有修改 Hive 字段或新增 Riverpod provider，因此不需要运行 `build_runner`。未提交或推送，工作区已有修改全部保留。

## 未检查项与阶段边界

- 没有调用真实第三方模型、真实凭据或真实大群；模型长期遵守结构化协议、讨论语义收敛和实际延迟留到 S8。
- 没有在本阶段实现 blocker 到可点击 `@` 操作、补角色、审批、安装和回答入口；这些是 S5 的目标。
- 没有在本阶段验证 Markdown→真实 DOCX、桌面路径授权、产物结构或附件发送；这些是 S6/S8 的目标。
- 没有在本阶段做发布构建、跨进程重启和旧备份迁移验收；S7/S8 负责这些场景。

## 放行决定

S4 范围内没有遗留阻塞问题，**可以进入 S5**。S5 的入口目标是把现有讨论/澄清/执行/审批/安装/恢复阻塞映射成同一 taskId、请求版本和阻塞标识绑定的可操作 `@` 提醒，并保持双入口幂等。
