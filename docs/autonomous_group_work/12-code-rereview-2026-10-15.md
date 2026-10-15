# 修复后代码复审

日期：2026-10-15。范围：首轮 F01–F19 的修复、受影响生产调用方、协议/权限/恢复/备份、模型上下文与相关测试。仍按用户要求仅 review，不做现场验收，不修改业务代码或测试。

基线 HEAD：`9bbaef7`，检查未提交工作区，不假设改动已提交。再次完整读取 `CLAUDE.md`、首轮报告及相关规格。代码审查包括正确性、失败边界、测试有效性、结构、安全、性能和旧状态兼容；没有仅凭修复声明或首轮测试结果关闭问题。

本轮对 146 个范围内修改/新增代码、测试及配置文件留取摘要，结束时这 146 份内容均未变化。结束盘点另发现新出现的 `test/zz_probe_live_connection_test.dart`，不属于留取的修复基线，也未纳入已启动的全量套件；未审查、执行或删除该文件。本报告的全量结果不覆盖这个后来新增的独立测试。

## 结论

**仍需修改，不能认定 F01–F19 已全部修复。确认本轮 14 项需要处理的问题：3 项 P1、11 项 P2。** 多处原始根因确实已封住，但存在业务误通过、文档视觉流程阻断、技能验证旁路等剩余问题及回归。以下列出本轮确定问题，原始编号继续用 F，本轮编号用 R。

首轮 19 项按具体根因/最低修复建议计，11 项已关闭，8 项仍部分修复；关闭不代表相关功能整体通过，例如 F02 白名单已修但正常合同入口另有 R03。F19 按首轮明确允许的“缺失显式标注”方案关闭，不移动修复标准。

本轮只新增这份复审记录；没有修复、格式化写入、暂存、提交或发布产品代码，没有读取真实 Hive/凭据或操作 GUI。

## P1

### R01 原生断言仍可只检查静态按钮，绕过真实业务验收（F04）

位置：[macos_native_app_automation.dart:1092](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/macos_native_app_automation.dart:1092)。

普通 click/resize 等动作不再直接签全部验收，这部分已改；新 assert 却从整个 assignment.expectedResult 和 acceptance.method 中提取所有引号片段，让模型任选一个，只要目标 label/value 包含它就给该验收 `businessResultVerified=true`。没有另外核对已完成的 requiredCapabilities/步骤。

可达示例：预期 `点击“保存”后显示“保存成功”并持久化`，直接断言现有“保存”按钮且 expectedText 为“保存”，不点击、不写入、不重启，也能签通过。最终使用校验只合并 verifiedAcceptanceIds，无法补回业务义务。

建议：逐验收冻结明确的结果断言，区分操作对象文字与结果；检查必需操作、状态变化及持久化/输出，不从描述的多处引用中任选弱条件。补“只有保存按钮、没有保存结果”的负例。

### R02 render 返回缺少 path，全部视觉页无法生成使用观察（F08 新回归）

位置：[default_work_task_runner_usage.dart:159](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/default_work_task_runner_usage.dart:159)，[work_document_tool.dart:446](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/work_document_tool.dart:446)。

为按候选路径/摘要绑定，`_recordDocumentModelUse` 新增 `data.path` 必须为 String 的检查；但 render 成功数据没有 path，wrapper 也没补。正文 read 有 path，render 没有，因此即使真实渲染成功且图像送达，仍在第 160 行 continue，永远无法得到 visual-read，全页完成门禁无法满足。

建议：统一工具输出的文件身份契约，按冻结候选绑定相对路径和摘要。补 render→实际模型消息→使用观察→完成门禁的整合测试，而不只测页图传输 helper。

### R03 正常原生请求仍缺模型可用的合同构造入口（F02 关联缺口）

位置：[work_discussion_v2_protocol_text.dart:29](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/work_discussion_v2_protocol_text.dart:29)，[work_discussion_state.dart:217](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/work_discussion_state.dart:217)。

白名单已允许 nativeBundle，但新任务仍只初始化 type/format/location/revisionTarget，发送给讨论模型的提案协议也未说明 nativeBundle 的 schemaVersion/appPath/archivePath 与 files 的关联。全 lib 检索没有应用播种该原生合同的入口。按当前公开协议产出的合法 `.app` 方案不带此字段，会在 candidateSources 走普通 File 分支，usage 也不注册 native.app。

这不是声称模型绝不可能猜到字段，而是正常入口仍依赖一个没有向模型描述、也没有由应用构造的私有前置条件。手工构造状态测试无法证明自然语言任务可达。

建议：向实际讨论提示提供严格原生合同结构或由可信路由播种，并校验 `.app` 任务不能静默误走普通文件路径；增加从自然语言请求到合法原生合同的整合测试。

## P2

### R04 不同路径的相同文档被去重后，无法分别完成（F08 新回归）

位置：[default_work_task_runner_usage.dart:252](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/default_work_task_runner_usage.dart:252)，同文件第 268 行。

新门禁按 documentPath+摘要分别要求证据，但正文 manifest 和观察去重键仍不含 documentPath。合法候选 `a/report.docx`、`b/report.docx` 字节相同，两份正文/来源/内容寻址引用均相同，第二份真实读取被当 duplicate 丢弃，新门禁却要求第二条路径自己的观察，因此永远不能满足。

建议：把候选相对路径纳入证据和去重身份；分别测“同名不同内容不可借证据”和“同名相同内容实际读取后可以完成”。此问题独立于 R02，在正文检查路径即可发生。

### R05 取消清理发现包变化，但失效结果没有持久化（F07）

位置：[macos_native_app_automation.dart:1316](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/macos_native_app_automation.dart:1316)，[default_work_task_runner_execution.dart:350](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/default_work_task_runner_execution.dart:350)。

正常工具动作/显式 close 会复核解包树并清除旧观察；暂停/停止调用 cancelTask 时却丢弃 `_close` 的失败结果，取消后的 onToolResult 也不再记录。若通过观察已封存，随后副本变化并取消，关闭检测虽然发现 nativeAppCandidateChanged，旧 v2UsageObservationRef 仍在。继续时只核原 ZIP、恢复原观察，副本已被清理，失效事实无法再从旧路径发现。

建议：将包失效写成可靠的本地任务证据/失效标记，恢复先查，不能只依赖正常工具返回值。补“通过观察→改副本→暂停清理→继续”的用例。

### R06 两套字体解析选出不同替代字体时仍放行（F12）

位置：[document_page_renderer.dart:311](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/document/document_page_renderer.dart:311)。

新逻辑只有 fc-match 的结果恰好匹配 PDF 实际字体时才记替换；有非空 fallback、但与 PDF 实际字体不一致时既不记替换也不记 unverified，最终仍可 resolved。本机只读探测缺失的 ChatGroupMissingFontReview99999 返回 Verdana，而前轮合成 DOCX 转换实际选择 LinuxLibertineG，正是两引擎不一致的情况。

建议：所有无法证明源字体实际解析的情况明确 unverified，不因“fc-match 有任意结果”放行；补不同解析器 fallback 的负例。本轮未重新做现场文档验收。

### R07 内置模板安装可激活同名未验证草稿（F17）

位置：[default_work_task_runner_delivery.dart:90](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/default_work_task_runner_delivery.dart:90)。

create 已改成不绑定的 draft，但 download 按名称及角色关系选已有 resourcePackId=null 技能。先创建名为 `Create Skills`、内容任意的未验证草稿，再安装 `meta.create-skills`，会复用该草稿并加入 skillIds，而非加载可信模板或验证草稿。配置修改审批不等于方法已验证。

建议：按可信模板身份/内容校验复用，不按显示名称混用；补 create→download→新任务提示的整合负例。

### R08 普通自建草稿没有成功验证后的激活入口（F17）

位置：[default_work_task_runner_delivery.dart:69](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/default_work_task_runner_delivery.dart:69)。

普通 draft 不写 skillIds，resolver/discoverableSkills 排除它；目前成功使用激活仅处理有 resourcePackId 的远程包。全库调用链没有为普通自建方法建立代表性验证、复测后激活的入口。避免提前激活是对的，但不能因此让合法成功方法永久不可复用。

建议：接通具有真实验证依据的自建草稿生命周期，并测试失败不激活、实际成功与复测后可在新任务使用。关联设计 §9.4/A21。

### R09 代码参考文件仍被误当成必须执行的脚本（F16）

位置：[skill_resource_pack_store.dart:276](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/agentic/skill_resource_pack_store.dart:276)。

纯 Markdown 方法已不再强制脚本；但 hasScript 对整个文件清单按扩展名判断。合法的 `SKILL.md + references/example.py`，Python 仅供阅读时仍要求 scriptRuns，否则无法验证。生产解析器隔离复现确认接受该结构。

建议：按方法声明和实际脚本入口判定义务，不强迫执行代码参考；同时保持真正需要脚本的方法必须实际运行。

### R10 改派制作人后面板继续显示旧推荐人（F10 关联回归）

位置：[work_task_panel_details.dart:276](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/presentation/work_task_panel_details.dart:276)，[work_task_coordinator_submission.dart:379](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/work_task_coordinator_submission.dart:379)。

自动推荐 A→群讨论合法改派 B 后，实际 production 按 B 的工作项执行，shell.executorId 仍为 A；面板优先取 shell 而不是当前唯一 maker，显示 A 为“制作执行者”。

建议：自主任务按当前计划唯一制作人展示，或同步非钉定推荐值；测试“推荐 A→制作 B→试用 C”，避免把试用人当制作人。

### R11 上版已经写坏的 blocked 检查点仍无继续入口（F09）

位置：[default_work_task_runner_production.dart:150](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/default_work_task_runner_production.dart:150)，[work_task_coordinator_discussion_lifecycle.dart:184](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/work_task_coordinator_discussion_lifecycle.dart:184)。

新 blocked 不再进入 `_recordUsageFailure`，新任务该分支已修；此前同一自主 schema 已写成 clarifying、工作项 done、当前候选存在且 planReady=true 的 blocked 任务没有迁移/显式继续修复。继续仍既不能进 production，也不能重新讨论。

建议：仅对有可信 blocked 依据、没有真实失败缺陷的旧形态，在显式继续时恢复可重新验证的阶段。不能一律把 clarifying 当环境阻塞而跳过讨论。

### R12 收据和钉定测试仍用旧语义，回归实际失败

位置：[work_collaboration_state_autonomy_test_cases.dart:277](/Volumes/new_disk/work/flutter/chat_group/chat_group/test/work_mode/work_collaboration_state_autonomy_test_cases.dart:277)，[default_work_task_runner_stage02_test_part_p8.dart:180](/Volumes/new_disk/work/flutter/chat_group/chat_group/test/work_mode/default_work_task_runner_stage02_test_part_p8.dart:180)。

前者用 `outputRefs:['image']`，第 303 行却期待可信收据有效；后者用 `outputRefs:['output-a']`，第 220 行期待选择下一成员 B。F11 修复后这些引用理应无效，实跑分别得到 false、A。后一个测试第 224 行仍将只改 shell.executorId 视作违反用户钉定，而 fixture 没有 explicitExecutorId，也与 F10 修复后的正确语义冲突；此断言被更早失败挡住，尚不能按一次实跑算作第三个失败用例。

建议：在隔离目录通过生产证据存储写真实受控文件；分别覆盖有效、删除、篡改与借用拒绝，并为用户明确钉定建立真实 fixture。不能为了测试绿而取消 F11 的文件核验或恢复错误的自动钉定。

### R13 原生候选的人工复核/基线路径仍读取工作区 ZIP（F03 残留）

位置：[default_work_task_runner_production_delivery.dart:10](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/default_work_task_runner_production_delivery.dart:10)，同文件第 45 行。

自动 review 已改取冻结 candidate.file，但 `_recordUserProductionReview` 的 testedFiles 及 `_republishProductionBaseline` 仍取 workspace/archivePath。正常原生发布只在临时目录封装并冻结 ZIP，工作区没有该 ZIP；验收项全为 manual/waived 时 `_prepareProductionReviewer` 明确安排 user-review，仍会触发同样的缺文件错误。基线重发还把绝对 testedPaths 传给 native candidate 分支，后者只接受合同相对 archivePath，即使补工作区 ZIP 也存在参数身份冲突。

建议：统一原生候选各审查/人工复核/基线重发分支的文件身份，而非只修一个入口；按原生合同传递正确的 requiredPaths。补含明确人工决定的原生候选分支测试，不把人工决定冒充全员已试用。

### R14 长讨论超过软字符预算后，整块个人记忆被丢弃

位置：[work_mode_memory_runner.dart:53](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/work_mode_memory_runner.dart:53)，[work_discussion_v2_requests.dart:25](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/work_discussion_v2_requests.dart:25)。

本轮全量测试 `不同成员真实接线：97 次读取后当前方案逐人认可` 在 [work_discussion_v2_test.dart:684](/Volumes/new_disk/work/flutter/chat_group/chat_group/test/work_mode/work_discussion_v2_test.dart:684) 丢失“稳定偏好_dev”。实际个人消息槽变成任务 JSON，说明不是单条偏好被筛掉，而是当前成员整块人格/关系/记忆没有插入。

调用链中，一旦 prepared 超 discussion 的软字符预算，runWithUnifiedMemory 直接退回原 conversationHistory；该预算至多 24576 字符，后续必要上下文却仍按模型真实大窗口放行。本轮给所有阶段追加的原生 assert 说明增加提示长度，使原有 97 次读取边界再次触发整块丢弃。此为已有预算策略在修复后暴露的可复现长上下文风险，不是本轮新写了一条记忆删除语句。

建议：预留当前成员简要人格/关系/必要记忆，优先收敛已替代证据和可选历史，不能删除未决义务；不要以删掉测试断言或再次压缩一小句提示作为唯一解决。真实拟人化效果仍需独立现场验收。

## 测试结果

独立命令日志：

- `/tmp/chat-group-rereview-20261015-analyze.log`：flutter analyze --no-pub，退出 0，No issues found。
- `/tmp/chat-group-rereview-20261015-gateway.log`：gateway npm test，32 通过、0 失败，退出 0。
- `/tmp/chat-group-rereview-20261015-flutter.jsonl`：`flutter test --no-pub --concurrency=1 --timeout 30s --reporter json`，3477 通过、3 失败、3 跳过，退出 1；最终 done.success=false，约 657 秒。
- `/tmp/chat-group-rereview-20261015-failed-rerun.jsonl`：对下表 3 个失败用例定向重跑，0 通过、3 失败，退出 1，约 11 秒；相同断言再次失败，不是只凭单次全量失败下结论。
- Dart 格式检查使用 `--output=none --set-exit-if-changed`：137 文件、1 个需格式化，退出 1；是 `work_agent_loop_checkpoint.dart`，没有写回文件。
- git diff --check、bash -n scripts/publish_local.sh：通过。
- `/tmp/chat_group_rereview_skills.dart`：直接调用生产 parser/prompt，4 项 PASS，覆盖纯引用包、含代码参考包、四种保留名拒绝、提示含 packId/SKILL.md。未把 parser 接受等同于实际验证激活。
- 曾用前轮 `/tmp/chat_group_review_native_archive.dart` 尝试独立 Dart 复现；新依赖链经 publisher→binary_document_parser 引入 Flutter 的 dart:ui，普通 Dart VM 编译退出 254，封装逻辑未运行。此尝试不计 F01 实测通过，也不把工具运行环境不适配当作业务漏洞；F01 本轮关闭依据生产扫描调用链核对。

| 稳定复现失败的用例 | 实际失败 | 位置 | 关联 |
| --- | --- | --- | --- |
| 不同成员真实接线：97 次读取后当前方案逐人认可 | 丢失稳定偏好_dev，个人上下文未插入 | work_discussion_v2_test.dart:684 | R14 |
| P1 逐成员串行试用切换 actor，不改用户钉定 executor 或借前人上下文 | 期待 B，实际 A；A 的旧假引用不再有效 | default_work_task_runner_stage02_test_part_p8.dart:220 | R12 |
| 使用正文 JSON 不能取得本地运行器收据，跨设备引用不继承权限 | 期待 valid=true，实际 false；引用不是受控文件 | work_collaboration_state_autonomy_test_cases.dart:303 | R12 |

定向命令：

```bash
flutter test --no-pub --concurrency=1 --timeout 30s --reporter json \
  --name '97 次读取|P1 逐成员串行试用|使用正文 JSON' \
  test/work_mode/work_discussion_v2_test.dart \
  test/work_mode/default_work_task_runner_stage02_test.dart \
  test/work_mode/work_collaboration_state_test.dart
```

全量跳过项仍为 1 项需实包路径的归档测试、2 项需 opt-in 的 Appium 服务归属测试。没有为 review 启动现场服务。临时日志是本机辅助，报告已保留结果，不声称 /tmp 能作为长期或跨设备证据归档。

本轮没有运行 build_runner、产品构建/签名、GUI、真实模型、原生服务或联网技能导入。当前修复没有新增 Hive 字段编号；生成源变更仍沿用首轮已有 adapter，本轮只读检查，不为 review 产生生成文件改动。

## F01–F19 复查表

“原根因已修”只说明当前代码封住首轮具体问题，不代表现场验收通过；关联回归另列。

| 原编号 | 复查结论 | 当前依据/剩余问题 |
| --- | --- | --- |
| F01 | 已修 | 原生全部包内路径及适用文件内容扫描已接入；未做真实敏感数据测试 |
| F02 | 原白名单已修 | actions 已允许 nativeBundle；正常协议/初始化缺口见 R03 |
| F03 | 部分 | 自动 review 改取 candidate.file；人工复核/基线仍有相同错误，见 R13 |
| F04 | 部分 | 普通动作不再签业务通过；断言降级旁路见 R01 |
| F05 | 传输主断点已修 | 原生结果含 image_url，checkpoint 接纳 native.app；真实图像送达仍须独立验收 |
| F06 | 已修 | 无 identifier 的当前窗口控件生成受控 selector；未在 GUI 实操 |
| F07 | 部分 | 正常路径重核树摘要；取消路径丢失失效事实，见 R05 |
| F08 | 部分且有回归 | 路径/摘要门禁已加强，render 契约和去重漏接，见 R02/R04 |
| F09 | 新流程已修、存量未修 | 新 blocked 保留 reviewing，旧坏检查点见 R11 |
| F10 | 原约束已修 | 只以 explicitExecutorId 钉定；制作人显示见 R10 |
| F11 | 已修 | valid 逐条读取受控证据并验证内容摘要；回归 fixture 需同步 |
| F12 | 部分 | 新增替换记录但仍有未证明即 resolved 的分支，见 R06 |
| F13 | 已修 | 内部队列 Future 立即装错误监听，调用方业务异常独立传播 |
| F14 | 已修 | parser/恢复入口及 store 拒绝根 pack.json/usage.json，大小写变体实跑通过 |
| F15 | 已修 | 实际提示及精简目录注入 packId 和 SKILL.md 读取入口，生产提示实跑通过 |
| F16 | 部分 | 无代码扩展名的引用包可走无脚本路径；代码参考仍误判，见 R09 |
| F17 | 部分 | 创建不直接绑定，但有下载旁路且普通草稿无验证激活，见 R07/R08 |
| F18 | 已修 | 指令去重保留大小写/运算符，只归一化换行 |
| F19 | 最低修复建议已满足 | 导出 manifest 显式标记使用证据缺失；仍未实现真实证据文件备份恢复 |

F19 本轮不再以“无提示悬空”重复报错：明确缺失符合首轮备选建议。它仍不是完整历史使用证据备份，后续验收须照实记录该限制，不能声称跨设备已恢复截图/收据。

## 检查边界

- 重新检查的安全/兼容防线包括外部代签、单制作人、明确用户钉定、受控引用摘要、远程权限不扩张、旧字段编号、恢复清执行信任，没有因上述修复确认额外放宽。
- 新运行器和使用模块仍偏长，结构维护性意见沿用首轮，不以风格偏好冒充新功能缺陷；本轮没有性能压测。
- 修复 F01 新增 `macos_app_bundle_archive.dart:8`→publisher，后者 `work_candidate_publication.dart:12` 又 import archive，形成循环依赖，违反仓库模块化指导；建议将共享交付安全校验放到不反向依赖发布器的现有合适层。当前分析/Flutter 编译未因此报错，此项作为结构问题单列，不计入 14 项 P1/P2。格式检查失败也单列，不混作业务漏洞。
- 所有失败检查继续完成不依赖它的独立检查；报告不把全量测试失败与现场环境缺失混为一类。
- 尚未执行真实模型、GUI/原生会话、实际 GitHub 导入、跨设备恢复及其他平台；仍有误通过、流程阻断和恢复风险，需修复后再按独立验收提示词验证。
