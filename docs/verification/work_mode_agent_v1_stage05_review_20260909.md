# Work Mode Agent v1 — Stage 05 全量 Review / 校验

**复核日期：** 2026-09-09（Asia/Shanghai）
**范围：** Task 23–27：错误分类与恢复、安全/数据生命周期/备份边界、自动化回归、macOS CUA 证据、Release `.app` / DMG 打包。
**执行约束：** 遵守 Ponytail；保留用户已有未提交改动、历史失败证据和旧 DMG，不执行 reset、checkout、清理、commit 或 push。

## 结论

源码、定向测试、串行全量测试、格式化、静态分析，以及当前 macOS Debug/Release 构建均通过。已生成并验证修复后的 macOS DMG；Task 26 的历史 CUA 记录为 33/33 PASS；Task 27 的 Release 清单如实记录了无真实模型凭据时的限制。

历史文件 `dist/macos/chat_group-1.1.0+1-macos.dmg` 仍保留作证据，不能分发；已通过脚本的受限后缀参数生成新的修复产物 `dist/macos/chat_group-1.1.0+1-stage05-20260909-macos.dmg`。新 DMG 只读挂载后的 entitlement、签名、架构和敏感内容扫描均通过。

## 发现与修复

### P1 — Release 包继承调试 entitlement（已修复）

- **证据：** `macos/Runner.xcodeproj/project.pbxproj:681` 原 Release 构建设置继承了 `get-task-allow`；原构建签名中出现 `com.apple.security.get-task-allow=true`。
- **修复：** Release target 设置 `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO`；`macos/Runner/Release.entitlements:5-12` 移除不需要的 `com.apple.security.network.server`，保留客户端网络、用户选择只读文件和音频输入能力。
- **复验：** 当前 Release `.app` entitlement 仅含 `app-sandbox=false`、`network.client=true`、`files.user-selected.read-only=true`、`device.audio-input=true`；不再含 `get-task-allow` 或 `network.server`。`codesign --verify --deep --strict` 通过。

### P2 — 计划引用不存在的测试目录（已修复）

- **证据：** Stage 05 原命令引用 `test/document`，该目录不存在；原命令因此出现目标加载失败。
- **修复：** 在 `docs/superpowers/plans/2026-08-27-work-mode-agent-v1.md:754,857,1279` 改为仓库实际存在的文档/多模态测试文件，避免后续执行者重复得到伪失败。

### P2 — Release 打包脚本被整体忽略且缺少 app 文件名/输出路径校验（已修复）

- **证据：** `.gitignore:95-98` 原先忽略 `scripts/*`，导致 `scripts/package_macos_dmg.sh` 无法进入可复现审查范围；脚本只检查 `*.app` 后缀，未拒绝 `../x.app` 形式的构建元数据。
- **修复：** `.gitignore:99` 增加脚本例外；`scripts/package_macos_dmg.sh:20-40` 支持仅含安全字符的输出后缀并拒绝越权路径，同时拒绝覆盖已有文件或符号链接；`scripts/package_macos_dmg.sh:66-71` 要求 `.app` 文件名必须是 basename，防止构建元数据把复制路径带出 Release 产物目录。脚本仍使用 `mktemp -d`、精确 `trap` 清理。

### 文档同步问题（已修复为历史快照说明）

Task 24 安全报告、Task 25 测试报告、Task 26 walkthrough/progress 均保留了当时的执行边界；其中“未开始 Task 25/27”与后续产物容易被误读为当前状态。已在这些文档顶部增加历史快照说明，并在 Release checklist 标明当前 entitlement 修复与旧 DMG 边界；没有覆盖首次失败证据。

## 当前校验记录

| 检查 | 结果 |
|---|---|
| `flutter test --concurrency=1 test/work_mode` | PASS — 462 项 |
| Agentic/Web Search/文档/多模态实际文件集合 | PASS — 359 项 |
| 生命周期与恢复关键回归 | PASS — 8 项 |
| `flutter test --concurrency=1` | PASS — 1983 项 |
| `flutter analyze` | PASS — No issues found |
| `flutter build macos --debug` | PASS — `build/macos/Build/Products/Debug/chat_group.app`（修复后复跑） |
| `flutter build macos --release` | PASS — Universal x86_64 + arm64，约 63M |
| Release entitlement / `codesign --verify --deep --strict` | PASS — 无 `get-task-allow` / `network.server` |
| `bash -n scripts/package_macos_dmg.sh` / 安全后缀校验 | PASS |
| `./scripts/package_macos_dmg.sh stage05-20260909` | PASS — 生成修复后的新 DMG |
| `./scripts/package_macos_dmg.sh`（已有产物保护） | PASS — 按设计拒绝覆盖旧 DMG |
| 新 DMG `hdiutil verify` / 只读挂载签名检查 | PASS — `65a67937464b5e7bc1014524d222653eaf3951d16518e7e4d3d7a14aa0f8e007`，26,994,458 bytes；无调试 entitlement/凭据/实际运行时数据 |
| 新 DMG 顶层布局 | PASS — 仅 `chat_group.app` 与 `/Applications` 符号链接 |
| 旧 DMG `hdiutil verify` / 只读挂载签名检查 | PASS — 容器校验有效；内容确认属于修复前构建（含 `get-task-allow` / `network.server`），不可分发 |
| `git diff --check` | PASS |
| `dart format --output=none --set-exit-if-changed lib test` | PASS — 657 files checked, 0 changed |

## 未完成或需明确标注的验收边界

- Task 27 隔离 smoke 没有可用真实模型凭据，因此真实模型读/写、网络请求和 token 流没有声称通过；已验证授权边界、失败路径、面板和重启持久化。
- Release 产物为 ad-hoc、无 Developer ID、无公证票据；`spctl` 被 Gatekeeper 拒绝是预期限制，不能作为正式分发包。
- Windows 只有代码/静态边界，未声明 Windows 实机安装验收。
- Task 24 已接受的 P2 结构/环境边界保持不变：跨进程 Dart I/O 的 TOCTOU 风险、LocalAgentBridge 兼容测试面、若干 >500 行文件，以及默认并发下偶发的记忆页面时序波动；串行全量复测通过。

以上边界不构成 P0/P1 阻塞；应交付新 DMG，不应交付保留的旧 DMG。
