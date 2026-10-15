# P2 macOS 自主闭环验证

日期：2026-10-13。状态：**未通过（实现与自动检查已通过，真实产品验收未通过）**。静态分析、macOS debug 构建、3,827 个全仓 leaf tests（3,824 通过、3 跳过、0 失败）和 669 条 P2 定向回归通过；另以 opt-in 方式启动并停止真实 Appium 3.8.0 服务，4 条服务生命周期与失败分类测试通过。真实 Mac2 session 仍在 macOS Automation Mode 认证处失败，尚未完成目标窗口操作、停止复测或多成员产品闭环。此前 P0 样本证据见 [04-p0-validation.md](04-p0-validation.md)，不替代这次 P2 验收。

## 实现范围

| 范围 | 实现与调用链 |
|---|---|
| 窄范围工具 | `AgentToolName.nativeApp` 只接受 `open/observe/act/close`；严格解析动作白名单、文本/滚动/缩放边界、运行时返回并核验的 `sessionRef` 和成员最新观察返回的 `elementId`。`DefaultWorkTaskRunner` 在现有使用段注册工具，复用同一 `WorkAgentLoop`、Dio、角色权限、审批指纹、任务取消和文件候选核验。模型不能提交 appPath、bundleId、服务 URL 或任意坐标。 |
| 会话引用生命周期 | `open` 返回运行时引用；相同成员、场景、候选和计划下重复 `open` 可取回现有引用，动作结果不确定时提示先 `observe`，不重放。后续 `observe/act/close` 必须回传并与活动会话精确匹配。引用只进入当前 loop 的模型上下文，从检查点和持久化工具结果剔除；进程重启后旧引用不能恢复本地会话。 |
| 责任和场景授权 | 打开目标时从冻结候选读取 `.app` 元数据，按当前成员、场景、候选摘要、使用计划和授权能力绑定会话。制作执行者身份与当前试用成员仍由 P1 状态分开。 |
| `.app` 候选封装 | [macos_app_bundle_archive.dart](../../lib/features/work_mode/macos_app_bundle_archive.dart) 仅处理 macOS `.app` 与 ZIP 传输载体。校验 Info.plist、bundleId、执行文件、签名、包内树摘要、执行权限和内部链接；拒绝外部链接、路径越界、特殊文件、重复名称、大小/压缩比超限及解包身份变化。普通文件候选发布保持原路径。 |
| 真实进程与数据路径 | 从冻结 ZIP 解包到权限为 0700 的本轮临时目录；会话同时绑定 bundle 路径和可执行文件路径，回报 PID、包内摘要、窗口几何和目标窗口截图。通过 `CHAT_GROUP_TEST_DATA_DIR` 给目标 app 单独数据路径；文案明确它不是操作系统沙箱。停止或角色切换前，核对 Appium session、目标进程和 WDA 端口；清理不确定时保留桌面锁并报告阻塞。 |
| 全局桌面锁和收据 | 使用 app-scoped `WorkResourceLockManager` 的同一 desktop tree-write 锁，不按任务分锁。动作前封存幂等标记，不盲目重放丢失响应的副作用。目标窗口 XML、截图和缩放 JSON 通过事件存储写入内容寻址证据；操作观察由运行时生成并绑定成员/场景/候选/计划。 |
| 权限与生命周期 | `ToolPermission.nativeApp` 追加在 Hive 枚举末尾并重建 adapter；同步工具名、解析器、registry、角色和任务授权、审批指纹、上下文及 provider。停止处理会关闭会话，身份桥接现在同时核对实际 bundle 与 executable 路径。 |
| Appium 服务归属 | `MacAppiumServiceOwner` 只从仓库内 P0 固定运行时启动 Appium 3.8.0/Mac2 4.4.0，验证 Node 版本、包版本、仓库内真实路径、进程参数和 loopback 监听 PID；固定端口已有外部监听时失败关闭，不接管或终止它。Appium 3 的会话枚举使用 `/appium/sessions`。 |

## 实际命令与结果

```sh
dart run build_runner build --delete-conflicting-outputs
```

结果：成功，363 个 build actions，7 个生成输出。P2 只追加 `ToolPermission.nativeApp`，未新增 Hive 字段。

```sh
python3 - <<'PY'
import subprocess
tracked = subprocess.check_output(['git', 'diff', '--name-only', '--', '*.dart'], text=True).splitlines()
untracked = subprocess.check_output(['git', 'ls-files', '--others', '--exclude-standard', '--', '*.dart'], text=True).splitlines()
paths = sorted(set(tracked + untracked))
raise SystemExit(subprocess.call(['dart', 'format', '--set-exit-if-changed', *paths]))
PY
flutter analyze --no-pub
git diff --check
```

结果：73 个文件格式检查通过，静态分析 `No issues found`，diff 检查通过。格式化初检修正了 3 个既有改动文件格式；末轮发现并修正一个进程退出分支的花括号 lint 后，重新分析通过。

```sh
flutter build macos --debug --no-pub
```

结果：构建成功，产物 `build/macos/Build/Products/Debug/伴伴.app`。只读核对 `CFBundleIdentifier=com.example.chatGroup`、`CFBundleExecutable=伴伴`、`ChatGroupTestDataEnvironment=CHAT_GROUP_TEST_DATA_DIR`、执行文件可执行位及 `codesign --verify --strict` 均通过。

```sh
CHAT_GROUP_P2_APP_PATH='build/macos/Build/Products/Debug/伴伴.app' flutter test --no-pub --timeout 30s --reporter failures-only --file-reporter json:build/p2_macos/p2_final.json \
  test/work_mode/agent_decision_parser_test.dart \
  test/work_mode/default_work_task_runner_stage02_test.dart \
  test/work_mode/macos_app_bundle_archive_test.dart \
  test/work_mode/work_candidate_publication_test.dart \
  test/work_mode/work_collaboration_state_test.dart \
  test/work_mode/work_discussion_v2_panel_test.dart \
  test/work_mode/work_discussion_v2_test.dart \
  test/work_mode/work_mode_policy_test.dart \
  test/work_mode/work_role_router_test.dart \
  test/work_mode/work_task_coordinator_test.dart \
  test/work_mode/work_task_event_store_test.dart \
  test/work_mode/work_mode_s8_end_to_end_test.dart \
  test/direct_chat_empty_reply_fallback_test.dart \
  test/database_service_ai_processing_dir_test.dart \
  test/database_service_credential_fallback_test.dart \
  test/database_service_message_index_test.dart \
  test/database_service_permanent_memory_adapter_test.dart \
  test/database_service_realtime_identity_test.dart \
  test/backup_restore_service_test.dart
```

结果：此批包括更新后的 S8 v2 回归、P1 状态/协调决议和候选包测试；669 个 leaf tests 全部通过。S8 使用确定性模型传输验证协调决议协议和冻结候选门禁；试用阶段明确返回 `blocked`，断言不交付。它是自动化回归，不代表真实成员操作，也没有伪造成功收据。

```sh
CHAT_GROUP_RUN_MACOS_APPIUM_TEST=1 flutter test --no-pub --timeout 30s test/work_mode/macos_appium_service_owner_test.dart
```

结果：2 条 macOS 生命周期测试通过：外部固定端口监听保持不变；受管 Appium 实际启动后，`/status` 返回版本 3.8.0、`/appium/sessions` 返回空会话，随后只停止本应用启动的子进程并确认 4725 端口关闭。

```sh
flutter test --no-pub --concurrency=1 --timeout 30s --reporter failures-only --file-reporter json:build/p2_macos/full_regression_final.json
```

结果：退出码 0，3,822 个通过、3 个跳过、0 个失败。全量串行测试包含修改后的 S8 和私聊回归。上述成功只代表自动化代码检查，不替代真实 App 会话和多成员使用验收。

```sh
flutter analyze --no-pub
git diff --check
```

结果：`No issues found`，diff 检查通过。S8 夹具和超时辅助文件已重新 `dart format`。

## P0 路线复测与阻塞

只读版本检查命令为 `build/p0_macos/runtime/node_modules/.bin/appium --version` 和 `APPIUM_HOME=build/p0_macos/runtime/appium-home build/p0_macos/runtime/node_modules/.bin/appium driver list --installed`；结果分别为 Appium 3.8.0、Mac2 4.4.0。本轮本机 Appium 只绑定 `127.0.0.1:4725`，WDA 使用 `127.0.0.1:10123`。使用已构建、签名校验过的隔离 `P0Sample.app`，尝试建立真实 Mac2 会话。XCTest runner 在启用桌面自动化阶段退出码 65，Appium 返回 HTTP 500；对应 xcresult：

`/Users/fengye/Library/Developer/Xcode/DerivedData/WebDriverAgentMac-clyajwgflvwhcfbrgcegpfwxhfib/Logs/Test/Test-WebDriverAgentRunner-2026.10.13_17-11-45-+0800.xcresult`

```text
The test runner failed to initialize for UI testing.
Underlying Error: Timed out while enabling automation mode.
```

只读命令 `/usr/sbin/DevToolsSecurity -status` 与 `/usr/bin/automationmodetool` 显示 Developer Mode 和 Automation Mode 均 disabled，且 Automation Mode 需要用户认证。诊断命令 `xcrun xcresulttool get test-results summary --path '/Users/fengye/Library/Developer/Xcode/DerivedData/WebDriverAgentMac-clyajwgflvwhcfbrgcegpfwxhfib/Logs/Test/Test-WebDriverAgentRunner-2026.10.13_17-11-45-+0800.xcresult'` 的摘要保存在 [wda-test-summary.json](p2-evidence/wda-test-summary.json)。没有更改系统设置、关闭认证或重复请求权限；本次没有创建可用 Appium session，因此没有 P2 目标窗口/控件树/操作前后截图、持久化读回、缺陷修复复测或停止期间输入阻断证据。Appium/WDA、样本进程和对应监听端口在失败后已停止或确认不存在；临时测试数据目录为空。原 P0 证据未覆盖，完整 Appium 日志仍保留在本机忽略目录 `build/p2_macos/appium.log`。

后续 Appium 服务归属测试实际启动了仓库内固定版本的 Appium 子进程，验证 status、会话枚举、PID 归属和关闭后的端口清理；这没有创建 WebDriverAgent/XCTest session，也没有绕过 Automation Mode。测试结束后没有遗留 Appium 监听。

## 规格对照和未闭合项

| 需求 | 当前结论 |
|---|---|
| 真实目标启动、窗口控件树、截图与几何、点击/输入/滚动/缩放 | 工具实现了受限调用与身份检查；本轮 Appium 会话在系统认证前置处失败，未现场验证这些操作。 |
| 候选冻结、ZIP 内 `.app` 身份与链接/执行权限、炸弹拒绝 | 真实 debug Flutter `.app` 完成包封装/解包测试；同 bundleId、损坏包、外链、摘要变化、压缩比/体积边界有隔离测试。未以运行中的产品工具启动并操作它。 |
| 每成员独立场景、真实模型决定与反馈、一个执行者修复、全员复测和交付一致 | 未运行隔离合成群或多成员独立模型配置；没有真实缺陷修复与复测记录，不能视为完成。 |
| 实际数据隔离 | 代码将运行目录传给 `CHAT_GROUP_TEST_DATA_DIR`，现有数据库路径实现和 macOS 凭据本地存储已做源码核对；由于目标 app 未启动，尚未从运行数据目录读回验证。环境变量不是 OS 沙箱。 |
| 停止、清理及资源锁 | 代码复用共享 desktop 锁和确认清理后释放；本轮没有活动 session 可验证取消竞争与迟到回包行为。单测不替代该硬件步骤。 |
| Appium 服务归属 | 开发仓库运行时已实现并单测验证启动、精确 PID/参数核验、外部占用拒绝、status/session 检查和关闭清理。该 Appium/Node 运行时位于忽略的 `build/p0_macos/runtime`，当前 `.app` 没有携带它；独立发布包未提供或验证该运行时，因此不能宣称发布版可直接使用 native.app。 |
| 系统边界 | 未安装系统依赖、未授予系统权限、未读取用户真实群聊/模型凭据，未发布或提交。路径允许访问不意味着目标程序受 macOS 安全沙箱限制。 |

## 本轮续作

- 修复了 `open` 失败后的清理路径：仅在 Appium session、目标进程和 WDA 端口均核实为空时关闭本运行器启动的 Appium；清理无法核实则保留桌面锁并返回暂停状态。
- 若创建 session 返回 HTTP 500，且只读 `automationmodetool -status` 明确显示 Automation Mode 关闭，`native.app` 现在返回带系统授权原因的 `paused/userActionRequired`，不继续让模型重试。未自动开启系统模式或再次触发授权提示。状态解析新增 1 条测试。
- `dart format`、`flutter analyze --no-pub`、`git diff --check` 通过；受管 Appium opt-in 测试 4 项通过（状态解析和暂停判定 2、Appium 启停/外部占用 2）；最终全仓串行回归退出码 0，3,827 完成、3,824 通过、3 跳过、0 失败。重新构建 Debug `.app` 成功，包身份仍为 `com.example.chatGroup` / `伴伴`，codesign 严格校验通过；端口 4725/10123 检查为空。
- 为确认 Codex 已有 UI 通道是否能作后备，曾启动一次仓库 Debug `.app`。它载入了默认本地首页列表；未继续点击、未进入聊天、未发起任务或读取消息正文和凭据。之后终止本次启动 PID，确认该进程退出。该探测没有验证 `native.app` 工具，且不是隔离启动，无法排除应用启动时自身写入普通运行状态；为避免扩大读取范围，未检查数据库内容。
- 当前 `automationmodetool -status` 返回 Automation Mode disabled 且需要用户认证；Codex UI 通道不能替代生产 Appium/WDA 会话，也不能证明候选操作收据。P2 现场验收仍未闭合。
- 2026-10-14 协议补充：`native.app` 的 open/observe/act 返回当前运行时 `sessionRef`；同一绑定下重复 open 可取回引用，方便在当前模型轮次间继续，并提示不确定动作先 observe。引用仅在当前 loop 模型上下文可见，不写入任务检查点。`AgentDecisionParser` 全文件 52 项通过，模型上下文短期可见/检查点剔除测试 1 项通过，静态分析通过。Mac2/XCTest 现场会话仍受系统认证阻塞。

此前回归还暴露过 S8 旧夹具缺少 P1 必需的逐成员使用场景和协调者决议。现已补齐各成员独立场景及协调者协议响应；产品夹具在没有原生操作能力时仅留下阻塞反馈，不能通过交付门禁。首次并发全量还出现一条私聊空回复兜底用例失败；该用例单独串行、P2 定向回归和最终串行全量均通过，未定位到对应的生产代码缺陷。

## 后续解除阻塞所需条件

需用户通过 macOS 自身认证开启 Automation Mode（用于当前 Mac 的 XCTest/Mac2 桌面自动化），并提供已隔离的合成群及各参与成员各自配置的测试模型；密钥应留在应用的本地配置入口，不贴入聊天。之后继续验证真实 `.app` 全操作、实际数据落点、修复前后版本绑定、停止清理和多成员交付闭环。独立发布包的 Appium/Node 运行时打包策略仍未验证。此报告不宣称 P2 产品验收通过。

## 用户确认的后续验收复查项

- 用户要求将影响范围留待后续验收时复查。当前记录为：P2 未通过不阻断普通 APP 开发、群聊或私聊；依赖 `native.app` 的 macOS 工作任务会因 Automation Mode 未开启而暂停，相关自主交付仍不能通过门禁。
- 后续验收时重新检查 Automation Mode、真实 Appium/Mac2 会话及 `.app` 多成员使用闭环，并确认独立发布包的 Appium/Node 运行时策略。复查完成前继续保持 P2 未通过，不把自动化测试结果当作现场验收。
