# S4 实施记录：讨论补充合并、执行 FIFO 与新任务边界

日期：2026-09-12
范围：只实施 `03-implementation-plan.md` 的 S4；未进入 S5–S8；没有自动提交。

## 实际调用链

群工作模式输入从 `ChatRoomPage._sendMessage` 进入
`_dispatchUserRequest`，再由 `_runWorkModeTask` 取得
`WorkTaskCoordinator.taskForConversation` 返回的会话归属。输入路由先通过
`followUpDecisionForTask` 和 `shouldRouteNewTaskForFollowUp` 取得协调器唯一的
follow-up 分类；同一任务的输入调用 `enqueueFollowUp`，明确新建的群任务回到
`WorkRoleRouter.route`，不会被旧任务的执行人截留。

协调器内部的路径是：

```text
enqueueFollowUp
  ├─ 讨论未完成/讨论刚完成但尚未执行
  │    └─ _renewDiscussionForRequest → updateDiscussionState 门禁
  ├─ 执行中或等待资源/审批
  │    └─ queuedUserRequests + queuedAttachmentMessageIds 持久 FIFO
  └─ 已完成且明确“新建/生成新产物”的群任务
       └─ _promoteNewArtifactFollowUp → 新 task → _maybeStartDiscussion

讨论完成
  └─ _updateDiscussionState → ready → _enqueueTask → _schedule →
     _start → _runWithLease → DefaultWorkTaskRunner/WorkAgentLoop

恢复、停止、数据清除和资源释放
  └─ 仍由同一个 WorkTaskCoordinator 串行持有；讨论 cancellation 与执行
     cancellation 一起等待，迟到回调不能复活任务。
```

本阶段继续保留四条红线：恢复中的任务占用会话控制器；不取消旧执行来丢弃新输入；
所有新输入先持久化；中文或英文“修改同一/相同/当前/上次文件”必须使用原产物的
明确路径，不能用重名自动改名躲避修订。

## 修复前后的触发例子

| 触发 | 修复前的偏差 | S4 后的行为 |
| --- | --- | --- |
| 讨论模型尚未返回时补充“请考虑移动端验收”，并附文件 | 新输入可能只进页面内存，旧模型返回 100% 后直接开跑 | 补充写入同一 task 的新 `requestRevision` 和附件 ID；旧 revision 的 100%/finish 被拒绝，下一轮只使用最新上下文 |
| 执行中连续发送中文、英文“修改 `/workspace/report.docx`”，各带附件 | 队列与附件可能错位，修订目标可能按重名另建 | 请求和附件按同一 FIFO 顺序落库；每条修订都保留 `/workspace/report.docx`，前一条释放后才启动后一条 |
| 已完成旧任务后说“新建一个 html 页面” | 最新完成记录可能继续沿用旧执行人、计划和产物 | 新建独立 task，清空旧执行人、计划、权限和路径，重新进行群讨论和职业资格选人 |
| 待审批时补充新的路径或产物范围 | 旧审批可能被沿用到更大的范围 | 清除旧审批决定、范围和待执行请求，保留输入并按新范围重新讨论/申请 |
| 任务面板或页面恢复时存在多个历史 task | 仅按最新更新时间选择，完成记录可能遮住仍在途的任务 | coordinator 按运行中讨论/执行、非终态检查点、终态回退顺序选择会话归属 |

“重新生成”属于同一产物的继续处理；只有明确“新建/创建/生成一个新的产物”等
新任务语义才允许新建 lineage。无法唯一判断修订目标时继续使用现有澄清问题，
问题回答唤醒对应 FIFO 头部，不建立无关独立任务。

## 实现位置

- `lib/features/work_mode/work_task_coordinator.dart`：集中会话归属、follow-up
  分类、版本递增、讨论续订、审批范围失效、FIFO 晋级、新任务分流、恢复/取消
  与资源释放；widget 不再复制归属排序和边界规则。
- `lib/features/chat_group/chat_room_agentic_input_support.dart`：调用上述唯一
  入口；收到补充时写入群消息回执，明确“已纳入讨论”或“执行完成后按 FIFO”；
  完成后的新产物回到正常路由，以便显式 `@角色` 和资格/权限检查重新执行。
- `lib/features/work_mode/work_follow_up_policy.dart`：区分新建与同一产物修订，
  保证“重新生成”不会误分成新文件。
- `lib/features/work_mode/work_role_router.dart`：提供复用的交付物合同和职业资格
  解析；新 task 不直接选择旧角色。
- `lib/features/work_mode/work_discussion_runner.dart`：每个新请求版本重新计算
  合格候选，并把持久附件的文件名/MIME 作为公开讨论上下文；不读取文件正文，
  讨论阶段不调用工具。
- `lib/features/work_mode/default_work_task_runner.dart`：执行阶段读取讨论补充的
  附件 ID 队列，并在真正执行前再次校验选定角色、群成员、职业资格和凭据。

没有增加 Hive 类型或第二任务引擎；讨论状态、FIFO 和附件仍复用现有
`AgentTask.executionStateJson`、附件消息 ID 队列、事件流和任务面板检查点。

## 验证矩阵

新增 `test/work_mode/work_s4_boundaries_test.dart`，使用 `Completer` 和可控
`Future`，不依赖真实 `sleep`：

- A10：讨论模型在途时连续补充，版本递增、附件上下文保留、旧完成回调失效；
- A12：版本门禁拒绝过期/跳跃的讨论结论，续订后的 ready 才能排队；
- A13：执行中两条中英文同文件修订按 FIFO 启动，附件和真实目标路径一一对应；终态检查点仍在途时也只入队、不提前晋级；
- A20：完成后“新建 html”建立新讨论 task，不继承旧执行人/计划/产物；
- 审批范围改变、历史完成记录遮挡在途任务、讨论取消/失败后的持久状态也有覆盖。

现有讨论状态/runner、coordinator、聊天 UI、角色路由、附件、澄清、恢复和取消
测试继续运行，确保 S1–S3 调用方没有被 S4 分流破坏。

已执行命令及结果：

```text
flutter analyze --no-pub                                      通过
flutter test --no-pub --reporter compact                       通过（2185 项）
git diff --check                                               通过
```

专项运行的 S4 相关测试集合也通过（讨论状态、讨论 runner、S4 边界、coordinator、
聊天 UI、任务面板、角色路由、follow-up policy 和 mention 解析）。

## Review 结论与剩余风险

已按需求符合性、正确性和边界、失败路径、测试有效性、可读性、架构、安全、性能、
新老兼容及仓库代码质量清单复核。S4 专项、完整测试、静态分析和 diff 检查均通过。

剩余风险：

1. 真实第三方模型的回复质量、凭据和职业描述只能通过集成环境验证，S4 仅验证
   结构化协议和可控竞态；真实模型验收属于 S8。
2. coordinator 为新群 task 建立的讨论记录故意不预填权限/角色；ready 后由当前
   执行角色的实际权限再次求交，这是安全边界，需在后续 UI 验收中确认提示清晰。
3. 没有讨论标记的旧“等待审批”任务在范围改变后会安全暂停并保留 FIFO，需用户
   走现有恢复/重新讨论入口；不会扩大旧授权。
4. 群消息回执由聊天页写入；直接调用 coordinator 的后台入口只有任务/事件状态，
   不会伪造聊天气泡。S5 再统一补齐可操作的 `@` 提醒入口。

S4 停止于此。下一阶段入口是 S5：把已有 blocker、澄清、审批、安装、补角色和
取消/恢复状态映射为可操作的 `@` 提醒；本阶段不实施 S5–S8。
