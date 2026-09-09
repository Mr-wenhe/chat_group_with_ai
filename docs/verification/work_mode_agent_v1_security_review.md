# Stage 05 / Task 24：工作模式 AI Agent V1 安全与生命周期审查

审查日期：2026-09-02
审查范围：V1 全部改动、测试、设置、迁移、事件、快照、搜索、可见浏览器、命令执行、备份/恢复及兼容入口。
审查状态：完成；未提交、未 push、未开始 Task 25。

> 本文是 2026-09-02 的 Task 24 基线快照，以上“未开始 Task 25”仅描述当日状态。Stage 05 后续的自动化、实机和 Release 结果以对应报告及 `work_mode_agent_v1_stage05_review_20260909.md` 为准，历史审查结论和首次失败证据保持不变。

## 1. 审查基线与范围

本次审查先读取并遵循：

- `AGENTS.md` 的 Review / 校验完整性规则和代码质量清单；
- `ponytail` 技能：优先复用现有能力、最小改动、保留安全/错误/数据丢失保护、对有意保留的能力上限写明原因；
- `docs/work_mode_agent_v1_requirements.md` 全部 V1 需求；
- `docs/work_mode_agent_v1_technical_design.md` 全部技术设计和验收矩阵。

审查覆盖以下边界：

| 区域 | 检查内容 |
| --- | --- |
| 工作任务内核 | `AgentTask`、V1 migrator、`WorkTaskCoordinator`、Agent loop、追问队列、角色交接、检查点和恢复 |
| 事件/快照 | JSONL 追加、快照 manifest、撤销、保留期/配额、清除 App 数据、符号链接和失败回退 |
| 授权/文件 | 全局文件夹授权、规范路径、敏感文件、外部修改、写入/删除/重命名和真实项目文件保护 |
| 命令 | 参数化进程、shell 元字符、工作目录/影响路径、取消、输出脱敏、legacy bridge 调用 |
| 搜索/浏览器 | API → 无 Key HTML → 可见浏览器优先级、URL/SSRF/网页不可信数据、搜索快照恢复 |
| 备份/恢复 | allowlist、API Key/凭据、绝对路径、快照/治理日志、ZIP 预检、staging、哈希、回滚和迁移 |
| UI/设置/测试 | 撤销与清数据文案、非模态执行面板、错误提示、普通聊天隔离、测试有效性和代码质量 |

## 2. 结论与分级清单

没有发现 P0 或未修复的 P1 阻塞项。审查期间发现的 P1 均已在本工作区修复，并用回归测试覆盖。仍保留的风险都是设计中明确记录的 P2：

| 等级 | 编号 | 发现、影响和证据 | 处置 |
| --- | --- | --- | --- |
| P0 | — | 未发现可导致任意目录删除、凭据外泄或无审批状态变更的阻塞路径。 | — |
| P1（已修复） | T24-01 | 清除 App 数据期间，正在结束的 runner 回调可能在事件/快照目录删除后重新创建日志，且可能把旧检查点写回。证据：原风险位于全局清理与 runner 异步回调交界。 | `WorkTaskCoordinator.stopAllForDataClear/resumeAfterDataClear` 进入维护态、暂停追加、取消并等待 active runs 和序列化尾栅栏；`_record`、checkpoint 和 snapshot 状态更新在维护态直接返回（`lib/features/work_mode/work_task_coordinator.dart:190-248,2021-2079`，`default_work_task_runner.dart:2222-2253`，`work_agent_loop_checkpoint.dart:134-140`）。 |
| P1（已修复） | T24-02 | 清除工作模式数据可能在任务未安全停止时部分清空 Hive 或 App Support，破坏恢复语义。 | 清理先停止任务，停止失败立即保留数据并返回；成功后才清事件/快照，最后释放维护栅栏（`lib/core/database/data_lifecycle_service_clear.dart:8-23,130-153`）。设置页在持久化目录已就绪时无法取得生命周期依赖则 fail-closed（`lib/features/settings/settings_page_lifecycle_support.dart:4-36`）。 |
| P1（已修复） | T24-03 | 可移植 `AgentTask` 曾可能携带授权绝对路径、审批/锁、工具结果、快照/治理证据或不透明旧操作文本；导入还可能信任攻击者构造的恢复字段。 | 导出/导入均采用 allowlist 和二次净化；只保留可重算的显示状态，丢弃本地能力和非便携路径；旧操作只保留脱敏 marker（`lib/features/backup/backup_entity_codec_memory.dart:267-371,391-459,477-517`）。本轮额外修复上下文 Map 键也必须脱敏（同文件 `:561-576`），并新增回归测试（`test/work_mode/work_mode_task_recovery_test.dart:274-294`）。 |
| P1（已修复） | T24-04 | 从备份恢复搜索快照时，持久化的 `safeMessage`、`retryable`、request id 或 hash 可能覆盖代码定义，造成敏感信息进入 UI/审计或错误重试策略。 | 恢复只接受失败 enum，重新生成安全文案和 retry policy；request id 规范化；非法原文 hash 丢弃（`lib/features/web_search/models/search_snapshot_models.dart:196-287`，`search_models.dart:242-259`，`search_failure_factory.dart:1-35`）。回归测试：`test/search_stage08_security_test_part_01.dart:407-426`。 |
| P1（已修复） | T24-05 | 备份源、staging、恢复目标、附件和快照树的符号链接/中间父目录可能把读写或删除导向用户项目外部；导出附件在源文件变化时可能产生不一致包。 | 所有关键路径使用 `followLinks:false` 和逐层父目录校验；ZIP 路径/条目/解压体积预检；附件复制前后 SHA-256/size 校验；临时文件独占创建，失败即停并回滚（`lib/features/backup/backup_inspector.dart:197-348`，`backup_exporter.dart:245-307,360-421`，`restore_executor.dart:270-349`，`work_snapshot_service.dart:1330-1433`）。 |
| P1（已修复） | T24-06 | 命令/错误/事件详情可能把 API token、URL、绝对路径或命令输出带入日志、面板或错误 toast；legacy bridge 的进程启动还未显式禁止 shell。 | 事件、命令和备份错误统一使用已有 scanner/sanitizer；生产命令及 legacy bridge 均 `runInShell:false`，参数化传递并限制环境（`lib/features/work_mode/work_task_event_store.dart:352-394,500-505`，`work_command_runner.dart:354-487`，`lib/features/agentic/tools/local_agent_bridge_server_support.dart:298-304`，`backup_models.dart:252-275`）。 |
| P1（已修复） | T24-07 | 撤销授权和清除 App 数据文案不清楚时，用户可能误以为会删除真实项目文件。 | 撤销文案明确“只停止 App 访问，不会删除目录或文件”（`lib/features/settings/work_mode_agent_settings_section.dart:306,320`）；清除数据明确只清理 App 内事件/撤销快照，授权目录真实文件不在范围（`lib/features/settings/settings_page_lifecycle_support.dart:133-145,235-245`）。 |
| P2（接受/后续优化） | T24-R01 | Dart `dart:io` 无法提供跨进程原子 no-clobber。恢复/manifest 替换在类型检查和 rename 之间仍有外部进程 TOCTOU 窗口；App 内已有路径锁、独占临时文件、哈希和失败回滚（`restore_executor.dart:287-313`，`work_snapshot_service.dart:1248-1297`）。 | 已在技术设计 4.4 明确记录为 V1 P2；后续可评估原生原子文件句柄/平台 API。当前不冒险引入新原生依赖，符合 ponytail。 |
| P2（接受/后续优化） | T24-R02 | `LocalAgentBridge*` 仍在兼容入口、测试、旧文档和 `bin/local_agent_bridge.dart` 中，共 23 个文件命中；V1 工作模式生产路径不依赖 localhost bridge，但删除会扩大兼容变更。 | 保留兼容 surface；已把 legacy 进程启动改为非 shell，生产 V1 继续走 App 内直接服务。后续清理兼容入口时再移除。 |
| P2（接受/后续优化） | T24-R03 | 代码质量扫描发现 23 个 Dart 文件超过 500 行，最大为 `agent_runtime.dart` 2933 行、`work_task_coordinator.dart` 2592 行、`default_work_task_runner.dart` 2266 行。大文件增加维护和审查成本，但本轮拆分会造成高风险大范围重排。 | 保留现状并登记拆分优化；本轮未做机械拆分，避免违反 ponytail 的最小改动原则。业务函数已按职责抽到 support 文件，新增复杂算法均有注释。 |
| P2（观察项） | T24-R04 | 一次默认并发全仓库运行出现 `memory_management_page_test.dart:1446` 滚动偏移和 `work_folder_grant_service_test.dart:347` 授权计数两个时序失败；两个测试单独复跑通过，串行全仓库和独立 `test/work_mode` 均通过，未形成稳定复现。 | 不把一次非确定性测试波动误报为产品安全缺陷；保留证据并建议后续隔离全局 Flutter/Hive 测试状态。最终验收采用串行全套结果。 |

## 3. 需求逐项核对

### 3.1 授权、事件、快照和清理

- 授权根目录仍是 App 全局能力，路径策略在工具层重新规范化并检查符号链接越界；Windows 比较使用大小写不敏感规范化。
- 事件写入路径为 `App Support/work_mode_agent/events/<taskId>.jsonl`，快照路径为 `App Support/work_mode_agent/snapshots/<taskId>/`，与设计一致（`docs/work_mode_agent_v1_technical_design.md:128-133`）。
- `clearAll` 只删除 App Support 的事件/快照树；no-follow 删除会删除链接本身，不会遍历链接目标（`work_task_event_store.dart:427-440`，`work_snapshot_service.dart:203-210,1420-1433`）。
- 全局清理在停止任务失败时不清 Hive、不清事件/快照；清理失败仍释放维护栅栏，便于用户重试而不会永久阻塞后续任务。
- 清除设置文案明确授权目录项目文件不在清理范围；测试覆盖真实项目文件内容仍保持不变（`test/work_mode/work_task_event_store_test.dart:221-248`、`work_snapshot_service_test.dart:560-583`、`data_lifecycle_ui_test.dart`）。

### 3.2 可移植备份边界

- `ApiConfig` 导出只写 provider/model/base URL 等非凭据元数据，导入强制 `apiKey=''`、`credentialId=''`、`hasCredential=false`；角色导入也清空 API Key（`lib/features/backup/backup_entity_codec_records.dart:12-33,35-97`）。
- `app_settings` 使用显式 allowlist；未列入的工作目录授权、治理 ledger、事件索引和运行时能力不进入备份（`lib/features/backup/backup_snapshot.dart:209-248`）。
- `AgentTask` 只携带可重算上下文；绝对路径、drive-qualified 路径、URI、`..`/`.` 段、快照路径、治理日志、审批范围、resource lock、工具结果和旧操作全文均被丢弃或脱敏 marker 化（`backup_entity_codec_memory.dart:267-371,391-420,477-576`）。
- 导入后二次净化阻止攻击者通过手工编辑 `.cgbak` 重新注入审批能力、绝对路径或工具结果；恢复后必须重新规划/重新审批。
- 导出 staging、备份检查和恢复均不跟随链接、限制 ZIP 条目/大小/膨胀比，并验证 manifest 与每个文件的 size/hash。

### 3.3 搜索、浏览器和命令

- 搜索失败分类与重试策略集中到 `search_failure_classifier.dart`；恢复快照不信任持久化文案、retry flag 或 correlation id。
- 搜索结果/网页正文被视为不可信数据，URL 校验、公开 HTTP(S) 边界和可见浏览器最终 fallback 仍由既有 provider chain 负责；本轮只修复恢复边界，没有另建搜索系统。
- 工作模式命令使用结构化 executable/arguments，所有生产 `Process.start/run` 明确 `runInShell:false`；测试覆盖 shell 元字符、绝对路径、符号链接影响路径和停止流程。
- legacy bridge 仅作为兼容测试/入口保留，启动同样禁止 shell；V1 工作模式生产路径不依赖 localhost HTTP bridge。

## 4. 本轮代码修改

1. `DataLifecycleService` 增加 work-mode stop / clear-artifacts / resume 回调；停止失败 fail-closed，避免部分清理。
2. `WorkTaskCoordinator` 增加全局清理维护栅栏、active-run drain、事件追加暂停和 late callback guard。
3. `WorkTaskEventStore`、`WorkSnapshotService` 增加 no-follow 父目录链检查、序列化清理、暂停/恢复 API 和安全删除。
4. 备份 codec/exporter/inspector/zip preflight/restore 增加 portable allowlist、导入后二次净化、秘密扫描、ZIP 限额、符号链接防护、复制后校验和安全错误展示。
5. 搜索快照恢复改为按 enum 重建安全失败信息、retry policy、request id 和 hash；增加统一 retry classifier。
6. 命令 runner 和 legacy bridge 明确关闭 shell，错误和事件详情统一脱敏。
7. 设置页区分“移除授权”和“清除 App 数据”的影响范围；新增上下文键脱敏回归测试。
8. `docs/work_mode_agent_v1_technical_design.md:135-140` 只记录了与实际实现不同的 Task 24 决策：清理维护栅栏、portable allowlist、no-follow/hash 校验、P2 residual TOCTOU 和脱敏文案；没有添加未实现的承诺。

## 5. 测试与工具证据

### 5.1 回归测试

| 命令 | 结果 |
| --- | --- |
| `flutter test test/backup_zip_preflight_test.dart test/backup_restore_service_test.dart test/work_mode/work_snapshot_service_test.dart test/work_mode/work_mode_task_recovery_test.dart test/work_mode/work_mode_data_clear_lifecycle_test.dart test/work_mode/work_task_event_store_test.dart test/backup_error_sanitizer_test.dart test/data_lifecycle_ui_test.dart test/memory_management_page_test.dart test/search_stage08_security_test.dart test/search_stage07_turn_context_test.dart --reporter compact` | 170 项通过；加入上下文键测试后的安全/生命周期定向集 126 项通过 |
| `flutter test test/work_mode --concurrency=1 --reporter compact` | **444 项通过** |
| `flutter test --concurrency=1 --reporter compact` | **1901 项通过** |
| 默认并发 `flutter test --reporter compact` | 一次运行出现 2 个时序失败（见 T24-R04）；两个失败测试单独复跑均通过，未发现稳定产品回归 |
| `flutter test test/memory_management_page_test.dart --plain-name 'returns from detail with search and scroll context intact' --reporter expanded` | 1 项通过 |
| `flutter test test/work_mode/work_folder_grant_service_test.dart --plain-name 'continues the first task after a picked folder is granted' --reporter expanded` | 1 项通过 |

测试有效性覆盖了：备份/恢复和 rollback、API Key 排除、可移植任务路径/能力边界、旧操作 marker、上下文键和值脱敏、事件/快照清理不触碰项目、父目录/文件符号链接、清理失败重试、命令注入和 shell 禁止、搜索快照不信任持久化 metadata、迁移和 Hive reopen。

### 5.2 静态和安全扫描

以下扫描在最终补丁（含上下文键修复）后重跑：

| 检查 | 结果 |
| --- | --- |
| 凭据模式扫描：`rg -n -i --glob '*.dart' --glob '!docs/verification/work_mode_agent_v1_security_review.md' "sk-|Bearer|AKIA|ASIA|AIza|BEGIN PRIVATE KEY|corpsecret" lib test docs` | 32 个命中，均为字段名、WeCom 代码或测试 fixture；未发现生产源码内置凭据。`git ls-files` 中 `data/api_configs.hive` 为 0，`.gitignore:15` 明确忽略。 |
| 进程/shell：`rg -n "Process\\.(start|run)|runInShell" lib/features/work_mode lib/features/agentic/tools` | 11 个生产调用点，`runInShell:true` 为 0；V1 runner 和 legacy bridge 均显式 false。 |
| symlink/TOCTOU：`rg -n 'followLinks:false|FileSystemEntity.type|isSymbolicLink|symbolic|TOCTOU|no-clobber' ...` | 65 个防护/说明命中；关键 App Support、staging、restore、附件和快照路径逐层 no-follow。跨进程 rename 残余按 T24-R01 记录。 |
| 原始日志：`rg -n "(^|[^A-Za-z])(debugPrint|print|logger|log)[[:space:]]*\\(" lib` | 仅 2 个非敏感命中：生成示例源码中的 `print` 和 debug-only bridge 注册提示；没有 V1 原始运行时输出日志。 |
| 临时标记：`rg -n --glob '*.dart' --glob '!docs/verification/work_mode_agent_v1_security_review.md' '\\b(TODO|TBD|FIXME)\\b|临时绕过' lib test docs` | 0 个命中。 |
| LocalAgentBridge 残留 | 23 个文件命中，均为兼容实现/测试/旧文档；无 V1 生产依赖链。 |
| 文件行数：目标 V1 目录 `find ... -type f -name '*.dart' | xargs wc -l` | 23 个文件超过 500 行；最大文件见 T24-R03。 |
| `flutter analyze` | **No issues found!**（5.5 秒） |
| `git diff --check` | **通过**，无空白/补丁格式错误。 |

扫描只报告数量和位置，不把测试 fixture 中的凭据样例写入本报告。

## 6. 代码质量逐项结论

- **正确性/边界/失败路径**：清理先停后删；事件是诊断数据，写失败不覆盖任务结果；快照失败在变更前阻止或要求确认；恢复按 transaction 回滚；错误路径保持可重试。
- **安全/数据处理**：生产工具层不信任模型输出；路径、URL、网页、命令输出、错误和备份字段均在边界重新校验/脱敏；API Key 和 credential id 不进备份。
- **注释**：复杂的生命周期栅栏、no-follow 父链、Windows 替换、Ponytail 有意上限和跨进程 residual 均写明 why；未发现需要补充的关键公共 API 注释。
- **命名/模块化**：新增类型名能表达职责；事件、快照、备份、搜索和命令逻辑分属 feature；未引入循环依赖。
- **硬编码**：V1 的 100 步、60 分钟、全局并发 2、30 天、2 GB 和输出/ZIP 限额均由模型/设置/策略常量承载；没有在业务函数中新增隐含凭据或 URL。
- **函数/文件长度**：新增函数保持单一职责；历史大文件债务按 T24-R03 登记，未作高风险大拆分。
- **性能/资源**：文件读取、ZIP 解压、哈希、快照和命令输出受大小/时间/条目上限；事件/快照写入串行化；面板使用流式事件；没有发现 UI isolate 上的新增无界全盘读取。
- **新老兼容**：V1 任务迁移只处理明确旧状态；备份同时识别 v1/v2；恢复 API Key 需要重新绑定；搜索快照旧字段按安全默认重建；普通聊天、自动聊天和私聊不进入工作任务调度器。

## 7. 未检查项与后续项

1. 当前环境没有 Windows 真实桌面运行时，无法完成 WebView2 缺失/安装提示和 Windows UI 的真实手工验证；平台分支、路径大小写、命令策略和 WebView service 单测已运行。macOS release 安装包/build 也未在本 Task 触发，避免把用户未要求的构建副作用带入审查。
2. 没有联网调用真实第三方搜索 API；搜索 provider 使用 fixture/本地 fake 验证安全边界，真实 API 可用性属于运行环境问题而非本地数据生命周期审查。
3. T24-R01 的跨进程 no-clobber TOCTOU、T24-R02 的兼容 bridge 清理、T24-R03 的大文件拆分和 T24-R04 的并发测试隔离均保留为后续优化，不阻塞本次 V1 安全结论。

## 8. 最终判定

Task 24 审查范围已完整执行；P0/P1 无遗留，关键安全/数据生命周期要求均有实现证据和测试证据。V1 可进入用户决定的下一阶段，但应在发布说明中保留“应用级限制不是 OS 强沙箱”、Windows WebView2 环境差异以及上述 P2 后续项。未执行提交、push 或 Task 25。
