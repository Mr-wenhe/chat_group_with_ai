# 工作模式 AI Agent V1 全量 Review / 验收报告

**复核日期：** 2026-09-09（Asia/Shanghai）
**复核对象：** 工作模式 AI Agent V1 全部实现、测试、文档、macOS 产物与真实操作路径
**复核方式：** 需求追踪 + 源码逐层审查 + 自动化测试 + macOS Computer Use 操作验收
**结论级别：** V1 本地 macOS 可用；公开分发和 Windows 实机验收仍有明确前置条件

## 1. 执行摘要

本次不是只看测试是否变绿，而是按照需求 FR-01～FR-09、Stage 01～05 产物和代码质量清单，检查了正确性、失败路径、权限边界、持久化、上下文连续性、架构隔离、性能保护、兼容性和真实 UI。

当前结论：

- 没有发现 P0 或未修复的 P1 阻塞项；
- 工作模式定向测试 462/462 通过；
- Agentic、网页搜索、文档和多模态相关回归 359 项通过；
- 生命周期与恢复关键回归 8 项通过；
- 串行全量 Flutter 测试 1983/1983 通过；
- flutter analyze、macOS Debug/Release 构建通过；
- 修复后的 macOS DMG 已完成只读挂载、签名、架构、布局和敏感内容扫描；
- 历史 macOS 真实 CUA walkthrough 为 33/33 PASS；
- 本轮又用 Computer Use 启动当前 Debug App，验证全局面板跨路由、折叠、重新展开、隐藏入口和群聊导航；
- Windows 已做代码、策略和构建边界检查，Windows 实机 UI 尚未执行；
- Release 包目前是 ad-hoc 签名，未做 Developer ID 和公证，不能直接作为公开分发包。

因此，工作模式已经达到“个人本地开发/文档工作流可用”的 V1 水平；若要作为正式公开安装包，还需要完成真实模型 smoke、Windows 实机、签名公证和后续安全加固。

## 2. 审查范围

### 2.1 功能范围

1. 全局任务协调、同会话排队和全局并发上限；
2. 工作目录批量授权、重新授权、移除和重启持久化；
3. 文件列表、读取、搜索、文本/源码分析；
4. PDF、DOCX、XLSX 和图片分析；
5. 创建、Patch、重命名、删除、覆盖、快照和撤销；
6. 路径规范化、符号链接、冲突、哈希和资源锁；
7. 结构化命令、输出流、超时、取消、缺失工具和安装边界；
8. 角色显式 @ 路由、AI 自动路由、产品→开发→测试接力；
9. 连续追问、完成后修订、上下文压缩和会话隔离；
10. 无 Key 搜索、可见浏览器、登录/验证码/付费墙人工介入；
11. 非模态全局执行面板、流式事件、隐藏/折叠/恢复；
12. 事件日志、检查点、快照保留、数据清除和备份边界；
13. macOS Debug/Release App 和 DMG 交付安全；
14. 普通聊天、自动发言和私聊主动联系与工作模式隔离。

### 2.2 代码与文档范围

- lib/features/work_mode/**；
- lib/features/chat_group/chat_room_agentic_input_support.dart 及工作模式接入；
- 工作模式相关测试集合；
- 需求规格、技术设计、Stage 计划和 Stage 05 审查报告；
- macOS Release entitlement、Xcode 构建设置和 DMG 打包脚本；
- 仓库内真实 CUA 截图及 walkthrough 记录。

### 2.3 未扩大范围

本轮没有修改与工作模式无关的业务功能，没有读取或输出 API Key，没有执行 commit、push、reset、checkout 或清理用户已有文件。

## 3. 审查方法和事实基线

审查先读测试和验收证据，再回到生产实现核对调用链，最后用 Computer Use 操作 macOS App。判断标准是：测试通过只说明自动化用例通过；真实可用性还必须有实现路径、失败处理和 UI/磁盘证据。

核心事实基线：

- 需求规格：docs/work_mode_agent_v1_requirements.md；
- 技术设计：docs/work_mode_agent_v1_technical_design.md；
- 真实 CUA：docs/verification/work_mode_agent_v1_macos_walkthrough.md；
- Stage 05 安全/发布复核：docs/verification/work_mode_agent_v1_stage05_review_20260909.md；
- 本报告对应使用手册：docs/work_mode_agent_v1_user_guide.md。

## 4. 架构核验

当前生产链路如下：

    ChatRoomPage / DM
      → 工作模式输入和会话策略
      → WorkTaskCoordinator（全局所有权、FIFO、并发、检查点）
      → WorkRoleRouter（@ 优先、模型路由、确定性降级、接力）
      → WorkAgentLoop（决策、步骤预算、重试、暂停、恢复）
      → Workspace / Document / Command / Search / Browser 工具
      → Approval / Snapshot / Resource Lock / Event Store
      → WorkTaskOverlayHost（全局非模态面板和流式事件）

源码核验重点：

- 全局协调器和最大并发 2：lib/features/work_mode/work_task_coordinator.dart:120-196；
- 任务提交、追问、审批和恢复：lib/features/work_mode/work_task_coordinator.dart:267-476；
- 100 步、60 分钟和有限重试：lib/features/work_mode/work_agent_loop.dart:121-187；
- 多目录授权、读写设置和授权确认：lib/features/work_mode/work_folder_grant_service.dart:114-165,257-415；
- 写入审批和不可逆操作门禁：lib/features/work_mode/work_change_policy.dart:197-294；
- 结构化命令、shell 禁止、URL/路径/影响范围检查：lib/features/work_mode/work_command_policy.dart:256-351,859-1240；
- @、自动路由和阶段接力：lib/features/work_mode/work_role_router.dart:15-203,246-520；
- 有界脱敏事件和 JSONL 恢复：lib/features/work_mode/work_task_event_store.dart:47-170,220-300；
- 跨路由非模态执行面板：lib/features/work_mode/presentation/work_task_overlay_host.dart:23-244；
- 群聊输入、任务派发和上下文接力：lib/features/chat_group/chat_room_agentic_input_support.dart:17-347。

生产工作模式没有依赖 localhost bridge 才能读写目录；LocalAgentBridge 仅保留兼容入口、测试和旧实现面。

## 5. 需求追踪矩阵

| 需求 | 核验结果 | 主要证据 | 边界 |
|---|---|---|---|
| FR-01 全局文件夹授权 | PASS | folder grant 单测；批量确认、重启、目录外重新授权 CUA #1～#3、#8 | 授权是 App 级记录，不是 OS 强沙箱 |
| FR-02 文件读取和分析 | PASS | workspace/document 测试；目录、PDF、DOCX、XLSX、源码 CUA | 音视频不支持；图片需视觉模型 |
| FR-03 文件变更 | PASS | change/mutation/snapshot 测试；写入、删除、撤销、冲突 CUA #5～#10 | 二进制文件不做原地源码式编辑 |
| FR-04 终端命令 | PASS | command policy/runner 测试；结构化命令、输出流、超时和安装边界 | 不代填密码、登录、验证码或交互菜单 |
| FR-05 调度、并发和冲突 | PASS | coordinator、lock、lifecycle 测试；FIFO、锁等待和最多 2 个任务 CUA | 同一会话串行；不同会话才可能并行 |
| FR-06 上下文和持久化 | PASS | checkpoint/recovery/context 测试；重启手动继续、完成后修订 CUA | App 重启不自动续跑 |
| FR-07 搜索和浏览器 | PASS | keyless/browser 测试；搜索降级、可见浏览器、人工继续和来源追问 CUA #29～#32 | Windows WebView2 和网络环境会影响浏览器 |
| FR-08 设置 | PASS | settings widget/service 测试；多个目录、普通写入确认、保留期和配额 | 删除/不可逆操作的确认不可关闭 |
| FR-09 普通聊天隔离 | PASS | spec guard、session、chat integration 测试；普通/自动/工作/私聊 CUA #33 | 工作模式只对当前会话开关生效 |

## 6. 真实 macOS Computer Use 验收

### 6.1 已完成的 33 项 walkthrough

完整的 33 项操作在 docs/verification/work_mode_agent_v1_macos_walkthrough.md 中逐项记录了：

- 初始状态和输入；
- 可见 UI、任务事件和按钮；
- 磁盘前后状态或哈希；
- 截图绝对路径；
- 首次失败和修复后的复测；
- “未测”与“PASS”的明确区分。

最终状态为 **33/33 PASS**。关键路径包括：

- 一次批量授权多个目录，取消不落盘，重启后仍显示可用；
- 只读目录读取和完整结论；
- 普通写入审批、删除始终确认、快照撤销；
- 外部修改后的撤销冲突保护；
- 离开聊天页、隐藏面板后任务继续；
- 停止普通流式生成与停止工作任务的区分；
- 多个追问 FIFO、同一文件修订不改名；
- @ 路由、自动路由、本地降级和产品→开发→测试接力；
- PDF/DOCX/XLSX/源码、视觉模型和无视觉模型暂停；
- 结构化命令、缺失工具安装边界；
- API Key 搜索、无 Key 降级、可见浏览器人工介入、来源链接追问；
- 普通、自动、工作模式和私聊隔离。

### 6.2 本轮实时补充操作

本轮在当前 Debug App 上进行了补充 smoke，避免只依赖历史截图：

1. 启动 build/macos/Build/Products/Debug/chat_group.app；
2. 观察已有全局工作任务面板；
3. 从角色列表切换到设置页，确认面板不随路由销毁；
4. 点击折叠，确认底部“工作任务 n 项”入口仍在；
5. 点击任务条重新展开，确认任务标题、角色、步骤、当前动作和结论保留；
6. 点击隐藏，确认页面保留右下角任务入口；
7. 在面板隐藏状态进入群聊，确认群聊仍可操作；
8. 没有点击撤销、删除或新的写入，未改变用户项目文件。

对应可复核截图包括：

- docs/verification/evidence/work_mode_agent_v1/08_two_grants.jpg；
- docs/verification/evidence/work_mode_agent_v1/355_delete_completed_panel.jpg；
- docs/verification/evidence/work_mode_agent_v1/382_hide_panel_closed_after_run.jpg；
- docs/verification/evidence/work_mode_agent_v1/30_my_world_room_for_panel.jpg。

补充 smoke 只用于验证面板生命周期和跨路由承载；权限、写入、浏览器人工介入等完整行为仍以 33 项 walkthrough 和自动化证据为准。

## 7. 自动化、构建和产物校验

| 检查 | 结果 | 说明 |
|---|---|---|
| dart format --output=none --set-exit-if-changed lib test | PASS | 657 files checked，0 changed |
| flutter analyze | PASS | No issues found |
| flutter test --concurrency=1 test/work_mode --reporter compact | PASS | 462 项 |
| Agentic/Web/文档/多模态相关文件集合 | PASS | 359 项 |
| 生命周期与恢复关键回归 | PASS | 8 项 |
| flutter test --concurrency=1 --reporter compact | PASS | 1983 项，串行执行 |
| flutter build macos --debug | PASS | Debug universal App |
| flutter build macos --release | PASS | Release universal App |
| bash -n scripts/package_macos_dmg.sh | PASS | 脚本语法有效 |
| 打包脚本越权后缀、空格、shell 注入、已有文件覆盖测试 | PASS | 拒绝非法输入且无 marker |
| 新 DMG hdiutil verify | PASS | 容器校验有效 |
| 新 DMG codesign --verify --deep --strict | PASS | 通过 |
| 新 DMG 架构 | PASS | x86_64 + arm64 |
| 新 DMG entitlement 扫描 | PASS | 无 get-task-allow、network.server |
| 新 DMG 敏感内容扫描 | PASS | 无 API Key、Bearer token、Hive/JSONL/日志运行时文件 |
| 新 DMG 顶层布局 | PASS | 仅 chat_group.app 和 /Applications 链接 |
| git diff --check | PASS | 无空白错误 |
| spctl --assess | 预期拒绝 | ad-hoc、无 Developer ID/公证，不是代码回归 |

当前修复后 DMG：

- 文件：dist/macos/chat_group-1.1.0+1-stage05-20260909-macos.dmg；
- SHA-256：65a67937464b5e7bc1014524d222653eaf3951d16518e7e4d3d7a14aa0f8e007；
- 大小：26,994,458 bytes；
- entitlement：app-sandbox=false、network.client=true、files.user-selected.read-only=true、device.audio-input=true。

旧文件 dist/macos/chat_group-1.1.0+1-macos.dmg 仍保留作历史证据。它的容器校验有效，但内容属于修复前构建，仍含 get-task-allow 和 network.server，不能分发。

## 8. 代码质量和安全审查

### 8.1 已修复问题

#### P1：Release 包继承调试 entitlement（已修复）

- 证据：原 Release 构建包含 com.apple.security.get-task-allow；
- 修复：macos/Runner.xcodeproj/project.pbxproj:681 设置 CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO；
- 同时从 macos/Runner/Release.entitlements:5-12 移除不需要的 network.server；
- 复验：当前 Release App 和新 DMG 只保留四项必要 entitlement，codesign 严格验证通过。

#### P2：Stage 计划引用不存在的测试目录（已修复）

- 证据：原计划引用 test/document，而仓库无该目录；
- 修复：docs/superpowers/plans/2026-08-27-work-mode-agent-v1.md:754,857,1279 改为真实存在的文档/多模态测试路径；
- 结果：后续执行者不会再因错误路径得到伪失败。

#### P2：DMG 脚本被整体忽略且路径校验不足（已修复）

- 证据：scripts/* 原本被 .gitignore 忽略，且只检查 .app 后缀；
- 修复：.gitignore:99 增加脚本例外；scripts/package_macos_dmg.sh:20-40 限制安全后缀、拒绝越权路径和覆盖；:66-71 限制 App 名称为 basename；
- 结果：脚本可审计、可复现，攻击性输入被拒绝。

### 8.2 已接受的 P2 和后续优化项

#### P2：跨进程文件替换仍有 Dart I/O TOCTOU 窗口

Dart dart:io 可以在 App 内使用路径锁、独占临时文件、哈希和回滚，但无法为外部进程提供完整的 no-clobber 原子句柄语义。类型检查到 rename 之间仍存在窗口。当前按 V1 设计接受，见 docs/verification/work_mode_agent_v1_security_review.md:T24-R01。

#### P2：LocalAgentBridge 兼容面仍存在

LocalAgentBridge 仍出现在兼容入口、测试、旧文档和 bin/local_agent_bridge.dart 中；当前生产工作模式不依赖 localhost bridge。立即删除会扩大兼容变更面，暂保留并将进程启动设置为非 shell。见 T24-R02。

#### P2：部分 Dart 文件超过 500 行

扫描发现 23 个 Dart 文件超过 500 行，最大文件包括 agent_runtime.dart、work_task_coordinator.dart 和 default_work_task_runner.dart。新增复杂逻辑已抽出 support 文件；本轮没有进行高风险机械拆分。见 T24-R03。

#### P2：默认并发运行曾出现一次时序波动

一次默认并发全仓库执行出现记忆管理页面滚动恢复和授权计数两个时序失败；两个用例单独复跑通过，串行全量和工作模式定向测试均通过。当前采用串行全量作为验收基线，建议后续隔离全局 Flutter/Hive 测试状态。见 T24-R04。

### 8.3 五个审查轴的结论

| 维度 | 结论 |
|---|---|
| 正确性 | 任务状态、审批、失败分类、恢复和上下文路径均有生产实现与回归证据 |
| 可读性 | 新增复杂逻辑有 why 注释和 support 文件；历史大文件债务已登记 |
| 架构 | 协调器、Agent loop、策略、工具、事件和 UI 分层；普通聊天/自动聊天/工作模式隔离 |
| 安全 | 路径、符号链接、命令、URL、敏感文本、日志、凭据和 Release entitlement 有多层门禁 |
| 性能 | 文件读取、输出、事件、步骤和时长均有界；工作区采用按需读取，没有默认全量索引 |

## 9. 能实现到什么程度

### 9.1 现在可以放心使用的场景

**本地项目和文档工作流：** 可以授权一个或多个项目目录，让 Agent 检查源码、梳理需求、分析文档、生成文本交付物、修改明确文件并给出差异。

**连续工作：** 可以像和一个小型产品/开发/测试团队协作一样，在同一会话中先问、再修改、再追问、再验证。任务完成后不满意，可以继续修改原文件，保留上下文。

**可控自动化：** Agent 可以自动完成低风险读取和分析；写入、删除、安装、提交和不确定影响的命令必须让用户看到范围和原因。

**可见执行：** 用户可以随时看到角色、步骤、当前工具、审批、结论和错误；隐藏面板不会隐藏任务本身。

**无 Key 搜索兜底：** 没有搜索 API Key 时仍可尝试无 Key 网页或可见浏览器；遇到登录/验证码会暂停并交还给用户。

### 9.2 还不能替代的东西

- 它不是 OS 级沙箱，不能抵御已经被授权进程利用的恶意子进程；
- 它不是关闭 App 后仍无限运行的后台服务；
- 它不是完整 IDE，不能替代专业 PDF/DOCX/XLSX 二进制编辑器；
- 它不是密码管理器，不会自动填写密码、验证码或登录；
- 它不是音视频理解模型；
- 它不是已经完成 Windows 实机验收的发布版本；
- 它不是已公证的 macOS 公开分发包。

### 9.3 适用成熟度判断

| 场景 | 判断 |
|---|---|
| 个人 macOS 本地使用、开发和文档工作 | 可用 |
| 团队内部试用、受控目录和有人工审批 | 可用，建议先用新 DMG 并保留日志 |
| 面向公众的 macOS 安装包 | 有条件可用，需 Developer ID、公证和真实模型 smoke |
| Windows 普通文件工作流 | 核心可用性有代码依据，需 Windows 实机验收 |
| Windows 可见浏览器 | 依赖 WebView2 检测/安装路径，需实机验证 |
| 高风险无人值守生产自动化 | 不建议，V1 明确要求人工审批和重启后手动继续 |

## 10. 后续优化路线

### P0/P1 前的发布必做项

1. 使用真实模型凭据完成一次最小读、写、命令、搜索和视觉 smoke；
2. 为 macOS Release 配置 Developer ID、签名、公证和 Gatekeeper 验收；
3. 在 Windows 10/11 各至少完成一次安装、授权、读写、恢复、命令和可见浏览器验收；
4. 为发布说明明确 App 级保护、无后台自动执行和音视频不支持。

### V1.1 优先优化

1. 缩小跨进程文件替换 TOCTOU，评估原生原子文件句柄/平台 API；
2. 增加更强的事务日志、崩溃恢复和可审计任务历史；
3. 提供权限预览、差异查看器、按任务授权范围和更清晰的风险摘要；
4. 隔离测试中的全局 Flutter/Hive 状态，消除默认并发时序波动；
5. 清理 LocalAgentBridge 兼容面，完成迁移后再删除旧入口；
6. 拆分超长历史文件，保持每个 widget、策略和 runner 职责单一。

### V2 能力

1. 原生 function/tool calling 和模型能力诊断，减少 JSON 文本协议修复；
2. 任务搜索、导出、成本估算、预算和保留期可配置；
3. 大工作区可选增量语义索引，但仍以按需读取为默认；
4. 设计安全的伪终端，允许用户介入密码、登录和菜单；
5. 在明确的推送、隐私和权限方案后，再考虑 App 关闭时的主动任务；
6. 如果进入 App Store 沙箱，增加 security-scoped bookmarks 和更严格的 OS 沙箱。

## 11. 最终验收结论

工作模式 AI Agent V1 的核心目标已经实现：单 App、本地目录授权、可见流式执行、可控写入、连续追问、上下文记忆、角色路由、任务恢复和普通聊天隔离均有实现与证据。

本轮 Review 结论为：

- **功能验收：通过（V1 本地 macOS 范围）；**
- **自动化质量：通过；**
- **安全门禁：无 P0/P1 遗留，P2 已明确接受或登记优化；**
- **macOS 真实 UI：33/33 PASS，并补做当前 App 面板 smoke；**
- **发布包：新 DMG 校验通过，但需 Developer ID/公证后才适合公开分发；**
- **Windows：待 Windows 实机验收，不把静态检查写成 UI 通过。**

交付时应使用修复后的新 DMG，不应使用保留作历史证据的旧 DMG。
