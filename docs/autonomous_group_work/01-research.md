# GitHub 调研与现有差距

调研日期：2026-10-13。范围：多角色讨论与调度、真实执行、进展判断、产物验收、技能导入，以及本仓库相关生产入口。依据是项目维护者的 README、文档、源码和 GitHub API。没有在本机安装或完整运行这些外部框架，也没有对本仓库做全量代码审计。

## 1. 结论

最接近讨论和制作形式的是 ChatDev；调度与空转调整可以参考 Magentic-One；当前框架方向同时参考 Microsoft Agent Framework；角色、工具和记忆组织参考 AgentScope；制作材料与实施职责参考 MetaGPT。

这些项目适合提供机制参考。已检查的来源不足以证明任何一个项目能直接满足“现有 Flutter 群聊人格 + 单执行者 + 所有成员分别操作 macOS App + 文档视觉检查 + GitHub 技能导入 + 原任务连续修订”。不能宣称接入一个框架就获得全部能力。

推荐保留本项目的调度和执行机制，补齐能力与证据合同。完整引入外部 Python/.NET 编排框架会产生新的状态、重试、权限、模型配置和恢复边界；目前没有证据表明这种替换比增量扩展更省工程量。

## 2. 相近项目

以下 SHA 为调研时通过 GitHub API 取得的分支提交；链接用于固定调研版本，不代表未来应自动升级到其最新版。

| 项目 | 调研提交 | 阅读入口 | 与需求的关系 |
|---|---|---|---|
| OpenBMB/ChatDev | `4fb2db0ea90375ce1059f44fe03ffbd191a7a169` | [README](https://github.com/OpenBMB/ChatDev/blob/4fb2db0ea90375ce1059f44fe03ffbd191a7a169/README.md)、[工作流配置](https://github.com/OpenBMB/ChatDev/blob/4fb2db0ea90375ce1059f44fe03ffbd191a7a169/docs/user_guide/en/workflow_authoring.md) | 对话协作、制作与审查的组织形式 |
| microsoft/autogen | `027ecf0a379bcc1d09956d46d12d44a3ad9cee14` | [Magentic-One 调度源码](https://github.com/microsoft/autogen/blob/027ecf0a379bcc1d09956d46d12d44a3ad9cee14/python/packages/autogen-agentchat/src/autogen_agentchat/teams/_group_chat/_magentic_one/_magentic_one_orchestrator.py) | 任务与进展记录、选发言者、停滞后重规划 |
| microsoft/agent-framework | `b53d25ed1cd2f54ee5e5e5ed548bb2c5515022f3` | [README](https://github.com/microsoft/agent-framework/blob/b53d25ed1cd2f54ee5e5e5ed548bb2c5515022f3/README.md) | 当前工作流、检查点与治理方向 |
| agentscope-ai/agentscope | `a8e90fa724fa5dc47c2b951e702543481573bf11` | [README](https://github.com/agentscope-ai/agentscope/blob/a8e90fa724fa5dc47c2b951e702543481573bf11/README.md) | 角色、记忆、工具和多代理协作组织 |
| FoundationAgents/MetaGPT | `11cdf466d042aece04fc6cfd13b28e1a70341b1f` | [README](https://github.com/FoundationAgents/MetaGPT/blob/11cdf466d042aece04fc6cfd13b28e1a70341b1f/README.md) | 职责分配和制作材料的衔接 |

### ChatDev

当前主分支是 ChatDev 2.0/DevAll；经典软件公司式 ChatDev 1.0 已移至 `chatdev1.0` 分支。2.0 的工作流配置提供 agent、python、human 等节点和条件边，可以组织审查后再次制作的循环。[维护者说明](https://github.com/OpenBMB/ChatDev/blob/4fb2db0ea90375ce1059f44fe03ffbd191a7a169/README.md)、[条件边配置](https://github.com/OpenBMB/ChatDev/blob/4fb2db0ea90375ce1059f44fe03ffbd191a7a169/docs/user_guide/en/workflow_authoring.md)。

本项目可借鉴：每个角色有自己的任务输入，制作、使用、反馈之间有明确交接。其示例中的 human 审稿节点和循环计数器不能直接作为本项目默认规则，用户已经选择自主裁决且不设累计轮次预算。

### Magentic-One 与 Microsoft Agent Framework

Magentic-One 的源码区分任务事实/计划与进展记录，检查任务是否满足、是否有进展、是否循环，并选择下一位发言者；停滞达到门槛后更新计划。它是调度参考，完成判断不能照搬为模型一句“已满足”，本项目必须核对真实产物和工具证据。[调度源码](https://github.com/microsoft/autogen/blob/027ecf0a379bcc1d09956d46d12d44a3ad9cee14/python/packages/autogen-agentchat/src/autogen_agentchat/teams/_group_chat/_magentic_one/_magentic_one_orchestrator.py)。

AutoGen 当前 README 声明进入维护模式，并推荐新项目使用 Microsoft Agent Framework。MAF README 描述了工作流、检查点、流式输出和治理支持。因此不能把 AutoGen 当成持续新增功能的首选新依赖。[AutoGen 维护说明](https://github.com/microsoft/autogen)、[MAF 能力说明](https://github.com/microsoft/agent-framework/blob/b53d25ed1cd2f54ee5e5e5ed548bb2c5515022f3/README.md)。

本项目可借鉴进展记录与有条件重规划；已经有 `WorkProgressGuard`，应扩充其证据输入，而不是再造一套停滞计数。

### AgentScope

维护者提供代理、工具、记忆和多代理应用的开发方式。[README](https://github.com/agentscope-ai/agentscope/blob/a8e90fa724fa5dc47c2b951e702543481573bf11/README.md)。本项目可参考角色上下文和工具返回结果的组织；“代理之间有消息交流”仍不等于每个角色已经实际使用文件或应用。人格表达也需要本项目自己的对话验收。

### MetaGPT

维护者以产品、架构、项目和工程角色组织软件制作，并强调 SOP 与材料产出。[README](https://github.com/FoundationAgents/MetaGPT/blob/11cdf466d042aece04fc6cfd13b28e1a70341b1f/README.md)。本项目可借鉴必要材料的交接；公开群聊不能照搬职责报告模板，否则仍会产生用户已经指出的机械感。

## 3. 真正使用产物的工具依据

| 平台/产物 | 已核对的能力来源 | 必须保留的限制 |
|---|---|---|
| macOS `.app` | [Appium Mac2](https://github.com/appium/appium-mac2-driver)、[启动条件](https://github.com/appium/appium-mac2-driver/blob/master/docs/getting-started/index.md)、[appPath/bundleId](https://github.com/appium/appium-mac2-driver/blob/master/docs/reference/capabilities.md)、[操作方法](https://github.com/appium/appium-mac2-driver/blob/master/docs/reference/execute-methods.md) | 基于 XCTest；需 Mac、Xcode、匹配的 Appium/driver 和系统权限；目标应用的可操作性必须现场验证 |
| 网页/HTML | [Playwright 操作追踪](https://playwright.dev/docs/api/class-tracing)、[Trace Viewer](https://playwright.dev/docs/next/trace-viewer) | 保存真实操作、截图及断言；普通网页工具无法证明原生 `.app` 已被操作 |
| Windows `.exe` | [FlaUI](https://github.com/FlaUI/FlaUI) | 使用 Windows UI Automation，需 Windows 环境；本次不承诺在 Mac 上完成 Windows 原生验收 |
| Android | [Appium UiAutomator2](https://github.com/appium/appium-uiautomator2-driver) | 需 Android SDK、模拟器或可连接真机 |
| iOS | [XCUITest 环境](https://appium.github.io/appium-xcuitest-driver/12.15/getting-started/system-requirements/)、[真机签名](https://appium.github.io/appium-xcuitest-driver/latest/getting-started/provisioning-profile/) | 模拟器与真机证据分开，真机配置不能由聊天模型伪造完成 |
| Office/PDF 渲染 | [LibreOffice 命令行参数](https://help.libreoffice.org/latest/en-US/text/shared/guide/start_parameters.html) | 可作为已安装的转换/渲染工具候选；渲染引擎与字体影响结果，不能承诺与所有 Word 版本完全一致 |
| GitHub 技能目录 | [Agent Skills 格式](https://agentskills.io/specification) | `SKILL.md` 可带 scripts/references/assets；导入正文不等于依赖和执行能力已安装 |

选用 Mac2 是待 P0 验证的工程建议。尚未在用户这台 Mac 上运行目标应用测试；不能据 README 宣称自绘界面、Flutter 控件树或所有第三方 `.app` 均可稳定操作。

## 4. 本仓库现状

以下为此次核对范围内的事实与需求差距，不是全仓库审计结论。行号基于调研时工作区；后续提交可能变化。

| 范围 | 当前依据 | 结论与需要改动 |
|---|---|---|
| 生命周期与单执行入口 | `lib/features/work_mode/providers/work_task_providers.dart:46`、`work_task_coordinator.dart` | 可复用 app 级协调器、`DefaultWorkTaskRunner`、`WorkAgentLoop`；不另建群执行引擎 |
| 逐成员认可 | `work_discussion_v2_approvals.dart:33` | 核验版本、候选和验收；尚未核验每个签字者自己的本轮使用记录 |
| 一般分歧 | `work_discussion_v2_approvals.dart:123`、`work_collaboration_state_gate.dart` | 反对意见会进入用户裁决，全员认可门禁与本次自主协调裁决要求存在差距 |
| 文档正文审查 | `default_work_task_runner_review.dart:116` | 已检查全文读取覆盖；未形成真实页面渲染、逐页视觉核验的合同 |
| 软件结果 | `default_work_task_runner_review.dart:165` | 检查命令输出中的验收 ID、摘要与结果；不能把输出一份 JSON 等同于可信交互过程 |
| 原生操作 | `default_work_task_runner_tools.dart:129` | 尚无 Mac2/native UI 操作工具；`browser.context` 也未注册 |
| `.app` 候选 | `work_candidate_publication.dart:164`、`work_artifact_delivery_guard.dart:949` | 候选发布核验普通文件；`.app` 目录需要窄范围封装与内层身份核验，ZIP 文件存在不能代替 App 验收 |
| 人格与记忆 | `work_discussion_v2_session.dart:506`、`work_discussion_v2_requests.dart:22`、`agent_prompt_builder.dart:10` | 已注入角色提示、统一记忆与发言规范；机械感不能简单归因于完全没有人格，需检查回合目标、协议压力与实际对话样本 |
| GitHub 技能 | `default_work_task_runner_delivery.dart:34`、`skill_download_service.dart:18` | 实际安装的是内置模板；`url/source` 参数没有形成远程导入实现 |
| 技能创建 | `default_work_task_runner_delivery.dart:4`、`character_skill_resolver.dart:23` | 创建指令元数据并绑定角色；`needsSkillCreation/skillCreationHint` 没有生产消费方，不是可靠自动触发器 |
| 启动技能预检 | `default_work_task_runner_context.dart:520`、`default_work_task_runner_execution.dart:361` | 确定性预装仅覆盖部分前端模板且不用于审查；不等于通用能力补齐 |
| 技能审批 | `default_work_task_runner_mutation_policy.dart:308` | 当前要求精确变更审批及无撤销确认；低打扰目标要通过明确授权合同扩展，不能删掉审批验证 |
| 用量归属 | `lib/features/ai_governance/ai_governance_models.dart:253` | 账本有请求、角色、会话与用量，但没有直接的 taskId/runBoundary；不能按会话总量冒充任务总量 |
| 空转保护 | `work_task_execution_policy.dart:75` | 已有真实指纹、相同条件失败及无进展保护；复用并接入新增试用/渲染证据 |

表中的未实现能力需要代码、运行时和真实环境同时接通。只改变提示词会使角色要求的动作继续落到不可用工具或人工阻塞上。

## 5. 改造范围判断

| 改造量 | 内容 |
|---|---|
| 可保留 | Flutter 群聊 UI、角色资料、统一记忆、模型网关、任务调度、文件服务、候选版本、事件存储与恢复基础 |
| 中等改动 | 逐角色试用编排、一般分歧的协调裁决、完成门禁、人格上下文、任务用量、持续授权和 UI 状态 |
| 较大新增 | 原生应用操作和身份核验、渲染及视觉证据、GitHub 技能资源包的安全导入与验证 |
| 后续独立阶段 | Windows/手机环境与远程证据回传，多执行者并行制作 |

不能根据这次有限调研给出可靠人天估算。P0 真机验证和 P1 状态/调用方梳理完成后，才能根据实际 SDK、模型、字体、应用框架和部署条件估算。优先验证最不确定的 macOS 操作链路，避免第三次重构完成后仍没有真实使用能力。
