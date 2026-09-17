# 未提交工作区审查与修复（2026-09-17）

## 范围与结论

审查起点为 30 个未提交文件（947 行新增、52 行删除），覆盖工作任务修订、调度收尾、审批提醒、私聊入口、任务标签/历史/耗时、Hive 与备份，以及全部配套测试。逐项对照根 AGENTS.md 和 `docs/group_work_discussion/02-requirements.md` 的 R10/R12、A03/A13/A19；没有将整个仓库所有历史功能纳入逐行审查。

移除违反执行 FIFO 约束的即时取消路径后，保留了任务展示、私聊系统提醒、深度修订识别和执行耗时改进。4 项发现均已修复；完整改动复审及最终自动化检查通过，本次范围内无已知未解决问题。未执行的真实环境验收不计为通过。最终验证结果见下文。

## 发现与处理（按严重级别）

### F01 · P1 · 运行中修订取消旧尝试，违反 FIFO 并竞争共享任务状态

- 证据：审查起点的 `work_task_coordinator_follow_up_input.dart:230` 调用 `_rerouteRunningTask`；`work_task_coordinator_follow_up_promotion.dart:366` 起修改共享 `AgentTask` 的请求、状态与检查点，并取消原 runner。实际 runner 尚未退出，仍可能写入相同 Hive 对象。与 AGENTS.md 及 R10 的“执行中输入持久 FIFO，不取消正在执行的任务”直接冲突。
- 影响：旧执行可能覆盖新请求状态；已排队请求顺序与附件语义难以保证，审批及失败收尾复杂化。
- 修复：移除该路径及对应标记/结果枚举/预测提示，恢复统一 FIFO。当前入口为 `lib/features/work_mode/work_task_coordinator_follow_up_input.dart:214`；不引入第二套执行状态机。
- 验证：`test/work_mode/work_task_coordinator_test.dart:476` 验证私聊连续修订不取消、原文件路径不变、附件逐条切换、同会话无并行及预算不重置；S4 测试验证群聊每次修订重新讨论。

### F02 · P1 · 深度形容词被当作覆盖原文件的授权

- 证据：原 `_hasEditVerb` 无条件接受“详细”和 `more detail`，使“详细阅读当前文件”“Explain in more detail what /workspace/report.md does”进入 reviseArtifact；“新建一份详细报告”也失去 newArtifact 分类。
- 影响：只读说明请求被注入原路径覆盖语义；新建请求错误继承旧任务处理方式。
- 修复：`lib/features/work_mode/work_follow_up_policy.dart:55` 区分新建与深度补充，`:309` 限定独立、明确的深度指令。显式修改仍沿用原策略，多个产物仍澄清。
- 验证：`test/work_mode/work_follow_up_policy_test.dart:150` 起覆盖只读、新建、单/多产物及原路径修订。

### F03 · P2 · 新测试未实际覆盖声称的异常和界面行为

- 证据：原 `an abandoned attempt failure does not fail the rerouted task` 在 runner 已经过异常判断后才设置 `throwOnAttempt=0`，其收尾并不会抛错；隐藏历史测试只调用字符串 helper，无法检测 UI 漏传参数；标签测试可被详情正文满足。
- 影响：测试即使通过，也不能证明失败处理、历史提示或标签正确。
- 修复：`test/work_mode/work_task_coordinator_test.dart:96` 在异步执行返回后真实抛错，`:529` 验证失败仍保留追问与附件；`test/work_mode/work_task_panel_test.dart` 改为定位指定标签、打开历史并点击任务详情；私聊提醒采用真实 waitingForApproval 状态并断言系统身份及审批动作。
- 验证：相关测试及全量测试；耗时测试另覆盖本次尝试起点和旧字段回退。

### F04 · P3 · 私聊预览的空白折叠正则转义错误

- 证据：修改范围内 `_lastMessagePreview` 仍使用 `RegExp(r'\\s+')`，匹配的是反斜杠文本，不能折叠换行和连续空白。
- 修复：`lib/features/direct_chat/direct_chat_list_page.dart:406` 使用 `RegExp(r'\s+')`，系统提醒保持系统身份，不拼接角色姓名。
- 验证：逐行审查、Dart 静态分析与 macOS 编译；未为这一处低风险展示修正新增独立测试。

## 其他审查结果

- 数据兼容：Hive 新增 nullable 字段 27，旧记录读取为 null，面板回退 startedAt/createdAt；生成器重新生成 adapter。备份编码/解码同步新增字段，并有导出恢复回归。
- 安全：提醒按钮校验任务 ID、会话 ID 和 action version；打开面板不等于批准操作。私聊无虚拟群成员，不借其他角色身份发言。未改变凭据、目录授权或外部命令权限边界。
- 架构/性能：复用既有协调器、持久 FIFO、系统消息服务和历史标题 helper；历史仍使用 ListView.builder，未新增依赖、网络调用或持久监听。移除取消路径引入的重复队列逻辑、无调用公共 API 和持久标记。
- 可读性：保留解释安全边界的注释；历史副标题直接使用 task.createdAt，移除冗余参数。生产代码未新增超大函数/文件；原有大文件未作无关拆分。

## 验证记录

- `dart run build_runner build`：通过，生成 1242 个输出，仅预期 adapter 留下差异。
- `flutter analyze --no-pub`：通过，无问题。
- `flutter test --no-pub test/work_mode/work_task_coordinator_test.dart test/work_mode/work_s4_boundaries_test.dart test/work_mode/work_follow_up_policy_test.dart`：134 项通过（收窄只读语义前）。
- `flutter test --no-pub --reporter expanded test/work_mode/work_follow_up_policy_test.dart test/work_mode/work_task_action_message_service_test.dart test/work_mode/work_task_panel_test.dart`：最终版本 70 项通过。
- 首轮全量测试结果为 2346 项通过、1 项失败。在运行中补入 F02 反例，仍使用此前编译的策略，捕获“详细阅读当前文件”误判。该轮结果不作为最终通过依据；修复后的独立定向测试已通过，将重新运行稳定代码版本的完整测试。
- `flutter build macos --debug --no-pub`：最终代码构建通过。第三方 desktop_webview_window 存在 javaEnabled 弃用警告，Xcode 有多架构目标选择警告，均未阻止构建。
- `git diff --check` 与 `dart format --output=none --set-exit-if-changed <22 个变更 Dart 文件>`：通过。
- `flutter test --no-pub --concurrency=1 --reporter expanded`：最终固定代码版本 2347 项全部通过，耗时 4 分 08 秒。日志 `/tmp/chat_group_review_full_final.log`；首轮失败日志 `/tmp/chat_group_review_full.log`；最终定向、分析、构建日志分别为 `/tmp/chat_group_review_final_targeted.log`、`/tmp/chat_group_review_analyze_final.log`、`/tmp/chat_group_review_build_final.log`。

## 未检查范围

未运行真实 LLM/付费 API、原生目录选择与审批交互、Android/iOS/Windows/Release 构建；这些需要相应设备、签名或外部服务，本次未改变相关平台配置。macOS Debug 构建与 widget 测试不能代替上述端到端体验验收。本报告仅对本次改动及已执行检查下结论。
