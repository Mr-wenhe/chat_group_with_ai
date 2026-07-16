# 阶段 02 技术方案：数据生命周期一致性

状态：已实施（2026-07-16）
对应需求：`02-data-lifecycle.requirements.md`

## 1. 架构决策

- 新增 `DataLifecycleService`，所有级联删除必须经过该服务，UI/Provider 不再直接只删主 Box。
- 删除采用“生成计划 → 展示影响 → 执行 → 校验 → 回收文件”的流程。
- Hive 无跨 Box 事务，因此使用可重入的删除计划和操作日志实现最终一致性。
- 文件回收最后执行，并且只处理 APP 管理根目录内的无引用文件。

## 2. 删除计划模型

建议使用不必持久化的 `DeletionPlan` 描述：

- target type/id
- 受影响 Box 和 key 列表
- 受影响文件候选
- 记录数量和用户可见摘要
- 保留策略选项

对于大删除，可持久化 `DeletionJob` 的阶段进度，支持 APP 重启后继续校验或重试。

## 3. 关联关系清单

### 群聊主键关联

- `ChatGroup.id`
- `Message.groupId`
- `GroupMemory.groupId`
- `CharacterMemory.groupId`
- `RelationshipState.groupId`
- `AgentTask.groupId`
- `WorkModeWorkspace.conversationId`
- app settings 中的 read/proactive/pin/work-mode/context checkpoint/index

### 角色主键关联

- `ChatGroup.aiCharacterIds`
- `Message.senderId` 和 DM conversation id
- `CharacterMemory.characterId`
- `RelationshipState` 的 speaker/target
- `CharacterSkill.characterId`
- `AgentTask.characterId`
- 置顶、主动联系和私聊来源设置

实现前应以实际模型字段复核并形成测试表，避免遗漏。

## 4. 文件引用回收

流程：

1. 从仍保留的 Message/Task 收集规范化附件路径集合。
2. 限制候选必须位于 `data/media` 或明确的 APP 管理目录。
3. 使用规范路径和符号链接检查防止越界。
4. 删除无引用候选；失败记录为可重试警告，不回滚已完成的数据库删除。

工作模式 workspace 默认不自动整目录删除，除非需求明确它完全归属于该会话。

## 5. 实施任务

### Task 02-1：建立关联清单和删除计划预览

**验收：** 对群聊、角色、配置可生成准确数量预览。  
**验证：** fixture 覆盖所有 Box 和设置键。  
**依赖：** 阶段 01 的配置/凭据语义。  
**预计范围：** M。

### Task 02-2：实现群聊级联删除

**验收：** 群记录、关联内容和设置索引按需求清理。  
**验证：** 数据库集成测试；重复执行两次结果相同。  
**依赖：** Task 02-1。  
**预计范围：** M。

### Task 02-3：实现角色删除策略

**验收：** 两种保留策略均无悬空群成员；私聊和技能/任务符合选择。  
**验证：** 群聊历史保留/删除两组 fixture。  
**依赖：** Task 02-1。  
**预计范围：** M。

### Task 02-4：实现配置替换/解绑/删除

**验收：** 引用角色被替换或进入未配置状态；凭据同步删除。  
**验证：** 请求解析回归测试，确认无 legacy fallback。  
**依赖：** 阶段 01、Task 02-1。  
**预计范围：** S/M。

### Task 02-5：附件引用回收和空间统计

**验收：** 孤儿文件可统计/清理，外部文件不会被删除。  
**验证：** 临时目录测试、符号链接和路径边界测试。  
**依赖：** Task 02-2、02-3。  
**预计范围：** M。

### Task 02-6：重构清空数据与 UI 文案

**验收：** 三类清空操作的范围清晰，Provider 状态全部刷新。  
**验证：** Widget 测试与数据库状态断言。  
**依赖：** 前述任务。  
**预计范围：** M。

## 6. 检查点

- [x] 所有关联表都有删除测试。
- [x] 删除操作幂等并能报告部分失败。
- [x] 媒体清理经过路径安全测试。
- [x] analyze/test 全绿，人工检查所有确认框文案。

## 7. 风险与回滚

| 风险 | 影响 | 缓解/回滚 |
|---|---|---|
| 跨 Box 删除中途失败 | 高 | 持久化步骤/可重入执行；数据库删除前生成计划 |
| 错删用户外部文件 | 严重 | 只允许 APP 管理根目录；真实路径校验；文件删除最后执行 |
| 保留历史消息后发送者缺失 | 中 | `DeletedCharacterSnapshot` 或稳定展示快照，不依赖当前角色 Box |
| 大会话删除阻塞 UI | 中 | 分批异步执行并展示进度，不在 build/UI 同步扫描 |

## 8. 实施决策

- 使用 `app_settings` 中的单条持久化删除作业记录，失败后可幂等重试。
- 删除角色并保留历史时保存轻量身份快照，私聊与导出统一显示“已删除角色”。
- 工作模式物理目录不自动删除；只清理属于会话的 Hive 工作区记录。
- API 凭据先于配置元数据删除；Keychain 删除失败时保留配置记录并等待重试。
- 单消息和未发送附件按候选路径回收；群聊/角色/全量删除及设置页手动清理才扫描完整媒体库。
