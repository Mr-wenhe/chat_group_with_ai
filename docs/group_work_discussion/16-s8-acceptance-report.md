# S8 完整验收报告：真实产物与规格同步

日期：2026-09-15（Asia/Shanghai）
范围：当前工作区全部 S1–S8 改动、根 `AGENTS.md`、`/Users/fengye/.codex/skills/ponytail/SKILL.md`、`docs/group_work_discussion/02-requirements.md` 的完整需求以及 A01–A21。
结论：**S8 总体验收未完成，暂不可宣布总体通过。** 自动化全链路、串行全量回归、真实 pandoc DOCX 和 WPS GUI 打开检查已完成；原生窗口启动、API 连接和一轮真实群聊讨论已补充检查，但精确工作任务的原生输入→讨论→Word 交付闭环、原生目录授权/撤销、真实转换器安装流程和 Microsoft Word GUI 仍未检查。

## 验收边界和执行原则

本轮读取并保留 S1–S7 历史记录事实；没有回写历史报告的通过结论，没有自动 commit/push/release，也没有安装真实软件或写入用户桌面。实现与验收遵循 Ponytail full：沿现有 `WorkRoleRouter → WorkDiscussionRunner → WorkTaskCoordinator → DefaultWorkTaskRunner → WorkCommandRunner` 生产路径检查，测试只替换模型传输为脱敏的结构化网关，并把文件写入映射到隔离临时授权目录。

本轮做了六个最小调整：

- `DefaultWorkTaskRunner.directoryService` 可注入，生产默认仍使用真实桌面解析；集成测试把“桌面”语义绑定到临时授权目录，避免验收写用户桌面。
- 群聊输入不再因为执行角色缺少工具权限而提前丢成一次性系统消息；`chat_room_agentic_input_support.dart:427-433` 先持久化讨论任务，生产 runner 仍在工具调用时重新校验角色权限，满足“群任务先讨论且可恢复”。
- S8 集成测试的辅助网关拆到 part 文件，保持测试职责清晰且每个新增测试文件低于约 500 行。
- 真实 macOS 检查发现关系审计页的返回按钮在桌面导航复用场景触发
  `ModalRoute.willPop` 断言；`MemoryPageAppBar` 改为直接 `Navigator.pop`，避免没有
  `willPop` scope 时崩溃。该改动已通过关系审计定向测试和静态分析。
- 续验复现了真实模型返回普通多行文本时的状态边界：协调员的非结构化预览曾被写入
  `decisionSummary`，换行使持久状态校验失败并掩盖原始协议错误。现在只有结构化校验通过的
  汇总才更新 `decisionSummary`；新增回归测试确认任务进入可解释阻塞状态且状态仍在边界内。
- S8 复审又复现了损坏的结构化 `discussionState` 标记被显示层当作“已存在”但没有生成恢复操作的路径；
  现在严格解析失败会生成 `discussionStateInvalid` 操作，若整个执行检查点还需要版本复核则保留单一
  `checkpointReview` 操作，避免任务无提示地停在暂停状态。新增损坏标记回归测试。

## 2026-09-15 续验记录

初次启动记录的“黑屏”来自此前运行实例；用当前工作区重新构建并启动
`flutter run -d macos --debug --no-pub` 后，macOS 窗口能显示角色页、群聊页、工作任务面板和可访问性树，黑屏阻塞已解除。
设置页中 `step fun` 和 `SenseNova` 的“测试”入口均返回成功；这证明本机保存的两个模型配置可连通，不能替代第三方模型输出质量验收。

在“我的世界”群聊中以当前真实模型运行了一轮普通群聊：前端、UI/设计、测试、产品经理等角色按消息顺序发言，群摘要收敛为网页版 MC 的方块采集、基础合成、背包和人物等范围；产品经理回复中包含取舍和进度安排。随后通过真实 UI 将工作模式开关切到开启状态，图标变为选中态且自动聊天停止。

尝试在同一原生输入框用 `@all … @产品经理` 精确原句发起工作任务时，Computer Use 的文本注入与提及候选弹层发生竞态，最终落库的历史任务请求被截断为 `@a`，因此这次不能作为精确原句的工作模式验收证据；它也不能证明当前路由器会错误地把完整请求交给前端。真实精确输入仍需用原生键盘/提及候选完成后重跑。

续验期间关闭调试应用时，Flutter 3.27.1 还输出了由 Computer Use 键盘注入造成的 `HardwareKeyboard` KeyUp 断言；未在代码路径或自动化测试中复现，暂记为测试工具/框架环境观察项。

本次继续复核时重置 Computer Use 会话并再次尝试原生输入：AX 树短暂显示了完整字符串，实际窗口仍保持占位符，发送动作没有形成新的可追踪任务；终端持续报告同一物理按键的重复 `KeyDownEvent`。因此这次也没有把自动化注入结果当作产品行为结论，精确任务闭环继续列为未检查。

随后在已激活窗口中改用可访问性 `setValue` 与文本粘贴：AX 树能显示完整值，但 Flutter 实际输入框仍保持占位符，未产生可发送消息；尝试真实键盘字符时又出现 `HardwareKeyboard` 的 KeyUp/物理键不一致断言。该复核仍未形成新的任务记录，继续按环境阻塞处理。

调试应用重启后，任务面板仍显示此前已落库的历史任务及其旧的“状态字段越界”失败文本。修复针对新的讨论状态写入生效，未回写这条历史记录；它需要在后续真实恢复/重试现场单独验证，不能当作新修复再次失败。

## 环境证据

| 项目 | 证据和结论 |
|---|---|
| 平台 | macOS 15.6 arm64；Flutter 3.27.1、Dart 3.6.0；`flutter devices` 发现 macOS desktop、Mac Designed for iPad 和 Chrome。仓库 AGENTS.md 的 Flutter 3.24 fork 兼容约束仍适用；本轮未触及依赖或平台工程。 |
| chat_group 原生 UI | 初次实例曾出现黑屏；续验从当前工作区重新构建后可显示角色页、群聊页、任务面板和可访问性树。精确工作任务输入仍受提及候选注入竞态影响，未形成完整原生闭环证据。 |
| 模型 | 设置页中 `step fun`、`SenseNova` 的连接测试均成功；已完成一轮真实群聊讨论观察。尚未完成精确工作任务的真实第三方模型质量和稳定性验收。 |
| 转换器 | `/opt/homebrew/bin/pandoc`，版本 `3.11`；真实执行 Markdown → DOCX。 |
| DOCX 结构 | `unzip -t` 对生成文件全部 OpenXML 条目报告 OK；`soffice --headless --convert-to txt:"Text"` 成功提取正文。 |
| GUI 打开 | Finder 识别产物为 `Microsoft Word document (.docx)`；WPS Office 成功打开并显示标题、目标范围、无限地图、方块采集、背包系统、合成系统、人物系统和验收标准。WPS 不是 Microsoft Word，Word.app 不存在，因此 Microsoft Word GUI 仍未检查。 |
| 路径/桌面 | 自动化只写隔离临时目录 `/tmp/chat_group_s8_docx.LzPYvc` 和测试 Hive 临时目录；没有写 `$HOME/Desktop`。真实原生目录授权/撤销入口未检查。 |
| 真实安装/审批 | 未执行真实软件安装；缺工具、安装拒绝/稍后和原生目录审批使用现有自动化状态机/临时授权覆盖。当前仍没有可安全执行的原生目录授权/撤销现场记录。 |

## 命令与结果

| 命令 | 结果 |
|---|---|
| `flutter --version` / `flutter devices` | Flutter 3.27.1、Dart 3.6.0；发现 macOS、Mac Designed for iPad、Chrome 三个 target。 |
| `flutter analyze --no-pub` | 通过，`No issues found!`（包含关系审计返回修复） |
| `flutter test --no-pub --reporter expanded test/work_mode/work_mode_s8_end_to_end_test.dart` | 通过，1 项；真实 provider/coordinator/runner/command 路径生成 DOCX |
| `flutter test --no-pub --reporter compact test/work_mode/work_task_user_action_test.dart test/work_mode/work_discussion_state_test.dart test/work_mode/work_discussion_runner_test.dart test/work_mode/work_mode_s8_end_to_end_test.dart test/work_mode/work_task_action_message_service_test.dart` | 通过，54 项；包含损坏 `discussionState` 标记恢复操作回归和 S8 讨论/交付链路 |
| `flutter test --no-pub --reporter compact test/relationship_audit_redesign_test.dart test/work_mode/work_mode_s8_end_to_end_test.dart` | 通过，6 项；包含关系审计返回修复和 S8 集成验收（修复后定向复跑） |
| `flutter test --no-pub --concurrency=1 --reporter compact test/work_mode` | 通过，716 项（包含本轮损坏讨论标记恢复回归） |
| `flutter test --no-pub --reporter compact test/work_mode/work_discussion_runner_test.dart` | 通过，19 项；新增多行非结构化协调员预览回归，确认不再触发“状态字段越界”并保留阻塞原因 |
| `flutter test --no-pub --concurrency=1 --reporter compact` | 通过，2277 项（包含本轮损坏讨论标记恢复回归的最终串行全量回归） |
| `dart format --output=none --set-exit-if-changed lib test` | 通过，690 个文件、0 个文件需修改 |
| `git diff --check` | 通过 |
| 首次 `flutter test --no-pub --reporter compact`（默认并发） | 部分运行到 `+2273 -1` 后在 `search_provider_config_form_page_test.dart` 的 “new key connection test does not persist before save” 附近长时间无进展并被停止；单独重跑该测试通过。这次结果作为未稳定的并发运行记录保留，原因未被证明，不能当作全量通过。 |
| `pandoc source.md -o output.docx` | 真实转换成功 |
| `unzip -t output.docx` | 17 个 OpenXML 相关条目均 OK，`No errors detected` |
| `soffice --headless --convert-to txt:"Text"` | 成功读取标题、章节和五项核心能力 |
| WPS GUI 打开隔离 DOCX | 成功显示正文；未保存文件 |

没有修改 pubspec、Hive schema 或平台工程文件，因此本轮没有运行代码生成或平台签名构建；平台构建仍需在 chat_group UI 修复且获得对应现场条件后再做。

## A01–A21 逐项结果

“自动化通过”只表示对应代码路径和失败边界有测试证据；“部分通过”表示仍有本轮明确未检查的真实条件，不能合并为总体验收通过。

| 编号 | 结果 | 证据与未检查项 |
|---|---|---|
| A01 | 部分通过 | 自动化从精确输入进入路由、三名职业成员讨论、产品经理 100% 汇总、两次审批和真实 DOCX；续验真实 UI 观察到多职业群聊讨论和产品取舍，但原生工作任务输入因提及候选注入竞态被截断，真实 Word 交付和用户桌面仍未检查。 |
| A02 | 部分通过 | 自动化覆盖没有“先讨论”关键词仍进入讨论门禁；真实群聊观察到先由多个角色发言再由产品经理收敛，原生工作任务门禁尚未用精确原句完成。 |
| A03 | 部分通过 | 普通/自动聊天、私聊隔离和工作模式 watcher 测试通过；真实 UI 已验证工作模式开关可选中并停止自动聊天，私聊固定角色的原生入口仍未检查。 |
| A04 | 自动化通过 | `work_role_router_test.dart` 覆盖未指定 HTML 时只接受本地具备前端职责的候选，测试角色不能冒充。 |
| A05 | 部分通过 | 路由和讨论测试覆盖 `@all` 与最终 `@角色` 分离，最终角色不被成员建议覆盖；原生提及候选注入竞态使精确 UI 场景未完成。 |
| A06 | 部分通过 | 路由/讨论/coordinator 测试覆盖无前端、指定错人、未知角色、补角色和 @用户 阻塞；真实群聊入口可见，成员管理和错误执行人现场仍未完成。 |
| A07 | 自动化通过 | 讨论 runner 测试覆盖短/中/复杂轮次、无进展收敛和不能伪报 100%。 |
| A08 | 自动化通过 | 讨论 runner 和 S8 集成测试覆盖各成员职责发言、执行人汇总、采纳取舍、100% 理解进度和不长期旁观；真实模型响应时延未检查。 |
| A09 | 自动化通过 | 讨论 runner 测试覆盖停用、无凭据、超时和失败成员不伪造发言；关键缺失进入阻塞。 |
| A10 | 部分通过 | coordinator、任务动作和面板测试覆盖必要问题暂停，回答后从原版本继续；真实任务面板可见，但精确任务的按钮后续操作尚未完成。 |
| A11 | 自动化通过 | coordinator/讨论门禁测试覆盖理解不足、开放问题、错误执行人和过期状态在任何工具调用前被拒绝。 |
| A12 | 自动化通过 | S4 边界和 coordinator 测试覆盖讨论补充合并、旧回复竞态、理解进度下降和版本失效。 |
| A13 | 自动化通过 | S4 边界、FIFO、附件和工作模式恢复测试覆盖同一原文件按顺序修改，不取消旧任务或静默重命名。 |
| A14 | 部分通过 | 缺 pandoc、安装/拒绝/稍后、检查点恢复和按钮幂等有自动化证据；当前环境已有 pandoc，未执行真实安装器、原生安装审批或失败后的现场恢复。 |
| A15 | 部分通过 | 临时目录授权、拒绝、撤销和路径门禁有自动化证据；未在 chat_group 原生 UI 中操作系统目录选择器、错误目录和撤销后现场恢复。 |
| A16 | 通过（自动化 + WPS） | DOCX 结构/正文/路径、零字节、陈旧文件、错误目录、损坏 ZIP 的交付门禁测试通过；本轮 WPS GUI 打开真实 DOCX 成功，Microsoft Word GUI 未检查。 |
| A17 | 自动化通过 | runner、附件重试和失败恢复测试覆盖文件已保存但附件失败、只重试交付不重复生成。 |
| A18 | 部分通过 | action/coordinator/recovery 测试覆盖两个入口重复批准、旧按钮失效、重启 checkpoint；原生任务面板可见，真实 App 重启后的按钮操作仍未完成。 |
| A19 | 部分通过 | recovery、context、backup、event 和 coordinator 测试覆盖离开页面、压缩、旧记录和手动恢复；实际杀进程、重开 chat_group 和跨重启现场操作未检查。 |
| A20 | 自动化通过 | S4 边界、router 和 coordinator 测试覆盖旧任务完成后明确新任务重新讨论、重新选人，不沿用旧执行人。 |
| A21 | 自动化通过 | 路径、附件、Skill、成员文本、备份和命令安全测试覆盖不可信内容不能改 Word 合同、执行人、授权或审批；真实恶意附件 UI 未检查。 |

## 逐维度 Review

- 需求符合性：当前规格已明确“群聊先公开讨论、再确定一个最终执行人”；旧的“需求 → 开发 → 测试自动接力”和“首位可用角色默认降级”只保留为历史基线或明确配置的旧式接力，不再是普通群任务规则。私聊固定当前角色，不引入虚拟群成员。
- 正确性和边界：角色资格、请求版本、讨论状态、理解百分比、DOCX 合同、执行人身份和路径在 coordinator/runner 再校验；工具权限仍在 runner 重新取交集。
- 失败路径：安装、命令审批、目录授权、澄清、附件重试、损坏 DOCX、过期按钮、取消和恢复均有独立状态和自动化覆盖。
- 测试有效性：S8 集成测试没有直接拼 helper 宣称端到端，使用真实生产 provider/coordinator/runner/command，并检查真实 pandoc 产物；测试模型是脱敏网关，不能推出第三方模型质量。
- 安全：没有输出凭据；测试桌面通过可注入解析器映射到临时授权目录；未扩大真实桌面授权。
- 性能与生命周期：串行全量 2277 项通过；讨论/任务取消、迟到回调、资源锁和监听释放有既有测试。
- 可读性和模块化：本轮 S8 测试已拆分辅助 part 文件。工作模式仍有 S1–S7 遗留的大文件（例如 `work_task_coordinator.dart` 约 4750 行、`default_work_task_runner.dart` 约 3884 行、`work_discussion_runner.dart` 约 1921 行、`work_discussion_state.dart` 约 915 行），超过 AGENTS.md 建议的约 500 行；它们属于历史增量，S8 未做高风险大重构，记录为后续 P2 可维护性风险。
- 注释/命名/常量/封装/新老兼容：新增桌面依赖有 why 注释，S8 测试使用稳定 ID/常量，未修改 Hive schema；现有大文件中的历史复杂函数仍需后续按模块拆分。

## 发现、修复与剩余风险

| 等级 | 项目 | 处理 |
|---|---|---|
| P1/P0 | 本轮未发现自动化路径中的 P0/P1 正确性或安全阻塞。 | 保留真实环境未检查结论，不把它们升级为通过。 |
| P2（已修复） | 群聊输入在入口处因角色工具权限不足直接写一条系统消息并丢失持久任务，绕过“所有群任务先讨论”。 | 删除入口早退；现在先持久化讨论任务，runner 在实际工具调用再次做权限交集校验；后续复审的 `flutter analyze`、工作模式 716 项和全量 2277 项均通过。 |
| P2（已修复） | 关系审计页返回按钮在桌面复用导航下触发 `ModalRoute.willPop` 断言。 | 改为直接 `Navigator.pop`；关系审计定向测试和静态分析通过；仍需在原生现场再次点击确认。 |
| P2（已修复） | 真实模型以多行普通文本回应协调员汇总时，诊断预览被写入 `decisionSummary`，持久状态因控制字符被拒绝，原始结构化协议错误被包装成讨论运行器失败。 | 仅允许 `summary.valid` 的结构化公开更新写入 `decisionSummary`；新增回归覆盖多行非结构化汇总，定向讨论测试通过。 |
| P2（已修复） | `discussionState` 只要是 Map 就会被显示层视为存在；若其内容无法通过严格解析，任务可能没有任何恢复按钮而永久停在暂停状态。 | `forTask` 现在严格解析失败时发布 `discussionStateInvalid`，并用解析后的安全状态生成普通 blocker 操作；若同一检查点还需要版本复核，保留一个 `checkpointReview`。新增回归测试；S8 定向 54 项、工作模式 716 项和串行全量 2277 项均通过。 |
| P2（续验限制） | 原生输入框的 Computer Use 文本注入与 `@all` 候选弹层竞态，导致本轮落库请求为 `@a`，不能形成精确原句闭环。 | 不是将截断输入当成产品路由结论；需要用真实键盘逐段输入并选中 `@all`/`@产品经理` 后重跑。 |
| P2（环境阻塞） | 精确工作任务的第三方模型质量、稳定性和真实交付尚未完成。 | 已验证两个连接可用并观察一轮真实讨论；仍需完成精确任务和失败/无进展现场。 |
| P2（环境阻塞） | 没有 Microsoft Word.app、真实转换器安装/原生目录授权现场。 | 需提供目标应用和用户授权后继续；WPS/headless 证据不能替代。 |
| P2（历史任务待恢复） | 调试重启仍可看到修复前已落库的旧讨论失败任务；本轮没有用原生按钮重试或回写历史状态。 | 在原生输入和审批环境可用后，先对该历史任务执行“回答问题/重试”，确认从检查点恢复；若产品要求自动迁移，再单独设计迁移规则并回归。 |
| P2（环境阻塞） | 没有 Microsoft Word.app；已完成 WPS GUI 和 headless soffice 检查。 | 安装/提供 Word 后重做正文、标题、章节、保存位置和渲染现场检查；安装必须走用户授权。 |
| P2（遗留可维护性） | 多个工作模式核心文件超过约 500 行。 | S8 保持最小根因修复，后续按职责拆分并逐项回归，不能在验收尾声做大规模重构。 |
| 观察项 | 默认并发全量回归曾在 `+2273 -1` 后卡住；早一轮串行全量随后稳定通过 2275，失败测试单独重跑通过；新增状态边界回归后的最终串行全量为 2277。 | 继续保留并发运行稳定性监控；当前不作为串行产品失败结论。 |

## 后续具体操作

1. 用原生键盘逐段输入原句，并在候选弹层中明确选择 `@all` 与 `@产品经理`，重新执行精确工作任务的讨论、进度、执行人和 Word 交付验收。
2. 在真实任务成功后，继续执行任务面板的必要问题、补充 FIFO、撤销/稍后处理和重启恢复现场检查。
3. 在用户明确授权下，通过 App 原生审批完成一次 pandoc 缺失安装/拒绝/稍后恢复，以及一次桌面目录授权、拒绝、撤销和跨重启继续。
4. 在 Microsoft Word GUI 或等价目标环境中重做 DOCX 打开检查。
5. 以上现场项完成后，更新本报告状态；在此之前保持“未完成验收”，不能以测试全绿替代验收。

历史 S1–S7 报告继续保留原事实和结论；本报告只记录 S8 当前证据和未检查项。
