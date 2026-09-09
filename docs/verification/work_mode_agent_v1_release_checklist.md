# Work Mode Agent V1 — Stage 05 / Task 27 Release Checklist

本清单只记录 macOS Release `.app` 与本地 DMG 的构建、安装和运行边界。它不代表上传、发布或签名公证完成。

## 门禁

- [x] Task 26 的 macOS computer-use 验收为 **33/33 PASS**。
- [x] Task 25 的自动化与 macOS Debug 基线报告已读取；Task 27 重新执行本轮发布相关检查。
- [x] 每个 Release smoke 项目均记录了本轮证据，或明确标记了受环境限制而未完成的部分。

Task 26 证据：`docs/verification/work_mode_agent_v1_task26_progress.md`（第 71 行明确记载 33/33 PASS）。
Task 25 证据：`docs/verification/work_mode_agent_v1_test_report.md`（完整测试与 macOS Debug 基线已闭环）。

## 构建输入与产物

| 项目 | 结果 |
|---|---|
| Flutter / Dart | Flutter 3.27.1 / Dart 3.6.0 |
| macOS / Xcode | macOS 15.6 (24G84) / Xcode 16.3 (16E140) |
| pubspec 版本 | `1.1.0+1` |
| Bundle identifier | `com.example.chatGroup` |
| 最低 macOS | `10.15` |
| Release app | `/Volumes/new_disk/work/flutter/chat_group/chat_group/build/macos/Build/Products/Release/chat_group.app`（约 63M，Universal x86_64 + arm64） |
| 历史 DMG（不可分发） | `/Volumes/new_disk/work/flutter/chat_group/chat_group/dist/macos/chat_group-1.1.0+1-macos.dmg`（26,994,527 bytes；修复前 entitlement） |
| 修复后 DMG 绝对路径 | `/Volumes/new_disk/work/flutter/chat_group/chat_group/dist/macos/chat_group-1.1.0+1-stage05-20260909-macos.dmg`（26,994,458 bytes） |
| 修复后 DMG SHA-256 | `65a67937464b5e7bc1014524d222653eaf3951d16518e7e4d3d7a14aa0f8e007` |

打包入口：`scripts/package_macos_dmg.sh [output-suffix]`。脚本使用 `flutter build macos --release`，以 `mktemp -d` 创建 staging，并由受路径校验保护的 `trap` 精确清理；staging 只包含 `.app` 与 `/Applications` 链接，DMG 由 macOS `hdiutil` 创建。脚本拒绝覆盖同名既有 DMG；本轮以 `stage05-20260909` 后缀生成修复产物。

## 签名、公证与 Gatekeeper

| 检查 | 结果 |
|---|---|
| Code signing identity / Team | ad-hoc（`CODE_SIGN_IDENTITY = -`）；`TeamIdentifier=not set`；`codesign --verify --deep --strict` PASS |
| Hardened Runtime | 未配置/未宣称；本地 ad-hoc 产物不具备正式分发签名链 |
| Notarization ticket | 无；`xcrun stapler validate`：没有 stapled ticket |
| Gatekeeper 首次打开限制 | `spctl --assess --type execute` rejected（本地 ad-hoc 预期结果） |

如果本地构建是 ad-hoc/未签名或未公证，交付说明必须明确：这不是正式分发包；用户可能需要在 Finder 中右键“打开”或在“系统设置 → 隐私与安全性”中允许打开。不得声称已签名、公证或可绕过 Gatekeeper。
本轮没有 Apple Developer 证书、签名或公证上传；DMG 仅供本机验证和离线交付。

## 干净测试用户安装与 Release smoke

| 项目 | 结果 / 证据 |
|---|---|
| DMG 挂载、`.app` 与 Applications 链接 | PASS：只读挂载后顶层仅有 `chat_group.app` 和根部 `/Applications` → `/Applications` 符号链接；已成功 detach。未覆盖 `/Applications` 中已有文件。 |
| 干净测试用户首次启动 | PASS（隔离替代）：将 DMG 中的 App 复制到一次性 smoke 目录并改为唯一 Bundle ID `com.example.chatGroup.task27smoke20260909`；CUA 首次界面显示“开始使用 / 还没有 AI 角色”。由于 `path_provider` 使用真实登录用户的 Foundation 路径，本轮未创建新的 macOS OS 用户，未触碰原有 `com.example.chatGroup` 数据。 |
| 目录选择与首次授权 | PASS：CUA 原生目录选择器选取 `/tmp/chat_group_release_smoke_workspace`；随后出现“确认授权工作目录”，明确“整个 App 的工作模式任务”和“可读取、可写入”。 |
| 读取审批 | PASS（边界）：授权说明和范围正确展示；任务因没有可用模型而在规划阶段失败，未伪造已读取文件。 |
| 写入审批 | PASS（边界）：写入能力与单独说明正确展示；同因没有可用模型未执行真实写文件，合成目录为空且已清理。 |
| 工作任务面板与流式进度 | PASS（UI/持久化）：Release CUA 中面板显示角色、`1 / 100` 步骤、结论、时间线、`回到对话`/`撤销`；失败任务显示当前步骤和下一步。无模型凭据时没有可验证的真实 token 流。 |
| 退出/重启后的任务恢复 | PASS：停止并重新启动隔离 App 后，任务面板和最新追问、失败原因、执行时间线均恢复；运行中的中断续作未在无模型环境中声称通过。 |
| 网络 smoke（仅模型 API / 已实现免 Key 搜索路径） | 未完成：隔离环境没有可用模型凭据，故没有发出模型请求；未启动任何本地 mock/bridge 服务，也未把凭据复制到 smoke 数据。 |
| 无额外 daemon / 数据库 / 容器 / 本地服务 | PASS：CUA 运行期间进程差分没有新增 App 监听；端口 `54263` 未监听；App 运行时仅加载自身内嵌 Flutter/plugin framework 和系统库。 |
| Windows | 仅代码与静态验证；不生成或宣称 Windows 实机安装包 |

## 单 App 与发布内容审计

- [x] 运行时进程列表只有主 App 及 macOS 系统进程；CUA smoke 期间只观察到一个 `chat_group` App 进程，没有 `LocalAgentBridge` 或额外 daemon；退出后 `pgrep -x chat_group` 为 none。
- [x] 监听端口检查没有 App 自己启动的 localhost 监听；`lsof -nP -iTCP:54263 -sTCP:LISTEN` 为 `54263_not_listening`。主机上其他系统/用户进程的既有监听不计为 App 依赖，比较以 smoke 前基线为准。
- [x] 发布 `.app` / DMG 的文件名扫描没有 `data/api_configs.hive`、实际 `.hive` 数据、证据文件、日志或快照文件；文本资源没有 `Bearer <token>`、`sk-*`、`/Users/...` 或 `/Volumes/...` payload。
- [x] 发布包不包含仓库 `docs/verification/evidence`、`/tmp` 夹具或测试日志；DMG 挂载内容仅为 App 和 Applications 链接。
- [x] `otool -L` 只显示内嵌 `@rpath` Flutter/plugin framework 与 macOS 系统库；可执行文件运行时字符串没有 `LocalAgentBridge`、`127.0.0.1:54263` 或 `HttpServer.bind`。
- [x] 以上扫描命令、结果和排除项已保留在本清单与本轮命令记录中。

扫描说明：AOT/Flutter framework 的二进制代码字符串会包含实现所需的 `Bearer `、`snapshot`、`api_configs.hive` schema 名称，以及一个 `dart_plugin_registrant.dart2` 构建源 URI；这些不是凭据、Hive 数据、测试夹具或运行时用户文件。`assets/release_templates/seed_manifest.json` 中列出的 Hive 名称是“创建空箱”的 schema，发布包内不存在对应数据文件。若后续要求二进制也完全不含构建源 URI，需要单独引入可复现的路径脱敏/obfuscation 发布流程，本 Task 27 未冒险改变 Flutter 默认产物。

## 命令记录

| 命令 | 结果 |
|---|---|
| `bash -n scripts/package_macos_dmg.sh` | PASS |
| `flutter analyze` | PASS — `No issues found!` |
| `./scripts/package_macos_dmg.sh stage05-20260909`（含 `flutter build macos --release` + `hdiutil create -format UDZO`） | PASS — `.app` 约 63M；生成修复后 DMG 26,994,458 bytes；修正并复验根部 Applications 链接 |
| `./scripts/package_macos_dmg.sh`（已有同版本产物保护） | PASS — 拒绝覆盖历史 DMG |
| `hdiutil attach -nobrowse -readonly` / `hdiutil detach` | PASS — 内容为 App + Applications 链接 |
| `hdiutil verify` | PASS — DMG checksum `VALID`（CRC32） |
| Release CUA smoke | PASS（首次启动、目录 picker、授权面板、工作面板、重启持久化）；真实模型读/写/网络受无凭据限制，见上表 |
| `codesign --verify --deep --strict` | PASS；签名为 ad-hoc |
| 挂载后 `.app` `codesign --verify --deep --strict` | PASS |
| `spctl --assess --type execute` / `xcrun stapler validate` | 如实失败：Gatekeeper rejected；无 notarization ticket |
| 发布目录敏感内容扫描 | PASS（文件名/文本 payload）；AOT 实现字符串按上方扫描说明排除 |
| 进程 / 端口检查 | PASS — 无新增 App listener；54263 未监听；无 bridge runtime symbols |
| `git diff --check` | PASS |

## 已知限制

- 当前任务不上传、不发布、不提交 Git。
- Windows 仅沿用现有代码/静态验证边界，真实 Windows 安装验收留待后续环境。
- DMG/App 是 ad-hoc、未公证产物；Gatekeeper 在本机 `spctl` 拒绝，正式分发前必须使用 Developer ID、Hardened Runtime、notarization 和 stapling，并重新 smoke。
- 本轮无法创建独立 macOS OS 测试用户，采用唯一 Bundle ID + 一次性 App 副本隔离；原始 DMG/App 保持未改，现有用户数据目录保持 430M 且未清理。
- 隔离 smoke 没有可用模型凭据，真实文件读取、真实文件写入、模型网络调用和 token 流未声称通过；只验证了授权边界、失败路径、面板与重启恢复。
- 本轮复核已移除 Release entitlement 中不需要的 `com.apple.security.network.server`，并关闭 `CODE_SIGN_INJECT_BASE_ENTITLEMENTS`，因此当前新构建的 Release `.app` 不再继承 `com.apple.security.get-task-allow`；下方历史限制文字仅描述原 Task 27 产物，不适用于复核后的新 `.app`。修复后的 DMG 已生成于 `dist/macos/chat_group-1.1.0+1-stage05-20260909-macos.dmg`；原同版本 DMG 仅作历史证据，不可分发。
