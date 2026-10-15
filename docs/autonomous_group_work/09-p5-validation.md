# P5 完整验证记录

日期：2026-10-14（Asia/Shanghai）。

结论：**最新自动化与静态检查通过；P5 完整产品验收未通过。** 公开发言提示调整后的第一次全量复测未完成，压缩提示后相关 v2 全文件通过；本轮协议示例及 `sessionRef` 接线后的最终全量 Flutter 回归退出码 0，3,480 项通过、3 项按环境跳过、0 项失败。真实产品 `.app` 会话、隔离群聊/私聊模型任务及视觉模型流程仍没有可用现场条件。P2/P3/P4 阶段记录里的阻塞继续有效，本记录不把样本、桩或自动化通过改写成真实产品通过。

## 本次检查范围与实现

检查范围为 02-design.md 的 R01–R16、A01–A30，以及当前工作区 P0–P4 和 P5 变更。保留了已有源码、文档、证据和其他本地修改；没有 reset、清理、暂存、提交或发布。

P5 沿用现有 AI 用量账本和 WorkProgressGuard，没有增加任务预算、累计轮次上限或第二执行循环。账本条目和请求诊断新增可空 taskId、runBoundary；旧记录继续可读，缺归属的历史记录保持未知，不猜测归属。生产工作模式中的讨论、执行、摘要、修订和真实重试均把 task/run 归属传到网关。每次真正的网络尝试有自己的请求 ID；同一 ID 重复写入不会重复累加，新的重试仍分别入账。缓存输入作为输入的一部分展示，不重复加总。用量面板按当前 taskId 汇总，分开列币种、估算/未知 token、缺价格和运行段/成员；不拿会话总量冒充任务总量。面板不可读账本时明确显示不可用。

P5 未改变 Hive 字段/枚举、@JsonSerializable 类型、备份白名单或全局治理设置；因此本阶段没有 build_runner 生成工作。P1/P4 中已有生成的 adapter 与旧编号规则按阶段记录核验。本轮另修复一个已有 widget 测试在关闭自动发言后未排空异步计时器的问题。

主要 P5 源码与测试：lib/features/ai_governance/ai_governance_models.dart、ai_governance_store.dart、ai_request_gateway.dart、ai_request_gateway_retry.dart；lib/features/work_mode/work_task_run_boundary.dart、default_work_task_runner_execution.dart、default_work_task_runner_model_io.dart、work_discussion_runner_model_io.dart、presentation/work_task_panel_details.dart、presentation/work_task_overlay_host.dart；test/ai_request_gateway_test.dart、test/ai_governance_ledger_lifecycle_test.dart、test/work_mode/work_task_run_boundary_test.dart、test/work_mode/work_task_panel_test.dart、test/chat_room_speaker_picker_budget_test.dart。

## 命令与结果

以下命令均在仓库根目录执行；单测按 30 秒单例超时、串行执行。此前全量日志保存在 build/p5-validation/flutter-test-full-final.log；本次追加复测结果见 p5-evidence/flutter-rerun-2026-10-14.md。

    flutter test --no-pub --concurrency=1 --timeout 30s --reporter failures-only
    本轮最终执行退出码 0；3,480 项通过、3 项跳过、0 项失败。3 项跳过是两个需要 CHAT_GROUP_RUN_MACOS_APPIUM_TEST 的 Appium 服务测试和一个需要 CHAT_GROUP_P2_APP_PATH 的实包测试；服务测试与真实包归档测试已另行 opt-in 通过，但没有创建产品 Mac2 session。此前路径改写断言曾单次失败，单项、整份 119 项讨论测试和本次全量均通过，根因未确认，保留为低级稳定性风险。当前产品 .app 原生会话仍受 P2 系统认证阻塞。复测摘要：p5-evidence/flutter-rerun-2026-10-14.md。

    flutter test --no-pub --concurrency=1 --timeout 30s test/ai_request_gateway_test.dart test/ai_governance_ledger_lifecycle_test.dart test/work_mode/work_task_run_boundary_test.dart test/work_mode/work_task_event_store_test.dart
    退出码 0；48 项通过。覆盖请求 ID 去重、真实重试入账、精确/估算用量、任务与运行段归属、事件存储边界。

    flutter test --no-pub --concurrency=1 --timeout 30s --plain-name '任务用量只汇总当前 taskId 并按币种与运行段展开' test/work_mode/work_task_panel_test.dart
    退出码 0；1 项通过。

    flutter test --no-pub --concurrency=1 --timeout 30s test/chat_room_speaker_picker_budget_test.dart
    退出码 0；1 项通过。关闭自动发言后清理待处理异步工作，避免 widget 测试泄漏 timer。

    CHAT_GROUP_RUN_MACOS_APPIUM_TEST=1 flutter test --no-pub --concurrency=1 --timeout 30s test/work_mode/macos_appium_service_owner_test.dart
    退出码 0；4 项通过。仅验证本地服务进程归属、启动/关闭、固定端口和状态处理；不创建 Mac2/XCTest WebDriver 会话。

    flutter test --no-pub --concurrency=1 --timeout 30s --reporter expanded test/work_mode/macos_app_bundle_archive_test.dart
    退出码 0；3 项通过、1 项跳过。真实产品包试验需要 CHAT_GROUP_P2_APP_PATH，当前未设置；其余测试覆盖包校验、内部链接/权限、外部链接和高压缩率 ZIP 拒绝。

    CHAT_GROUP_P2_APP_PATH='/Volumes/new_disk/work/flutter/chat_group/chat_group/build/macos/Build/Products/Release/伴伴.app' flutter test --no-pub --concurrency=1 --timeout 30s --reporter expanded test/work_mode/macos_app_bundle_archive_test.dart
    退出码 0；4 项通过，包括真实 Flutter .app 打包、包内摘要和解包检查。未启动产品包或创建 Mac2/WDA 会话。细节见 p5-evidence/macos-app-bundle-2026-10-14.md。

    flutter test --no-pub --concurrency=1 --timeout 30s --plain-name 'P3 renders every before-docx page with verified fonts' test/work_mode/work_document_real_render_test.dart
    退出码 0；1 项通过，约 22 秒。P3 的生产渲染器单独回归也有 4 项通过。

    flutter analyze --no-pub
    退出码 0；No issues found。

    dart format --output=none --set-exit-if-changed $(git diff --name-only --diff-filter=ACM -- '*.dart') $(git ls-files --others --exclude-standard -- '*.dart')
    退出码 0；131 个受改动 Dart 文件，0 项需格式化。

    git diff --check
    退出码 0；无空白错误。

    flutter build macos --no-pub
    退出码 0；产出 build/macos/Build/Products/Release/伴伴.app。

    plutil -extract CFBundleIdentifier raw -o - build/macos/Build/Products/Release/伴伴.app/Contents/Info.plist
    stat -f '%Sp %Su:%Sg %N' build/macos/Build/Products/Release/伴伴.app/Contents/MacOS/伴伴
    分别确认 bundleId=com.example.chatGroup，执行文件权限为 -rwxr-xr-x。

    codesign --verify --deep --strict --verbose=2 build/macos/Build/Products/Release/伴伴.app
    退出码 1；报告外层 Contents/Frameworks/App.framework 嵌套代码已修改或无效。

    codesign --force --deep --sign - build/p5-validation/resigned/伴伴.app
    codesign --verify --deep --strict --verbose=2 build/p5-validation/resigned/伴伴.app
    副本严格校验通过。此本地 ad-hoc 重签用于定位签名问题，不是构建管线修复或发布签名验证。

一次尝试用 Flutter 3.27.1 的 --build-dir 选项选择单独构建目录，CLI 返回未知选项；该失败没有改动源码，也不计为构建通过。随后实际执行上面的默认 Release 构建，并单独核对其产物。

在 gateway 目录运行 npm test，退出码 0，32/32 通过；覆盖 GitHub 固定 SHA 与引用资源读取、DNS/IP 拒绝、输入注入/路径穿越、鉴权、限流、配额、熔断和请求中止。上游 GitHub 传输使用测试替身，不代表真实仓库导入。

本次公开表达提示更新后，另执行以下定向复测；此前记录的全量 Flutter 套件是在这次提示文案变更前完成的。

提示更新后的第一次全量重跑未完成：运行到 `+2380 ~1 -1` 时，97 次读取用例缺少开发成员个人偏好；接着有较长无输出间隙。压缩提示后单项与整份 v2 讨论测试通过。协议示例及 `sessionRef` 接线后再次串行执行全量回归，最终 `+3480 ~3`、退出码 0。此前路径断言单次失败仍未定位根因。详细记录见 `p5-evidence/flutter-rerun-2026-10-14.md`。

    flutter test --no-pub --concurrency=1 --timeout 30s --reporter failures-only test/agentic/agent_prompt_builder_test.dart
    退出码 0；11 项通过。确认执行提示包含本人操作结果证据约束、共享证据来源和“情境示例不是事实/固定台词/证据”的说明。

    flutter test --no-pub --concurrency=1 --timeout 30s --reporter failures-only --plain-name '不同成员真实接线：0 次读取后当前方案逐人认可' test/work_mode/work_discussion_v2_test.dart
    退出码 0；1 项通过。确认 v2 每位成员收到同一条共用发言约束。

    flutter test --no-pub --concurrency=1 --timeout 30s --reporter expanded --plain-name '不同成员真实接线：97 次读取后当前方案逐人认可' test/work_mode/work_discussion_v2_test.dart
    退出码 0；1 项通过。确认压缩提示后长上下文仍保留当前成员的个人记忆。

    flutter test --no-pub --concurrency=1 --timeout 30s --reporter failures-only test/work_mode/work_discussion_v2_test.dart
    退出码 0；119 项通过，覆盖整份 v2 讨论提示和状态回归。

    flutter analyze --no-pub
    退出码 0；No issues found。

    dart format lib/features/agentic/agent_prompt_builder.dart test/agentic/agent_prompt_builder_test.dart test/work_mode/work_discussion_v2_test.dart test/work_mode/work_discussion_v2_regressions.dart
    退出码 0；4 个文件无格式变更。

    git diff --check
    退出码 0；无空白错误。

此前阶段的定向结果及日志见 05-p1-validation.md、06-p2-validation.md、07-p3-validation.md 和 08-p4-validation.md。P1 定向主套件 641 项、合约复测 154 项通过；P3 文档/提示相关定向套件 150 项通过；P4 Flutter 技能套件 171 项、Gateway 32 项通过。P4 曾尝试完整 runner 回归并在单例 30 秒上限处中断；提示更新前完整 Flutter 回归覆盖了测试树并通过，但这不等于真实多模型任务通过。提示更新后的全量复测结果和根因修复见 p5-evidence/flutter-rerun-2026-10-14.md。

本次协议示例接线补充了 `native.app` 的运行时 `sessionRef`：由 `open` 返回、供同一活动候选下后续观察/操作核验，只进入当前 loop 模型上下文并从检查点剔除；同一绑定下重复 `open` 可安全取回现有引用，不重放不确定动作。`flutter test --no-pub --concurrency=1 --timeout 30s --reporter failures-only test/work_mode/agent_decision_parser_test.dart` 退出码 0，52 项通过；`flutter test --no-pub --concurrency=1 --timeout 30s --reporter expanded --plain-name 'runtime sessionRef reaches the live model but not its checkpoint' test/work_mode/work_agent_loop_test.dart` 退出码 0，1 项通过；末轮 `flutter analyze --no-pub` 无问题。该补充已纳入随后最终全量 Flutter 回归，退出码 0，3,480 项通过、3 项跳过、0 项失败；P5 仍因真实产品与多模型现场验收缺失而未通过。

## 当前设备、应用和实测边界

| 项目 | 实际验证 |
|---|---|
| 设备/系统 | 当前一台 Apple Silicon Mac，macOS 15.6（24G84），arm64；没有 Android、iOS、Windows、远程设备或第二台 Mac 实测。 |
| 工具链 | Xcode 16.3（16E140）；Flutter 3.27.1 / Dart 3.6.0；Node 24.14.1 / npm 11.11.0；Appium 3.8.0 / Mac2 4.4.0。 |
| App 类型 | P0 实际操作独立 AppKit 样本，以及带显式原生语义桥的 Flutter counter 样本。生产伴伴 Flutter .app 本轮构建、检查身份/权限，并通过真实包归档和解包测试；未通过 Appium、XCTest 或 Codex UI 完成产品交互，也未读取真实聊天、Hive 或凭据。第三方 App 未测。 |
| 产品包 | build/macos/Build/Products/Release/伴伴.app 的 CFBundleIdentifier 为 com.example.chatGroup，执行文件为 伴伴 且有执行位；真实包归档、摘要核对和解包测试 4/4 通过。增量构建包的 codesign --verify --deep --strict 失败，报告 Contents/Frameworks/App.framework 的外层嵌套摘要无效；App.framework 单体校验通过。保留该构建后复制到 build/p5-validation/resigned/伴伴.app 并进行本地 ad-hoc 重签，副本严格校验通过。重签副本未启动；这不是 Developer ID 签名、公证或已修复的构建管线证明。 |
| 文档 | P3 用 python-docx 生成的合成 DOCX/PDF，使用 LibreOfficeDev 26.8.0.0.alpha0 与 Poppler 26.05.0 渲染；真实查看修复前后 16 张页图，逐页覆盖 4/4，并读回正文。字体为 PingFang SC。没有使用用户生产文档，也没有调用视觉模型。 |
| 模型/群聊/私聊 | 本轮没有发起任何真实模型请求，没有读取或要求用户粘贴 API Key。没有可核验的隔离测试群 ID/工作目录、群内每成员模型、私聊测试角色或生产搜索网关安全配置，因此真实多角色讨论、视觉检查和 GitHub 群聊/私聊技能复用均未执行。 |
| 系统原生权限 | P2 记录中的 automationmodetool 状态为 Automation Mode disabled 且需要用户认证。按用户此前“记录，后续验收再看”的要求，没有再次请求或尝试关闭系统认证。 |

## 严重级发现

| 严重级 | 发现与影响 | 处置/证据 |
|---|---|---|
| 高 | 生产产品 .app 的 Mac2/WDA/XCTest 原生控制会话仍无法建立。成功启动样本和 Appium 服务本身不等于可操作产品，也没有产品控件树、真实业务数据落点或修复前后产品版本证据。 | 保持 P2/P5 未通过。Automation Mode 系统认证是已记录阻塞，本轮没有重复请求。见 06-p2-validation.md、04-p0-validation.md。 |
| 高 | 没有隔离测试组、组 ID/目录及每个参与成员各自可用的测试模型；不能取得真实讨论、本人操作/反馈、修改、复测和最终交付凭据。 | 不使用个人 Hive、现有聊天或凭据补做验收；保持 R01、R04/R05、A01/A07/A18 等未通过。见 07-p3-validation.md、08-p4-validation.md。 |
| 高 | GitHub 技能只有固定 SHA/网关/权限/资源的自动化边界证据，没有使用生产搜索网关导入真实公共技能，也没有在群聊和私聊用同一包完成代表性任务并复测。 | 不声称技能已验证或激活。真实网络凭据留在应用现有安全设置；此处没有进行凭据测试。见 08-p4-validation.md。 |
| 中 | 当前 Release .app 的增量产物严格签名校验失败；本地复制品 ad-hoc 重签后可验证，但未运行且没有 Developer ID/公证证明。 | 保留原包和副本作为检查产物；产品包发布/原生会话前需要修复或确认构建签名链。检查命令输出记录在本报告与本机 build/p5-validation/。 |
| 低（未复现） | 一次全量复测中，`work_discussion_v2_test.dart:255` 的路径改写断言实际得到 `desktop`，未匹配期望的绝对路径。单项和整份文件重跑、本轮最终全量均通过；根因尚未确认。 | 记录在 p5-evidence/flutter-rerun-2026-10-14.md；另有较早的 speaker-picker fake timer 与文档渲染超时，修复与证据见 build/p5-validation/flutter-test-full.log。本轮全量 3,480 项通过、3 项跳过。 |
| 低 | 全量 Flutter 回归有 3 项按条件跳过；其中 2 项是未设置 CHAT_GROUP_RUN_MACOS_APPIUM_TEST 时跳过的服务所有权用例，另 1 项要求 CHAT_GROUP_P2_APP_PATH 的真实产品包试验。 | 服务所有权用例另行启用后 4 项通过；实包测试随后单独启用，含真实包共 4 项通过。产品包交互仍未验证，不按归档通过计为原生使用通过。 |

## R01–R16 矩阵

证据缩写：P0 = 04-p0-validation.md 与 p0-evidence/；P1 = 05-p1-validation.md 与 p1-evidence/；P2 = 06-p2-validation.md；P3 = 07-p3-validation.md 与 p3-evidence/generated/；P4 = 08-p4-validation.md；P5 = build/p5-validation/flutter-test-full-final.log、p5-evidence/flutter-rerun-2026-10-14.md、p5-evidence/macos-app-bundle-2026-10-14.md 及本报告。

| ID | 结论 | 检查结果与证据 |
|---|---|---|
| R01 | 未通过 | 没有真实群任务跑完讨论、定案、单人制作、全员使用、反馈、修复、复测和自动交付。P2、P3、P4 分别有现场阻塞，见 P2/P3/P4。 |
| R02 | 部分 | 软件样本 UI 和真实合成文档流程经过实测；生产产品 .app 未操作，真实模型也没有检查文档。见 P0、P3。 |
| R03 | 部分 | 当前 Mac 已构建、核对生产包身份/执行位，并通过 `.app` 归档和解包测试；P0 原生样本通过，产品原生交互仍受 Automation Mode 与签名检查限制。见 P0、P2、本报告及 p5-evidence/macos-app-bundle-2026-10-14.md。 |
| R04 | 未通过 | 没有全体参与成员在当前候选上的独立本人收据；自动化拒绝借用/代签不等于真实成员已使用。见 P1/P2。 |
| R05 | 未通过 | 没有真实多成员不同场景覆盖和最终模型反馈；场景分配/覆盖只有状态与门禁测试。见 P1/P2。 |
| R06 | 未验证 | v2 提示、人格、记忆、接话上下文和有限改写已测；没有隔离组真实对话样本供产品标准评价。见 P3。 |
| R07 | 部分 | 单制作人、固定 executorId 与试用 actor 分离的状态/runner 测试通过；没有真实执行人操作当前产品候选。见 P1/P2。 |
| R08 | 部分 | 用户指定执行者和资格边界有自动化回归；没有真实模型任务验证最终行为。见 P1。 |
| R09 | 部分 | 普通分歧由协调者定案、保留反对理由且不覆盖真实失败的边界测试通过；未验证真实协调者模型裁决。见 P1/P3。 |
| R10 | 部分 | 候选发布、报告和文件检查有实现与测试；本次没有真实任务产出、试用报告及交付文件闭环。见 P1/P2。 |
| R11 | 部分 | 唯一生产完成门禁、当前候选和全员使用条件有自动化测试；真实任务没有到达可交付状态。见 P1/P2。 |
| R12 | 通过（自动化） | 不加任务预算；账本按 task/run、成员、币种区分，缓存不重复、真实重试分开计数，未知/估算/缺价显式显示，任务 UI 不使用会话总量冒充。真实 provider 用量仍未产生。见 P5。 |
| R13 | 部分 | 复用 WorkProgressGuard、暂停/停止入口及相关保护测试；没有真实长任务观察“有依据调整后仍空转自动暂停”。见 P1/P2。 |
| R14 | 部分 | 群/私聊共用技能链路、固定 SHA、资源、权限、备份和自动化边界通过；没有真实 GitHub 导入后在群与私聊复用。见 P4。 |
| R15 | 部分 | 视觉能力预检、全页覆盖、字体/渲染 manifest 和缺少能力阻塞路径有代码/样本测试；没有视觉模型接收真实页图并给出反馈。见 P3。 |
| R16 | 部分 | 本机 AppKit/Flutter 样本真实操作通过；生产伴伴 .app 原生控制未建立，不能把样本证明扩展到任意 Mac App。见 P0/P2。 |

## A01–A30 矩阵

| ID | 结论 | 检查结果与证据 |
|---|---|---|
| A01 | 未通过 | 需要真实完整群任务；本轮没有隔离模型和原生产品会话。见 P2–P5。 |
| A02 | 部分 | 用户点选/明确制作人、咨询 @ 不作为委托、试用者不改变 executorId 有 P1 自动化测试；无真实模型流程。见 P1。 |
| A03 | 部分 | 代码可报告资格/能力阻塞且不会伪造人员；本机缺项已按环境记录，但未取得并核对隔离群的全体成员配置。见 P1/P2。 |
| A04 | 部分 | 普通偏好分歧的协调决议与反对意见保留有自动化验证；真实模型讨论未执行。见 P1/P3。 |
| A05 | 通过（自动化） | 用户明示冲突/越权不允许协调决议覆盖的规则有状态与协议测试；无现场用户冲突场景。见 P1。 |
| A06 | 通过（自动化） | 只有一人操作或其他成员只读/签字时，生产门禁测试拒绝完成；这不是真实使用验收。见 P1/P5。 |
| A07 | 未通过 | 全员独立模型、工具会话、不同场景及完整必达项覆盖没有真实执行。见 P1/P2。 |
| A08 | 通过（自动化） | 替换成员/场景/receipt 引用及借用收据的身份绑定测试通过；无真实收据。见 P1/P5。 |
| A09 | 通过（自动化） | 模型文本、tests JSON 或伪造截图路径不能生成可信操作观察的边界测试通过；没有把测试桩算作真实交互。见 P1/P2。 |
| A10 | 通过（自动化） | 候选/验证版本改变使旧成员使用证据失效的保守门禁有测试；未做产品真实修改后回归。见 P1/P2。 |
| A11 | 通过（自动化） | 损坏包、缺执行文件/位、外部链接及高压缩率 ZIP fixture 拒绝测试通过；真实产品包未通过 Appium 启动验证。见 P2 与 P5 包归档测试。 |
| A12 | 部分 | 运行时要求固定 appPath/bundleId 并检查候选身份；未运行同 bundleId 旧进程与候选竞争的真实产品场景。见 P2。 |
| A13 | 部分 | P0 样本真实点击、输入、滚动/窗口调整、关闭重开、预埋故障检查和修复复测；不是伴伴产品操作。见 P0。 |
| A14 | 部分 | P0 默认 Flutter 树失败，显式原生语义桥样本获得业务树；生产应用控件树和缩放校准仍未验证。见 P0/P2。 |
| A15 | 部分 | 全局桌面锁及资源清理有自动化测试；未用两个真实群并发争用桌面或用户切焦点验证。见 P2。 |
| A16 | 部分 | 合成 DOCX/PDF 的跨页表格、遮挡、错字、模板腔经真实渲染查看、修改并复渲染；不是用户生产文档或真实视觉成员检查。见 P3。 |
| A17 | 部分 | 合成样本全页 4/4 覆盖、字体和引擎记录通过；没有实际视觉模型，也没有用真实长文档验证覆盖上限。见 P3。 |
| A18 | 未通过 | 没有实际多角色模型讨论样本，无法评判自然接话、风格、依据和异议。见 P3。 |
| A19 | 部分 | 内置模板与 GitHub 资源导入已分开，固定 SHA 和来源状态自动化测试通过；未从真实公共仓库导入。见 P4。 |
| A20 | 通过（自动化） | 路径穿越、恶意权限、注入、未知许可/缺资源和外链拒绝测试通过，下载不能自动执行或激活。见 P4。 |
| A21 | 未验证 | 没有真实成功方法可复用，未创建或激活技能；没有因网络/权限/SDK 缺失制造技能。见 P4。 |
| A22 | 未通过 | 没有同一个真实资源包在群聊和私聊由真实角色分别加载/执行并完成任务。见 P4。 |
| A23 | 通过（自动化） | 多次请求去重、真实重试单独入账、未知/估算 usage、缓存子集和任务/会话分界通过测试；无 live provider usage。见 P5。 |
| A24 | 部分 | WorkProgressGuard、合法等待、停滞和自动暂停的代码回归通过；没有真实长期任务确认累计迭代不限额及调整后暂停。见 P1/P2/P5。 |
| A25 | 部分 | Appium 服务所有权用例 4 项通过；P0 样本能清理。产品 Mac2/WDA session 因系统 Automation Mode 阻塞，故产品原生暂停/停止/继续/退出闭环未验证。见 P0/P2/P5。 |
| A26 | 通过（自动化） | FIFO 补充、附件引用与逻辑原路径修订相关 runner/event-store/恢复回归在全量测试通过；未在真实群任务连续发修改。见 P1/P5。 |
| A27 | 通过（自动化） | 删除后迟到返回不复活状态及资源清理边界在自动化回归通过；未在真实产品工具进程上执行。见 P1/P2/P5。 |
| A28 | 通过（自动化） | 旧完成不补造使用，未知 schema 阻塞，旧未完成显式恢复建当前策略的测试通过；没有读取用户生产历史数据。见 P1/P5。 |
| A29 | 通过（自动化） | 完整/配置/会话备份映射与缺文件可见、执行权限/可信度重置、资源生命周期测试通过；没有读取或导出用户真实数据。见 P1/P4/P5。 |
| A30 | 通过（自动化） | 文件已经完成但附件发送失败时保留完成和重发入口、不重新制作的状态回归在全量测试通过；没有真实外部投递。见 P1/P5。 |

## 未检查项与风险

- 当前 Mac 之外的平台、设备、第三方应用及远程桌面均未测。
- 没有真实视觉模型、真实多角色模型/成员讨论、隔离群和私聊任务、生产 GitHub 导入或真实外部交付。
- 当前伴伴 .app 只检查了构建、Info.plist 身份、执行位和签名；未启动或连接 Mac2。未经系统认证无法核验真实窗口、控件树、焦点、应用数据存储位置和暂停清理。
- 本次未检查个人 Hive、用户 API Key、系统钥匙串内容，也没有改动全局治理配置；因此不能声称真实用户配置恢复/用量对账已端到端验收。
- P5 自动化范围已执行，但 R/A 需要的现场条件缺失；整体状态保持未通过。P2 未通过不阻断普通 App 开发、群聊或私聊，依赖 native.app 的 Mac 自主任务仍会暂停。
