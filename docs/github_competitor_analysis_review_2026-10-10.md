# GitHub 竞品建议复评与两个实施任务

评估日期：2026-10-10。依据：[原 HTML](/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/github_competitor_analysis_2026-10-10.html)、当前仓库源码、项目官方 GitHub 与文档，以及用户逐项确认的目标。

本次范围是十项建议的产品必要性、已有能力、实施优先级和两个任务的边界，未做整个仓库或竞品的运行验收。HTML 是待核实的分析材料，其建议不是实施指令。

## 结论

十项不必全部实施，更不能照搬 HTML 的 P0/P1/P2 排序。文档把若干已有能力写成缺失，也把角色卡导入、社区后端、插件 SDK 等独立工程打包成一个“优化项”，低估了成本。

对当前已确认的日常陪伴目标，最优先的是 **第 2 项的逐次 AI 选人，加上第 8 项中的前台可见性、取消、有限回合和预算护栏**。第 3 项先完善已有“群共同设定”，完整世界书暂缓；完整 APPEND 也暂缓。

两个任务的需求范围已确认，足以写出可执行提示词。这是对范围的明确，不是对真实模型效果或工程一次成功率给出 99% 的统计保证。

## 文档中会影响决策的出入

| HTML 的判断 | 核对证据 | 对优先级的影响 |
|---|---|---|
| 现有发言选择是纯随机 | [HumanizedChatOrchestrator](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/chat_group/humanized_chat_orchestrator.dart:52) 已有点名、最近发言、关系、话题及随机扰动；当前主要在一轮开始时确定名单 | 增加基于最新回复的逐次选人，保留已有意图和兜底机制 |
| 只有群摘要，没有召回、跨群记忆 | [MemoryContextSelector](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/memory/memory_context_selector.dart:17) 已按观察者读取全局永久记忆，含关键词相关性和预算排序 | 第 9 项大部分是重复待办，先评估实际召回效果再决定新方案 |
| 没有现成角色可用 | [角色预设入口](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/ai_character/ai_character_list_page.dart:301) 已有快速创建 | 角色卡仍有互操作价值，但不能据此断言必须立刻建角色社区 |
| 缺乏群级预算与长上下文管理 | [会话预算](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/ai_governance/ai_request_guard.dart:199) 和 [最终窗口裁剪](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/agentic/context_window_manager.dart:167) 已存在 | 给新增选择器接入现有护栏，而非重做预算系统 |
| 单用户、无后端 | [ChatGroup 共享字段](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/core/models/chat_group.dart:43)、[realtime 说明](/Volumes/new_disk/work/flutter/chat_group/chat_group/realtime/README.md) 及 gateway 已存在 | 第 10 项不能当作从零新增；实验联机与正式多人服务需分开评估 |
| 需要完整世界书保存共同背景 | [群描述与公告](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/chat_group/chat_group_form_page.dart:126) 及 [现有描述注入](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/chat_group/chat_orchestrator.dart:196) 已覆盖少量固定设定的基础需求 | 先完善入口、语义优先级和最终请求保留，首版无需另一套存储 |

GitHub 对标也需要修正：SillyTavern 的 Natural 使用规则，APPEND 是上下文处理模式；官方提醒合并人设可能造成身份混淆。Aithos 明确使用模型逐次决定下一位或结束，较符合此次目标。[SillyTavern 官方说明](https://docs.sillytavern.app/usage/core-concepts/groupchats/)、[Aithos GitHub](https://github.com/excing/WebMultiAgentChat)

## 十项逐一评判

这里的优先级按“日常陪伴、自然接话、几条固定共同设定”排序；不是对所有产品定位通用的路线图。

| 原序号 | 项目 | 是否必要 | 当前建议 |
|---|---|---|---|
| 1 | Tavern 角色卡、导入导出、角色社区 | **角色卡互操作有价值，整包不是当前必需** | P1/P2。现有预设可用于起步。有真实导入需求后先做最小文件互操作；社区 API、自有后端和多种图片容器另行评估 |
| 2 | AI 选择器与 APPEND | **逐次选择必要；全文 APPEND 当前不必要** | P0。在已有规则编排上增量实现，使用统一已有 API 配置。保留其他成员公开简介，减少身份混淆与上下文费用 |
| 3 | 世界书 | **少量共同设定值得完善；完整世界书暂不必要** | 轻量版 P1，作为第二个任务。复用描述、公告，每次生效。大量背景按话题激活时，再做关键词条目与绑定 |
| 4 | 工作模式卖点、移动端与更多工具 | **取决于产品主线，不是当前陪伴体验的前置条件** | 当前暂缓扩展。之后根据真实工作用户需求完善审批、文件与任务体验；不因“独有”判断就扩建浏览器、图像、定时等工具 |
| 5 | 可插拔 Provider 与社区 SDK | **现有 Provider 分层可用；公开 SDK 不急** | P2/P3。已经有 [SearchProvider 接口](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/web_search/providers/search_provider.dart:120)。等有真实扩展贡献需求再设计 SDK，避免重复抽象及破坏网关边界 |
| 6 | 安装、分发和首次上手 | **值得优化，但先证明实际用户卡点** | P1。优先“配置 API → 选角色 → 开始聊天”的路径；发布脚本复杂不等于用户安装困难。保留仓库签名红线，不采用 HTML 中含混的免签名方案 |
| 7 | UGC 分享与迁移 | **迁移重要，已有备份基础；UGC 可后做** | P1/P2。先把现有 `.cgbak` 恢复和 API 重新绑定说明做清楚。角色分享与历史迁移分开，不把私有记忆默认当分享内容 |
| 8 | 规模与稳定性 | **必要部分应随第 2 项一起做** | P0 配套：当前群、前台、停止、资格、轮次、窗口和预算。新增 selector hook、任意大群能力另议；本次未核实“超过 5 个角色就崩”这一普适阈值 |
| 9 | 结构化记忆、召回、跨群统一、向量与图谱 | **前三项已有基础；向量与图谱缺少当前必要性证据** | 暂缓重建。先用真实遗漏、误召回、成本案例评估现有选择器；不要自动清理用户重要事实来追求竞品功能对齐 |
| 10 | 多用户协作 | **不是当前新增重点，已有实验联机** | 不再从零立项。若用于正式多人场景，先处理身份权限、TLS 和断线恢复；不为未确认的未来需求预留一套新模型 |

完整世界书通常涉及常驻/关键词条目、启用与过滤、预算、递归和作用范围。对用户只需要几条常驻设定的情况，实施全部能力没有足够收益依据。[SillyTavern World Info](https://docs.sillytavern.app/usage/core-concepts/worldinfo/)

RisuAI 的公开能力包含 Lorebook、长期记忆、群聊和插件，说明这些是不同功能，也说明 HTML 的生态比较不能只用简单有/无概括。[RisuAI GitHub](https://github.com/kwaroran/RisuAI)

AutoGen 提供候选缩减、模型选人、重复发言控制与结束条件。这些机制可借鉴；并不能据此证明 Flutter 群聊在 5 人以上必然失效。[AutoGen SelectorGroupChat](https://microsoft.github.io/autogen/stable/user-guide/agentchat-user-guide/selector-group-chat.html)

## 最优先的实施顺序

1. **任务 1：自然接话与运行边界。** 先补齐当前页面与前后台约束，再接入逐次选择器、统一配置、有限调用与失败兜底。目标是用户能看到“上一位说完后，合适的人接话”，离开群后不再自动生成。
2. **任务 2：常驻共同设定。** 复用已存在字段，改善填写说明、提示词分区与冲突语义，验证最终实际请求保留设定。目标是固定称呼、人物关系和群内约定对本群每次请求有效。
3. **之后再评估第 6 项的首次上手，以及第 1/7 项的角色导入和迁移。** 依据真实使用障碍决定先后。SDK、向量、图谱、完整世界书和新后端暂缓。

两任务顺序执行。任务 1 不依赖完整世界书，只读取现有描述、公告；任务 2 完成时再统一核对角色请求和选择器使用的共同设定。文件存在交集，不建议两个执行者同时直接修改同一工作区。

## 用户已确认的边界

- 目标：日常陪伴，自然接话，角色关系与共同背景一致。
- 调用：质量优先，每条发言前最多一次选择请求，受轮次和预算限制。
- 配置：所有群共用一个全局指定的已有 API 配置选人，角色继续使用自己的配置发言。
- 生效：所有普通群默认使用；只在当前可见群和 App 前台运行。切群、离页、后台、停止时取消，迟到响应不续聊。
- 成员资料：保留姓名、身份、性格等公开简介，不完整合并人设。
- 共同设定：几条固定内容由用户编辑，每次聊天提供；复用群描述、公告，不建完整世界书。
- 本次交付：评判、优先级与两份独立提示词，不直接开发功能。

## 可复制的任务提示词

- [任务 1：当前前台群聊的 AI 自然接话](/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/optimization_prompts/2026-10-10-task-1-natural-group-chat.md)
- [任务 2：每次聊天生效的固定共同设定](/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/optimization_prompts/2026-10-10-task-2-shared-group-context.md)

## 核查记录与限制

已完整读取 `CLAUDE.md` 和原 HTML，使用 `rg`、`rg --files`、`cat`、`sed` 查阅相关源码、调用方、设置、生命周期、窗口管理、备份与测试；用 `git status --short` 确认开始时工作区干净；通过网络工具读取以上官方 GitHub 与文档。本次没有读取真实 Hive 聊天记录、调用真实模型或更改 API 凭据。

范围内的十项建议均已评估，没有把第一处文档错误当作完整结论。特别核对了隐藏历史、窗口预算、前台/路由差异、取消后续跑和设置引用等新功能易遗漏的失败边界。

另有一处仓库约束与现有实现不一致：`CLAUDE.md` 导出/备份红线禁止输出 `apiProvider` / `apiConfigId`，而 [既有备份 codec](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/backup/backup_entity_codec_records.dart:47) 与测试仍携带这些字段。两份提示词要求新增内容遵守红线，并记录现有冲突，不借机扩展此行为或擅自重写整个备份系统。

仅新增 Markdown 文档，因此未运行 `flutter analyze`、Flutter 单测或构建；具体实现的回归检查已写入每份任务提示词。没有实测竞品、闭源 mostaron、真实模型自然度、费用和延迟，也未重新核验全部 star 数与活跃度。产品优先级由已确认目标与机制证据决定，不由 star 数决定。

文档检查通过：三个文件均可读取、本地源码与提示词链接及行号有效、十项序号完整、两份提示词覆盖用户已确认的范围，且没有行末空白。

需要知晓：选择器会增加 API 调用和延迟；客户端取消已发出的上游请求不保证撤销计费。正确携带共同设定有助于一致性，但不保证任何模型永远遵守设定。
