# APP 优化与增强分阶段路线图

状态：草案，等待逐阶段评审  
建立日期：2026-07-14

## 1. 目的

把当前 APP 的发布、安全、数据一致性、架构和产品增强事项拆成可以独立讨论、实施和验收的阶段目标。每个阶段均提供两份文档：

- `*.requirements.md`：回答为什么做、给谁用、要做到什么程度。
- `*.technical.md`：回答准备怎么做、影响哪些模块、如何迁移和验证。

本文档只负责总顺序和跨阶段约束。具体范围以各阶段文档为准。

## 2. 已确认的范围边界

本轮明确不处理：

- `data/*.hive` 是否继续由 Git 追踪。
- `docs/archive/conversations/` 是否继续由 Git 追踪。
- 已进入 Git 历史的数据清理、历史重写和仓库级密钥扫描。

说明：上述事项仅暂缓，不代表不存在风险；后续应另建独立目标处理。本路线图中的安全阶段只处理 APP 运行时的凭据和本地桥接安全，不改变上述 Git 策略。

## 3. 阶段总览

| 顺序 | 阶段目标 | 主要结果 | 前置依赖 |
|---|---|---|---|
| 00 | 正式版可用性基线 | Android 正式版联网、版本/品牌元数据一致、发布冒烟门禁 | 无 |
| 01 | 凭据与本地 Agent 安全 | API Key 单一安全存储、本地桥接具备会话鉴权并按需启动 | 00 |
| 02 | 数据生命周期一致性 | 删除、清空、配置解绑和附件回收行为与 UI 承诺一致 | 01 |
| 03 | 聊天核心架构与性能 | 聊天状态机解耦、历史分页、收件箱索引、附件异步处理 | 02 |
| 04 | 完整备份、导入与恢复 | 用户可验证地备份和恢复角色、群聊、消息、记忆与附件 | 02；建议在 03 后落地 |
| 05 | 模型能力、成本与联网治理 | 模型能力准确、成本可控、联网搜索可感知且可关闭 | 01、03 |
| 06 | 记忆、搜索与文档智能 | 记忆可管理、全局检索、文档可理解，形成长期使用价值 | 03、04、05 |

## 4. 文档索引

### 阶段 00：正式版可用性基线

- [需求文档](./00-release-baseline.requirements.md)
- [技术方案](./00-release-baseline.technical.md)

### 阶段 01：凭据与本地 Agent 安全

- [需求文档](./01-runtime-security.requirements.md)
- [技术方案](./01-runtime-security.technical.md)

### 阶段 02：数据生命周期一致性

- [需求文档](./02-data-lifecycle.requirements.md)
- [技术方案](./02-data-lifecycle.technical.md)

### 阶段 03：聊天核心架构与性能

- [需求文档](./03-chat-architecture-performance.requirements.md)
- [技术方案](./03-chat-architecture-performance.technical.md)

### 阶段 04：完整备份、导入与恢复

- [需求文档](./04-backup-restore.requirements.md)
- [技术方案](./04-backup-restore.technical.md)

### 阶段 05：模型能力、成本与联网治理

- [需求文档](./05-ai-governance.requirements.md)
- [技术方案](./05-ai-governance.technical.md)

### 阶段 06：记忆、搜索与文档智能

- [需求文档](./06-intelligent-experience.requirements.md)
- [技术方案](./06-intelligent-experience.technical.md)

## 5. 通用质量门禁

每个阶段都必须满足：

- `flutter analyze` 无问题。
- 全量 `flutter test` 通过，并新增该阶段关键回归测试。
- 涉及 Hive model/provider 时运行 `dart run build_runner build --delete-conflicting-outputs`。
- 涉及平台配置时至少执行对应平台 release build 或检查最终合并产物。
- 用户可见行为必须有明确的失败提示和恢复路径。
- 不得把 API Key、完整提示词或对话正文写入普通日志。
- 阶段完成后更新需求状态、技术决策和 CHANGELOG。

## 6. 逐份评审方式

建议每次只评审一份文档，顺序为：

1. 先确认该阶段需求文档中的范围、用户流程和验收标准。
2. 再确认技术方案中的数据迁移、接口、任务拆分和风险。
3. 技术方案被接受后才进入实现。
4. 实现中的重大方案变化回写技术文档；昂贵且难逆转的决策另建 ADR。

## 7. 当前待确认

- 阶段 00 是否要在本轮同时更换正式包名和产品显示名。
- 阶段 01 是否允许在系统安全存储不可用时完全禁止保存 Key，还是允许明确告知后的本地降级。
- 阶段 04 的备份默认是否必须加密。
- 阶段 06 是否优先做全局搜索，还是优先做文档理解。
