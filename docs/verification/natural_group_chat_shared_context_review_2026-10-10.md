# 自然接话与固定共同设定：代码 Review

日期：2026-10-10。对象：评审时工作区中尚未提交的两项功能改动。

结论：**已有实现，但验收不通过，不能标记为完成。** 找到 4 项 P1 和 2 项 P2。静态分析与 260 个既有相关测试通过；补充边界用例揭示了现有测试没有覆盖的失败路径。

## 范围与依据

依据用户已确认的范围及两份实现提示词：

- [任务 1：自然接话](/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/optimization_prompts/2026-10-10-task-1-natural-group-chat.md)
- [任务 2：固定共同设定](/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/optimization_prompts/2026-10-10-task-2-shared-group-context.md)
- [CLAUDE.md](/Volumes/new_disk/work/flutter/chat_group/chat_group/CLAUDE.md:162) 的红线、死循环防护、代码质量与完整 Review 要求。

审查包括普通群逐次选人、普通用户与空闲回合、路由和 App 生命周期、角色回复及摘要/压缩/重试/重新生成调用方、群设置保存和更新、上下文窗口、API 配置引用、备份与删除集成，以及相关测试。工作区还存在工作模式、关系审计与消息气泡等其他改动；只检查它们与上述两项功能的交界，不对这些独立改动给出完成结论。

本次没有修改功能代码、提交 Git、调用真实提供商或读取真实聊天数据库。复现使用隔离 Hive、假模型与有限 pump。

## 全部发现

### 1. P1：等待选人时，关闭自动聊天或离开后返回，旧回合仍能继续回复

定位：

- [chat_room_speaker_picker_support.dart:89](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/chat_group/chat_room_speaker_picker_support.dart:89)
- [chat_room_agentic_support.dart:158](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/chat_group/chat_room_agentic_support.dart:158)
- [chat_room_page_lifecycle_support.dart:44](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/chat_group/chat_room_page_lifecycle_support.dart:44)
- [chat_room_page_session_support.dart:320](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/chat_group/chat_room_page_session_support.dart:320)

证据：选择器 await 后只复检 `_roomWorkAllowed`。自动聊天开关、回合停止状态、原请求是否已取消没有在这一异步边界后复检。后台暂停会取消选择器 token，但选人阶段没有活跃 stream，因而不会通过 `_stopStreaming` 标记回合停止；快速返回后可见性布尔值恢复为 true，旧结果仍可被采纳。关闭自动聊天也只停止调度，没有让待选人的当前回合失效。

假模型复现两种情况：等待选人时关闭自动聊天，再返回合法角色 ID，仍启动角色请求；等待选人时进入后台再恢复，token 已取消，迟到结果仍启动角色请求。即使取消被上游转换为失败，当前实现也可能将其当作普通不可用状态执行本地兜底。

影响：停止后继续发言和消耗 API；违反“迟到结果不得启动下一位”的验收条件。

建议：使用已有回合标识或最小的有效性版本，让停止、离页、后台使当前普通回合永久失效；在每个 await 后复检原回合、取消状态、自动开关与成员资格。取消须结束，不得降级为本地选人。工作模式协调器保持独立。

### 2. P1：硬预算拒绝被丢失，选人失败后仍会兜底调用角色

定位：

- [chat_room_speaker_picker_support.dart:348](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/chat_group/chat_room_speaker_picker_support.dart:348)
- [chat_room_speaker_picker_support.dart:110](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/chat_group/chat_room_speaker_picker_support.dart:110)

证据：网关返回的 `governanceBlocked` 与其他失败统一转成 null，调用方随后执行 `_localSpeakerPick`。复现使用已知价格的选择器和极低硬预算；选择器被网关阻止、实际选择请求数为 0，但本地兜底仍启动了一个价格未知模型的角色请求。价格未知模型沿用既有策略，无法靠下一次预检补救这个回合决策错误。

影响：预算已经要求停止，当前回合仍可能继续产生调用与费用。模型价格未知本身是既有能力边界，此处的问题是丢失了已经明确发生的预算拒绝。

建议：区分可降级失败与硬拒绝/取消。预算阻塞和权限阻塞返回结束回合的结果，不进入本地兜底。

### 3. P1：切走群聊时，排队用户消息可能被取出后不再得到回复

定位：

- [chat_room_agentic_input_support.dart:167](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/chat_group/chat_room_agentic_input_support.dart:167)
- [chat_room_page_state.dart:406](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/chat_group/chat_room_page_state.dart:406)
- [chat_room_agentic_round_execution_support.dart:157](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/chat_group/chat_room_agentic_round_execution_support.dart:157)

证据：队列消费检查 `_canTouchUi`，其只检查 mounted、disposed 与 `_pageActive`，没有路由可见性或 App 前台条件。全屏页面盖住群聊时，State 仍可满足该条件。旧回合 finally 会取走下一条排队消息；新回合随后因 `_roomWorkAllowed == false` 正常返回，不抛错，也不重新排队。

复现：选人未完成时关闭空闲自动聊天，发送普通聊天消息，再打开覆盖页面；旧选择结束后返回群聊，角色请求数仍为 0。用户消息本身还在数据库，丢失的是待处理回复请求。

影响：用户看到消息发出，却一直没有回复；返回页面的恢复逻辑无法找回已经消费的队列项。

建议：普通聊天在消费前检查 `_roomWorkAllowed`；消费后的可见性变化也须保留或重新排队尚未执行的请求。不要用群页面可见性阻断已提交的工作任务。

### 4. P1：前台限制尚未覆盖摘要、失败重试与重新生成的完整异步路径

定位：

- [chat_room_conversation_support.dart:66](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/chat_group/chat_room_conversation_support.dart:66)
- [chat_room_conversation_support.dart:44](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/chat_group/chat_room_conversation_support.dart:44)
- [chat_room_agentic_round_support.dart:421](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/chat_group/chat_room_agentic_round_support.dart:421)
- [chat_room_interaction_support.dart:309](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/chat_group/chat_room_interaction_support.dart:309)
- [chat_room_conversation_support.dart:386](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/chat_group/chat_room_conversation_support.dart:386)

证据来自静态调用链审查：

- `_generateSummary` 在解析凭据之前检查可见性，凭据解析 await 后直接发送请求；期间切走仍能开始摘要。摘要返回后也没有回合有效性检查就保存群记忆。
- `_retryFailedReply` 解析凭据前后只检查角色禁言，没有可见性/停止检查，也没有随页面取消的 token。
- 重新生成在实际请求前仍检查 `_pageActive`，全屏覆盖和后台未必改变这个值。
- 压缩请求已有发送前的可见性检查，但取消与返回后的有效性检查缺失，旧压缩结果仍写入临时上下文。
- 共同设定超窗的错误消息也在新可见性复检之前进入 `_appendMessage`；后者使用 `_canTouchUi`，不能拦住仍 mounted 的隐藏群。

影响：正常选人入口暂停后，外围请求仍可能在后台启动；迟到摘要或压缩结果继续改变旧群上下文。

建议：将第 1 项的普通回合有效性与取消机制贯穿实际网络入口、返回处理和持久化边界。已有摘要/记忆系统无需重写；本项未用真实提供商或专门的摘要慢凭据 fixture 验证。

### 5. P2：通用窗口裁剪没有保护共同设定和全部候选 ID

定位：

- [chat_room_agentic_round_support.dart:127](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/chat_group/chat_room_agentic_round_support.dart:127)
- [chat_room_speaker_picker_support.dart:287](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/chat_group/chat_room_speaker_picker_support.dart:287)
- [context_window_manager.dart:197](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/agentic/context_window_manager.dart:197)，既有裁剪算法，此次新增调用方未处理优先级。

证据：当前算法先删旧对话，再按文本体积缩短最大的 system 消息，不区分必需和可选内容。

两个纯函数复现均失败：

1. 小输入预算能容纳完整共同设定、角色身份和最新用户输入，但加入可选摘要后，共同设定仍被裁短。新增 `survives` 会拒绝回复，错误地要求用户缩短原本放得下的设定。
2. 6 个合格候选的公开身份描述较长时，按选择器实际 2048 token 上限拟合后，`candidate-2`、`candidate-3`、`candidate-4` 的 ID 消失；这些角色不能被模型公平选中。

影响：任务 2 在窗口紧张时不满足“低优先内容先让位”；任务 1 只是在裁剪之前覆盖了全部候选。

建议：在对应请求组装处先保留必需的小区块与候选稳定 ID，缩短可选简介、摘要和旧历史。角色请求确实连必需内容也装不下时再报错；选择器必要协议/ID 放不下时有限降级。无需重写所有功能的窗口管理。

### 6. P2：配置引用清理仅挂在设置页面，删除结果与恢复边界不完整

定位：

- [settings_page_config_support.dart:122](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/settings/settings_page_config_support.dart:122)
- [ai_speaker_picker_settings.dart:48](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/settings/ai_speaker_picker_settings.dart:48)
- [data_lifecycle_service_character.dart:136](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/core/database/data_lifecycle_service_character.dart:136)，既有共享删除入口缺少新引用的清理。

证据：UI 无条件执行 `clearIfReferencing`，未判断配置是否实际删除；凭据删除失败、配置仍存在时，原选人器绑定也会被清空。相反，直接通过共享 `DataLifecycleService.deleteApiConfig` 完成删除的隔离测试中，配置已不存在，但设置仍保存 `to-delete`。

备份白名单不包含新键，避免导出这一点正确；但白名单排除并不等于恢复时清理已有本机残留值。残留 ID 若随后通过允许保留 ID 的恢复策略恢复、并重新绑定凭据，`resolveConfig` 只按 ID 和 `hasCredential` 判断，会重新启用旧选择。当前恢复策略没有“覆盖现有配置”模式，本发现不依赖这种模式。

影响：删除失败时意外改变全局选择；集中删除与后续恢复存在悬空绑定再生效的可能，未落实任务要求的明确重新选择。

建议：在共享删除入口确认对应配置确实被移除后清理新引用，UI 依赖该结果；恢复与修复路径显式处理失效引用。用实际删除/恢复服务测试，不只测试 `clearIfReferencing` 辅助函数。

## 已实现且方向正确的部分

- 复用一个设备本地的已有 API 配置 ID；选人器与角色发言使用各自配置。没有新增明文 Key 存储或把新引用加入可分享备份。
- 选择器通过网关与安全凭据解析器请求；输入/输出、响应体、总时限和重试次数有界。
- 稳定 ID、明确点名优先、无候选/唯一候选、结束协议和一次本地降级均有实现。
- 动态选人读取候选共同可见历史，角色回复另按自己的可见范围处理；没有全文合并私有人设或跨群设定。
- 群描述和公告复用为固定共同设定，集中组装并去掉原先重复注入；保留旧模型字段与备份格式。群编辑返回后刷新当前群设置。
- 没有新增依赖、Hive 字段编号、数据库迁移或完整世界书系统。

这些通过项不能抵消上面的失败路径，也不证明真实模型的自然度已经达到用户预期。

## 执行的检查与结果

- `flutter analyze`：通过，`No issues found`。
- `git diff --check`：通过。
- `flutter test --timeout 30s --concurrency=1 --reporter expanded`，分别指定 16 个功能/调用方测试文件：**136 个通过**。
- 同一参数指定 7 个网关、资格、私聊、流式会话、备份与删除回归文件：**124 个通过**。
- 临时边界 fixture `/tmp/chat_group_feature_review_probe_test.dart`，逐个使用 `--plain-name` 运行：关闭自动聊天、后台再返回、硬预算阻塞、隐藏时排队、共同设定优先级、全部候选 ID、共享配置删除。失败断言用于证明期望行为尚未满足，不是修复后的通过证据。

相关回归日志：

- [136 个功能回归](/tmp/chat-group-feature-review-tests-20261010.log)
- [124 个共享服务回归](/tmp/chat-group-feature-review-regressions-20261010.log)

补充证据：

- [关闭自动聊天](/tmp/chat-group-feature-review-off-probe-20261010.log)
- [后台再返回](/tmp/chat-group-feature-review-return-probe-20261010.log)
- [硬预算阻塞](/tmp/chat-group-feature-review-budget-probe-20261010.log)
- [排队消息](/tmp/chat-group-feature-review-queue-probe-20261010.log)
- [共同设定裁剪](/tmp/chat-group-feature-review-window-probe-20261010.log)
- [候选 ID 裁剪](/tmp/chat-group-feature-review-candidate-probe-20261010.log)
- [集中删除引用](/tmp/chat-group-feature-review-config-probe-20261010.log)

临时 fixture 初版曾出现清理阻塞、未隔离工作协调器和凭据 ID 不符合删除规则的问题；这些不是产品缺陷依据。调整隔离 fixture 后逐项单独运行，以对应日志中的最终行为断言为准。临时文件未加入正式测试目录，修复时应将有效场景收敛为正式回归。

现有新测试更偏向纯规则、builder 和页面切换后不发起新调度，缺少“请求正等待时停止/恢复”、硬预算后的集成结果与最终裁剪候选完整性。任务 2 的 builder 测试也不足以证明实际角色请求的所有窗口边界。

## 修复顺序与未验证范围

先处理第 1、2、3、4 项：停止后的副作用、硬预算与用户输入处理；随后修复第 5、6 项的窗口与引用兼容，再补上述正式回归并复审。

未执行全仓全部测试、平台构建、真实设备界面验收或真实 API 调优；本次只评审两项功能及相关交界，无模型 schema 变更，因此未运行代码生成。其他正在修改的工作模式等独立改动未给出审核结论。

剩余风险：当前实现仍可能在停止后调用模型、把预算拒绝降级处理、漏掉排队回复；因此不能以静态分析和既有测试通过作为完成依据。
