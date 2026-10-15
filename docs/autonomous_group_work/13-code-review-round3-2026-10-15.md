# 第三轮修复复审

日期：2026-10-15。范围：第二轮 R01–R14 修复、相关调用方及新增测试，并复查修复对首轮安全/兼容防线的影响。只做代码 review，不做 GUI、真实模型或原生服务现场验收。

本轮重新完整读取 `CLAUDE.md`，比较上轮结束时代码摘要与当前工作区。起始有 147 个范围内修改/新增代码、测试、配置文件，其中 32 个文件相对上轮有变化；先前出现的临时 live-connection 测试已不在工作区，不擅自还原或执行它。没有修改业务源码、仓库测试、配置或用户数据；只新增本报告，隔离探针位于 `/tmp`。

## 结论

**仍需修改。确认 4 项问题：1 项 P1、3 项 P2。** 本轮多个生产入口与测试已有正确修复，但原生断言被新的变化条件阻断，自建草稿激活仍未真正接通，并出现字体覆盖及人工基线版本关联问题。

以下 T 编号为本轮问题，括号内 R 编号指第二轮报告。源码推演与实跑证据分别说明，不把代码 probe 当产品验收。

## 发现

### T01 [P1] 断言拿动作完成后的快照作变化前基线，稳定的正确结果无法通过（R01）

位置：[macos_native_app_automation.dart:1126](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/macos_native_app_automation.dart:1126)，同文件第 919、1093 行。

本轮已收窄预期文本提取并要求能力覆盖，封住了上次“只匹配保存按钮”的具体问题。但 `_act` 开头使用 `session.latest` 作 before；前一次 click/input/reopen 结束时，latest 已更新成动作完成后的 after。assert 本身不执行改变业务状态的动作，仅再次 capture，却要求 `!previousText.contains(expectedText)`。

例如点击后已正常显示“保存成功”，click 返回的最新快照包含该文字，模型下一步 assert 必须使用该观察提供的 elementId。assert 的 before、after 都包含“保存成功”，因此结果必为 false。先 observe 同样把正确结果写成 before；重开后稳定保留的数据也一样失败。只有恰好在 assert 前后异步变化才可能偶然满足，不能作为可靠使用路径。

证据：直接核对生产 `_act` 的 before 获取、每次动作的 latest 更新、assert 的无副作用 switch 分支及上述布尔判据。当前新增测试只验证 `nativeExpectedOutcomeTexts` 的正则提取，没有驱动生产动作→观察→assert。

建议：把业务断言与可追溯的场景动作前基线关联，或保存动作的 before/after 并核对已完成动作带来的结果；不能强迫状态恰好在“纯断言”期间再次变化，也不能恢复为只看任意静态控件就通过。补稳定正确结果能通过、静态按钮不能通过的完整 adapter 用例。

### T02 [P2] 草稿在进入验证追踪前就被旧策略过滤，新增激活流程不可达（R08）

位置：[default_work_task_runner_context.dart:600](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/default_work_task_runner_context.dart:600)，[work_mode_policy.dart:174](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/work_mode_policy.dart:174)。

新增 `_presentedLocalDrafts` 只遍历 `WorkModePolicy.resolveSkills` 返回的 result，尝试记录“非全局、本人、无 resourcePackId、尚未在 skillIds”的草稿。但 resolveSkills 对这些 installedSkills 恰好会在第 174 行 continue。默认解析仅生成内置技能，不能把数据库中的普通草稿加回来。

因此普通草稿从未进入模型提示或 presented 集合，`_recordLocalDraftSkillsAfterSuccess` 拿到空记录，新增 `recordDraftSuccessfulUse` 即使单独测试通过，也不能使实际自建草稿在新群/私聊任务中被使用和验证。

实跑：`dart --packages=.dart_tool/package_config.json /tmp/chat_group_review3_draft_probe.dart`，直接调用生产 WorkModePolicy，输出：

```text
draftReturnedByProductionPolicy=false
draftEligibleForValidationTracking=false
```

现有新增测试直接调用 store，绕过生产 `_skillsFor`，因此漏掉该断点。

建议：提供明确、受限、标注未验证的草稿试用入口，并据本人实际使用、产物和复测证据激活；不要简单把全部草稿当已验证技能注入。补 create→试用任务→成功复测→激活→新任务复用的 runner 整合测试。

### T03 [P2] 为避开未使用样式，字体扫描漏掉真实使用的继承字体（R06 新回归）

位置：[binary_document_parser.dart:76](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/document/binary_document_parser.dart:76)。

本轮已修复 fc-match 与实际 PDF 字体不一致时错误 resolved 的分支，但新 declaredDocxFonts 只要正文出现任一直接 rFonts，就立即返回 directFonts，完全不再读 styles/numbering。常见 DOCX 同时有直接格式 run 和样式继承段落；例如第一段直接 Arial，第二段实际使用 MissingStyle，其字体是不存在的 ChatGroupMissingFontReview3。扫描仅返回 Arial，缺失的真实使用字体不进入 coverage 核验，仍可能把发生替代的文档标为 resolved。

实跑隔离 Flutter 测试 `/tmp/chat_group_review3_font_test.dart`，构造两段正文及实际引用的样式，直接调用生产 parser：

```text
productionDeclaredFonts=[Arial]
Expected: contains ChatGroupMissingFontReview3
Actual: [Arial]
```

该探针退出 1，确认声明收集遗漏；没有运行 LibreOffice 或真实视觉模型，不冒称现场字体效果已验收。源码中的 shortcut 注释说明限制，但不能把未验证的字体静默报告为已验证。

建议：解析实际使用样式与直接格式的继承，或在无法判定的混合文档上保守标 unverified；既不要把未使用样式一律强加给页面，也不要只因存在一个直接字体就忽略所有继承字体。

### T04 [P2] 人工基线重发只验证旧冻结文件，却重新封装当前工作区文件（R13 关联回归）

位置：[default_work_task_runner_production_delivery.dart:8](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/default_work_task_runner_production_delivery.dart:8)，同文件第 16–26 行。

原生 ZIP 路径和相对 requiredPaths 的具体错误已修。但 `_republishProductionBaseline` 将 testedFiles 一律改成 candidate.file，只验证冻结版本自己；随后 publishCandidate 仍从当前工作区读取/打包产物。若用户对旧候选作人工验收/豁免后工作区内容已变化，验证旧候选自然通过，却把人工决定沿用到不同内容的新候选。普通文件和原生 App 都有这条身份断裂。

调用链：用户决定导致需求版本变化后，`_prepareCompletedProduction` 在有 manual/waived 及历史候选时绑定 baseline；本函数验证旧 frozen bytes；publish 从工作区获取新 bytes；验收 manual/waived 及对应用户 responseRef 仍保留，人工审查分支使用新候选形成报告。已有“用户审查不转移给变更内容”的注释与真实检查不再一致。

建议：若只是为用户决定建立新版本基线，应从已确认的冻结 bytes 重发；若要发布工作区当前 bytes，必须在发布前与用户确认版本核对，并在不同内容时使旧人工认可失效。不要为了支持原生 ZIP 而取消普通文件版本一致性。补“旧候选获人工决定→工作区变更→基线重发拒绝/重新确认”的负例。

## 第二轮逐项复查

| 第二轮 | 本轮状态 | 说明 |
| --- | --- | --- |
| R01 | 部分修复并有新阻断 | 正则不再选保存按钮，能力覆盖/持久化检查已增加；稳定结果断言见 T01 |
| R02 | 已修 | render.data 现在携带 path，与使用观察的路径/摘要绑定契约一致 |
| R03 | 已修代码入口 | 实际讨论协议已说明 nativeBundle 三字段、相对路径及 files 唯一 ZIP 关系；不等于现场模型已成功形成合同 |
| R04 | 已修 | 正文 manifest 有 documentPath，duplicatesDocumentUse 纳入路径及摘要 |
| R05 | 已修 | close 将 native-session-invalidated 标记写入本地提交存储；恢复观察及最终 receipt 校验均读取该标记 |
| R06 | 部分修复并有新遗漏 | fallback 不匹配实际字体时改 unverified；混合直接/样式字体见 T03 |
| R07 | 已修 | download/preflight 通过可信模板 ID、角色及完整内容匹配，不再按同名草稿复用 |
| R08 | 未真正接通 | 新增 store 与成功回调，但生产策略提前过滤草稿，见 T02 |
| R09 | 已修具体边界 | hasScript 只要求 scripts/ 下的脚本运行，references/example.py 不再强制执行 |
| R10 | 已修 | 自主任务面板优先显示当前方案的唯一制作工作项 owner |
| R11 | 已接通恢复入口 | 显式继续允许旧 clarifying 检查点重进讨论；session 根据 productionReady 回 ready，再安排当前候选审查，不直接跳到交付 |
| R12 | fixture 已更新 | 使用真实受控证据，并按 explicitExecutorId 测钉定；实跑结果见下 |
| R13 | 旧路径问题已修、版本关联仍有问题 | 人工审查改取冻结载体，原生重发用相对键；基线验证/发布来源不同见 T04 |
| R14 | 已修 | 个人上下文先完整装配，只收敛可选聊天预览，必要内容仍按实际模型窗口检查 |

当前代码保留首轮已修的受控证据摘要、包内敏感资源检查、远程包保留名、packId 提示、队列异常处理和运算符去重等防线；备份的使用证据仍按已接受方案明确标缺，未声称完整跨设备恢复。

## 验证记录

- `flutter analyze --no-pub`：退出 0，No issues found；日志 `/tmp/chat-group-review3-20261015-analyze.log`。
- gateway `npm test`：32 通过、0 失败，退出 0；日志 `/tmp/chat-group-review3-20261015-gateway.log`。
- 修改及新 Dart 的格式检查（`--output=none --set-exit-if-changed`）：138 文件，0 项需格式化，退出 0，没有写回源码。
- `git diff --check`、`bash -n scripts/publish_local.sh`：通过。
- 草稿生产策略隔离 Dart probe：退出 0，复现 T02；首次构造缺少必填参数未编译，补齐临时 fixture 后执行上述成功，不计首次尝试为产品问题。
- 混合字体隔离 Flutter probe：1 失败、退出 1，复现 T03；日志 `/tmp/chat-group-review3-20261015-font-probe.log`。未修改仓库测试或产品文件。
- 全量 Flutter 回归：`flutter test --no-pub --concurrency=1 --timeout 30s --reporter json`，3473 通过、3 跳过、1 加载编译失败，退出 1，耗时约 13 分钟；日志 `/tmp/chat-group-review3-20261015-flutter.jsonl`。唯一失败是 `chat_api_service_streaming_test.dart` 的 `failureDetail` 字段编译错误，不是测试断言失败。
- 测试期间流式 API、用量治理及设置相关共 14 个文件发生并发变化，故上述全量结果属于混合版本，不能宣称冻结快照全绿，也不能把这次编译错误直接当作稳定产品缺陷。随后新进程定向重跑流式 API、ChatApiService、治理 ledger/gateway，以及上一轮涉及的 work_discussion_v2、stage02、work_collaboration_state 共 7 个测试入口：306 通过、0 跳过、0 失败，退出 0；日志 `/tmp/chat-group-review3-20261015-targeted.jsonl`。先前编译失败未在当前版本复现，R12 涉及的测试也通过。
- 并发变更后的再次 `flutter analyze --no-pub`：退出 0，No issues found；日志 `/tmp/chat-group-review3-20261015-analyze-final.log`。本轮 4 项发现所在的工作模式、技能、文档目标文件未在测试期间变化。

本轮并行审查调用未成功，未拿到任何本轮分工审查产物，因此以上结论均由主审实际阅读当前代码、调用链和隔离证据后形成，没有沿用失败代理的旧答案当复审。

## 检查完整性与限制

检查范围涵盖需求对应、正确性、错误/恢复路径、模型可见协议、证据/文件版本、安全授权、测试有效性、可读性与旧数据兼容。新增字段未改变本轮 Hive 编号，不运行可能写回源码的生成器。没有发现需要增加第二执行循环或推翻现有架构的理由。

结构方面，原生封装器与发布器仍循环 import，原生运行器、usage、store 文件偏长；这两项沿用上一轮维护性意见，没有借风格偏好扩大本轮功能缺陷计数。未做性能压测。

未检查 GUI、真实成员模型/视觉送达、原生桌面服务、联网 GitHub 导入、跨设备备份恢复及其他平台；不得把 headless 回归或临时 probe 当真实产品验收。当前主要风险是正确结果也无法完成，以及尚未验证的方法和版本在流程中缺少可靠衔接。
