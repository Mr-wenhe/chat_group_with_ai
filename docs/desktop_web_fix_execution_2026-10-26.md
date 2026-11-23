# 智谱优先与四种模式修复执行记录

## 已确认需求

- 圆桌保持智谱检索及讨论流程；开场与后续成员均禁止自主联网；修复来源不符、摘要失真和显示残留。
- 仅智谱新闻角色仅使用智谱。普通私聊、群聊开启智谱时先查智谱，再允许自主补查、读取和下载；关闭智谱时仍可用自主工具。
- 普通私聊、普通群聊、私聊工作、群聊工作均验证真实搜索→读取→原文件下载→附件可打开。
- 按用户 2026-11-20 最新范围验收四个独立配置：deepseek v4.1 / `deepseek-flash`、SenseNova / `sensenova-6.8-flash-lite`、截图中的 `maritaca / S5-free`、`qiniu / qiniu/conatus-free`。商汤5.2 / `deepseek-v4-flash` 按 DeepSeek 别名记账，不独立验收；旧名 StepFun 角色映射 Qiniu。跳过 Oray，不调用其 Key。
- Windows 保留完整实现与跨平台检查，本轮无实机验收；不提交、推送或发布。

## 进度（验收闭环完成；失败项按实保留）

已通过新增失败回归复现并修复：

1. `SearchContextFormatter` 的 Dart `replaceAll(..., r'$1')` 把捕获引用当字面量，产生 `$1` 残留。改为真实捕获内容；测试同时保留段落、链接及标点。
2. 有效文档合同可缺少可选 `files`，制作基线却强制转 List。统一解析已确认单文件位置并复用于变更检查和发布；位置不明则澄清，已有候选审查不被新制作门禁拦截。
3. `unchanged` 命中了无词边界的 `change`，把新建原文件下载误判为旧文件修订。回归使用实际请求复现，修订动词改为完整英文词。
4. 仅 QA 编号、`test workspace` 不再触发仅测试报告写入限制；实际测试报告任务继续受限。
5. 圆桌及仅智谱新闻角色的自主工具资格收口，主动私聊复用资格判断。
6. 智谱摘要补充官方来源、日期、主题及链接约束；圆桌开场只总结相关证据，资料不足时不得补造最新事实。
7. 搜索失败不再显示无效的“点击查看诊断”操作；类型异常转换为可理解文案；讨论/启动失败释放槽时保留其他任务所有权。

后续回归已覆盖圆桌与新闻角色工具资格、普通/主动回复路由、S3 工作讨论上下文、来源呈现、联网工具协议、读取/下载失败映射，以及任务取消、重启恢复、接力和附件重发。2026-11-17 的记录分别列出定向结果：路由/协议与来源组 60 项、主动私聊与工作路由组 234 项、搜索质量回归组 77 项、联网与读取下载组 61 项；这些分组存在交叉，不合并为总数。最新九文件路由/主动回复/工作权限联合回归 274 项通过。附件交付生命周期 11 项通过；智谱失败上下文进入自主搜索流的衔接回归也已通过（`network_reply_stream_test.dart` 整文件 20 项通过，搜索结果使用测试替身）。本轮重跑 `flutter analyze` 无问题；自动聊天调度、联网回复流/治理网关、聊天流定向回归共 83 项通过；当前工作树的 macOS Debug 隔离构建通过，产物 `build_qa_web_current_20261117/macos/Build/Products/Debug/伴伴.app`，版本 `2.6.1+15`。详细回执见 `docs/desktop_web_ui_acceptance_2026-10-26.md` 末尾。Windows worker 的运行时打包、可执行格式和路径规则静态检查通过；没有 Windows 实机验收。

原四配置普通私聊的历史结论与回执详见 `docs/desktop_web_ui_acceptance_2026-10-26.md`：商汤5.2 为 HTTP 429 `insufficient_quota`；deepseek v4.1 有搜索/读取信息，但 raw 读取为 `SOURCE_HTTP_ERROR`、下载为 `NETWORK_TOOL_FAILED`；StepFun 为 HTTP 400、没有有效订阅；SenseNova 模型请求成功但只输出 1/6 token，未产生工具回执。前三条现仍计失败的是商汤、deepseek v4.1 与 SenseNova；StepFun 已移出当前矩阵。失败不代表模型不支持。没有本轮界面复验时，不升级为通过。

最新复核（2026-11-17 17:49–17:56 CST）：17:41 源码通过 `flutter analyze`；生命周期、流取消/看门狗/页面可见性和自动聊天调度相关回归共 20 项通过。当前工作树 macOS Debug 隔离构建成功，产物仍为 `build_qa_web_current_20261117/macos/Build/Products/Debug/伴伴.app`，版本 `2.6.1+15`；六个 worker TypeScript 文件的 SHA-256 与源文件一致，随包 Node 为 `24.14.1`、`darwin-arm64`。实际运行 App PID `86911` 版本也是 `2.6.1+15`，但与隔离构建的 `kernel_blob.bin` SHA-256 不同，不能据此确认二者源码完全一致。只读句柄表明它仍持有 Hive 数据文件与锁；未读数据库、未操作 App、角色、权限或 API Key。矩阵保持通过 0、失败 3、未验证 17；具体回执、hash 和未完成界面步骤见验收记录末尾。本轮没有清理已有诊断测试，也未提交、推送或发布。

追加复核（2026-11-17 18:00–18:05 CST）：当前生产路由入口逐项核对未发现绕过圆桌/新闻角色/`zhipuSearchAnswerOnly` 门禁的自主联网路径；来源以内联气泡和校验过的可点击链接呈现。16 文件相关联合回归 313 项通过，Node 依赖的 3 项补跑通过，另有 1 项 Web-only 用例按平台跳过。`flutter analyze` 无问题，Gateway `npm test` 12/12 通过；Windows 运行时留存包六个 worker 文件与当前源 hash 相同，PE32+ x86-64 Node 24.14.1 包仅做静态检查。macOS 隔离构建沿用上一节：本轮未改生产代码。暂存的 `scripts/package_web_worker.py` 快照缺 `public_web_dns.ts`，未暂存工作树版本已含；保持暂存区不动。真实 App 矩阵、圆桌内容质量、权限关闭确认和正式交付仍未完成。

## 2026-11-17 真实界面矩阵起始快照

| 配置 | 模型 | 普通私聊 | 普通群聊 | 私聊工作 | 群聊工作 |
|---|---|---|---|---|---|
| 商汤5.2 | deepseek-v4-flash | 失败：HTTP 429 `insufficient_quota`；无读/下载/附件证据 | 未验证 | 未验证 | 未验证 |
| deepseek v4.1 | deepseek-flash | 失败：raw 读取 `SOURCE_HTTP_ERROR`、下载 `NETWORK_TOOL_FAILED`；无附件打开 | 未验证 | 未验证 | 未验证 |
| SenseNova | sensenova-6.8-flash-lite | 失败：模型仅输出 1/6 token，无联网工具回执 | 未验证 | 未验证 | 未验证 |
| maritaca | S5-free | 失败：最近一次 Debug UI 将“Fresh acceptance run”误路由到工作模式；无可核验搜索/读取/下载及附件打开回执 | 未验证 | 未验证 | 未验证 |
| qiniu | qiniu/conatus-free | 未验证：无本轮搜索/读取/下载/附件回执 | 未验证 | 未验证 | 未验证 |

截至该快照，矩阵合计通过 0、失败 4、未验证 16（5 配置 × 4 模式）。用户截图只显示 `maritaca / S5-free` 与 `qiniu / qiniu/conatus-free` 的 Key 已保存且被遮罩；最近保存的 CUA 截图显示数据库保护页无法打开 `api_configs`。本轮遵守仅做代码/构建验证的要求，未复查窗口，故当时的界面状态、配置/角色详情均未核验。后续实测进展以 `docs/desktop_web_ui_acceptance_2026-10-26.md` 末尾记录为准，不以本快照的矩阵标签代替当前状态。尚须真实界面验证普通聊天智谱优先及失败后自主补查、圆桌/新闻角色所有可达入口和内容质量、矩阵格的完整联网与附件打开，以及群聊工作独立审查和正式交付。StepFun 任务 `c440b0fe-47a8-456d-a3c0-0c12158d1c56` 后续已记录为历史任务；当前范围替换为 maritaca 与 qiniu。验收角色工作区读写权限最后一次只读记录为开启，之后应在目标收尾时关闭并界面确认。代码级检查不替代实际界面验收。不得将旧版本截图或单测替代上述验收。

进程状态补记（2026-11-17 18:09 CST）：只读 `ps` 未找到伴伴 App 进程，上一节记录的 PID `86911` 已退出。磁盘上的两个 Debug 包仍为 `2.6.1+15`，kernel 哈希不同；本轮没有重启或启动 App。真实 UI 验收仍待继续，矩阵为通过 0、失败 3、未验证 17。

2026-11-17 18:50 CST 调整：普通私聊和普通群聊的普通回复联网工具次数统一为 6；私聊仍保留独立的 120 秒工具等待上限。`flutter analyze` 通过，当前源码 macOS Debug 隔离构建通过（`2.6.1+15`，Node `24.14.1`），产物未启动。本次未运行测试、未操作 UI/数据库，也未提交、推送或发布；矩阵仍为通过 0、失败 3、未验证 17。

2026-11-17 21:44 CST 续核：公开联网请求中的普通词 `run` 曾被工作模式门禁误判；`work_mode_policy.dart` 已收窄为明确的本地执行目标，`Fresh acceptance run` 回归与 `run tests`、下载后运行脚本门禁共 4 项通过。再跑 `test/network_reply_stream_test.dart` 和 `test/chat_room_search_runtime_test.dart` 共 25 项通过；`flutter analyze` 无问题（12.7 秒）。已验证最新隔离 Debug 包 `build_qa_web_route_fix_20261117/macos/Build/Products/Debug/伴伴.app` 为 `2.6.1+15`，Node `24.14.1`；当前运行进程 PID `8409` 指向较早的 `build_qa_web_current_20261117`，虽同为 `2.6.1+15`，其 `kernel_blob.bin` SHA-256 `1d0c4af9be565093c0b26261fec18a5f1f2fd2d3fd081135026694e722b896ab` 与最新隔离包 `dcd4abb18eade98b67547a67cd3c6f455a9e92f53a792adcb6f20ff059a3c545` 不同；新路由修复包未启动、未做 UI 复验。私聊/群聊上限为 6 次，私聊 120 秒时限保留；`CLAUDE.md` 已同步。`test/qa_web_fix_diagnostics_tmp_test.dart` 仍保留，本轮未创建临时诊断文件或改 App/数据库/角色/权限/API Key。矩阵按最新验收记录为通过 0、失败 4、未验证 16；没有提交、推送或发布。

2026-11-17 21:52 CST 补充验证：`gateway/npm test` 12/12 通过。工作树版 `scripts/package_web_worker.py win-x64` 成功打包到 `/tmp/banban_web_worker_goal_verify_20261117`；Node `24.14.1`、目标 `win-x64`、PE32+ x86-64，六个 worker TypeScript 文件逐个与 `gateway/src` 字节一致，CMake 安装目录与 `WebWorkerClient.bundled()` 路径相符。此项不运行 Windows 二进制、不代替 Windows 实机验收。原暂存区保持不变：`scripts/package_web_worker.py` 的暂存快照仍缺 `public_web_dns.ts`，工作树版已包含；本轮未暂存或提交。无 UI 操作，矩阵及权限复原状态不变。

2026-11-17 21:58 CST 圆桌门禁与回归复核：当前普通回复将 `_roundtableModeEnabled && !_isDirectChat` 传给 `RoundtableNewsRoleService.allowsAutonomousWebTools`，故圆桌每位发言者都不注册桌面自主联网工具；圆桌使用用户回合的智谱来源快照。验收文档总表已改正，旧 UI 记录中的后续 `[W1]` 自主来源保留为历史违规证据。圆桌、仅智谱角色、来源回合与联网上下文五文件回归 32 项通过；首跑发现 `network_reply_context_test.dart` 把空 delta 心跳纳入 `.single` 断言，过滤合法心跳后重跑通过。`flutter analyze` 无问题（12.0 秒）。只改测试与文档，未改生产源码；无 UI 操作，圆桌真实内容质量和 20 格矩阵仍待界面验收。

2026-11-17 22:06 CST 主动私聊与工作联网门禁复核：私聊普通回复与主动私聊均调用 `RoundtableNewsRoleService.allowsAutonomousWebTools`；圆桌、内置新闻角色和仅智谱角色不获得自主 `web.search`、`web.read`、`web.download`。工作工具注册经过 `filterWorkModeNetworkTools`，工作讨论上下文也按同一资格门禁注入来源。补齐主动私聊回归，断言三种自主联网工具均不进入仅智谱角色请求；`direct_chat_proactive_budget_test.dart` 与 `work_mode/work_web_tools_test.dart` 共 22 项通过。`flutter analyze` 为 `No issues found!`（13.4 秒），暂存区和工作树 `git diff --check` 均通过。

只读版本复核：磁盘最新路由修复隔离包 `build_qa_web_route_fix_20261117/macos/Build/Products/Debug/伴伴.app` 为 `2.6.1+15`，kernel SHA-256 `dcd4abb18eade98b67547a67cd3c6f455a9e92f53a792adcb6f20ff059a3c545`。当前运行 PID `8409` 仍从较早的 `build_qa_web_current_20261117` 启动，版本同为 `2.6.1+15`、kernel SHA-256 `1d0c4af9be565093c0b26261fec18a5f1f2fd2d3fd081135026694e722b896ab`；最新隔离包没有运行。本轮按用户指示只做代码/构建验证，没有操作窗口、角色、权限、数据库或 API Key。

当前矩阵维持通过 0、失败 4、未验证 16；普通聊天与工作模式的真实联网、附件打开、圆桌/新闻角色 UI 质量复核、六个验收角色权限关闭确认和群聊工作独立审查/正式交付仍未完成。保留既存 `test/qa_web_fix_diagnostics_tmp_test.dart`，没有新建或清理临时诊断文件；未提交、推送或发布。

2026-11-17 22:14 CST 扩展回归：`flutter test --reporter=compact` 对 26 个测试文件运行搜索路由、圆桌/智谱角色资格、读取/下载、来源气泡、附件预览与路径、私聊/群聊中断恢复、工作模式工具权限、任务持久化恢复、任务交付和附件呈现回归；435 项通过，0 失败。结果基于测试替身与 Flutter 测试环境，不替代 macOS 真界面联网验收。生产源码未变；沿用 21:34 的 macOS Debug 构建与版本核对。

2026-11-17 22:16 CST 工作任务接力/附件重发补充回归：`work_role_router_test.dart` 的制作→开发→审查角色接力、`work_task_coordinator_test.dart` 的交付待重发时推进任务、`work_task_panel_test.dart` 的已完成任务附件重发入口各 1 项通过。该结果验证路由和重发控件代码；群聊工作真实独立审查、正式交付及最终气泡打开附件仍待 UI 实测。

2026-11-17 22:20 CST 工作模式入口与制作工具回归：`default_work_task_runner_stage02_test.dart`、`work_mode_chat_ui_integration_test.dart`、`work_mode_end_to_end_test.dart` 共 125 项通过。覆盖私聊/群聊工作入口接线、工作工具注册及联网/文件权限门禁、审批、读取、制作、附件交付和撤销流程。联网/API 由测试替身提供，不算真实搜索或 UI 验收。

2026-11-18 08:37 CST 当前源码 macOS Debug 构建复核：`flutter build macos --debug` 成功，隔离产物 `build_qa_web_current_20261118/macos/Build/Products/Debug/伴伴.app`，版本 `2.6.1+15`，kernel SHA-256 `dcd4abb18eade98b67547a67cd3c6f455a9e92f53a792adcb6f20ff059a3c545`。`flutter analyze` 无问题（17.7 秒）。随包 Node 为 `24.14.1` / `darwin-arm64`，六个 worker TypeScript 文件与 `gateway/src` 逐项字节一致。临时 Flutter `build-dir` 已移除并确认全局配置未设置；隔离包未启动。

只读运行版本复核：PID `8409` 仍从 11 月 17 日的 `build_qa_web_current_20261117` 启动，版本 `2.6.1+15`、kernel SHA-256 `1d0c4af9be565093c0b26261fec18a5f1f2fd2d3fd081135026694e722b896ab`。当前运行包仍不是 11 月 18 日隔离包。本轮没有启动或操作 App、角色、权限、数据库或 API Key；矩阵维持通过 0、失败 4、未验证 16。已有暂存内容保持原样；未提交、推送或发布。

2026-11-18 08:40 CST Gateway/Windows worker 复核：`gateway/npm test` 12/12 通过。工作树版 `scripts/package_web_worker.py win-x64` 打包到 `/tmp/banban_web_worker_goal_20261118_0837`；Node `24.14.1`、归档 SHA-256 与固定值一致、`node.exe` 为 PE32+ x86-64，六个 worker TypeScript 文件与 `gateway/src` 逐个字节相同。Windows CMake 的安装目标 `${CMAKE_INSTALL_PREFIX}/web_worker` 与 `WebWorkerClient.bundled()` 定位相同；未在 macOS 上执行 Windows 二进制。暂存版打包脚本仍缺 `public_web_dns.ts`，工作树版本包含该文件；本轮未改变暂存区。

2026-11-19 12:46–12:53 CST DeepSeek 私聊工作补测与构建复核：配置 `deepseek v4.1 / deepseek-flash`，任务 `3c8f7059-7263-4441-aae0-f99e8f1a14f4` 停止，详情见 UI 验收文档同时间小节。模型两次搜索没有得到 raw README；随后把 GitHub 仓库 HTML 下载成 `.html`，不能作为原文件验收。`agent_prompt_builder.dart` 增加单文件最多一次初搜与一次定向补查、GitHub raw 查询模板及原文件来源下载门槛；`agent_prompt_builder_test.dart` 12 项通过。针对两文件的 `flutter analyze --no-pub` 无问题，`git diff --check` 通过。全量分析唯一报告是既存未跟踪 `test/game/_ddz_final_layout_preview.dart:126` 的 info。macOS Debug 构建成功，当前实际进程 PID `84665`、版本 `2.6.1+15` / build `15`，运行路径为本仓库 Debug 包；包内 kernel SHA-256 `119b79da93ceca1764092ed2a084e23957d8f39c85fa3e84f9da1daf4f7c6992`。当前五配置 × 四模式仍为通过 `4`、失败 `9`、未验证 `7`；圆桌/新闻路由实测、余下格、群聊工作审查与正式交付、权限关闭回读尚未完成。本轮未改角色、权限或 Key，未提交、推送或发布。

2026-11-18 08:42 CST 工作模式误路由回归复核：`network_request_gate_test.dart`、`work_mode_policy_test.dart`、`work_mode_chat_ui_integration_test.dart` 共 16 项通过。包含 `Fresh acceptance run` 的公开搜索请求仍停留在普通聊天，以及同时含本地执行意图时才进入工作模式的门禁。此为测试环境路由验证；Maritaca 普通私聊仍需新 Debug UI 实测。

2026-11-18 08:45 CST 智谱失败回退与联网协议复核：`roundtable_news_role_service_test.dart`、`chat_room_search_runtime_test.dart`、`network_reply_stream_test.dart` 共 27 项通过。覆盖普通角色关闭两个智谱开关后仍可用自主联网、仅智谱角色保持原生智谱路由、智谱搜索失败后进入自主补查、工具调用上限、读取/下载状态传递及损坏 JSON 只修正一次。此为测试替身回归，不替代真实服务回执或 macOS UI 验收。

2026-11-18 12:06 CST 真实 Debug UI 续验遇到 Hive 锁占用。当前源码 Debug 包 PID `3554`，版本 `2.6.1+15`，kernel SHA-256 `dcd4abb18eade98b67547a67cd3c6f455a9e92f53a792adcb6f20ff059a3c545`；保护页错误为 `ai_characters.lock` 的 `Resource temporarily unavailable (errno 35)`。只读进程与文件句柄检查确认旧包 PID `70297`（`build/macos/Build/Products/Debug/伴伴.app`，版本同为 `2.6.1+15`，kernel SHA-256 `760eadcdb4f1bd04f9ffe260b8e9abe5534fc211b52baba0bec5c9dc7fbea65d`）持有同一 `ai_characters.hive` 和 lock 文件。此证据表示并行实例锁冲突，不据此判断数据库损坏；没有关闭旧包、复制/修复数据库、改角色权限或 API Key。截图：`docs/verification/evidence/web_search_2026-11-18_database_lock_conflict.png`。需退出旧包并重启隔离 Debug 后才能继续 UI 矩阵；通过 0、失败 4、未验证 16 不变。完整细节见 UI 验收记录末尾。

## 2026-11-18 13:41 CST DeepSeek 普通私聊续验

Debug App `build/macos/Build/Products/Debug/伴伴.app` 当前运行 PID `45490`，版本 `2.6.1+15`，kernel SHA-256 `d270939ea5383ed38c93e6b7ebff6129616b75d283a2f63382c9ab3ecef6d837`。DeepSeek v4.1 / `deepseek-flash` 的真实私聊在会话 `dm:f10b6e20-9a0b-4384-8cc5-eaff205b19b4` 完成：首轮免目标 URL 搜索实际命中官方 GitHub 仓库；同一后续消息将 s1 登记为 HTML 仓库页、s2 登记为 raw README，随后真实 `web.read(s1)` 和 `web.download(s2)` 均成功。原始下载 `qa-deepseek-dm-20261118-r6.md` 为 6946 字节，SHA-256 `4bc9b330ef1c690f06adb0f90c25018c980977ad47d25d88efca11f45e91930a`；最终 AI 气泡附件已从界面打开并预览正文。旧回合模型文本所称“读过”因无 `public-web` 读取快照未沿用，来源编号错位原因为 URL 分属不同回合，而非服务商或联网工具失败。

五配置矩阵由通过 0、失败 4、未验证 16 更新为通过 1、失败 3、未验证 16。完整来源、消息 ID、时间、读取哈希、附件打开结果和剩余界面步骤以 `docs/desktop_web_ui_acceptance_2026-10-26.md` 新增小节为准。继续验收时先处理验收角色模型映射和权限恢复，其他代码/构建/路由/圆桌质量项目仍按原记录待核。未提交、推送或发布。

## 2026-11-18 18:10 CST 当前代码/构建与界面状态校正

- 当前桌面端联网工具次数统一为每轮最多 6 次；普通私聊的 120 秒等待上限保留。新增重复请求一次恢复、查询与请求标识、搜索/读取/下载安全回执持久化，详见同日 `docs/desktop_web_ui_acceptance_2026-10-26.md`。
- 本轮定向回归 64 项通过；`flutter analyze --no-pub` 无问题；macOS Debug 版本 `2.6.1+15` 构建及启动成功，kernel SHA-256 `93d35b705f5df612ad06b23afc62c60c4694af61b247beef943d89ebeb57b4eb`。Windows worker Node 24.14.1 打包、六个源码 SHA-256 及 CMake/运行时路径核对通过；无 Windows 实机验收。
- 五配置矩阵以较新的 UI 验收记录为准：通过 2、失败 3、未验证 15。SenseNova 普通私聊在上一版 Debug 中模型请求成功但无联网工具调用；本轮改动后未能完成第二次 UI 复验，不推断模型不支持工具。
- CUA 当前返回 `frontmostApplicationChanged` 与 `timeoutReached`，界面验收暂停。没有更改验收角色、权限或任何 API Key；历史六角色权限关闭回读沿用但未重新确认。未继续/编辑停止中的 `QA-WORK-GROU…`，未使用“干活的群”。
- 本轮没有创建临时诊断测试；保留既有 `test/qa_web_fix_diagnostics_tmp_test.dart`。不提交、推送或发布。

2026-11-18 18:18 CST 补充代码回归：同一源码树追加 14 个既有测试文件，共 618 项通过，覆盖联网上下文与来源继续、圆桌/仅智谱工具门禁、流取消和页面恢复、附件预览、工作任务恢复/接力/审批及协调。Dart 源码未变，沿用 18:08 的 `2.6.1+15` Debug 构建、18:10 的全量 `flutter analyze` 和 Windows 静态打包证据。CUA 再次超时，五配置 UI 矩阵仍为通过 2、失败 3、未验证 15；角色映射、六项权限、智谱真实路由与圆桌内容复核尚未验证。

2026-11-18 18:21 CST CUA 再次续接：Debug 截图可读，但每次搜索框操作后服务超时，随后 AX 状态也超时。停止中的 `QA-WORK-GROU…` 保持原状；无角色/权限/API Key 更改，无聊天发送。新的 UI 矩阵证据为零。代码与测试验证已完成，剩余真实界面工作受同一 CUA 服务阻断。

2026-11-18 18:38 CST 用户恢复目标后重新核验：Debug 包 PID `59113`、版本 `2.6.1+15`、kernel SHA-256 与 18:08 构建一致。CUA 可读截图，但关闭任务面板后出现斗地主进行中页面；切换来源不确定。未操作游戏状态或验收角色，不新增 UI 证据。当前代码路由入口仍经 `RoundtableNewsRoleService`/`filterWorkModeNetworkTools` 门禁；真实圆桌/新闻角色验收、矩阵与权限回读仍待完成。

2026-11-18 18:40 CST 路由专项复验：智谱搜索运行时、圆桌/新闻角色工具资格、工作联网工具过滤、主动私聊联网与联网回复流共 5 个测试文件 51 项通过。当前 Debug UI 已在暂停的斗地主对局页；返回会销毁游戏 director，未触碰游戏。未改源码，沿用 18:08 Debug 构建。真实矩阵继续待验，计数 2/3/15。

2026-11-18 19:02–19:19 CST 用户切回角色页后继续验收。实际运行 Debug App 为 `build/macos/Build/Products/Debug/伴伴.app`，`2.6.1+15`，PID `59113`，kernel SHA-256 `93d35b705f5df612ad06b23af62c60c4694af61b247beef943d89ebeb57b4eb`。UI 回读确认五个目标配置角色映射；未编辑角色、权限、Key 或游戏状态。详情见 `docs/desktop_web_ui_acceptance_2026-10-26.md` 同时间小节。

商汤5.2 / `deepseek-v4-flash` 普通私聊在当前构建下完成真实搜索与网页读取；工具回执分别成功，后续聊天 reply 与 retry 均为 `http_429` / `insufficient_quota`。定位为搜索、读取后的服务端模型额度错误；无下载回执、附件或气泡附件打开证据，格仍失败，不据此判断模型不支持工具。当前工具调用上限代码仍为 `networkReplyToolCallLimit = 6`。未改生产源码。

既有 `test/qa_web_fix_diagnostics_tmp_test.dart` 与本轮只读消息/回执副本诊断均运行通过；Hive 原文件大小和修改时间未变。本轮新建的 `test/qa_st_message_receipts_tmp_test.dart` 已删除；既有临时诊断测试保留。分析、macOS 构建及代码回归沿用 18:10–18:40 的有效证据，因为生产源码未变。矩阵计数仍为通过 2、失败 3、未验证 15；未提交、推送或发布。

补记：`qa_st_message_receipts_tmp_test.dart` 首次运行因诊断脚本直接 import Hive generated `part` 文件而编译失败；将导入改为模型库后复跑通过。该问题仅在一次性诊断脚本中，未改生产源码；脚本已删除。


2026-11-18 19:23–19:26 CST SenseNova 普通私聊在同一 `2.6.1+15` Debug App 中复验：模型 `reply` 请求成功（5186 ms、1719/190 tokens），AI 返回普通短句，无搜索快照、工具回执或附件。结论仍为该格失败；不推断模型不支持工具。详情与会话/消息 ID 见 UI 验收文档同时间小节。只读临时测试 `test/qa_sensenova_current_receipts_tmp_test.dart` 已清理，Hive 文件大小与 mtime 未变；生产源码未改。矩阵仍为 2/3/15。

2026-11-18 19:38–19:55 CST DeepSeek 普通群聊补测完成：首轮未给目标 URL，真实搜索查询命中官方 GitHub 仓库，读取动态仓库页成功但该页下载哈希不一致，故保留为失败尝试。后续对本群公开 raw README 执行真实读取与下载，均为 6946 字节、SHA-256 `4bc9b330ef1c690f06adb0f90c25018c980977ad47d25d88efca11f45e91930a`；附件与同版本官方 raw 基线字节一致，且已从最终 AI 气泡打开预览。群 ID `8eed902b-e1f5-4b00-89dc-e9a23f4a7d7c`，成功 request `064941fc-ef3f-4c66-bdee-7e6b2098a98a`。当前矩阵 3 通过、3 失败、14 未验证。临时诊断 `test/qa_deepseek_group_diagnostics_tmp_test.dart` 已删除，既有诊断测试保留。沿用 Debug PID `59113`、`2.6.1+15` 和 kernel SHA-256 `93d35b705f5df612ad06b23af62c60c4694af61b247beef943d89ebeb57b4eb`；未改生产代码、权限或 Key；不提交、推送或发布。

2026-11-18 20:23–20:30 CST Maritaca 普通群聊复验：首轮搜索命中官方仓库但 raw README 定向搜索结果不足；官方 raw README 后续读取/下载回执成功，文件 6946 字节、SHA-256 `4bc9b330ef1c690f06adb0f90c25018c980977ad47d25d88efca11f45e91930a`，与同版本 raw 基线 `cmp` 一致。最终气泡为消息 `8e5f40e0-e804-4b6e-82c5-f49aa0f804e3`。自动回复不断更新列表，本次无法从气泡打开附件预览；本格因附件步骤未闭环记失败。详见 UI 验收文档。当前 3 通过、4 失败、13 未验证；本轮临时诊断 `test/qa_mar_group_diag_tmp_test.dart` 已删除，未改生产源码/权限/Key，未提交、推送或发布。

2026-11-19 07:35–07:48 CST 代码与构建复核：联网回复流共享单轮 6 次真实工具执行上限，定向测试 14 文件/253 项通过；全量 `flutter analyze --no-pub` 无问题。macOS Debug 隔离构建成功，版本 `2.6.1+15`，kernel SHA-256 `59784f1a63eb33f9f5a861026600490bfaabf8d4e1708901e543b43f254fca9f`。当前实际运行 Debug App PID `99297`，同版本号但 kernel SHA-256 为 `d5842dd4b4b165922e87222778c252588460abc5a615334296d398b8fbd51aff`；新包未启动，不能将代码/构建结果当作当前 UI 进程证据。Windows worker Node `24.14.1` 打包、PE32+ 格式、六个源文件一致性和 CMake/运行时目录规则检查通过；Worker 测试 4 通过、1 项浏览器平台门禁按预期跳过，无 Windows 实机验收。界面将六个 `QA-Matrix-*` 验收角色的“读工作区／改文件”保存为开启；`QA-Web-D52` 未改且沿用历史权限开启记录。后续须完成矩阵与权限关闭回读。五配置矩阵仍为通过 3、失败 4、未验证 13。本轮没有新 UI 工具回执，未提交、推送或发布。

2026-11-19 08:00–08:06 CST：隔离 Debug 包现已启动，PID `17812`，版本 `2.6.1+15`，kernel SHA-256 `59784f1a63eb33f9f5a861026600490bfaabf8d4e1708901e543b43f254fca9f`。当前 AX 仍在 `QA-Matrix-ST` 普通私聊；输入框里有未发送的拼接草稿，未产生新请求或联网回执。旧 429 气泡是历史记录。本节无 UI 矩阵进展，仍为通过 3、失败 4、未验证 13；用户将自行切回角色页。权限复原、圆桌/新闻路由复核和其余矩阵未完成。未提交、推送或发布。

2026-11-19 08:11–08:12 CST 代码路由静态复核：圆桌角色、新闻角色和 `zhipuSearchAnswerOnly` 角色在普通回复/主动私聊/工作模式均无自主联网工具旁路；普通回复智谱搜索失败后自主搜索有回归覆盖。来源上下文明确分开检索与发布时间，气泡来源链接由内嵌组件展开，`$1` 清理及不弹来源对话框有回归证据。依据既有通过的 14 文件/253 项记录，未重复运行测试。以上均属代码/自动化证据，圆桌内容质量、智谱补查及各实际入口仍待 Debug UI 验收；矩阵仍为通过 3、失败 4、未验证 13。当前窗口仍在 ST 私聊，无新请求。未提交、推送或发布。

2026-11-19 08:16 CST：重新读取 PID `17812` 并截图，App 仍在 `QA-Matrix-ST` 普通私聊，未切回角色页；未操作窗口。未发送草稿或产生新工具回执，矩阵仍为通过 3、失败 4、未验证 13。继续实测需要当前窗口切回角色页；权限复原和全部 UI 门禁尚未完成。未提交、推送或发布。

2026-11-19 09:48–09:57 CST：继续 Debug UI 实测。Maritaca 普通群聊 `QA-Matrix-Mar-Group-20261118` 的最终 AI 消息 `8e5f40e0-e804-4b6e-82c5-f49aa0f804e3` 中，附件 `qa-maritaca-group-20261118-r2.md` 已点击并在预览中显示 README 正文；现场文件为 6946 字节、SHA-256 `4bc9b330ef1c690f06adb0f90c25018c980977ad47d25d88efca11f45e91930a`。详见 UI 验收文档本时间小节。当前 Debug App PID `70277`、版本 `2.6.1+15`、隔离构建 `kernel_blob.bin` SHA-256 `59784f1a63eb33f9f5a861026600490bfaabf8d4e1708901e543b43f254fca9f`。五配置 × 四模式更新为通过 4、失败 4、未验证 12；路由专项、圆桌质量、余下 12 格及临时角色权限关闭回读未完成。本轮未改生产代码、权限或 Key；未提交、推送或发布。

2026-11-19 10:02–10:10 CST：私聊工作复验暴露两类模型端失败。Maritaca `S5-free` 的 `purpose=agent` 请求收到 HTTP 404，脱敏正文称模型已弃用；未进入联网工具阶段。DeepSeek `deepseek-flash` 的模型请求成功，但任务循环调用 `web.search` 13 次、`web.read` 1 次，无下载与最终附件；面板报告 21.39 万 Token。达到第 15 步后停止任务并保留记录，没有重试。详情见 UI 验收文档同时间小节。只读诊断临时测试已删除，既有诊断文件保留。测试后两会话工作开关均关闭；五配置 × 四模式为通过 4、失败 6、未验证 10。未提交、推送或发布。

2026-11-19 10:18–10:43 CST：修复普通聊天路由的误拦截。复现 `supported desktop platforms` 被 `desktop` 关键词误识别为本地工作；收窄为桌面文件/目录/项目/代码请求。补强 `networkReplyStream` 提示，明确普通私聊/群聊可调用公开网页工具且无需开启工作模式。七个定向测试文件 71 项通过；`flutter analyze --no-pub` 无问题；macOS Debug 构建成功，版本 `2.6.1+15`，最终 kernel SHA-256 `7bf22459d693b8e3f87750f57e63b1ed77406190754498ab564765c456e838c7`。最终包 PID `9678` 已启动并停在角色页；补强协议后的实际模型回归未重发。

修正门禁后的 ST 普通私聊实际回归，用户消息 `99d90045-9d61-4d29-b81f-b5dc639ec50a` 的 `purpose=reply` 请求 `a8bf8595-4dd5-4ace-a31f-9bac550686f9` 成功，但回复声称没有工具通道，且该用户轮没有 `web.search`/`web.read`/`web.download` 回执。同期另有 `autoChat` 搜索 request `efcf4f99-a33e-4ed0-9272-38cca7aaf8ae` 返回 5 个非官方结果，后续 autoChat 请求触发 HTTP 429；未把它归给用户 reply，也未据此判模型不支持。ST 私聊仍失败，矩阵继续为 4/6/10。详情、消息/收据、模型文本和时间线见 UI 验收文档末尾。

本轮临时路由复现测试 `test/qa_work_mode_route_diag_tmp_test.dart` 与 Hive 字节副本诊断 `test/qa_st_web_route_diag_tmp_test.dart` 均已删除；保留既有 `test/qa_web_fix_diagnostics_tmp_test.dart` 和路由回归测试。没有改角色、权限或 Key；未提交、推送或发布。

2026-11-19 13:12–13:28 CST DeepSeek 私聊工作 raw 来源补测与搜索源修复：任务 `5f524449-6983-449c-8f1f-c2b6ced17639` 使用 deepseek v4.1 / `deepseek-flash`、角色 `QA-Matrix-DeepSeek`。两次 `web.search` 均报告成功，但首搜只回词典类结果，`site:raw.githubusercontent.com/flutter/flutter README.md` 补查只回 README 介绍/预览页；没有 `web.read`、`web.download` 或工作区写入。任务事件日志没有保存 search receipt ID 或来源的完整 URL，按证据边界不补造；该私聊工作格仍失败，五配置矩阵保持通过 4、失败 9、未验证 7。

根因在 `DesktopWebService.search`：DuckDuckGo 只要解析出任意可用 URL 就提前返回，即使结果违反查询中的 `site:` 主机或路径约束，因而不会尝试 Bing。现已按 `site:` 校验候选来源的主机及路径；当前引擎无匹配来源时继续尝试下一引擎。新增回归覆盖 DDG 返回错误仓库后由 Bing 命中正确 raw 文件，以及两个搜索源均不符合时拒绝返回结果。相关 `desktop_web_service_test.dart` 20 项、`public_search_parser_test.dart` 6 项及 `agent_prompt_builder_test.dart` 12 项通过，共 38 项；全量 `flutter analyze --no-pub` 无问题。隔离 macOS Debug 构建成功，产物 `build_qa_code_verify_20261119/macos/Build/Products/Debug/伴伴.app`，版本 `2.6.1+15`，kernel SHA-256 `99d5ced71904f6afa28085850ed3b5f4aab8c750711c5daabda834d0f0d0d6e0`；随包 Node `24.14.1`，六个 worker TypeScript 文件与 `gateway/src` 一致。Xcode 报旧默认 build 目录下的 stale-file/allowed-root 警告，构建仍成功；临时 Flutter `build-dir` 配置已清除。13:23 CST 曾只读观察到 PID `5862` 指向默认 Debug 包，13:28 CST 进程列表未找到伴伴 App；默认包与隔离包的 kernel SHA-256 分别为 `ce2d0246ca546fdf5c3079689bfe6591215d1cfa92cd8fd2da8a463ffdd8bf78`、`99d5ced71904f6afa28085850ed3b5f4aab8c750711c5daabda834d0f0d0d6e0`。默认包可执行文件时间戳为 13:19；无法仅凭现有记录判定其变化是否由构建或外部操作造成。没有重启 App 或操作窗口；隔离包未启动，故没有 UI 复验。未改角色、权限、Key；未提交、推送或发布。

2026-11-19 13:31–13:40 CST 路由门禁代码复核：9 个测试文件/两个讨论用例共 63 项通过。覆盖普通聊天智谱搜索路由、圆桌新闻角色与发言候选隔离、智谱专用角色普通/主动/工作路径的自主工具拒绝、工作模式网络门禁、群调查读取及下载权限拒绝，以及智谱失败后的自主联网回复流。该证据只证明代码与自动化路径，不替代真实模型回执、圆桌内容质量或 UI 矩阵；当前进程列表无伴伴 App，磁盘默认包版本仍为 `2.6.1+15`。矩阵仍为通过 4、失败 9、未验证 7，权限未改。本轮未创建临时诊断文件。

2026-11-19 13:40 CST 路由作用域静态复核：私聊 `ChatRoomLoader` 仅把当前角色传入联网运行时；群聊联网角色集合限定为该群当前成员及已加载的历史角色。新闻角色的“仅智谱搜索”状态不会从其他会话全局泄漏。此项为代码读取结论，不新增自动化或 UI 证据；路由回归仍沿用本节上方 63 项记录。

## 2026-11-19 20:02–20:15 CST 新闻工作任务协议修复与 Debug 复验

- 复核新闻角色私聊工作任务 `63822806-9999-44b6-bf0b-06a71aab71a2` 的原始事件：模型提交 `web.search` 时把 `startSection`、`nextSection` 两个 `web.read` 分页字段混入搜索参数；此前三次协议修复仍重复该形状，搜索没有执行。该证据定位到工具参数协议，不代表模型不支持工具。
- 修复 `AgentDecisionParser`：仅在 `web.search` 上剔除误带的 `startSection` / `nextSection`，其他未知字段仍由闭合 schema 拒绝。提示词明确 `web.search` 只接受 `query`。新回归覆盖该修正并保留 `url`、`path` 等越权字段拒绝检查。
- 定向 `agent_decision_parser_test.dart` 57 项通过；提示词、解析器、`work_web_tools_test.dart`、`work_agent_loop_test.dart` 四文件合计 225 项通过。`flutter analyze --no-pub` 无问题（13.5 秒），`git diff --check` 通过。
- `flutter build macos --debug` 成功。新 Debug 包 `/Volumes/new_disk/work/flutter/chat_group/chat_group/build/macos/Build/Products/Debug/伴伴.app` 版本 `2.6.1+15` / build `15`，kernel SHA-256 `f6584e28e6d37e1d1f624494fc0c005f20fd9194d9e488817cb4ed2341a30698`。终止旧 PID `91197` 后启动本包；新 PID `98361` 的命令路径指向该包。构建输出有旧隔离构建目录的 stale-file/allowed-root 警告，构建退出码为 `0`。
- 用新包从任务面板重试旧新闻任务。事件 `167–171` 只有 queued/planning/failed/交付进度，失败为 `WorkspacePathException: 已保存的工作目录不再受授权覆盖，请重新选择目录。`；没有新模型调用、搜索/读取/下载回执或文件。界面“重新授权”返回“当前任务没有等待目录授权”，不能恢复该旧检查点。专用空临时目录 `/tmp/banban_web_acceptance_20261119/news_work_retry` 已创建，未向任务授权，仍为空。
- 自动化回归继续确认新闻搜索角色和智谱专用角色的工作联网工具会从注册表移除；普通角色保留这些工具。实际新闻工作入口仍因过期工作区检查点无法完成新一轮调用，记未验证；不把旧错误或新授权失败伪装为成功，也不重试自主搜索。未改新闻角色权限、API Key 或搜索 Key。
- 五配置 × 四模式矩阵仍为通过 `4`、失败 `12`、未验证 `4`。圆桌内容质量、新闻主动回复与可用工作入口、四个群聊工作格及权限关闭的当前全角色复核仍未完成。未提交、推送或发布。

## 2026-11-19 21:10–21:23 CST DeepSeek 群聊工作格界面尝试与权限复原

- 本节未修改产品代码。沿用 20:02–20:15 已记录的 225 项定向回归、`flutter analyze --no-pub` 与 macOS Debug 构建证据；未重复测试或构建。实际 Debug App 退出重启后 PID `14544`，版本 `2.6.1+15` / build `15`，kernel SHA-256 `f6584e28e6d37e1d1f624494fc0c005f20fd9194d9e488817cb4ed2341a30698`。
- 两次准备 DeepSeek 群聊工作时，群成员选择 UI 的点击与复选框状态发生错位。两次都放弃未保存表单；群聊总数仍为 `103`，没有创建群聊、会话或任务，也没有调用模型或联网工具。详细界面证据见 `docs/desktop_web_ui_acceptance_2026-10-26.md` 同时间小节。
- 已复原临时角色改动：`QA-Matrix-DeepSeek` 的模型保持 `deepseek v4.1 / deepseek-flash`；`QA-Matrix-Review-B` 恢复 `maritaca / S5-free`；两角色重新打开的权限界面均确认 `workspaceRead` / `workspacePatch` 关闭。其他 QA 角色未被更改。无 Key 变更。
- 五配置 × 四模式仍为通过 `4`、失败 `12`、未验证 `4`。DeepSeek、商汤、Qiniu、SenseNova 的群聊工作格仍未验证；本次 UI 选择问题不据以标为模型或联网失败。未提交、推送或发布。

## 2026-11-19 21:38–22:12 CST DeepSeek 群聊工作回执与隔离构建

- DeepSeek 群聊工作任务 `118541ae-5919-46f3-b48e-fd6394ec2b36` 的两条真实搜索回执均为 `NO_SEARCH_RESULTS` / `sourceCount=0`：GitHub 仓库查询 receipt `77468c11-a37c-4bb0-88b3-bddfbfb80f43`、raw README 定向补查 receipt `70197b9d-e0a9-49d3-91cb-69387a207a51`，request `2b8ad55c-0e1f-4665-b513-573257b21573`。没有读取、下载、候选冻结、审查或最终附件；指定审查角色不在实际协作 team，任务因无进展安全暂停。该格记失败，不据此判断模型不支持，也不再无进展重试。详细回执与权限关闭证据见 UI 验收文档同时间小节。
- 定向回归 `233` 项通过；`flutter analyze --no-pub` 通过；`git diff --check` 通过。隔离 `flutter build macos --debug --no-pub` 成功，版本 `2.6.1+15`，kernel SHA-256 `05d9f439094c0967fc1a342fb64f53c25b389386731a01c5127be1ddf84a6ec1`。临时 Flutter build-dir 设置已移除。正在运行的 PID `14544` 仍为旧默认 Debug 包，版本 `2.6.1+15`、kernel SHA-256 `f6584e28e6d37e1d1f624494fc0c005f20fd9194d9e488817cb4ed2341a30698`；隔离新包未启动。
- 五配置 × 四模式更新为通过 `4`、失败 `13`、未验证 `3`；尚未完成的群聊工作格为商汤、Qiniu、SenseNova。圆桌内容质量、仅智谱新闻角色所有可达入口、剩余矩阵和权限复核继续待验。本轮未修改生产代码；保留所有已有 dirty changes，不提交、推送或发布。

## 2026-11-19 22:22–22:32 CST Qiniu 群聊工作格与权限回读

- Qiniu 群聊工作任务 `fddc5697-8273-494b-9cec-5b82b3d16013`（会话 `e8aa3cdc-02cb-4360-8e70-bff3bc31a453`）在群讨论阶段发生 7 条 `HTTP 429` 失败事件，且群缺少与目标 Qiniu 模型匹配的 development 角色。没有搜索、读取、下载回执或附件；任务留在安全检查点，未恢复或重试。该格记失败，不能据此判断模型不支持。详情见 UI 验收文档同时间小节。
- 临时角色 `QA-Matrix-Review-A` 已恢复 `maritaca / S5-free`，`QA-Matrix-StepFun` 保持 `qiniu / qiniu/conatus-free`；两角色的 `workspaceRead` / `workspacePatch` 已在运行中的 Debug UI 保存关闭并重新打开确认关闭。没有修改其他角色或 API Key。
- 实际 Debug App PID `14544`，版本 `2.6.1+15` / build `15`，kernel SHA-256 `f6584e28e6d37e1d1f624494fc0c005f20fd9194d9e488817cb4ed2341a30698`。五配置 × 四模式为通过 `4`、失败 `14`、未验证 `2`；未验证为商汤、SenseNova 群聊工作。圆桌内容质量、仅智谱新闻角色所有可达入口和群聊工作正式审查/交付仍未完成。本节只改验收文档；未提交、推送或发布。

## 2026-11-19 23:12–23:17 CST 商汤群聊工作续验与当前状态复核

- 按用户更新后的范围，矩阵为商汤5.2 / `deepseek-v4-flash`、deepseek v4.1 / `deepseek-flash`、SenseNova / `sensenova-6.8-flash-lite`、`maritaca / S5-free`、`qiniu / qiniu/conatus-free`；StepFun 已从目标配置移除。旧角色名 `QA-Matrix-StepFun` 当前映射 Qiniu，不代表仍测 StepFun。
- 真实 Debug App PID `14544`，进程路径 `/Volumes/new_disk/work/flutter/chat_group/chat_group/build/macos/Build/Products/Debug/伴伴.app`；实际 `CFBundleShortVersionString=2.6.1`、`CFBundleVersion=15`，运行包 `kernel_blob.bin` SHA-256 `f6584e28e6d37e1d1f624494fc0c005f20fd9194d9e488817cb4ed2341a30698`。隔离构建哈希不同，未启动。
- 在群聊页尝试滚动定位已创建的 `QA-Web-Work-ST-20261119`（群 ID `52acb006-daf0-45a6-a43e-e68db7d9de96`）。本次截图和 AX 列表仍只显示旧群；滚轮及列表容器滚动均未把目标卡片带入可见区域，因此没有进入该群、启动工作任务或触发模型/联网调用。该群聊工作格仍未验证，不记为模型或联网失败。建群时选中的两个 QA 角色为 `QA-Matrix-ST` 与 `QA-Matrix-Review-A`；当前没有未发送工作任务。
- 再次读取旧任务 `c440b0fe-47a8-456d-a3c0-0c12158d1c56` 事件日志，末尾仍停在 sequence `157` / `2026-11-19T10:54:04.473793Z`：恢复检查因“项目需在本设备重新绑定并核对，历史认可不能授权执行”暂停。候选阶段无法恢复，未点“继续测试”，没有独立审查、正式交付或最终气泡附件；由于 StepFun 已退出本轮矩阵，不重跑该格。
- 本次没有改产品代码、角色权限、模型映射或 API Key，也没有新建临时诊断文件。现有验收角色权限关闭证据沿用记录；本轮界面再次确认 `QA-Matrix-ST`、`QA-Matrix-SenseNova`、`QA-Matrix-Review-A` 的 `workspaceRead` / `workspacePatch` 均关闭。实际 UI 格数为通过 `4`、失败 `14`、未验证 `2`。只复用 21:38–22:12 的 `233` 项回归、`flutter analyze --no-pub` 与隔离 macOS 构建，不重复运行；源码未变。未提交、推送或发布。

## 2026-11-19 23:27–23:35 CST 新闻角色普通回复智谱路由复验

- 实际 Debug App 仍为 PID `14544`、版本 `2.6.1+15`，kernel SHA-256 `f6584e28e6d37e1d1f624494fc0c005f20fd9194d9e488817cb4ed2341a30698`。角色页显示 `新闻角色` 配置 `glm-4-flash`；在同一私聊会话 `dm:acc526a0-ff01-4ddd-8709-314be3d45d99` 进行路由复验。
- 一次较长中文草稿在 Computer Use 输入阶段被错误映射成 `7 Flutter Dart` 并误发；不作为有效验收查询。本轮随后发送两条截图可见的 ASCII 查询，均未包含目标 URL。普通回复查询 `Search Flutter official blog; return date, fact and URL.` 的智谱搜索回执 `9ac3014c-6ae3-4bde-95e9-059bd917342c`、消息/root request `2432999f-c6e2-42c8-872e-d9f20fdb16b7`；`provider=zhipu-native`、`status=completed`、时间 `2026-11-19T15:27:47.019005Z`（23:27:47 CST），界面显示 5 个来源。模型回复 request `c8d8d5c4-cc70-49d8-8c9e-c946c064c74b`（`provider=zhipu`、`model=glm-4-flash`）成功。
- 首次有效查询的来源为博客园 Flutter 客户端、bmabk Flutter 资料、博客园 2019 文章、天眼查转载 Flutter 2、tool.lu 布局文章；均非 Flutter 官方来源。模型未给出可核对的发布日期或正文事实，答复称近 7 天无官方文章。随后定向补查 `Zhipu only: search Flutter official blog after Nov 12 2026.` 的回执 `1b3dc954-fda0-4ff7-896a-bc4835ba5530`、消息/root request `dbedb779-f1de-410c-932d-7f04ee363b26`；`provider=zhipu-native`、`status=completed`、时间 `2026-11-19T15:29:34.056714Z`（23:29:34 CST），界面显示 5 个来源。补查返回 52pojie、CSDN 及三个无链接来源，仍无官方证据；模型回复 request `7a194585-cc9e-4a54-b135-3826c5ecc892`（Zhipu / `glm-4-flash`）成功并报告证据缺口。来源列表从气泡内展开，没有弹出来源对话框。
- 本轮这两条有效查询均只观察到智谱原生搜索回执；没有 `web.search`、`web.read` 或 `web.download` 回执。模型路由通过，检索相关性和来源质量失败。同期 `purpose=proactive / custom / S5-free / HTTP 404` 请求与本角色的 `purpose=reply / zhipu / glm-4-flash` 请求分开，不计入本格。此前 UI 记录中新闻角色主动回复开关为关闭；本轮没有启用它。点击私聊右上角工作入口未打开任务面板，也未创建任务；临时工作目录 `/tmp/banban_web_acceptance_20261119/news_work_20261119_2330` 未写入文件。主动回复与工作模式实际联网隔离仍待验证。
- 本轮没有改产品代码、角色、权限或 Key。沿用已有 233 项回归、Flutter 分析、macOS 构建证据；`git diff --check` 通过，验收文档无尾随空白。五配置矩阵仍为通过 `4`、失败 `14`、未验证 `2`。未提交、推送或发布。

## 2026-11-20 00:42 CST 群聊工作恢复与权限复核

- 当前运行 Debug App PID `14544`，进程路径 `/Volumes/new_disk/work/flutter/chat_group/chat_group/build/macos/Build/Products/Debug/伴伴.app`；`CFBundleShortVersionString=2.6.1`、`CFBundleVersion=15`，包内 `kernel_blob.bin` SHA-256 `f6584e28e6d37e1d1f624494fc0c005f20fd9194d9e488817cb4ed2341a30698`。
- 对旧任务 `c440b0fe-47a8-456d-a3c0-0c12158d1c56` 点“继续”后，恢复校验仍要求在本机重新绑定并核对项目；最新任务事件序号 `160` 回到暂停状态。任务没有进入独立审查、正式交付或最终附件打开阶段。旧 StepFun 已退出当前五配置范围，不重跑该格。
- 在 `QA-Web-Work-ST-20261119` 中提交续验任务后，任务标识前缀 `3c41949a` 停在需要用户回答，当前群缺少 development 能力；可选角色只符合 `maritaca / S5-free`，不符合制作/审查角色必须同为商汤配置的要求。没有选择不匹配角色，没有模型调用、联网工具回执或候选，群聊工作格仍未验证。
- Debug UI 已将 `QA-Matrix-Review-A` 恢复为 `maritaca / S5-free`。保存后重开权限表单确认 `workspaceRead` / `workspacePatch` 均关闭；`QA-Matrix-ST` 本轮重开表单也确认两项关闭，行动能力仍开启。其他四个 QA 矩阵角色沿用验收文档中的既有界面关闭证据。没有改 API Key、真实角色或其他权限。
- 本轮没有产品源码改动或新建临时诊断文件。保留 `test/qa_web_fix_diagnostics_tmp_test.dart` 和所有既有工作树改动；沿用 2026-11-19 21:38–22:12 的 `233` 项定向回归、Flutter 分析及 macOS Debug 构建证据，当前运行内核哈希一致，不重复执行。矩阵仍为通过 `4`、失败 `14`、未验证 `2`。目标未完成；未提交、推送或发布。

## 2026-11-20 00:54–00:58 CST 群聊工作入口复试与六次额度回归

- 当前运行 Debug App PID `14544`，路径 `/Volumes/new_disk/work/flutter/chat_group/chat_group/build/macos/Build/Products/Debug/伴伴.app`，版本 `2.6.1+15`；内核 SHA-256 仍为 `f6584e28e6d37e1d1f624494fc0c005f20fd9194d9e488817cb4ed2341a30698`。磁盘 Debug 包内核与运行进程对应版本一致。
- 复试商汤群聊工作时，新建表单仅填写了未保存的临时名称 `QA-Web-Work-ST-20261120` 和主题 `Public Flutter documentation research`。成员筛选 `QA-Matrix-ST` 同时显示 `QA-Matrix-ST` 与旧名 `QA-Matrix-StepFun`（当前映射 Qiniu）；勾选控件没有出现在无障碍树中，坐标点击也没有改变复选状态。已返回群聊列表放弃表单；群聊数仍为 `100`。没有创建群、任务或会话，没有模型请求、联网回执、文件或附件；不计为矩阵失败，商汤与 SenseNova 群聊工作仍未验证。没有改角色、权限、配置或 Key。
- `lib/features/web_search/desktop/network_reply_stream.dart` 的 `networkReplyToolCallLimit` 为 `6`，普通私聊和普通群聊调用方共用该常量。`flutter test --no-pub test/network_reply_stream_test.dart` 通过 `24` 项，包含“默认联网工具额度为 6 次”、达到上限后的收尾、普通聊天联网工具可用及智谱失败后自主搜索回退。源码修改时间早于当前 Debug 包构建时间；沿用 2026-11-19 已记录的 `flutter analyze --no-pub` 和 macOS Debug 构建证据，没有重复构建。
- 五配置 × 四模式仍为通过 `4`、失败 `14`、未验证 `2`。未提交、推送或发布。

## 2026-11-20 01:08–01:21 CST 圆桌界面续验与路由回归

- 圆桌临时群表单的成员列表滚动造成 AX 焦点漂移，无法可靠确认 QA 成员，已退出未保存表单；群聊列表红色徽标仍显示 `100`，没有发送消息或触发模型/联网调用。
- 新闻角色既有私聊仍显示两条智谱搜索回复、各 5 个来源；未发新消息。私聊工作入口未打开任务面板，主动回复与工作入口 UI 路由仍未验证。
- 路由回归 5 个文件、`54` 项通过；`flutter analyze --no-pub` 无问题；`git diff --check` 通过。运行 Debug App `2.6.1+15`，PID `14544`，kernel SHA-256 `f6584e28e6d37e1d1f624494fc0c005f20fd9194d9e488817cb4ed2341a30698`，与现有构建证据一致。
- 矩阵仍为通过 `4`、失败 `14`、未验证 `2`；目标未完成。未改源码、角色、权限或 Key；未提交、推送或发布。

## 2026-11-20 01:22–02:12 CST 商汤私聊工作任务复核与修复

- 更正 01:22–01:27 的初记：发送无目标 URL 请求后，UI 创建了 QA-Matrix-ST 私聊工作任务 `916b01af-a49d-4fde-9483-beeb23c0f73f`，会话 `dm:03dc0216-c92f-454c-9362-32952bea7144`；它不是普通私聊回复，也不是既有提醒中的任务 `5bcead6d`。旧条目把“尚无联网回执”错误推广成“没有任务/模型调用”。
- 真实联网回执：两次搜索 `site:github.com/flutter/flutter README`、`site:raw.githubusercontent.com/flutter/flutter README.md` 均 `NO_SEARCH_RESULTS`；后续 `Flutter GitHub repository official README` 搜索成功（5 个来源，仅含 GitHub 仓库根页 `https://github.com/flutter/flutter`），定向 raw 搜索再次 `NO_SEARCH_RESULTS`。`web.read` 与 `web.download` 都对仓库根页成功，分别为 327123 字节、SHA-256 `d3f429dea9af8286d0d22a8314e7f6722aed9a9dfbe918ca7cde3303f5b02674` 和 `6e0325062324ba5b4b654e890128c5dd0bea6abf8179505a3176d9e63d08fa76`；下载名虽是 `README.md`，内容实为 HTML，不是 raw README。
- 02:06 在 Debug UI 为 `QA-Matrix-ST` 临时开启 `workspaceRead`（`workspacePatch`保持关闭），保存后继续任务。模型随后第 2、3、4 次重试均失败，任务以 `HTTP 429 请求失败` 结束；没有新增有效搜索、读取或下载回执。未继续点击重试。
- 已从该任务最终 AI 气泡打开 `README.md` 附件。预览显示 GitHub 页面源码（`data-color-mode`、`githubassets.com` CSS），确认附件路径可打开，但文件内容错误。实际文件 `/private/tmp/banban_web_acceptance_20261119/st_private_work/downloads/qa-st-private-work-20261119.md/downloads/download_rngbkK/README.md` 为 HTML，327123 字节，SHA-256 `6e0325062324ba5b4b654e890128c5dd0bea6abf8179505a3176d9e63d08fa76`；无 raw 原件比对、有效 README 事实或通过证据。此任务属于私聊工作，不改变普通私聊矩阵格；已失败的 ST 私聊工作格计数不变。
- 新增下载 MIME 守卫：`text/html` / `application/xhtml+xml` 不能以 `.md` 等非 HTML 文件名交付，返回安全错误 `CONTENT_TYPE_MISMATCH`，并清理未提交的部分文件。回归覆盖 HTML 冒充 README。当前源码定向 8 文件、99 项通过；`flutter analyze --no-pub` 无问题。Windows worker 临时包 `/tmp/banban_web_worker_goal_verify_20261120` 为 Node `24.14.1`、`win-x64` PE32+ x86-64，6 个 worker 源文件与 `gateway/src` 字节一致；`windows/CMakeLists.txt` 安装路径与 `WebWorkerClient.bundled()` 运行时定位一致。macOS Debug App PID `8055`、`2.6.1+15`、kernel SHA-256 `f1304042cf39e5d882649aacec50fdbca5d8a348b7309c9ca2b3ba0d8638705c`；包内 6 个 worker 文件与源文件一致。
- `QA-Matrix-ST` 的 `workspaceRead` 随后在 Debug UI 关闭并保存，重开权限页确认 `workspaceRead` / `workspacePatch` 均关闭。未改真实角色、其他角色、API Key 或搜索 Key；既有 `test/qa_web_fix_diagnostics_tmp_test.dart` 保留，本轮新建的诊断文件已删除。五配置 × 四模式仍为通过 `4`、失败 `14`、未验证 `2`；未验证为商汤、SenseNova 群聊工作。圆桌质量、新闻角色主动/工作入口仍未完成。未提交、推送或发布。

## 2026-11-20 02:14–02:23 CST 商汤群聊工作待答项回读

- **配置 / 群 / 构建：**`QA-Matrix-ST` → 商汤5.2 / `deepseek-v4-flash`；既有群 `QA-Web-Work-ST-20261119`（群聊列表显示 2 个角色）；任务前缀 `3c41949a`。Debug App PID `8055`、版本 `2.6.1+15`，kernel SHA-256 `f1304042cf39e5d882649aacec50fdbca5d8a348b7309c9ca2b3ba0d8638705c`。
- **任务状态：**只读打开“回答问题”面板，确认任务仍为 `需要你回答`，原因是当前群缺少 development 能力；没有发送答复、继续、停止、撤销或重试。候选清单所有角色均为 `S5-free`，含唯一明确标为 Software engineer 的 `QA-Web-ST`，没有商汤模型角色。未加入模型不匹配成员，任务保持等待。
- **联网 / 交付：**本次只读回看没有触发模型请求或 `web.search` / `web.read` / `web.download`；无来源、读取事实、文件、候选冻结、独立审查、正式交付或最终附件。商汤群聊工作矩阵格仍未验证，原因是没有符合本格配置的 development 角色。
- **状态保护：**只切换群聊与只读任务面板；没有改角色、模型映射、权限或 Key。没有创建/删除群聊、任务或临时文件。六个 QA 角色的临时工作区权限继续沿用已保存并通过界面复核的关闭记录。

## 2026-11-20 02:33–02:41 CST 商汤群聊工作成员答复与临时角色复原

- Debug App PID `8055`，路径 `/Volumes/new_disk/work/flutter/chat_group/chat_group/build/macos/Build/Products/Debug/伴伴.app`，版本 `2.6.1+15`；当前运行包内核 SHA-256 `f1304042cf39e5d882649aacec50fdbca5d8a348b7309c9ca2b3ba0d8638705c`。
- 对群 `QA-Web-Work-ST-20261119`、任务前缀 `3c41949a` 回复：仅由 `QA-Matrix-ST`（Software engineer，商汤5.2 / `deepseek-v4-flash`）制作，并由 `QA-Matrix-Review-A` 以同一配置独立审查；不加入 S5-free 角色。App 随即返回 `HTTP 429`、`failureCode=discussionStreamFailed`，说明未取得可采纳的协作结果且原成员/责任未变。没有重试或选择配置不匹配的候选；将提示暂放后，面板显示讨论中、需求版本 6、候选轮次 0，同时历史待答卡仍存在。
- 该群聊工作格没有联网工具回执、候选、独立审查、正式交付或附件；继续记为未验证。HTTP 429 单独作为服务限流记录，不作为模型不支持工具的证据。
- 为这次受阻尝试临时将 `QA-Matrix-ST` 职务改为 Software engineer，并把 `QA-Matrix-Review-A` 临时切至商汤；随后分别恢复原职务 `Temporary web acceptance tester` 与 `maritaca / S5-free`。Debug UI 保存后重开两角色权限页，确认 `workspaceRead` / `workspacePatch` 均关闭。未改真实角色、API Key、搜索 Key 或其他角色权限。
- 本轮没有产品源码改动或临时诊断文件。矩阵仍为通过 `4`、失败 `14`、未验证 `2`；目标未完成。保留既有工作树改动；未提交、推送或发布。

## 2026-11-20 02:45–03:03 CST SenseNova 群聊工作任务路由超时后暂停

- **配置 / 模式 / 构建：**制作角色 `QA-Matrix-SenseNova` → SenseNova / `sensenova-6.8-flash-lite`；独立审查角色 `QA-Matrix-Review-A` 在本次任务期间临时切到同一配置。新建群 `QA-Web-Work-SenseNova-20261120`，群聊工作任务卡显示前缀 `2942c0f3`（完整 ID 未在面板显示）。Debug App PID `8055`，版本 `2.6.1+15`，kernel SHA-256 `f1304042cf39e5d882649aacec50fdbca5d8a348b7309c9ca2b3ba0d8638705c`。
- **任务输入 / 路由：**首条任务要求先搜索 Flutter 官方 GitHub README，未提供目标 URL；读取正文并提取可核对信息；将 raw README 保存到 `/tmp/banban_web_acceptance_20261120/sensenova_group_work/README.md`，报告文件名、大小和 SHA-256；候选冻结后走“继续测试”、独立审查、正式交付和最终气泡附件。点击确认需求后面板为讨论中、需求版本 1、候选轮次 0；“继续”未推进。随后 UI 明确报告“模型候选推荐未完成：模型请求超时，未采纳模型选择”，候选为上述两名 SenseNova 配置角色。这是群任务执行人推荐阶段的模型请求超时，不是搜索服务回执，也不证明模型不支持联网工具。
- **分工 / 暂停：**按 UI 提供的“指定最终执行人”入口尝试选择制作角色 `QA-Matrix-SenseNova` 后，任务面板实际显示负责人 `QA-Matrix-Review-A`、当前成员 `QA-Matrix-SenseNova`，分工尚未得到符合任务要求的确认。等待一轮仍无新讨论或工具回执后，在“补充需求／暂停”面板选“保持暂停”。最终面板为“等待处理”、需求版本 1、候选轮次 0，需由用户点击“继续”才能从当前讨论检查点恢复。没有再次重试、停止或撤销任务。
- **工具 / 交付：**本次没有成功模型讨论、`web.search`、`web.read` 或 `web.download` 回执；无来源链接、正文事实、文件、哈希、候选冻结、独立审查、正式交付、附件或打开结果。只读检查发现请求目标 `/tmp/banban_web_acceptance_20261120/sensenova_group_work/README.md` 是一个空目录，不是 README 文件。该群聊工作格仍未验证；模型请求超时单独记录，UI 未提供 HTTP 状态或外部服务诊断，不判模型能力失败。
- **权限 / 角色复原：**完成临时任务准备后，`QA-Matrix-SenseNova` 与 `QA-Matrix-Review-A` 的 `workspaceRead` / `workspacePatch` 均在 Debug UI 关闭、保存并重开权限页回读为关闭。Review-A 已恢复 `maritaca / S5-free`，SenseNova 保留原 `sensenova-6.8-flash-lite`；未改 API Key、搜索 Key、其他权限或真实角色。其他四个 QA 矩阵角色沿用此前逐项保存并界面确认关闭的记录。
- 本轮没有产品源码改动或新建临时诊断文件。保留既有临时诊断回归测试和所有未提交改动；沿用有效的 `233` 项定向回归、`flutter analyze --no-pub` 与 macOS Debug 构建证据，源码未变。矩阵仍为通过 `4`、失败 `14`、未验证 `2`；未验证为商汤、SenseNova 群聊工作。目标未完成；未提交、推送或发布。

## 2026-11-20 03:11–03:26 CST 圆桌智谱路由复核与 UTC 日期标注修复

- **配置 / 会话 / App：**临时群 `QA-Roundtable-Web-20261120`，群 ID `95e4944e-5643-48d3-8cc7-b8afda4b33ed`；普通发言角色 `QA-Matrix-DeepSeek`、`QA-Matrix-SenseNova`，内置圆桌新闻角色参与检索。圆桌模式 UI 显示开启。搜索时实际 Debug App PID `8055`，版本 `2.6.1+15`，kernel SHA-256 `f1304042cf39e5d882649aacec50fdbca5d8a348b7309c9ca2b3ba0d8638705c`。
- **搜索回执：**首轮用户消息 `c8c4b078-4c68-476d-b61f-ba87b5c71712`，搜索请求 `137720a5-78c3-46b7-882e-cc5fd79ccf64`；原查询要求最新 Flutter stable 与官方公告日期、只用智谱、不用自主联网工具。回执 `provider=zhipu-native`、HTTP `200`、5 来源、`fromCache=false`、`degraded=false`、1073 ms。记录时间 `2026-11-19T19:12:33.233878Z`，即上海时间 `2026-11-20 03:12:33`。该日期时区换算说明模型回答中的 `2026-11-19` 是 UTC 日期，并非本地检索日。
- **一次补查：**用户消息 `6448f80f-f453-4239-92d8-ec9a360f3e0b`，搜索请求 `f9237c31-9e45-458d-b383-8b7d6a7fc49d`，回执同为 `zhipu-native` / HTTP `200` / 5 来源，1272 ms，未走缓存。因桌面自动化 `type_text` 丢弃了输入中的中文，实际查询缩成 `Flutter stable Flutter 2026-11-20`，没有保留“只核验官方发布记录”等限制；这是唯一一次补查，未再追加查询。因此“智谱路由”有快照证据，但“针对官方原文的有效定向补查”未验证。两次快照都没有自主工具来源；群聊中未出现自主 `[Wn]` 引用或 `autonomous-web` 快照。
- **来源 / 内容质量：**首轮 S1 是第三方 CNBlogs 页面 `https://www.cnblogs.com/developer-laoliu/articles/23695395`，标题 `2026年11月`，回执 `publishedAt=2026-11-16T16:00:00.000Z`；正文摘要转述 Flutter 3.50 / Dart 3.14 与 11 月 11 日发布说法。首轮 S3 也讨论 Flutter 3.50，但 `url=null`，摘要内虽提到官方博客地址，不能作为可点击官方来源。其余首轮结果涉及记账软件、Memos 与 OpenWrt。补查仍返回同一 CNBlogs 第三方页面；另有 Flutter 教程、Memos、无链接面试文章及 Flutter/Dart 支付 SDK 排名，没有官方发布页或 stable 源。结果卡里的 URL 来自真实 `zhipu-native` 搜索快照，但本轮没有另行打开网页验证可达性。圆桌总结正确保留“未取得可核验的官方来源”，没有 `$1`；后续发言持续转向 3.47.x 补丁、hotfix 和清单分工，未始终聚焦“当前最新 stable”主题，内容质量不通过。
- **时间标注修复：**实际回答只写 `检索时间为 2026-11-19`，未标明 UTC，易与本地 `2026-11-20` 混淆；搜索上下文此前只把发布时间字段转成 UTC 日期，也未在字段名标时区。`search_context_formatter.dart` 现将其标为 `发布时间（UTC）`，`search_prompts.dart` 增加“用户要求区分时须分别注明 UTC 时区、不可把检索日作发布日期”的规则。定向 `flutter test --no-pub test/search_stage06_test.dart` 35 项通过；`flutter analyze --no-pub` 无问题（17.6 秒）；`git diff --check` 通过。
- **新构建与诊断清理：**`flutter build macos --debug --no-pub` 成功，只有多个目标架构提示和旧隔离构建目录 stale-file 警告，退出码 `0`。包版本 `2.6.1+15`；内核 SHA-256 `1281fe5c10abae305388c5a3e91c1c75226b3f5600e40405037a85dbb29d6482`。退出临时群后重启新包，当前 PID `33365` 从该 Debug App 路径运行；没有在新包中重复发送圆桌查询。为读取 QA 群消息而本轮创建的只读 Hive 诊断测试已运行并删除；它确认两条快照中的提供方、时间、请求 ID 和来源均来自持久记录。既有 `test/qa_web_fix_diagnostics_tmp_test.dart` 保留。未改角色权限、API Key 或搜索 Key。
- 本专项不计入 20 格；矩阵仍为通过 `4`、失败 `14`、未验证 `2`。时间标注修复尚未做新的圆桌 UI 回放，官方链接可达性也未确认；智谱新闻角色可达入口、余下矩阵格及群聊工作审查/正式交付仍待验。未提交、推送或发布。

## 2026-11-20 03:39–03:47 CST SenseNova 群聊工作续验

- 继续原群聊工作任务 `2942c0f3`（完整 ID 未在 UI 显示），配置为 `QA-Matrix-SenseNova` 制作、`QA-Matrix-Review-A` 独立审查，双方 SenseNova / `sensenova-6.8-flash-lite`。运行 Debug App 为 PID `33365`、版本 `2.6.1+15`，kernel SHA-256 `1281fe5c10abae305388c5a3e91c1c75226b3f5600e40405037a85dbb29d6482`。
- 执行用户授权的“调整审查角色模型后重试”。UI 仍保留审查成员此前 `300` 秒、`0` 正文字符的待决卡。评审角色随后发布 `方案与验收详情.json`（3.7 KB），制作角色确认接受方案；候选轮次仍为 `0`，没有执行人员或工具调用。
- 只读先前证据显示目标 `.../sensenova_group_work/README.md` 是空目录。未删除该目录；通过任务“补充需求”将目标改为同一临时根下的 `attempt_2/README.md`，保持搜索、读取、原样下载、哈希、候选冻结、独立审查、正式交付和最终附件验收要求。补充后面板仍处于“等待处理”；点击“继续”返回“当前动作正在收尾，请等待安全停点”，故停止继续点击，未触发第二轮重试。
- 本轮没有 `web.search` / `web.read` / `web.download` 回执，没有公开来源、摘录、下载文件、哈希、候选、独立审查、正式交付或最终 AI 气泡附件。本格仍未验证，不能作为通过或模型不支持工具的证据。现有任务保持待处理。
- 已恢复 `QA-Matrix-Review-A` 为 `maritaca / S5-free`，保存后重开表单确认 `读工作区`、`改文件` 关闭。`QA-Matrix-SenseNova` 配置未变；同样从 Debug UI 确认两项权限关闭。没有改 API Key、搜索 Key 或其他角色。
- 矩阵保持通过 `4`、失败 `14`、未验证 `2`。无产品源码或诊断文件改动；既有 `233` 项定向回归、Flutter 分析与 macOS Debug 构建证据仍有效。未提交、推送或发布。

## 2026-11-20 03:55–04:11 CST 商汤普通私聊复验与模型额度定位

- Debug 构建仍为 PID `33365`、版本 `2.6.1+15`，kernel SHA-256 `1281fe5c10abae305388c5a3e91c1c75226b3f5600e40405037a85dbb29d6482`。`QA-Matrix-ST` 在 UI 配置为商汤5.2 / `deepseek-v4-flash`；诊断实际 provider `sensenova`。
- 首条尝试误发到正在等待用户处理的私聊工作任务 `916b01af-a49d-4fde-9483-beeb23c0f73f`，不是普通回复；它作为 FIFO 补充需求入队。只读 Hive 诊断将模型请求关联到该 task：一次成功后五个后续请求返回 `HTTP 429`，详情含 `inference exceeds tpm/rpm limit`、`insufficient_quota` 和 `rpm exhausted`。随后模型请求成功，但工作任务在第 5 步因 `workspaceRead` 未授权暂停。未开启权限、未继续任务；这轮证据不支持“模型不支持联网工具”。
- 关闭当前会话工作模式后重新发普通私聊：用户消息 `24ac8ce7-6f3f-4a40-acc3-98d14c8530e5`，AI 消息 `0e8513c5-78f4-4177-ab38-a9a7abb75bcf`，会话 `dm:03dc0216-c92f-454c-9362-32952bea7144`。普通回复诊断 `purpose=reply` 三次均成功；网络快照 `provider=autonomous-web`，`web.search` 与 `web.read` 回执均 success，命中并读取 GitHub 官方 Flutter README，事实正文和 W1 来源链接在最终 AI 气泡中显示，且 W1 点击后在 Chrome 正常打开。
- UI 到 `04:11` 仍显示“AI 正在回复…”。本轮没有 `web.download` 或附件校验/打开记录；因此只验证了普通私聊搜索、读取与来源展示子项，不把完整矩阵格标为通过。原六个 QA 角色的 `workspaceRead` / `workspacePatch` 均保持关闭，未改真实角色或 Key。临时只读诊断测试 `qa_st_private_reply_diagnostic_tmp_test.dart` 已删除；保留既有 `qa_web_fix_diagnostics_tmp_test.dart`。矩阵仍 `4/14/2`，目标未完成；未提交、推送或发布。

## 2026-11-20 04:12–05:23 CST 回合完成刷新修复、路由复核与权限收尾

- `chat_room_agentic_round_execution_support.dart` 在释放普通回复/主动回复 guard 后显式刷新 UI，避免消息已落库但“AI 正在回复…”残留；新增 `test/chat_room_reply_completion_ui_test.dart` 先复现后验证该行为。`work_mode_policy.dart` 同时排除明确禁止本地文件操作的否定指令，并把纯公开资料搜索/读取/下载留在普通回复路由。普通私聊和群聊仍共用联网工具上限 `6`；私聊单独的 `120s` 等待时限未改。
- 联网路由与生命周期定向回归 11 个文件共 `84` 项通过；`flutter analyze --no-pub` 输出 `No issues found!`；`git diff --check` 通过。详情见验收文档本节。
- 隔离 macOS Debug 构建成功：`build_qa_web_ui_refresh_20261120/macos/Build/Products/Debug/伴伴.app`，版本 `2.6.1+15`，`kernel_blob.bin` SHA-256 `2c8fa8a9672d2e79127d32ef2097431e3cbba5716f103814dd6cb3a1a246d2aa`。真实界面由 PID `65164` 运行该隔离包；系统版 `/Applications/伴伴.app` PID `41587` 未触碰。
- 只读 Hive 快照诊断 `test/qa_news_route_diagnostics_tmp_test.dart` 运行成功后已删除；`test/qa_web_fix_diagnostics_tmp_test.dart` 及有效回归测试保留。诊断使用 `.hive` 文件字节副本，前后大小和修改时间一致；未读取或输出任何 Key。
- Debug UI 中六个 QA 验收角色仍存在：DeepSeek、Review-A、Review-B、SenseNova、ST、旧名 `QA-Matrix-StepFun`（当前配置 Qiniu）。逐角色检查后六个角色的 `workspaceRead` / `workspacePatch` 均关闭。发现 DeepSeek 角色残留 `workspaceRead=on` 后，按既有授权关闭、保存并重开表单回读；其他五个角色两项原本均关闭。没有改真实角色、API Key 或搜索 Key，也没有恢复暂停中的任务。
- 真实矩阵结论未变：通过 `4`、失败 `14`、未验证 `2`。新闻角色质量仍不通过；此路由专项不是矩阵格。目标未完成；保留全部既有未提交改动；未提交、推送或发布。

## 2026-11-20 05:28–05:35 CST 商汤普通私聊重试定位

- Debug UI 当前隔离构建为 `2.6.1+15`，PID `65164`；kernel SHA-256 `2c8fa8a9672d2e79127d32ef2097431e3cbba5716f103814dd6cb3a1a246d2aa`。商汤 `deepseek-v4-flash` 普通私聊模型调用和自动重试均因 SenseNova `HTTP 429 insufficient_quota` 在 165 ms / 123 ms 失败；无该消息的联网审计、联网快照或附件。详细消息、请求 ID 与验收结论见 UI 验收文档同时间小节。该格不通过，但此失败不指向产品工具协议缺陷；额度恢复后再复验。
- 保留测试 `test/work_mode/network_request_gate_test.dart` 的新提示回归，`2` 项通过。为关联本条 Hive 记录而建的只读诊断文件已删除；既有 `test/qa_web_fix_diagnostics_tmp_test.dart` 保留。未改产品源码或 App 数据，沿用既有分析、84 项回归及 macOS Debug 构建证据。未提交、推送或发布。

## 2026-11-20 09:39–10:04 CST Debug UI 回读与临时诊断收尾

- Debug App 启动时先出现 `ai_characters.lock` 获取失败（`Resource temporarily unavailable`，errno `35`）。未修复或改写 Hive 文件；旧 App 进程退出后，从隔离构建重新打开 UI，角色数据可读。当前运行 PID `5626`，包版本 `2.6.1+15` / build `15`，kernel SHA-256 `2c8fa8a9672d2e79127d32ef2097431e3cbba5716f103814dd6cb3a1a246d2aa`。
- Qiniu 角色仍沿用旧名 `QA-Matrix-StepFun`，保存配置为 `qiniu / qiniu/conatus-free`。其私聊工作任务 `a31a53ee-1f89-4197-bf39-23013ffd00b0` 仍为 `paused`，当前步骤 `8`、动作数 `4`，原有排队数 `0`，错误为自动修复无进展。本轮有一条误入该旧任务对话的用户消息 `764c3db0-9ac3-4b08-b1ec-a9ef54b06cd5`（`isWorkMode=true`，内容误带 `test` 前缀）；任务快照仍显示 `queuedUserRequestCount=0`，没有搜索快照或工具回执。没有点击继续、停止或撤销；不把此消息计入普通私聊格，也不据此改变矩阵结论。
- 打开 `QA-Matrix-Review-A` 的旧私聊未发送新用户提示，但产生了自动回复请求。`autoChat` 请求 `64f0a424-8462-4358-99d5-c76ae5815126` 与重试 `f1288c1f-2533-4a6a-a395-dd907553d52e` 使用 `custom / S5-free`，均 HTTP `404`；提供方错误明确为 `deprecated_model`（S5-free 已弃用）。相邻 `proactive` 请求亦 HTTP `404`。没有 `web.search` / `web.read` / `web.download` 回执；未改变 Maritaca 配置或 API Key。随后返回角色列表，界面再次显示 `QA-Matrix-Review-A → maritaca / S5-free`。
- 本轮只读诊断 `test/qa_qiniu_task_status_tmp_test.dart` 通过，使用 Hive 内存副本；记录完成后已删除该文件和 `/tmp/qa-qiniu-task-status.out`。保留 `test/qa_web_fix_diagnostics_tmp_test.dart`。沿用联网请求闸门 `2` 项回归、既有 `84` 项路由/生命周期回归、Flutter 分析和隔离 macOS 构建结果；本轮没有产品源码改动。六个 QA 角色的工作区读写权限仍沿用此前 UI 关闭回读，不曾在本轮打开。
- 五配置 × 四模式矩阵仍为通过 `4`、失败 `14`、未验证 `2`。本轮不新增或改判格子；目标未完成。未提交、推送或发布。

## 2026-11-20 10:33–11:08 CST 裸 JSON 工具协议修复与 SenseNova 普通聊天复验

- 根据旧版 Debug 私聊曾把裸 `{"tool":"web.search",...}` 泄漏到气泡的实际记录，`_ReplyFenceScanner` 现在在回合结束时识别独立 JSON 工具对象；无工具键的普通 JSON 仍作为正文。损坏且声明工具的独立 JSON 复用现有一次性格式纠正，不把协议噪声显示给用户。新增/保留回归覆盖分片裸 JSON 搜索、普通 JSON 正常显示、损坏 JSON 仅纠正一次。
- 验证：`flutter test --no-pub test/network_reply_stream_test.dart test/network_reply_context_test.dart test/inline_search_reply_test.dart`，`40` 项通过；`flutter analyze --no-pub` 无问题（18.3 秒）；macOS Debug 构建成功。临时 `flutter config --build-dir` 已恢复为空值。保留全部预存 dirty changes；无提交、推送或发布。
- 真实界面使用 `/Volumes/new_disk/work/flutter/chat_group/chat_group/build_qa_web_sensenova_20261120/macos/Build/Products/Debug/伴伴.app`，PID `37804`，`2.6.1+15` / build `15`，kernel SHA-256 `c3ebbb1d6f1502a8545a224e5890be2fc629d9a80d59bf22c090efa90a3fbd26`。SenseNova 普通私聊模型回复成功，但两次真实 `web.search` 回执均为 `NO_SEARCH_RESULTS`，因此无读取、下载、附件及打开证据。SenseNova 普通群聊的模型回复请求成功，AI 返回闲聊且没有联网快照或任何工具回执；该格仍失败。
- 普通私聊搜索快照 `c6f54f45-c95f-4e11-9e4f-eb4b8805f4cc`；失败搜索回执 `5cf3b345-a3a5-4959-98b3-5d6ba9eec254`、`14053409-56e8-4a43-bbe5-a3bc2fdd522e`。普通群聊 `QA-Matrix-SenseNova-Ordinary-Group` / `2eda7aa4-7534-46ac-a7e0-b3ee52a86a62`，用户消息 `c0c21e09-6dfa-45ab-b4c1-3b667fbc4533`，成功模型请求 `1c01be6d-c30c-435a-bbfb-021f19bd2216`。没有使用新搜索 Key、贝锐 Key、Codex CLI 或独立搜索服务。
- SenseNova 群聊工作仍卡在既有任务 `2942c0f3`：Debug UI 当前显示需求版本 `5`、候选轮次 `0`、状态“待你确认”，`QA-Matrix-Review-A` 的 300 秒请求收到 `0` 个正文字符。此前按同模型配置调整恢复仍回到同一待决卡；本轮只读确认状态，未再次重试、继续、停止或撤销。故该矩阵格保留未验证。
- 临时只读诊断 `test/qa_sensenova_ordinary_diag_tmp_test.dart` 已删除；保留 `test/qa_web_fix_diagnostics_tmp_test.dart` 和联网回归。SenseNova 与 Review-A 的 `workspaceRead` / `workspacePatch` 在构建前已由 Debug UI 回读关闭；沿用另外四个 QA 验收角色的关闭证据。本轮没有改角色权限、API Key、真实角色或暂停任务。
- 用户将本轮矩阵收敛为 DeepSeek、SenseNova、Maritaca `S5-free`、Qiniu `qiniu/conatus-free` 四个配置。商汤5.2 / `deepseek-v4-flash` 按用户指示作为 DeepSeek 别名，不独立占格；旧名 StepFun 的验收角色对应 Qiniu。当前 16 格汇总通过 `4`、失败 `11`、未验证 `1`，明细见 UI 验收文档本节。圆桌质量、仅智谱新闻角色全部可达入口及工作任务审查/正式交付仍未完成。目标未完成。

## 2026-11-20 11:47 CST SenseNova 群聊工作任务恢复阻塞

- 使用 SenseNova / `sensenova-6.8-flash-lite` 制作角色 `QA-Matrix-SenseNova` 与临时同配置审查角色 `QA-Matrix-Review-A`，在 `QA-Web-Work-SenseNova-Repeat-20261120` 新建任务 `55015b50`。需求版本 `2` 已确认；任务卡停在讨论恢复，候选轮次 `0`、负责人 Review-A、当前成员 SenseNova，约 6 分钟无新阶段事件。按规程停止任务并保留检查点，没有反复点击“继续”。
- 无可核验的模型调用诊断或 `web.search` / `web.read` / `web.download` 回执；无来源、摘录、文件、哈希、候选、独立审查、正式交付或最终附件。判定该矩阵格为工作任务阶段失败，不推断模型不支持联网。
- CUA 中文输入丢失导致首版任务说明带残片；已补充修正并确认需求版本 2。没有文件写入或联网调用。临时仅开启 SenseNova 与 Review-A 的 `workspaceRead` / `workspacePatch`；结束后均关闭并保存，SenseNova UI 重开确认两项关闭，Review-A 恢复 `maritaca / S5-free`。没有修改 Key 或其他角色权限。
- 当前 Debug App PID `49628`，路径 `build_qa_web_sensenova_20261120/macos/Build/Products/Debug/伴伴.app`，版本 `2.6.1+15` / build `15`，kernel SHA-256 `c3ebbb1d6f1502a8545a224e5890be2fc629d9a80d59bf22c090efa90a3fbd26`。未创建临时诊断文件；保留既有诊断回归。沿用同一源码版本的 `40` 项联网回归、`flutter analyze --no-pub` 和 macOS Debug 构建证据。矩阵更新为通过 `4`、失败 `12`、未验证 `0`；目标未完成。未提交、推送或发布。

2026-11-20 11:57 CST 当前构建与智谱路由复核：运行 Debug App PID `49628`，版本 `2.6.1` / build `15`，内核 SHA-256 `c3ebbb1d6f1502a8545a224e5890be2fc629d9a80d59bf22c090efa90a3fbd26`。四配置为 DeepSeek v4.1、SenseNova、Maritaca、Qiniu，商汤 `deepseek-v4-flash` 仅按用户要求视作 DeepSeek 别名；矩阵 16 格为通过 4、失败 12、未验证 0。普通回复智谱原生搜索与自主工具流分开，既有回归覆盖智谱失败后自主补查；主动私聊、圆桌、工作任务的新闻角色门禁通过 `RoundtableNewsRoleService` / `filterWorkModeNetworkTools`。两次新闻角色 UI 请求只有智谱快照；主动入口无可触发候选，工作入口无工具回执；圆桌来源与主题质量仍不通过。仅复核代码、既有测试和 App 元数据，本次未改产品源码或角色/Key，未重跑测试；未提交、推送或发布。

2026-11-20 12:04–12:06 CST 补记：DeepSeek v4.1 QA 角色两项智谱搜索开关均为关闭时，私聊 `dm:f10b6e20-9a0b-4384-8cc5-eaff205b19b4` 产生 `isWorkMode=false` 的 `autoChat` 消息；模型请求成功并调用 `autonomous-web`。初搜成功返回 5 个链接，raw 定向补查为 `NO_SEARCH_RESULTS`；未读取或下载。该证据只证明自动私聊可调用自主联网，不算手动普通 `reply` 或矩阵格通过。DeepSeek 会话的工作模式已恢复原开启状态；临时只读诊断文件已删除。SenseNova 两项开关回读关闭，但 CUA 未形成新的手动消息，本项仍待验证。

2026-11-20 12:20–12:31 CST 续验状态：SenseNova UI 验收被共享 Hive 锁阻塞。Debug App PID 49628（2.6.1+15，kernel SHA-256 c3ebbb1d6f1502a8545a224e5890be2fc629d9a80d59bf22c090efa90a3fbd26）显示 ai_characters.lock errno 35；只读 lsof 确认系统版 /Applications/伴伴.app PID 75389（2.6.0+14）持有 ai_characters.lock 与 api_configs.lock。未关闭系统版或操作数据。定向联网测试 40 项通过，flutter analyze 无问题，独立 macOS Debug 构建成功（kernel SHA-256 ac8816c64c09eda9e3746a4d8de67ae9a714e3d7b3ab21436c90aee6652b02e9），git diff --check 通过。没有新增矩阵回执；四配置矩阵仍按最近有效证据为通过 4、失败 12、未验证 0。待用户退出系统版释放锁后继续实测；未提交、推送或发布。

2026-11-20 12:32–12:35 CST 复核：系统版伴伴 PID 75389 仍持有 ai_characters.lock、api_configs.lock，SenseNova UI 未产生新回执。联网路由定向回归 66 项、Gateway Node 单测 12 项通过；Windows worker Node 24.14.1 win-x64 包校验为 PE32+ x86-64，六个 worker 文件哈希一致，CMake 与运行时目录一致，未做 Windows 实机验收。矩阵沿用最近有效状态；等待用户释放共享锁后继续界面验收。

## 2026-11-20 20:26–20:40 CST 流式空完成分类修复与 Debug 复验

- `AiRequestGateway.streamChatMessage` 收到无 token、无可见 `done.content` 的终止事件时，现在记录 `empty_completion` 失败和推理 token 数，输出净化后的错误事件。原有 `networkReplyStream` 按此错误执行一次低推理重试，重试失败后才结束，不把空正文记成成功，也不虚报搜索工具调用。
- 新增回归：reasoning-only 空完成归为失败，带正文的 `done.content` 仍成功；空回复触发一次重试，再进入搜索工具路径。`flutter test --no-pub test/ai_request_gateway_test.dart test/network_reply_stream_test.dart`，`66` 项通过；`flutter analyze --no-pub` 无问题；隔离 macOS Debug 构建成功，版本 `2.6.1+15` / build `15`。`git diff --check` 通过。临时 build-dir 已恢复为空。
- Debug App `/Volumes/new_disk/work/flutter/chat_group/chat_group/build_qa_web_resume_20261120/macos/Build/Products/Debug/伴伴.app`，PID `18872`，`kernel_blob.bin` SHA-256 `27bb921d32ff5f055f0f44b85aafd919a9f7c62d5c9cbe2748bb3d8f345fc39e`。SenseNova 私聊普通回复和一次 retry 均耗尽 `4096` reasoning token 后以空正文失败；请求 ID、消息 ID 与无工具回执结论见 UI 验收文档本节。该结果证实新的诊断与重试路径，不构成搜索支持结论。
- 重启后 UI 确认六个 QA 验收角色仍存在，六者“读工作区”“改文件”均关闭。本轮只读查看，未保存角色或权限。矩阵沿用四配置范围，仍通过 `4`、失败 `12`、未验证 `0`。保留所有预存未提交改动；未提交、推送或发布。

## 2026-11-23 11:20–12:40 CST 四配置收尾与联网复核

- SenseNova 普通私聊上限仅对 `sensenova-6.8-flash-lite` 普通私聊设为 `8192`；群聊、工作任务和其他模型不变。预算回归验证该例外边界，序列化回归断言发送 JSON 字段 `max_tokens=8192`。为让空完成失败也能直接核对上限，`AiRequestDiagnostic` 新增仅含数值的 `requestedMaxTokens`，不保存请求正文或 Key；新回归覆盖 `8192` 经失败诊断和 toMap/fromMap 往返。
- SenseNova UI 会话 `dm:74f5d00b-1859-41c5-8d84-84c73ae5e240`，用户消息 `76e2f428-33e1-4b4b-bd09-0ea627368d2d`，AI 气泡 `a8996d4d-0e56-446d-909c-564b76cb93ed`。reply `e4dcae7a-d3d5-4c89-a294-6836a91d4f7a`（UTC `03:33:50.455Z`）输入 `1990`、输出/推理 `517`；retry `78bd711f-b207-4da5-87fb-bf3e616a3df5`（UTC `03:33:51.757Z`）输入 `1911`、输出/推理 `1`。两次均 `empty_completion`，无搜索/读取/下载回执、来源、附件或打开结果。不能据此标记模型不支持联网。公开 API 文档确认 `max_tokens` 是含 reasoning 的最大输出参数，并以 `finish_reason=length` 表示达到请求上限；文档没有声明该模型的数值最大上限。故已证实参数可用且该次请求被接受，尚无证据证明服务商把 `8192` 定义为硬上限。
- 新 Debug App `/tmp/banban_web_fix_goal_20261123/macos_build/macos/Build/Products/Debug/伴伴.app`，PID `33001`，版本 `2.6.1` / build `15`，`kernel_blob.bin` SHA-256 `d7e1af047f55376a2d3d6a43b12a380e81a9767fe08c8dab2cccf5cf145c489f`。定向回归 `79` 项与联网/路由/UI相关回归 `62` 项通过；`flutter analyze --no-pub` 无问题；macOS Debug 构建成功；Windows 仅做 worker 文件哈希、Node `24.14.1` win-x64 PE 架构和 CMake 路径静态复核，未做 Windows 实机验收。
- **12:52 CST 参数诊断版 Debug 复测：**新包 `/tmp/banban_web_fix_goal_20261123/macos_build_paramdiag/macos/Build/Products/Debug/伴伴.app`，版本 `2.6.1+15`，kernel SHA-256 `3a204eaf29e6896ea17a1de49b2c74d47ce212436f3d74134b8acb8e00d7d089`。实际 SenseNova 普通私聊会话仍为 `dm:74f5d00b-1859-41c5-8d84-84c73ae5e240`；用户消息 `79d20c1d-b0a3-4469-b1b2-139f09090277`。失败诊断实际持久化 `requestedMaxTokens=8192`：reply `bdac4e37-9632-4a1d-9c1b-35b06135aa08` 输入 `2109`、输出 `22`（推理 `22`）；retry `c76b38ee-7ec2-4127-8465-445168f0679f` 输入 `2030`、输出 `103`（推理 `103`）。两笔 `exactUsage=true`，均 `empty_completion`，实际请求未耗尽 `8192`；没有搜索、读取、下载、来源、附件或打开结果。服务端成功返回 usage 且未拒绝该参数，确认接受 `8192`；公开文档仍未给出此模型数值硬上限。
- 新增 `requestedMaxTokens` 后，`ai_request_gateway_test.dart`、`chat_api_service_streaming_test.dart`、`context_window_manager_test.dart` 共 `79` 项通过；`flutter analyze --no-pub` 无问题；参数诊断版 macOS Debug 构建成功。只读 Hive 字节副本诊断通过并确认原文件大小/修改时间未变，随后删除本轮临时 `test/qa_sensenova_max_tokens_diag_tmp_test.dart`。保留已有 `test/qa_web_fix_diagnostics_tmp_test.dart`；未提交、推送或发布。
- 新闻角色 `glm-4-flash` 普通回复界面显示 `nativeModel`，智谱搜索返回 5 个无 Flutter 官方链接结果；无发布日期、正文事实或自主搜索/读取/下载旁路。主动回复没有可触发候选，工作入口不可达，均记未验证。圆桌检查开场、后续与总结；一次误发的单词 `Flutter` 搜索和一次有明确目标的智谱补查均只走 `nativeModel`，补查时间 `2026-11-23 12:27:35 Asia/Shanghai`，结果仍无 Flutter 官方 URL、发布日期或正文事实。讨论漂到证书话题与 `3.47.8`，未见 `$1` 格式残留；质量不通过，不调用伴伴自主联网工具。
- 旧任务 `c440b0fe-47a8-456d-a3c0-0c12158d1c56` 的 Debug UI/持久状态仍要求本机重新绑定并核对原项目；原工作区路径缺失，记录不在候选阶段，没有可点的有效“继续测试”。未伪造项目或把旧候选当交付。新建 Qiniu 群聊工作任务 `15a54b51` 使用 `QA-Matrix-StepFun`（Qiniu maker）和同配置 `QA-Matrix-Review-B`；已确认需求，但独立审查收到两次 HTTP `429`，没有候选、冻结、审查、正式交付或可打开附件，判失败。
- 六个验收角色最终均为关闭；曾开启的 DeepSeek、SenseNova、Review-A、Review-B、StepFun（Qiniu）已保存关闭，ST 本轮未修改且 UI 显示关闭。本轮 Debug UI 重开核对了 DeepSeek、SenseNova、Review-B、StepFun 和 ST；Review-A 保存关闭后未能在本轮重新打开表单读回开关，历史 Debug UI 有该角色关闭的回读证据。未改真实角色、API Key 或搜索 Key。
- 当前矩阵最新计数为通过 `3`、失败 `13`、未验证 `0`：DeepSeek 普通私聊的本轮失败覆盖较早通过记录；其余格状态沿用 UI 验收文档逐格记录。保留既有诊断测试 `test/qa_web_fix_diagnostics_tmp_test.dart` 和有效回归；只删除本轮 `test/qa_sensenova_budget_diagnostics_this_turn_tmp_test.dart` 与 `/tmp/banban_web_fix_goal_20261123/route_tests.log`。无提交、推送或发布。
- 目标未完成：矩阵 13 格失败；新闻主动/工作入口未验证；圆桌来源质量失败；旧任务无法恢复。Review-A 权限复原现已由 Debug UI 回读确认。

## 2026-11-23 13:01–13:42 CST DeepSeek 普通私聊自主联网复测

- **配置 / 模式 / 构建：**`QA-Matrix-DeepSeek`，DeepSeek v4.1 / `deepseek-flash`，普通私聊 `dm:f10b6e20-9a0b-4384-8cc5-eaff205b19b4`。Debug App `/tmp/banban_web_fix_goal_20261123/macos_build_paramdiag/macos/Build/Products/Debug/伴伴.app`，PID `62254`，版本 `2.6.1+15`，kernel SHA-256 `3a204eaf29e6896ea17a1de49b2c74d47ce212436f3d74134b8acb8e00d7d089`。首条用户消息 `7690e8e0-6312-4248-abdf-7485329a7d8d` 不含目标 URL；两条后续复核消息 `f463adae-e605-45ed-b6b0-a5bcc775cbea` 和 `6c3c66af-7d1c-4cea-ba37-fe8a4a38130d` 也不含目标 URL。
- **模型 / 搜索：**首条 AI 消息 `fc008819-2b1d-430c-b4b7-360e0a760c2f` 的快照使用 `autonomous-web`。初搜 `site:github.com flutter/flutter README.md repository` 于 `2026-11-23T05:01:03.297607Z` 返回 `NO_SEARCH_RESULTS`，receipt `82dca18f-b225-4a43-ae9e-099dc5cde0f9`，request `74795a38-fb66-49f8-97ca-b465cb8826f1`，0 来源。
- **后续搜索 / 读取：**receipt `f5533ca5-1774-4519-8f50-c7860c649ca3`（request `91315d90-b650-4e39-9f36-47a38287fd78`，`2026-11-23T05:06:15.741649Z`）以宽词搜索成功，5 条结果均来自 Flutter 官方文档/中文镜像或第三方教程，没有 GitHub 仓库。`web.read` receipt `2dd2f25c-5155-4af4-8630-44db695b371c` 于 `05:06:28.269872Z` 读取 `https://flutter.dev/` 首页，正文 `75569` 字节、SHA-256 `8f9ffc5f32bf787056c050c1440472404ee91a99fe256c69a8f3c949cdfc2fb7`。AI 报告的可核验事实为 Flutter 是用于以单一代码库构建多平台应用的开源框架。该页不是 GitHub README，正文无绝对发布日期/更新日期。
- **定向查询 / 交付：**第三个查询 `Flutter GitHub repository README` 于 `2026-11-23T05:09:28.014316Z` 返回 5 条非 GitHub 结果；receipt `92e1a947-cf56-4498-8a2c-cdbe9124caaf`，request `04fd84c1-fa14-4c7c-92c0-4188215e2d8f`。没有 `web.download` receipt、下载文件、附件、下载字节数/哈希。最后 AI 气泡 `592dc108-cf25-440e-8318-8f7aa7aaf0bf` 没有附件，因此没有可点击打开的文件。格结论仍失败：自主搜索/读取路径已实测，但结果没有目标 GitHub README，无法完成下载和附件闭环；不判模型不支持联网。
- **路由 / 权限：**DeepSeek 角色两项智谱搜索开关此前在 Debug UI 读回关闭；本轮实测 `autonomous-web` 手动私聊路由，首搜失败后补查仍可继续。历史 DeepSeek 普通群聊于 2026-11-18 已完成 raw README 附件打开闭环。六个 QA 角色的 `workspaceRead` / `workspacePatch` 均已关闭；本轮重开 Review-A 表单，界面截图确认两项均未选中。
- **后续工具协议复核：**`2026-11-23T05:17:26.207151Z` 的 `web.read` 回执 `a92d417e-7e92-41b1-846b-f568522153d4` 因复用上一轮 `sourceId=s1` 返回 `SOURCE_NOT_REGISTERED`，没有正文。CUA 输入失真导致用户消息 `4b3aa004-f3fa-4d49-8fe8-de4fb007735b` 只含关键词片段，该提示与随后 receipt `19af2b2f-b1a0-4068-a7e8-8ec774aea48b` 不计作有效复测。随后验证英文输入后，用户消息 `f3910198-9178-4f24-a361-262e43efd57e` 发起查询 `Flutter source code GitHub official repository`；搜索 receipt `ac597eeb-74f1-4fdf-b582-bddb1a97c0ed` / request `f136ea5d-3095-4b88-8d83-0577346ffa42` 于 `2026-11-23T05:23:06.052165Z` 返回 `REQUEST_FAILED`、`retryable=false`、0 来源，完成时间 `05:23:18.176209Z`。没有读取/下载/附件；最终 AI 气泡 `cf727b52-68f7-434f-827d-3002899336d1` 无附件，无法点击打开文件。此为服务搜索失败，不归因为模型不支持联网。
- 临时只读诊断 `test/qa_deepseek_dm_diag_this_turn_tmp_test.dart`、`test/qa_deepseek_dm_messages_this_turn_tmp_test.dart`、`test/qa_deepseek_receipts_this_turn_tmp_test.dart` 均仅读取 Hive 字节副本，现已删除；保留 `test/qa_web_fix_diagnostics_tmp_test.dart`。当前矩阵通过 `3`、失败 `13`、未验证 `0`。未提交、推送或发布。

### 2026-11-23 13:34–13:42 CST 续验

- 同一 Debug App / `QA-Matrix-DeepSeek` 私聊会话继续使用无目标 URL 的用户消息 `dd0b53fd-2408-4b08-be90-c8943dc85981`。搜索 request `420dc9d6-3efd-4662-8369-ba8ec6d34aed` 于 `2026-11-23T05:34:34.184421Z` 成功，receipt `aba30531-5932-47b7-9f79-e6c83a98b7dc`；查询 `Flutter official source repository README`，provider `Bing HTML`，返回 `flutter.dev`、`docs.flutter.dev/install`、`flutter.cn`、`runoob.com`、`docs.flutter.cn/install/` 五项，无 GitHub/raw 来源。
- `docs.flutter.dev/install` 的两笔 `web.read` receipt 为 `598e5bcc-3296-4036-af6d-0ce5b7838f87`（startSection `0`、nextSection `1`）和 `fe8a7d29-96c0-40c2-bc3e-3ed1f5819d44`（startSection `1`，成功；回执未记录 nextSection，序列化器省略 null）。两笔回执均记整页 `byteLength=152622`、SHA-256 `faddc43b8af708a9a887cf07a4e4933b07b5f80ff07e3cd7da738cf6edb0fa9c`；源码 `DesktopWebService.read` 在分页前对整份响应字节计算这两项，因此重复值属于同一页面级证据，不等于下载文件哈希，也不单独证明分段正文已拼接。AI 气泡报告页面写有 Flutter 3.50 文档说明及 `2026-11-20` 页面更新日。搜索结果 `publishedAt=null`，故页面更新日不当作发布日期。回执保存读取元数据、不含正文；正文事实保留为 UI 中 AI 所述，不作为附件闭环证据。
- 定向用户消息 `4ebd2ee0-4814-4fd3-ab3c-5cb6d3827812` 触发搜索 request `ea66955d-71f4-4823-80a0-a366d9ef6405`，receipt `24dbe38c-1a7a-437e-9a5c-833d06298b8b` 于 `2026-11-23T05:37:39.397436Z` 成功；查询 `Flutter official GitHub source repository README`，仍返回相同五个非 GitHub 来源。随后用户消息 `127db73e-616a-4b60-a212-a20ea0cb7fd0` 的查询 `Flutter SDK official GitHub repository` 返回 `REQUEST_FAILED`、`retryable=false`、0 来源；receipt `c8a45224-12dc-4a82-885f-fcc749e4f9d8` / request `7a0bf26a-e761-46d1-a6ca-bd8baa5bb65d`，完成于 `2026-11-23T05:42:08.324481Z`，未提供 HTTP 状态码。没有 `web.download` 回执；临时目录没有 `README.md`，本轮 AI 气泡没有附件或可点击打开的文件。
- **结论：失败。**本轮 UI 证明 autonomous-web 可成功搜索和分段读取公开网页，且也实测不可重试的检索失败；两次成功查询都未返回 GitHub/raw README，附件交付未发生。按工具阶段记录，不把该结果归因为模型不支持联网。矩阵仍通过 `3`、失败 `13`、未验证 `0`。本轮只读 Hive 字节副本诊断回归通过，文件大小与修改时间前后不变；临时测试随后删除。既有 `test/qa_web_fix_diagnostics_tmp_test.dart` 保留。


### 2026-11-23 14:08–14:10 CST SenseNova 普通私聊输出上限复测

真实 Debug UI 在 `QA-Matrix-SenseNova` / `sensenova-6.8-flash-lite` 普通私聊会话 `dm:74f5d00b-1859-41c5-8d84-84c73ae5e240` 发送纯文本控制提示 `Reply with exactly OK and no other text. Do not call tools.`。App 为 `/tmp/banban_web_fix_goal_20261123/macos_build_paramdiag/macos/Build/Products/Debug/伴伴.app`，PID `62254`，版本 `2.6.1+15`，kernel SHA-256 `3a204eaf29e6896ea17a1de49b2c74d47ce212436f3d74134b8acb8e00d7d089`。用户消息 `7244be09-3d7d-4a20-9e24-fe8f2d6f5ebc` 收到错误气泡 `e5fe8cdf-25ca-40f4-a541-16e59d8490b9`：“模型返回了空内容（推理可能占满了输出预算）”。

只读 Hive 字节副本诊断回归通过，原文件大小与修改时间未变化。`reply` request `53457b0a-6193-4be1-a68e-2557d338e49b` 的实际参数记录为 `requestedMaxTokens=8192`、`exactUsage=true`；提供方 `custom` 返回 input `2135`、output `8192`、reasoning `8192`，latency `68878 ms`，时间 `2026-11-23T06:09:52.707175Z`，状态 `failed / empty_completion`。该响应证明 8192 参数已被本次调用接受并返回对应 usage，但不代表已查明服务商文档定义的硬上限。retry request `71dba504-60ba-4a5a-b5b8-d774fb7afb68` 仍传 8192，input `2056`、output/reasoning `49`，latency `2251 ms`，时间 `2026-11-23T06:09:54.967486Z`，仍为 `empty_completion`。后台 `purpose=autoChat` 调用不属于控制提示或验收格，不计入结果。全程无联网工具回执、来源、下载或附件可打开；该格仍失败，不归因为模型不支持联网。临时诊断 `test/qa_sensenova_control_diag_tmp_test.dart` 已删除，既有 `test/qa_web_fix_diagnostics_tmp_test.dart` 保留。

**SenseNova 普通私聊格仍失败。**8192 专用上限生效，首轮 reasoning 用量达到 8192 后仍空回复；重试 49 reasoning 后也空回复。群聊与工作模式上限没有随本次修复提高。


### 2026-11-23 14:36–15:20 CST 智谱开关真实 UI 路由续验

使用 Debug App `2.6.1+15` / PID `62254` 和 QA 角色 `QA-Matrix-DeepSeek`。普通私聊消息 `0733eb60-d026-4c66-bda8-62cbe3eeaec6` 的 UI 先显示 `nativeModel`，真实快照 provider `zhipu-native`、HTTP `200`、5 来源；search request `366496e5-5963-4023-b0d8-a8e43bf98abc`，UTC 检索 `2026-11-23T06:37:47.630118Z`。来源均非 Flutter 官方域名或无 URL。普通群聊消息 `97d903b8-679d-412f-b9a1-99ece6dc881b`（同名群 ID `7299424f-bff2-45b1-9634-650858de61a1`）同样先经 `zhipu-native`，HTTP `200`、5 来源；随后目标不匹配时继续 `autonomous-web` 查询 `fac5e3c2-b07e-41bf-a81f-1a1f4e3d69d7`，读取官方安装页后又有一次 `REQUEST_FAILED` `8ac7afe0-4976-40d0-a0da-4e061c47735a`。这证明实际 UI 中智谱先行，搜索质量不足时仍可继续自主联网。

把 QA 角色 `允许使用智谱搜索来源` 暂时开启期间，`仅使用智谱搜索问答流程` 保持 off；测试完保存关闭，并重开表单确认两个开关均 off。另一同名普通群（ID `8eed902b-e1f5-4b00-89dc-e9a23f4a7d7c`）手动查询后实际使用 `autonomous-web`，snapshot request `f5a49b0a-8b88-49fa-8f4c-70a0ceb1a38a` 返回官方安装页，AI 气泡报告已读取两段正文；后续查询 `5b10ef67-b0eb-4767-b319-1219f9a91b2d` 失败。该本轮关闭态 group 请求均为 `isWorkMode=false`。普通私聊关双开关的 autonomous-web 证据和关闭态 group raw 原件交付闭环沿用验收文档历史小节。

真实 Zhipu 请求在这两条 UI 查询中均 HTTP 200；不能把它们写成实时 Zhipu 服务失败。失败后的自主回退由 `test/network_reply_stream_test.dart` 和本轮 62 项路由回归覆盖。六个 QA 角色 workspace read/patch 权限仍关闭；本轮 DeepSeek QA 搜索开关已恢复关闭，未改 Key 或真实角色权限。

**收尾状态：验收目标完成，矩阵通过 3、失败 13、未验证 0。**失败项、未验证入口及原因见 `docs/desktop_web_ui_acceptance_2026-10-26.md` 最终汇总；“完成”仅指验收证据、路由复核和权限收尾闭环，不代表失败格通过。回归、分析、Debug 构建和 Windows 静态检查均沿用该文档记录。未提交、推送或发布。

### 2026-11-23 16:29 CST Windows worker 当前包静态复核

- `windows/CMakeLists.txt` 在安装阶段调用 `scripts/package_web_worker.py win-x64 <CMAKE_INSTALL_PREFIX>/web_worker`；`WebWorkerClient.bundled()` 以 `Platform.resolvedExecutable` 所在目录为基准，Windows 读取同级 `web_worker/node.exe` 和 `web_worker/src/desktop_worker.ts`，安装目录与运行时解析规则一致。
- 临时包 `runtime.json` 为 Node `24.14.1` / `win-x64`，归档 SHA-256 `6e50ce5498c0cebc20fd39ab3ff5df836ed2f8a31aa093cecad8497cff126d70`；`node.exe` 为 PE32+ x86-64，SHA-256 `58e74bf02fc5bbacc41dcb8bef089961cd5bddd37830b87784e4fc624d145d1f`。
- 临时包内六个 worker 源文件与当前 `gateway/src` 逐项 SHA-256 一致：`desktop_worker.ts` `f156e72068aad0d94946d5becf6e26c0da4045980ff67d8ea292f7cced5dd692`、`public_web_transport.ts` `61eea3761a17b3c9565dec80bd6150c18fa0927df08461ef42828715dde946f4`、`public_web_dns.ts` `e9584c9d1fa35a06ad1720eb439edda213d20119fc5de6f2a3186317abdbfd8e`、`network_security.ts` `b1f3e1b7901cf180164b5906b577b46489a367f4495df2e1d0acee982ba373df`、`types.ts` `36478603ef14a9861b89795fda618e8b9aaf5857baad315f8fb34048daa59d4d`、`github_skill_upstream.ts` `1f3ad5ecfcf4214e056a4184c203f4cf2ff6c9434cc78270b0211cd01e06dba7`。
- 本次只读核对包与路径，没有启动 Windows worker 或做 Windows 实机验收；未改打包代码、Key 或联网服务。

### 2026-11-23 16:31 CST Debug App 收尾状态

- 磁盘 Debug 包仍为 `2.6.1+15`，`kernel_blob.bin` SHA-256 `3a204eaf29e6896ea17a1de49b2c74d47ce212436f3d74134b8acb8e00d7d089`。最终 `ps` 核对时，验收进程 PID `62254` 已退出；未发现其他伴伴进程或对应 Hive 数据锁。SenseNova 与路由 UI 回执均在该进程退出前产生并已记录；结束时没有运行中的 Debug App。
