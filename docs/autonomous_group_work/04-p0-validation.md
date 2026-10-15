# P0 macOS 现场验证记录

日期：2026-10-13（Asia/Shanghai）。续验结论：**P0 在本机、自有可测试构建范围内通过。** AppKit 原生操作链及显式启用原生语义桥的 Flutter 样本均实际跑通。默认 Flutter 包和任意第三方应用仍未证明可操作；Flutter 3.27.1 内部属性与启动时序是明确限制，不能直接作为生产运行器。下文保留首次失败及续验发现。

原生 AppKit 样本已完成实际输入、保存、关闭重开、检出持久化故障、修复复测、窗口调整及会话清理。首次 Flutter 验证只有坐标点击，默认构建及 Dart `ensureSemantics()` 均不见业务树。续验通过原生桥激活的启动顺序对照，取得真实业务树并按控件点击；最终同一包连续两次冷启动均由 0 变为 1，包树摘要未变。未进入 P1。

## 首次验证范围和工作区保护

完整读取根目录 `CLAUDE.md`、`01-research.md`、`02-design.md`、README 和 `03-prompts.md` 的 P0 指令。检查起始 `git status --short`、全部已跟踪 diff 和工具注册/解析入口。原有六个已修改文件、提及候选测试及设计文档均保留，不改生产协作、权限、Hive、模型网关、备份或 UI。

新增范围：`tool/p0_macos/Sample.swift`、构建脚本、真实操作脚本、本记录及目标窗口证据。运行时、npm 依赖、样本构建和完整本地日志在被忽略的 `build/p0_macos/`；没有向全局 npm 或系统安装软件。npm 的本地安装会使用用户 npm 缓存，Xcode 会使用默认 DerivedData。这些目录不是操作系统沙箱。

`rg` 检查的生产落点为 `default_work_task_runner_tools.dart`、`work_tool_registry.dart`、`agent_decision_parser.dart`、`features/agentic/tool_request.dart`、macOS Runner 配置及 `database_service.dart`。没有找到已注册 Mac2 工具，所以没有假设 README 所述能力已存在。P0 脚本不注册生产 tool、不增加 JSON/settings/Hive 字段，无调用方、checkpoint、导出恢复或生命周期迁移变更。

## 环境实测

| 项目 | 实际结果 |
|---|---|
| OS / 架构 | macOS 15.6，24G84，arm64 |
| Xcode | 16.3，16E140，`/Applications/Xcode.app/Contents/Developer` |
| Swift | 6.1，目标 arm64-apple-macosx15.0 |
| Flutter / Dart | 3.27.1 / 3.6.0，Engine cb4b5fff73 |
| Node / npm | 24.14.1 / 11.11.0 |
| 初始 Appium | PATH、全局 npm 和检查的本地安装目录无 Appium |
| 本次本地依赖 | Appium 3.8.0、Mac2 4.4.0，固定直接版本；npm lock 在本地 runtime |
| Developer mode | `DevToolsSecurity -status` 返回 disabled；未修改 |
| Automation Mode | disabled，要求系统认证；未禁用认证或执行自动修复 |
| Mac2 doctor | 0 required fixes；认证和 ffmpeg 为 optional 提示；未安装 ffmpeg |
| 实际 XCTest | WDA TEST BUILD SUCCEEDED；实际成功建立 Mac2 会话 |
| 权限 | 当前 XCTest 能操作样本；未读取 TCC 数据库，不能据此声称所有进程/应用均获授权 |

Appium 仅监听 `127.0.0.1:4725`，WDA 请求配置为 `127.0.0.1:10123`。未启用 insecure shell、prerun/postrun、屏幕录像或远程上传。系统认证保持开启；doctor 的关闭认证建议没有执行。WDA 在日志中报告 `localhost`，未单独采集运行期间所有监听地址，不据此保证 WDA 的监听实现仅绑定 loopback。

## 首次实际执行与结果

| 要求 | 结果与证据 |
|---|---|
| 合法 bundle | 两版 Swift 编译、Info.plist lint、执行位、签名 verify 均通过，`build-{bug,fixed}.log` |
| 正确 appPath / bundleId | `com.chatgroup.p0.sample`；每次截图关联 `*-process.txt` 核对完整执行路径 |
| 控件树 | `p0-note`、`p0-save`、`p0-result`，`bug-before.xml` |
| 目标截图 / 校准 | 元素截图限定 `p0-window`，560×348 points 对应 1120×696 pixels，2× |
| 实际输入 / 点击 | WebDriver element click / clear / value / click；`*-actions.json` 和前后页图 |
| 业务与持久化 | 故障版显示保存成功，但重启后内容为“错误：内容未持久化”；工具读取文件与 UI 值一致，`bug-result.json` |
| 修复与复测 | 编译时关闭 P0_BUG；显式终止旧包，另建固定 appPath 的会话；重启后正确恢复 `P0-fixed-重启核对`，`fixed-result.json` |
| 两版身份不同 | bug SHA-256 `0c04368f5b7f98efaab3185fdf5c9399d49127017a7298272e0708af29345590`；fixed `10c5f4dd469ce867587d89bb93ed9851149361f632fa38ecce5de1e86db67619` |
| 实际窗口调整 | Mac2 clickAndDrag 右下角；560×348 → 660×428，2×；`fixed-resized-geometry.json` |
| 暂停 | P0 脚本发送前守卫拒绝动作，实际请求数未增加、便签摘要未变；`control-result.json` |
| 停止 | terminateApp + DELETE session，核对目标进程退出；没有测试生产协调器暂停/停止 |
| Flutter 构建 | 官方 `flutter create` counter 样本，独立 bundleId `com.chatgroup.p0.p0Flutter` |
| Flutter 控件树 | 默认和 Dart `ensureSemantics()` 两种构建均只有窗口/空 group，未通过 |
| Flutter 交互 | 根据 800×628 points / 1600×1256 pixels 校准，Mac2 点击全局 (1316,816)，计数 0 → 1；人工视觉核对前后图，未伪造树断言 |
| 清理 | Flutter terminateApp 返回 true、session 删除、目标进程退出；Appium SIGINT 后退出，随后 ps/lsof 未发现本轮 WDA/xcodebuild 或 10123 listener |

样本仅通过显式 `P0_DATA_DIR` 写 `build/p0_macos/data/note.txt`，不使用 UserDefaults 或 Application Support。Flutter counter 无持久化和网络。未启动现有伴伴 App，未访问现有聊天或凭据。

暂停证明限于本次串行现场脚本的发送前守卫；不证明生产任务取消、在途请求抢占、跨任务桌面锁或用户抢焦点已经实现。恢复未盲重放不确定副作用，故障和修复是独立明确操作。

## 命令与复现

从仓库根目录执行，需 macOS GUI 登录会话及当前用户 XCTest 权限：

```bash
sw_vers
uname -m
xcode-select -p
xcodebuild -version
xcrun swift --version
/usr/sbin/DevToolsSecurity -status
/usr/bin/automationmodetool
mkdir -p build/p0_macos/runtime
npm install --prefix build/p0_macos/runtime --save-exact appium@3.8.0 appium-mac2-driver@4.4.0
```

注册和预检（工作目录 `build/p0_macos/runtime`）：

```bash
APPIUM_HOME="$PWD/appium-home" ./node_modules/.bin/appium driver install --source local "$PWD/node_modules/appium-mac2-driver"
APPIUM_HOME="$PWD/appium-home" ./node_modules/.bin/appium driver doctor mac2
```

回到根目录，构建并启动服务：

```bash
bash tool/p0_macos/build_sample.sh bug
bash tool/p0_macos/build_sample.sh fixed
APPIUM_HOME="$PWD/build/p0_macos/runtime/appium-home" build/p0_macos/runtime/node_modules/.bin/appium --address 127.0.0.1 --port 4725 --log "$PWD/build/p0_macos/appium.log" --log-no-colors
```

通过 `POST /session` 创建 W3C 会话：platformName=Mac，automationName=Mac2，appPath 为故障包绝对路径，bundleId=com.chatgroup.p0.sample，environment.P0_DATA_DIR 为独立测试目录绝对路径，systemHost=127.0.0.1，systemPort=10123，noReset=true，serverStartupTimeout=60000。不要省略 appPath/bundleId；不要 attach 默认 Finder。响应存入 `build/p0_macos/session-response.json`，执行：

```bash
python3 tool/p0_macos/exercise_sample.py bug
```

使用 Mac2 `macos: terminateApp` 终止故障包、DELETE 旧会话；将 appPath 改为 fixed 包另建会话，响应保存到同一路径，再执行 `python3 tool/p0_macos/exercise_sample.py fixed`。脚本必须由操作者建立正确会话，不自动接管其他会话；重复运行会覆盖本次同名证据，请先归档目录。固定版脚本自动完成 resize、暂停检查、终止与删除会话。每次请求 timeout=30s；这不是累计任务预算。

Flutter 复现：`flutter create --platforms=macos --org com.chatgroup.p0 --project-name p0_flutter build/p0_macos/flutter_sample`，在样本目录 `flutter build macos --debug`。先按实际 plist bundleId 和完整构建 appPath 建 Mac2 会话，GET source 只保留目标窗口子树。第二次在生成的 main.dart 的 runApp 前加 `WidgetsFlutterBinding.ensureInitialized().ensureSemantics();`，重新构建、终止旧进程并启动新会话，仍无业务控件树。点击前须重新核对窗口坐标/尺寸/截图与目标进程；本次的硬件坐标不可直接用于另一台设备。

完整 Appium 日志可能带系统菜单/最近项目，只留本机 build 目录，不作为提交证据。`p0-evidence/` 只含目标窗口子树/图片、受限请求、结果和摘要清单；没有桌面截图。截图已真实查看，保存/重启/调整的目标内容与结果一致。证据文件 SHA-256 清单用于发现改动，不是可信收据注册，更不是产品门禁。

## 首次发现和后续调查方向

1. **阻塞**：Flutter 3.27.1 默认以及仅开启 Dart semantics 时，Mac2 不见业务树（`p0-evidence/flutter-before.xml`、`flutter-semantics-before.xml`）。本次只证明坐标点击；需要继续验证原生 accessibility 激活与树桥接，再验证真实关键交互。不能用原生样本或 smoke test 替代。
2. **未实现**：生产暂停/停止和全局桌面锁未接 Mac2。P0 守卫只在独立脚本里；P2 必须复用协调器和资源锁验证在途取消与清理，不直接把此脚本当生产运行器。
3. **隐私边界**：Mac2 全量 source 含系统菜单和最近项目；观察必须在进入模型/持久证据前投影到目标窗口。此次初始 source 已改存目标子树，完整调试日志不提交。
4. **旧包风险**：现有 Release/chat_group.app 的 plist 为 com.example.chatGroup，当前产品配置已名“伴伴”；不能把旧包当本轮构建。实际数据库 `_getDataDir()` 使用 Application Support，与 CLAUDE 的非 release 数据目录概述有差异；本次未修改规则或数据服务。
5. **已修复**：macOS Bash 3 在 `set -u` 下展开空 flags 数组失败；fixed 构建改为显式 P0_FIXED flag，重建成功，非法 variant 自检返回 2。
6. **操作失误已收尾**：一次 Flutter rebuild 在仓库根目录发起，随后中止并在独立样本目录重跑；未启动其产物，git status 的生产源码改动与开始时一致。其日志移入本地 build 目录。
7. **会话限制**：一次观察在默认 newCommandTimeout 后返回 404；重新建立明确目标会话（300 秒空闲时限）后完成点击，无副作用盲重放。这是会话空闲期限，不是任务累计上限。

下一项可执行调整是用 Accessibility Inspector 或经用户授权短暂开启 VoiceOver，核验原生 accessibility 激活后 Flutter 业务树是否出现。未进行系统辅助功能设置变更，不扩大权限、不关闭认证。Engine 固定版本的源码显示原生 accessibility 状态参与语义桥接；这只是调查依据，不是此机验证结果：[Flutter Engine cb4b5fff73](https://raw.githubusercontent.com/flutter/engine/cb4b5fff73/shell/platform/darwin/macos/framework/Source/FlutterEngine.mm)。Mac2 前置和版本范围参考[官方 getting started](https://github.com/appium/appium-mac2-driver/blob/master/docs/getting-started/index.md)。

## 首次校验范围与限制

已执行：两个真实 Swift 构建及签名/执行位/身份自检；真实故障与修复操作断言；固定包进程路径检查；非法 variant 断言；`bash -n`；Python 编译检查；独立 Flutter `flutter analyze` 无问题，`flutter test --timeout 30s` 1 个 counter smoke test 通过（约 5 秒）；`git diff --check`；新增实现审查和 P0 逐项规格对照。没有 Hive/model 变更，未运行 build_runner。质量清单已按 P0 范围核对：样本与脚本独立、无第二执行循环、无凭据处理、无生产接口变更；图像证据可追溯，系统沙箱限制明确。

未检查：真实 chat_group `.app` 的控件/交互、业务树问题的系统辅助功能调整、生产桌面锁/焦点夺取/在途取消、权限撤销与迟到写回、真实成员模型操作反馈、所有文档页图和视觉模型、GitHub 技能、P1–P5、全仓 Flutter 测试和生产静态分析。现有 counter 单测仅证明样本逻辑，不能证明原生树或群协作验收。没有发布、系统安装或第三方程序沙箱证明。

## 续验：Flutter 原生语义桥

用户回复“那继续P0”后，按上轮提出的具体范围短暂开启 VoiceOver。通过系统设置读到初始 off、切换 on、完成首次“使用旁白”提示，并确认真实 VoiceOver 进程运行。样本激活、重启和运行中重新开启后，Mac2 及独立 AX 读取仍只有窗口外壳。随后恢复 off，未改“不再显示”选项。已安装的 Accessibility Inspector 也限定检查 p0_flutter；结束后关闭本次启动的 Inspector 和系统设置，未安装新软件。

只读诊断取得原生 engineGetterAvailable=true、engineSemanticsEnabled=false、内容 group 子节点为 0。直接在 awakeFromNib 中将内部开关设为 true、同时提前开启 Dart `ensureSemantics()`，仍无业务树；这份失败保留为 `engine-bridge.json`、`bridge-ready.xml`。改变启动顺序后成功：移除样本里的 Dart 强制语义句，待原生引擎启动后启用其语义桥，Mac2 取得真实按钮、说明文字和数值节点。

这支持“该版本的语义桥与启动顺序需要调整”，尚不足以证明默认 Flutter accessibility 的全部失败原因。没有给空 group 补造节点、没有通过源码或计数模型代替真实树、没有在测试脚本直接改 counter 状态。第一次成功后的真实 element click 使树中数值由 0 变 1，截图也实际显示 1。

最终可复现样本采用 `tool/p0_macos/FlutterBridgeWindow.swift`，以显式环境标记 `P0_ENABLE_NATIVE_SEMANTICS=1` 开启一次原生桥激活。使用的 `setSemanticsEnabled:` 是该 Engine 内部接口；样本固定等 3 秒是现场验证便利措施，**不是生产就绪握手**。未修改仓库 Runner 或生产功能。P2 必须重验版本、实现就绪观测与能力门禁；不得把此代码无条件用于默认包或第三方应用。

## 续验命令与实际结果

在已生成的独立 Flutter 样本目录，确保 main.dart 不含提前调用的 `ensureSemantics()`，执行：

```bash
cp /Volumes/new_disk/work/flutter/chat_group/chat_group/tool/p0_macos/FlutterBridgeWindow.swift macos/Runner/MainFlutterWindow.swift
flutter build macos --debug
flutter analyze
flutter test --timeout 30s
```

续验样本 DebugProfile.entitlements 的 app-sandbox 值改为 false，对齐仓库当前 macOS 构建；默认模板的 true 与最终构建是不同条件。仅改独立样本，没有改变系统安全设置或生产签名配置，也不宣称测试程序已被操作系统隔离。最终构建的 codesign deep/strict 核验成功。

使用前述本地 Appium 启动命令，并从仓库根目录运行：

```bash
python3 tool/p0_macos/exercise_flutter.py
```

| 检查 | 实际结果 |
|---|---|
| Flutter build | 最终真实 debug `.app` 构建成功，`flutter-final-build.log` |
| Flutter analyze | No issues found，约 1.5 秒 |
| Flutter 单测 | counter smoke test 1 个通过，约 2 秒，单例 timeout=30s |
| 两次独立冷启动 | 每次完整 appPath/bundleId 启动，真实业务树 0 → element click → 1 |
| 候选一致性 | 开始/结束完整 bundle 树摘要相同：`28138547797f4589003b35731d1bf758808fa5241b072d15bf9e21aeaa14f957` |
| 运行身份 | 每次前后保存真实进程完整路径，并与最终样本路径核对 |
| 真实页图 | 两次 before/after 都有目标窗口 PNG，after 图均实际核对为 1 |
| 原生暂停复测 | 用实际有效 p0-save 元素的请求验证发送前拒绝，非请求一个本来无效的元素；文件摘要不变 |
| 原生修复复测 | 再次真实保存、关闭重开、正确恢复；窗口调整仍成功 |
| 清理 | 每次终止目标进程、删除会话；最后 Appium SIGINT，ps 和 lsof 未见本次样本、WDA、xcodebuild 或 4725/10123 listener |

新增 Python 均 AST 语法检查通过，Bash `-n`、`git diff --check` 通过；Swift 最终源由真实构建校验。逐项检查 P0 需求、调用范围、失败路径、证据有效性、安全边界及质量清单。未改 Hive/JsonSerializable，无 build_runner 要求。原有生产 diff 仍为六文件 49 插入/8 删除；本轮新增仅 P0 样本/脚本/记录/证据。

## 续验全部发现与限制

1. **路线限制**：最终通过的是自有、显式可测试构建。默认包、仅 Dart 开启语义、单纯 VoiceOver 开启和早期原生开关激活均未解决业务树问题。不能把样本结果扩大为 Flutter 全版本或任意第三方 App 可用，也没有做 SDK 升级。
2. **生产前必须调整**：样本的内部属性和固定 3 秒延时必须经过版本预检与就绪观测；本次无第二执行循环或生产工具注册。串行脚本不等于生产桌面锁、焦点保护、在途取消、删除闸门已实现。
3. **真实异步观察**：第一次冷启动脚本在 click 后立即断言数值 1 失败。改为有界读取当前真实树，等待达到 1 后取截图；同一场景始终只点一次。原失败日志保留，不将等待后的结果回填为首次通过。
4. **WDA 清理边界**：两次会话创建曾返回 500，提示 10123 busy；后续核验该 listener 消失后重新创建成功。Mac2 在参数不同时可能重建共享 WDA（源码 `hasSameOpts` 包含 showServerLogs/host/port/root），运行器不能只看到 DELETE session 成功就释放设备资源，必须核对所管理服务/进程和端口。未对未知占用者发送 kill。
5. **旧会话拒绝**：一次会话创建失败后，诊断命令仍读到旧 session-response，GET source 返回 404，未到达点击。随后改为建立成功后才执行依赖脚本。记录该操作失误；旧 response 不授权新操作。
6. **文件 I/O 阻塞**：读取诊断时，样本主线程阻塞于 `Data.write` → `open_dprotected_np`，另一个 XCTest snapshot 线程等待主线程，导致 30 秒 source timeout。堆栈保留于本机；不能凭此断言全部由 App Sandbox 或 TCC 引起。核对本轮样本 PID 后 SIGTERM 收尾，改用 `/private/tmp/chat-group-p0-*` 专用目录取得只读诊断，无磁盘权限扩张。最终样本移除了诊断文件写入。
7. **额外输入法授权**：结束时系统设置出现“允许 testmanagerd 启用搜狗拼音”的提示，已选择“不允许”，未授予输入法读取键入内容的新权限。不能将 XCTest 输入法设置流程当作任务的一般授权入口。
8. **系统恢复**：旁白开始为 off，结束恢复 off；最后 ps 未见 VoiceOver。Inspector 和本次打开的系统设置已关闭。Developer mode 和 Automation Mode 仍按实际只读检查记录，没有运行关闭认证的命令。
9. **未检查项**：生产 chat_group 本身的关键控件和业务交互、不同 Flutter Engine/发行模式、VoiceOver 树失败的完整原因、生产桌面锁/焦点/在途取消、所有成员模型、文档渲染、GitHub 技能及 P1–P5；未跑全仓静态分析和全量测试。独立 counter 的 analyze/单测不是产品验收。

新增受限证据位于 `p0-evidence/continuation/` 和 `p0-evidence/flutter-repeat/`，完整本地日志仍在 build 目录。SHA-256 清单已读回核验，图像未包含无关桌面。续验结束保留真实文件和证据；只关闭本轮目标会话/进程。下一阶段可在这个受限可行性基础上推进状态合同，P2 仍需解决上述生产就绪限制，不能把 P0 脚本当交付门禁。
