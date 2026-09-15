# S1 实施记录：请求语义、最终执行人与产物合同

日期：2026-09-11
范围：仅执行 `03-implementation-plan.md` 的 S1；没有进入 S2，没有提交或推送。
基线：开始时除 `docs/group_work_discussion/` 外工作区没有未跟踪代码改动；保留了该目录原有文档。

## 已完成

1. 在 `WorkRoleRouter` 中把 `@all` 作为讨论受众处理。只有“最后由/最终由/输出/交付”等明确最终动作后的角色才成为执行人；普通单一 `@角色` 和多阶段明确 `@` 仍保持显式路由。`@角色评估/咨询/补充建议` 会作为咨询对象返回，不会被误当最终执行人。
2. 未指定执行人时不再使用第一个可用角色，也不再把短模型推荐直接当作最终推举。模型只可在本地资格核验后调整候选顺序；路由返回 `candidateSelection`、合格候选 ID 和可展示理由；没有候选时明确要求 @用户补充匹配角色。
3. 增加 `frontend` 阶段。纯 HTML/网页请求只接受角色配置中的前端职责、前端关键词或角色绑定 Skill；角色名字、人格标签和全局 Skill 不再单独提供职业资格。角色绑定的非全局 Skill 只能作为辅助证据。
4. 增加最小 `WorkDeliverableContract`：产物类型、格式、位置、内容范围、显式执行人、修订目标和请求版本。Word/Word 文档识别为 `docx`；HTML 主题写入 Word PRD 时不再被误推导为 HTML 开发阶段。
5. 共享提及解析支持已知角色名后紧跟中文动作的写法（例如 `@小产输出文档`），同时保留未知、重名和普通聊天提及诊断。
6. 路由结果现在同时返回未知提及、重名提及和多个最终执行人的结构化诊断，并提供 `needsMentionClarification`；S2 可以按字段持久等待澄清，不需要解析展示文案。

## 复用与取舍

- 复用 `analyzeMentionedCharacterIds`，没有再建第二套完整 @解析器；工作模式只增加最终执行意图的轻量判定。
- 复用 `WorkRoleStageKind`、`WorkHandoffStage`、`WorkRoleRouteResult` 和现有角色/Skill 数据，没有新增 Hive 类型、provider、依赖或职业注册中心。
- 保留 `modelSelector` 公共构造参数和模型决策类型以兼容调用方，但 S1 只把通过本地角色/能力/职责核验的结果作为候选排序提示，不能把它变成最终执行人；后续群讨论阶段再使用候选信息完成推举。
- 产物合同目前作为路由结果值对象返回；持久化、检查点、讨论状态和执行门禁属于 S2，尚未改动。

## 测试覆盖

扩展 `test/work_mode/work_role_router_test.dart`，覆盖：

- `@all` + 最终 `@产品`、Word/桌面合同、HTML 主题不生成开发接力；
- 无指定执行人返回候选，不首选第一人；附件-only 也等待推举；
- 纯 HTML、英文 `Frontend Engineer`、测试角色误指定、全栈/前端职责；
- 名字/人格标签/全局 Skill 不能伪造前端资格；
- Word 请求、修订路径和 requestRevision；
- 重名、未知角色、私聊固定角色、模型选择器不能覆盖显式路由；
- 咨询 @、@all 讨论受众、最终委托分离，以及模型推荐无效/不合格时保留本地候选；
- 明确的产品→开发→测试多阶段 @ 接力仍可建立和恢复。

## 验证结果

已执行：

- `flutter test --no-pub test/work_mode/work_role_router_test.dart test/mention_parsing_test.dart test/agentic/character_skill_resolver_test.dart test/agentic/expert_skill_catalog_test.dart`：57 项通过。
- `flutter test --no-pub test/work_mode/work_role_model_selector_test.dart`：4 项通过。
- `flutter test --no-pub test/work_mode`：532 项通过；首次回归发现旧 UI 集成测试仍假定未指定执行人会自动开跑，已改为明确 `@开发角色` 后复跑通过。
- `flutter test --no-pub`：2085 项通过。
- S1 五个受影响源码入口执行 `flutter analyze --no-pub lib/features/chat_group/chat_room_utils.dart lib/features/work_mode/work_role_model_selector.dart lib/features/work_mode/work_role_router.dart lib/features/work_mode/work_role_router_models.dart lib/features/work_mode/work_role_router_planner.dart`：通过，No issues found。
- 复核期间工作区另有未纳入 S1 的 PPT 失败恢复改动短暂造成全量分析报错；按“保留现有改动、S1 不越界”的约束未修改这些文件。待工作区稳定后再次执行无参数 `flutter analyze --no-pub`：通过，No issues found。
- `dart format`：已格式化本阶段修改的 Dart 文件。
- `git diff --check`：通过。

## 验收矩阵覆盖

- A04：部分覆盖。S1 已返回前端候选并禁止未匹配角色直接执行；“群内真实讨论和推举”留给 S3。
- A05：已覆盖。@all、咨询对象与最终执行人分离，咨询/阶段 @不会覆盖最终动作；完整聊天讨论留给 S3。
- A06：部分覆盖。角色不匹配、无候选、未知/重名会停止并给出 @用户原因；可操作补角色入口留给 S5。
- A20：策略层部分覆盖。未指定任务不再沿用首角色；完成任务后的旧任务分流属于 S4，当前未实现。
- B01：未完成。S1 只准备语义和候选，不实现群成员讨论。
- B02：本阶段已修复路由语义，但“讨论后最终执行权”需 S2/S3。
- B03：本阶段已冻结真实 DOCX/桌面合同，实际转换、验证和禁止 Markdown 降级需 S6。

## 未检查与剩余风险

- 未运行平台构建、真实多角色 API、真实桌面授权或 DOCX 转换；这些属于后续阶段/最终验收。全仓 Flutter 测试已通过 2085 项。
- 当前生产输入在未指定执行人时会收到候选/等待路由说明，但不会保留完整讨论任务；S2 必须把候选与合同接入持久任务状态。
- 合同尚未进入 `AgentTask` 检查点和完成门禁；在 S6 前不能宣称 Word 交付问题已经解决。
- `WorkRoleModelSelectorService` 的独立协议测试未在本阶段改动；已单独验证 4 项协议测试，并由路由层核验其候选推荐不会绕过资格与推举语义。

## S1 → S2 入口复核

- 结构化入口已具备：`WorkRoleRouteResult` 同时携带产物合同、候选 ID、讨论/咨询 ID、请求版本和提及澄清诊断；候选等待不会产生 `characterId`，因此不能被误当成可执行任务。
- 已确认的边界仍属于 S2：当前生产入口在候选等待时只显示系统提示并返回，不创建持久讨论任务；S2 必须把这些字段接入 `AgentTask.executionStateJson` 和唯一协调器门禁。此处不提前改造讨论流程。
- 复核后未发现需要阻止进入 S2 的 S1 级接口缺口；S2 的第一项应是消费上述结构化结果并保持请求版本/合同不丢失。

结论：S1 的请求语义、候选资格和产物合同已实现并通过本阶段测试；S1 完成，不代表群讨论、持久门禁、Word 转换或全功能验收完成。
