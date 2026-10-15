# P4 GitHub 技能与成功流程验证

日期：2026-10-14。状态：**实现与定向自动检查完成；群聊/私聊真实技能复用验收未完成，P4 不标记为通过。** 本记录区分生产代码路径、自动化检查和真实模型使用；网关测试替身及本地脚本测试都不作为真实 GitHub 技能端到端验收。

## 实现范围与调用链

| 能力 | 实现与调用链 |
|---|---|
| 内置与远程区分 | `skill.download` 仍只调用 `SkillDownloadService` 安装 catalog 模板；新增 `skill.github.search`、`skill.github.import` 和 `skill.resource.read`，均接入既有 `AgentDecisionParser`、单一 `DefaultWorkTaskRunner` 工具注册、角色/任务权限及既有取消和 mutation 审批路径。 |
| 受控发现与固定提交 | 发现复用配置的生产搜索 Gateway。导入只接收 `owner/repo/path/ref`，客户端不收任意 URL。Gateway 构造固定 `https://api.github.com` 请求，核验 DNS 公网地址，不跟随重定向，分支/标签解析成 commit SHA 后所有资源都按该 SHA 读取，并复用 Gateway 鉴权、限流、配额、熔断和统一错误处理。 |
| 文件清单和信任边界 | 仅收固定提交下技能目录中的 `SKILL.md` 及支持格式的资源；限制文件数、深度、单文件和总大小，拒绝路径越界、符号链接、未知格式、无效编码和缺失/外部引用。客户端严格解析 YAML frontmatter 和文件摘要；未知许可保留为未知状态。`allowed-tools` 只保存成作者请求资料，不能赋予权限。 |
| 受限存储和使用 | `CharacterSkill` 只追加可空 Hive 字段 `resourcePackId`（字段号 9），已运行 `build_runner`。资源包用内容摘要标识并存于应用数据目录；模型只能以当前角色已有绑定的 `packId/path` 读取，所有读文件都核对清单大小与 SHA-256。包内脚本只能复制到已授权 workspace 后经现有 `command.run` 策略执行；只有退出码为 0、脚本与包内摘要匹配时才记录脚本成功证据。 |
| 激活与沉淀 | 下载导入只保存未验证包，不执行系统安装、不授予 `CharacterSkill` 权限、不自动绑定角色资格。生产使用收据绑定 task、conversation、character 和资源；同一角色实际读取 `SKILL.md`、成功运行包内脚本，并分别完成成功的群聊与私聊任务后，且许可已识别，才标记验证并激活。创建技能策略还要求明确请求、真实方法缺口或成功任务产生的新复用方法，先去重并查已有/内置/GitHub；网络、权限、依赖或 SDK 缺失不能通过造技能绕过。 |
| 备份、恢复和清理 | 完整、配置和会话导出均随关联技能包含资源包；恢复检查包内摘要并保留引用映射，但恢复时强制回到未验证状态、清除工具权限且不恢复角色激活绑定。缺少/损坏文件在导出检查中显式列出。删除技能后按剩余引用清理不再使用的包；运行时收据不进入备份。 |

主要 P4 调用点为 `github_skill_service.dart`、`skill_resource_pack.dart`、`skill_resource_pack_store.dart`、`default_work_task_runner_mutation_policy.dart`、`default_work_task_runner_delivery.dart`、`default_work_task_runner_command_execution.dart`、`default_work_task_runner_execution.dart`、`backup_exporter.dart`、`restore_plan.dart` 和 `restore_executor.dart`。群聊与私聊都沿用现有工作模式 runner；没有增加第二执行循环或通用 URL fetch。

## 实际命令与结果

```sh
cd gateway && npm test
```

结果：退出码 0，32 项通过。包含授权/配额路由、分支转 SHA、固定 SHA 读取、结构化请求错误、引用资源、外链与路径约束、符号链接、大小限制及未知许可等网关边界；GitHub 上游由测试传输替身提供，因此不表示本机真实 GitHub 导入已完成。

```sh
flutter test --reporter compact \
  test/agentic/skill_resource_pack_test.dart \
  test/agentic/expert_skill_catalog_test.dart \
  test/work_mode/agent_decision_parser_test.dart \
  test/backup/skill_resource_pack_backup_test.dart \
  test/backup_restore_service_test.dart \
  test/data_lifecycle_service_test.dart
```

结果：退出码 0，171 项通过。覆盖严格 schema、URL/额外参数注入、资源解析与校验、无效/未知许可、缺失依赖失败不产生成功凭据、只有角色本人在群聊和私聊分别读取并成功执行才可激活、备份范围往返及恢复时权限/验证状态重置、删除清理。

```sh
dart run build_runner build --delete-conflicting-outputs
flutter analyze --no-pub
git diff --check
```

结果：生成器成功（11 outputs，26 actions）；静态分析 `No issues found!`；diff 检查退出码 0。另有 `flutter test test/database_service_realtime_identity_test.dart` 退出码 0、2 项通过，用于诊断恢复测试数据目录身份。

```sh
flutter test test/work_mode/default_work_task_runner_stage02_test.dart
```

结果：尝试运行完整 runner 回归时进入真实单次时限用例，超过仓库规定的 30 秒单测上限；已中断该次运行，进度到约 47 项，**不能算作通过**。P4 定向套件和静态分析已独立完成；完整 stage02 runner 回归仍未完成。

## 后续技能提示对齐（2026-10-14）

收到技能发现与沉淀提示要求后，核对了实际生产路径：`default_work_task_runner_execution.dart` 通过 `_skillsFor` 把当前技能交给 `AgentPromptBuilder`，并在每轮重建提示；群聊与私聊仍共用这一条 runner。更新了通用技能管理器及 `meta.find-skills`、`meta.create-skills` 提示，明确用户指定来源优先、只按结构化字段固定提交导入、保留真实仓库/提交、按需加载正文与引用资源、校验脚本/依赖/权限、拒绝技能内容扩大权限或改变验收，以及真实运行复测后才验证/激活。

修正了无匹配模板时的创建暗示：保留 `general.workbuddy-expert-builder` 旧 ID 和安全模板作为可选内置目录回退，但任务解析不再把它注入为当前任务技能，也不再设置 `needsSkillCreation` 或自动生成创建提示。仅缺少匹配项不会触发沉淀。首轮定向测试有两条断言沿用旧文案而失败；修订为与新提示实际措辞一致后，以下最终命令通过：

```sh
dart format lib/features/agentic/character_skill_resolver.dart lib/features/agentic/expert_skill_catalog.dart test/agentic/expert_skill_catalog_test.dart test/agentic/character_skill_resolver_test.dart
flutter test test/agentic/expert_skill_catalog_test.dart test/agentic/character_skill_resolver_test.dart test/agentic/skill_download_service_test.dart
flutter analyze lib/features/agentic/character_skill_resolver.dart lib/features/agentic/expert_skill_catalog.dart test/agentic/expert_skill_catalog_test.dart test/agentic/character_skill_resolver_test.dart
git diff --check
```

结果：20 项定向测试通过；静态分析 `No issues found!`；格式化及 diff 检查通过。本次没有真实模型、生产搜索 Gateway 或隔离群/私聊环境，因此这次改动也没有取得真实 GitHub 导入和群聊/私聊复用收据；原 P4 未通过结论保持不变。

## 规格对照、未检查项与风险

| 需求 | 结论 |
|---|---|
| 群聊和私聊共用既有工具链、搜索 Gateway、权限及脚本策略 | 调用链和定向代码/测试已检查；同一 production runner 支持两类任务。 |
| 固定 SHA、受限 manifest、未知许可、恶意权限、路径穿越和损坏包 | 边界检查及网关/Flutter 测试通过；未用真实公共仓库完成用户侧导入。 |
| 仅真实成功方法才验证/激活，备份不迁移可信度或设备权限 | 当前实现与自动化检查通过；没有将单测当作真实操作收据。 |
| 用一个含引用资源和脚本的公共技能在群聊/私聊实际复用，再复测 | **未完成。** 本机尚未运行隔离测试组，无法取得成员各自模型、群聊与私聊任务以及实际操作收据；不能宣布共享成功流程验收通过。 |
| 完整 runner 回归 | **未完成。** 单次真实时限用例超过项目 30 秒要求，本次中断。 |

本次没有读取 API Key 或默认个人模型/聊天数据。要完成剩余现场验收，需要隔离测试组及目录、群聊成员各自的模型配置、可用的生产搜索 Gateway 凭据（留在应用安全设置中）和一个许可可确认、含本地引用资源及安全脚本的公共技能。系统级依赖缺失应报告并停止该技能验证，不能通过技能安装脚本补齐。P2 原生 macOS 真实自动化和 P3 真实多角色自然度验收仍分别按原阶段记录保持未通过。
