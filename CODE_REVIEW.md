# 项目代码审查复核报告（修复后）

**项目**: AI 群聊模拟器（chat_group）
**审查日期**: 2026-08-04
**审查基线**: `main / 0b22b26` + 当前工作区修复
**审查范围**: 本轮 Review 涉及的 `lib/`、`test/` 变更
**审查结论**: 本轮 P1 网关重试、群聊额度绕过和角色额度并发写回均已修复；分析器与全量测试通过，建议提交合并。已读双写原子性和治理 Store 生命周期保留为 P2。

## 一、当前验证结果

| 检查 | 结果 | 说明 |
|---|---|---|
| `dart run build_runner build --delete-conflicting-outputs` | 通过 | 990 outputs，0 errors |
| `flutter test` | 通过 | 673 项全部通过 |
| `dart analyze` | 通过 | 无 error |
| `flutter analyze` | 通过 | `No issues found`，退出码为 0 |
| `git diff --check` | 通过 | 无空白错误 |

因此当前代码达到合并门槛；P2 项目不阻塞本轮合并，但应保留在后续任务中。

## 二、已确认完成的修复

### 关键/高优先级

1. `AiGovernanceStore.forDatabase(db)` 按数据库实例复用治理 Store，并通过 `GovernancePersistence.guard` 共享 `AiRequestGuard`，使 `_reservedMicros` 跨网关实例可见。
2. `AiRequestGateway` 不再自行接收 `ModelCapabilityRegistry`，统一从共享 Store 获取 guard。
3. `DatabaseService` 的初始化/索引重建使用 `Completer`，异常通过 `completeError` 传递给并发等待者。
4. 重试记录增加 `attemptRecorded`，避免流式完成事件和 `finally` 重复记账。
5. `RetryHandler` 补齐第 5 次重试延迟：`8000ms`。
6. 关系模型、API 配置模型的默认值已移动到源文件注解，并重新生成 `.g.dart`；不再依赖手改生成文件。
7. `ApiConfig` 的 Hive 字段 4 增加默认值并改为可空，生成适配器可以读取缺少该字段的旧记录。
8. 治理网关非流式和 `sendChatMessageStreamed` 重试已将 `RetryAttempt.temperatureFor()` 传入底层请求，保持底层 `maxRetries: 0` 避免双重重试。

### 流式、调度与数据一致性

1. UTF-16 截断会避开高代理符，不再切断 emoji 代理对。
2. `SseParser` 使用 UTF-8 字节数累计正文，限制 2 MB，并在错误/超限后设置 `terminated`，忽略后续输入。
3. `ChatApiService` 在 `[DONE]` 和流正常结束路径都检查 `parser.terminated`，错误后不会再发成功 `done` 事件。
4. `AutoChatScheduler.stop()`、`start()`、`coolDown()` 的状态处理已补齐；冷却期间的回合不会被 `nextInterval()` 覆盖。
5. 重新生成失败时不再持久化错误占位消息，原消息继续保留。
6. 被 pin 的关系命中后使用 `return`，不会继续执行本次关系规则更新。
7. `markDirectChatRead()` 在 Hive 写入前更新摘要缓存，避免同进程后续读取到旧摘要。
8. 企微明确认证失败码会清除 token 缓存；普通网络错误不会误删 token。
9. Web 查询参数交给 Dio 编码，移除手工二次编码。
10. 备份未知枚举值改为抛 `FormatException`，由恢复事务回滚，不再静默映射到第一个枚举值。

### 性能与清理

1. pinned key 使用缓存，避免重复读取 Hive。
2. 活跃策略由 `O(n×m)` 改为 `Set`/`Map` 查找。
3. 删除不可达分支，空名字增加 `?` 回退。

## 三、仍需修复的问题

以下问题是当前代码复核后仍然存在的，不包含已经关闭的旧 Review 项。

### 已关闭：治理网关重试温度回退

文件：`lib/features/ai_governance/ai_request_gateway.dart`

实现逻辑已正确：操作回调接收 `RetryAttempt`，非流式和 `sendChatMessageStreamed` 都使用 `attempt.temperatureFor(originalTemperature)`，底层重试次数仍为 0；网关回归测试已直接断言 retry 0、4、5 的温度序列。

### 已关闭：群聊主动服务绕过每小时回复额度

文件：`lib/features/chat_group/group_chat_proactive_service.dart`

实现已接入 `ReplyEligibilityPolicy`，达到 `hourlyLimit` 时在请求前阻断；成功持久化后通过数据库统一记账。群聊主动额度回归测试已覆盖达到上限阻断和成功后记账。

### 已关闭：角色回复额度异步读改写覆盖窗口

文件：`lib/features/chat_group/reply_eligibility_policy.dart`、`chat_room_page.dart`、`direct_chat_proactive_service.dart`

`DatabaseService.recordCharacterReplyUsage()` 现在按 `characterId` 维护 Future 队列，在同一串行边界内重新读取、递增并等待 Hive 写入。聊天室、群聊主动和私聊主动都统一调用该方法。并发回归测试验证两次成功更新最终计数为 2。

注意：当前串行化解决的是成功记账的 lost update；若产品要求并发请求绝不超过 hourlyLimit，需要另行设计“额度预留/失败回滚”，不在本轮扩大范围。

### P2：`markDirectChatRead()` 仍不是持久化原子提交

文件：`lib/core/database/database_service.dart`

当前缓存提前更新已解决同进程旧数据问题，但摘要和 `direct_chat_read_at` 仍是两次 Hive 写入。第二次写入失败时，内存缓存、摘要和已读时间可能不一致。

建议：保留写入前的旧值，在任一步失败时恢复两个 Hive 值和内存缓存；或者把两个字段合并成一份可恢复记录。至少补一个可注入写入失败的测试，并检查群聊已读路径是否需要相同策略。

### P2：治理 Store 的静态缓存缺少生命周期边界

文件：`lib/features/ai_governance/ai_governance_store.dart`

`_instances` 是静态 `Map<int, AiGovernanceStore>`，键由 `Object.hash(db, db.hashCode)` 得到。当前单数据库运行通常正常，但该 Map 永不释放，且整数 hash 不是严格的对象身份键；多数据库测试或长期重建数据库时可能造成 Store 保留或极低概率碰撞。

建议：使用对象身份作用域的缓存（例如 `Expando`）或由 `DatabaseService` 明确持有并在 dispose 时清理。必须保留同一数据库共享 guard、不同数据库相互隔离的测试。

### 已关闭：`legacyApiKey` 的兼容层与分析器门禁

文件：`lib/core/models/api_config.dart`、相关迁移/备份文件及生成适配器

字段 4 缺失导致的 Hive 崩溃风险已修复。遗留字段现在是 Hive 私有字段 `_legacyApiKey`，仅通过命名明确的迁移边界访问器使用；生成适配器由 build_runner 生成，`flutter analyze` 已无问题。

建议：

1. 迁移、备份和开发回退仍只能通过明确的 migration accessor 访问；不得恢复业务层直接读取 Hive 明文 Key。
2. 字段 4 保留 `defaultValue: ''`，适配器由 build_runner 重新生成。
3. 网关温度回退和群聊额度均有直接回归测试。

## 四、明确暂不修复的项目

以下两项目前可以记录为技术决策，不作为本轮合并阻塞项：

1. **LRU 缓存线程安全**：当前 Flutter 单 isolate 架构下，UI 代码在同一消息循环执行；除非引入共享多 isolate 访问或 profiling 证明存在问题，否则不增加 Mutex。
2. **文档解析 isolate 生命周期**：当前代码注释已说明这是有意简化；只有 profiling 证明大文件解析造成资源泄漏或卡顿时，才改为受管理的 isolate。

其余“大文件拆分、主题色硬编码、设置页版本字符串、UI 即时刷新、空成员 @ 菜单、同分排序 tie-breaker”等属于 P2/P3 维护项，建议在对应功能继续变更或有用户影响时处理，不要与本轮治理/数据一致性修复混在同一个大 PR 中。

## 五、建议新增的回归测试

1. SSE 正好达到 2 MB、超过 2 MB，以及中文/emoji 多字节内容的边界行为。
2. `markDirectChatRead()` 任一次 Hive 写入失败时，摘要、已读时间和缓存能够恢复一致。
3. 同一 `DatabaseService` 得到同一个 Store/guard，不同数据库得到不同 Store/guard。
4. 旧 `ApiConfig` 缺少 legacy 字段时能够按既定迁移策略读取或明确回滚。

## 六、可直接交给开发者的详细提示词

```text
你是本项目 chat_group 的 Flutter/Dart 资深工程师。请在当前工作区继续处理
CODE_REVIEW.md 中“仍需修复的问题”，只修改源码和必要的回归测试，不要修改
本评审结论来掩盖问题。

目标：在不破坏现有行为、安全边界和 Hive 数据兼容性的前提下，处理剩余 P2 项并保持当前已通过的 P1 回归测试：

1. 如产品确认需要严格限制并发额度，再设计角色回复额度预留与失败回滚。
   - 当前版本已经按 characterId 串行化成功记账；只有在需要“并发请求不超过上限”时才继续扩展。
   - 预留必须有失败回滚，不能把失败请求永久计入额度。

2. 处理 markDirectChatRead 的失败一致性。
   - 保留写入前的摘要、direct_chat_read_at 和缓存快照。
   - 任一次 Hive 写入失败时恢复旧值和旧缓存，不能吞异常。
   - 检查群聊已读方法是否存在同类问题；如果没有，说明原因。
   - 补失败路径测试。

3. 收口 AiGovernanceStore.forDatabase 的生命周期。
   - 保证同一 DatabaseService 共享同一个 Store/guard。
   - 保证不同 DatabaseService 不共享 Store/guard。
   - 避免使用可能碰撞的整数 hash 作为对象身份键。
   - 不要为了修复缓存而把 Store 改成全局单例；保留测试隔离。
   - 如果 DatabaseService 已有 dispose 生命周期，优先在那里清理；否则选择最小、可解释的对象身份缓存。

4. 维护 legacyApiKey 兼容边界。
   - 保护 API Key 红线：Release 不得从 Hive 明文读取或写入 API Key；测试连接不得临时持久化用户新输入的 Key。
   - 将业务层直接访问 legacyApiKey 的位置收敛到迁移专用 accessor；当前 `_legacyApiKey` 不得重新公开。
   - 不要手工编辑任何 .g.dart；先修改模型源文件注解，再运行 build_runner 重新生成。
   - 字段 4 已增加 defaultValue: ''，修改模型后必须重新运行 build_runner。
   - 保持 flutter analyze 退出码为 0；不得用全局 ignore 把真实问题隐藏掉。

约束：
- 先阅读 AGENTS.md、CODE_REVIEW.md 以及相关文件的所有调用方，再编辑。
- 不新增依赖，不做与本清单无关的大规模重构。
- 不修改用户已有的无关工作区变更。
- 不手改生成文件，不删除现有回归测试。
- 保留当前单 isolate 的简化决策；不要为了 LRU 缓存添加 Mutex。
- 任何新增共享状态都必须有生命周期和测试隔离说明。

完成后必须运行并报告：
1. dart run build_runner build --delete-conflicting-outputs（如果模型/Provider 有变化）。
2. flutter analyze（必须退出码 0，不能有未解释的问题）。
3. flutter test（全部通过）。
4. 与本次问题对应的定向测试。
5. git diff --check。

最终输出请按以下格式：
- 已修复：按问题编号列出文件和行为变化。
- 测试结果：列出每条命令和退出结果。
- 仍延期：只列出经过确认不阻塞合并的项目及延期理由。
- 不要声称“clean”，除非 flutter analyze 确实零问题并返回 0。
```

## 最终结论

本轮修复已经解决了原 Review 中最明显的治理共享、SSE 终止、调度冷却、生成文件维护、网关温度回退、群聊额度绕过、角色额度丢失更新、已读缓存和多项兼容性问题。建议合并，剩余项目为：

1. 已读状态失败回滚；
2. 治理 Store 生命周期治理；
3. 如果产品要求强额度上限，再增加额度预留/失败回滚。

本次同步更新了评审文档，并完成了业务源码、生成文件和回归测试修复。
