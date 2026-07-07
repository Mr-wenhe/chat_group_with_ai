# Humanized Chat Engine Design

日期：2026-07-07

## 背景

当前应用已经具备群聊、流式回复、引用回复、场景模式、自动聊天、群记忆和角色自我记忆等能力，但聊天仍容易呈现明显的 AI 问答感：角色常常像被点名答题，回复偏完整、礼貌、总结化，角色之间缺少真实关系带来的偏心、摩擦、默契、沉默和插话。

本设计的目标是让 AI 群聊更接近真实人类群聊：角色有长期记忆、有关系、有情绪余温、有表达习惯，也会因为关系和当下气氛决定是否开口、对谁开口、用什么语气开口。

## 目标

- 让角色之间、角色与用户之间形成可演变的关系状态。
- 将角色记忆从单段摘要升级为分层记忆：事实、关系情绪、人格成长。
- 让群聊发言选择从简单随机升级为基于动机的群聊节奏引擎。
- 让 prompt 注入具体状态和本轮社交动作，而不是泛泛要求“像真人”。
- 将核心逻辑放进可测试的纯 Dart service/helper，减少 `ChatRoomPage` 的继续膨胀。

## 非目标

- 第一阶段不做完整人生模拟器，不引入日程、职业成长、隐秘目标或复杂人生事件线。
- 第一阶段不实现关系可视化编辑；数据模型预留初始关系能力，UI 不进入本阶段范围。
- 第一阶段不删除 `AICharacter.memorySummary`，它保留为兼容字段和迁移材料。
- 第一阶段不改变 API Key 存储策略，也不改变已有导出安全边界。

## 体验原则

- 选择路线：关系系统 + 分层记忆 + 群聊节奏引擎。
- 关系策略：初始关系可设定，但真正的亲疏、偏见、默契和矛盾从聊天中演变。
- 群聊节奏：明显鲜活但不失控。允许短句、附和、反问、轻微跑题、接梗、点名别人，也允许角色不回应。
- 记忆策略：事实、情绪关系、人格成长分层管理，只保存会改变下一次反应的内容。
- 回复风格：少总结、少完整答题腔，更多口语、半句、态度、关系延续和当下情绪。

## 数据模型

### CharacterMemory

一条记录表示某个角色在某个群里的长期记忆。这样同一个角色在不同群里可以长成不同的人。

字段：

- `id`：唯一 ID。
- `groupId`：所属群。
- `characterId`：所属角色。
- `facts`：稳定事实列表，例如用户偏好、群里发生过的重要事件。
- `relationshipNotes`：关系和情绪记忆，例如“我觉得小林说话有点冲，但观点有用”。
- `personaGrowth`：人格成长记忆，例如口头禅、偏好、雷点、表达习惯。
- `lastUpdatedAt`：最近更新时间。
- `createdAt`：创建时间。

迁移策略：

- 如果新 `CharacterMemory` 为空，且 `AICharacter.memorySummary` 非空，则把旧内容作为 `personaGrowth` 的初始材料。
- 不在第一阶段删除或清空旧字段，避免破坏现有数据。

### RelationshipState

一条记录表示某个群里 `source` 对 `target` 的单向关系状态。关系保持单向，因为真实关系经常不对称。

字段：

- `id`：唯一 ID。
- `groupId`：所属群。
- `sourceCharacterId`：感受关系的一方。
- `targetId`：另一个角色 ID 或用户标识。
- `targetType`：`ai` 或 `user`。
- `affinity`：亲近度，范围 `-100..100`。
- `trust`：信任度，范围 `-100..100`。
- `friction`：摩擦度，范围 `0..100`。
- `familiarity`：熟悉度，范围 `0..100`。
- `recentMood`：最近情绪，例如 `warm`、`annoyed`、`awkward`、`protective`、`neutral`。
- `notes`：短文本关系备注。
- `lastInteractionAt`：最近互动时间。
- `createdAt`：创建时间。

第一阶段通过本地规则自动创建关系记录；不实现初始关系编辑 UI，但模型保留 `notes` 和初始分数字段，保证未来入口可以复用同一份存储。

## 核心组件

### HumanizedChatOrchestrator

纯 Dart helper/service，负责根据上下文选择发言者和本轮社交动作。

输入：

- 当前群成员。
- 最近消息。
- 当前用户消息和提及对象。
- `CharacterMemory` 列表。
- `RelationshipState` 列表。
- 资格判断函数，例如 API 配置、启用状态、每小时限制。
- 随机源，测试中使用固定随机源。

输出：`List<ReplyIntent>`。

`ReplyIntent` 字段：

- `speakerId`：发言角色。
- `action`：`answer`、`agree`、`challenge`、`joke`、`askBack`、`topicShift`、`comfort`、`callOut`。
- `targetId`：这句话主要冲谁去，可为空。
- `lengthHint`：`oneLiner`、`short`、`normal`。
- `toneHint`：例如轻松、别扭、认真、带刺、温柔、冷淡。
- `reason`：调试和测试用，不展示给用户，不写入聊天内容。

发言分数由以下因素组成：

- `mentionBoost`：被 @ 或被直接问到，强烈加分。
- `relationshipBoost`：亲近的人说话、讨厌的人说话、刚被冒犯都会影响开口动机。
- `topicInterestBoost`：话题命中职业、偏好、长期关注点。
- `recencyPenalty`：刚说过的人降低分数，避免刷屏。
- `silenceChance`：即使有资格也允许不说话。
- `interruptChance`：少量概率插话、补刀、接梗。
- `cooldownByMood`：尴尬、疲惫、冷淡时降低开口概率。

第一阶段强度：

- 用户消息后通常 1-2 个角色回应，允许 0-3 个。
- 自动聊天允许更高比例的接梗、轻微跑题、点名别人。
- 冲突、吃醋、站队只作为轻微关系摩擦出现，不做连续剧式爆炸。

### HumanizedMemoryService

负责每轮后更新关系和分层记忆。

关系更新：

- A 经常赞同 B：A 对 B 的 `affinity` 和 `familiarity` 缓慢上升。
- A 被 B 反驳：A 对 B 的 `friction` 上升；当反驳语气强或连续发生时，`recentMood` 变为 `annoyed`。
- 用户经常 @ 某角色：该角色对用户的 `familiarity` 上升；当互动语气友好时，`affinity` 小幅上升。
- A 帮 B 解围：B 对 A 的 `trust` 上升。
- 长时间无互动：不删除关系，但 `recentMood` 慢慢回到 `neutral`。

记忆更新：

- 用户消息触发的 AI 回合结束后尝试更新。
- 自动聊天每 2-3 轮更新一次，避免 API 成本过高。
- 消息少于阈值时只做本地关系分数更新，不调用 LLM 总结。
- LLM 输出结构化 JSON，保存前做解析、裁剪、去重和长度限制。

JSON 形状：

```json
{
  "facts": ["用户最近在做 X", "群里讨论过 Y"],
  "relationshipNotes": ["我觉得小林说话有点冲，但观点有用"],
  "personaGrowth": ["我最近越来越习惯用半开玩笑的方式反驳"],
  "discard": ["只是寒暄，不必长期记住"]
}
```

失败策略：

- 记忆更新失败不影响聊天。
- JSON 解析失败时丢弃本次 LLM 记忆更新，但保留本地关系分数变化。
- 保存前限制每层条目数量和总字符数，避免记忆无限膨胀。

### HumanizedPromptBuilder

负责把 `ReplyIntent`、角色基础设定、分层记忆和关系状态组装为模型可执行的上下文。

注入内容：

- 角色基础设定和原 `systemPrompt`。
- 与当前话题或目标相关的 facts、personaGrowth。
- 2-4 条最相关关系，例如“你对小林有点不服，但认可他的专业”。
- 本轮开口原因，例如“你刚被小林反驳，有点不服”。
- 本轮社交动作，例如“只补一句带刺的反问，别超过 25 个字”。
- 禁止项：不要总结全局、不要说自己是 AI、不要每次完整回答、不要替别人发言、不要固定格式。

示例意图上下文：

> 你刚被小林怼了，有点不服；你和阿月比较熟。这轮你不是回答问题，而是对小林补一句带刺的反问。保持一句话，别超过 25 个字。

## 数据流

1. 用户发送消息或自动聊天计时触发。
2. `ChatRoomPage` 收集最近消息、角色、记忆和关系状态。
3. `HumanizedChatOrchestrator` 返回 `ReplyIntent` 列表。
4. 每个 `ReplyIntent` 传给 `_generateAiReply`。
5. `_buildApiMessages` 或新 `HumanizedPromptBuilder` 根据 intent、记忆和关系组装消息。
6. `ChatApiService.streamChatMessage` 流式生成回复。
7. 回复落库后，`HumanizedMemoryService` 更新关系和分层记忆。
8. 如果记忆更新失败，聊天结果保持不变，下一轮继续。

## UI 和产品入口

第一阶段 UI 保持克制：

- 聊天页不展示内部 `ReplyIntent.reason`。
- 导出不包含 API Key，也不包含内部 debug reason。
- 第一阶段不增加“真人感强度”开关，固定使用默认强度 B。
- 第一阶段不增加初始关系编辑 UI，也不做复杂关系图。

## 与现有代码的关系

- `AICharacter.memorySummary` 保留，作为迁移材料和兼容字段。
- `GroupMemory` 继续用于群体话题摘要，不替代角色级 `CharacterMemory`。
- `ChatOrchestrator` 保留现有兼容逻辑；新增真人化选择、intent 和 prompt 逻辑放入 `HumanizedChatOrchestrator` 与 `HumanizedPromptBuilder`。
- `ChatRoomPage` 只负责页面状态和调用服务，尽量不承载新增核心算法。
- 新 Hive 模型需要更新 `DatabaseService` 注册和打开 box，并运行 `dart run build_runner build`。

## 测试计划

新增或扩展测试：

- `humanized_chat_orchestrator_test.dart`
  - 被 @ 的角色优先级显著提高。
  - 高摩擦关系更容易产生 `challenge` 或带刺语气。
  - 高亲近和信任更容易产生 `agree`、`comfort` 或 `askBack`。
  - 刚发过言的角色受到冷却惩罚。
  - 固定随机源下输出稳定。

- `humanized_memory_service_test.dart`
  - 本地关系规则能更新 affinity、trust、friction、familiarity。
  - 记忆 JSON 解析失败不会抛出到聊天流程。
  - 每层记忆会裁剪、去重、限制长度。
  - 旧 `memorySummary` 能作为 `personaGrowth` 初始材料。

- `humanized_prompt_builder_test.dart`
  - prompt 包含 intent、相关关系和分层记忆。
  - prompt 不包含 debug reason。
  - prompt 包含禁止 AI 腔和固定格式的约束。

回归测试：

- `flutter analyze`
- `flutter test`
- 需要模型变更时运行 `dart run build_runner build`

## 验收标准

结构验收：

- 新 Hive 模型存在并注册。
- 旧 `memorySummary` 不丢失，能作为迁移材料。
- 主要新增逻辑在纯 Dart service/helper 中，有单元测试覆盖。

逻辑验收：

- 被 @ 的角色仍然高优先级回应。
- 关系高摩擦时更容易反驳或带刺。
- 高亲近和信任时更容易附和、安慰、追问。
- 刚说过的人有冷却，避免连续刷屏。
- 自动聊天允许轻微跑题和点名别人。

记忆验收：

- 事实、关系、人格成长分层保存。
- 记忆更新失败不影响聊天。
- 自动聊天不会每轮都调用昂贵记忆总结。
- 导出不泄露 API Key，也不导出内部 debug reason。

体验验收：

- 连续 20 条群聊中，能看到短句、附和、反问、点名、关系延续中的多种形态。
- 回复明显减少“首先、其次、总结、我认为我们可以”等答题腔。
- 角色会引用过去关系或情绪，但不会凭空编造重大事件。

## 实施顺序

1. 新增 Hive 模型、box 注册和基础 provider/service 读取接口。
2. 新增 `ReplyIntent`、`HumanizedChatOrchestrator` 和单元测试。
3. 接入 `_runAiRound`，先让发言者选择和 intent 生效。
4. 新增 `HumanizedPromptBuilder`，改造 `_buildApiMessages` 输入。
5. 新增 `HumanizedMemoryService`，先本地关系规则，再接入 LLM 分层记忆。
6. 加回归测试，运行代码生成、分析和测试。

## 风险和缓解

- API 成本上升：自动聊天降低记忆更新频率，消息少时只做本地关系更新。
- 角色人格漂移过快：关系和人格变化使用小步更新，并限制每轮记忆写入数量。
- 模型输出无效 JSON：解析失败不影响聊天，下一轮再尝试。
- `ChatRoomPage` 继续膨胀：新增核心逻辑必须放在纯 Dart service/helper。
- 关系过度戏剧化：第一阶段默认强度为明显鲜活但不失控，冲突只作为轻微摩擦。
