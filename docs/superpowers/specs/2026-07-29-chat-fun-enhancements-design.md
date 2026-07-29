# Chat Fun Enhancements Design

日期：2026-07-29

## 背景

当前应用已具备丰富的人格系统（14 个预设 + 自定义）、关系系统（affinity/trust/friction/mood）、分层记忆（facts/relationshipNotes/personaGrowth）、6 种场景模式、自动聊天 idle loop、群记忆摘要等能力。角色之间已有关系分数和情绪状态，但聊天体验仍停留在"角色在说话"的层面——缺少互动感、意外感和游戏化元素。

本设计在现有架构之上，通过三个增量功能让聊天从"有角色的对话"升级为"角色在互动"。

## 目标

- 在对话中注入不可预测的互动元素，让用户感受到角色之间有真实的"化学反应"。
- 利用已存在但未被利用的数据层（RelationshipState.mood、RelationshipState.scores）增强体验。
- 所有新功能通过 prompt 注入实现，不修改核心聊天引擎的 API 调用和渲染流程。
- 功能可独立开关，用户可以选择开启或关闭。

## 非目标

- 不做完整游戏系统（无积分、无等级、无排行榜）。
- 不做跨设备社交（所有互动在本机角色之间）。
- 不修改现有数据模型——所有新能力基于现有字段或非持久化运行时状态。

## 设计原则

- **基于已有数据**：关系分数、人格预设、场景模式、记忆系统——不做从零的新能力。
- **prompt 注入驱动**：所有行为变化通过 system message 注入实现，不改动 API 调用流程。
- **运行时轻量**：事件检测和表情解析在 orchestrator 层完成，不增加新的持久化模型。
- **可开关**：每个功能通过群级设置控制，用户可独立开启/关闭。

---

## 1. 随机互动事件系统

### 概述

在对话过程中，基于关系状态和聊天节奏，随机触发小规模互动事件。事件通过临时 system message 注入，影响当前轮次或接下来几轮的角色行为。

### 事件类型

| 事件 | 触发条件 | 行为效果 | prompt 注入 |
|------|----------|----------|-------------|
| **吃瓜围观** | 两个角色摩擦 > 30，其中一人发言后 | 第三方角色插话点评 | 注入"你刚才看到 A 和 B 的对话，忍不住想插一句…" |
| **突然杠上** | 两个角色摩擦 > 50 | 下一轮这两个角色互相对线 | 注入"你刚才被 B 顶了一句，你觉得必须反驳…" |
| **接梗捧哏** | 一个角色 affinity > 60 且刚发了有趣内容 | 好友角色附和、接梗 | 注入"B 刚才说的特别有意思，你忍不住想接一句…" |
| **冷场救场** | 连续 2 轮无人回复用户消息 | 一个角色主动打破沉默 | 注入"群里突然安静了，你觉得应该说点什么…" |
| **回忆杀** | 群里有 ≥5 条历史消息且 ≥10 分钟未活跃 | 角色引用之前的某个话题 | 注入"你突然想起之前群里聊过的一个话题…" |
| **暴躁模式** | 角色 friction > 60 且发言 | 该角色回复风格更冲、更短 | 注入"你今天心情不太好，说话带刺…" |
| **撒娇模式** | 角色 affinity > 70 且对话对象是用户/好友 | 角色语气软化、用语气词 | 注入"你今天心情特别好，说话软软的…" |

### 触发引擎

新增 `RandomEventPolicy` 类，放在 `features/chat_group/policies/` 下：

```dart
class RandomEventPolicy {
  final Random random;
  final double triggerProbability; // 默认 0.15，每轮检测一次

  /// 返回本轮应该注入的事件描述，null 表示无事件
  String? evaluateEvent({
    required List<AICharacter> characters,
    required List<Message> recentMessages,
    required Map<String, RelationshipState> relationships,
    required String? groupTheme,
    required int silenceRounds,
  });
}
```

- 每轮 `_runAiRound` 开始前调用 `evaluateEvent`
- 如果返回非 null，将事件描述作为额外 system message 注入本轮 API 调用
- 事件不影响角色选择（谁发言），只影响发言内容风格
- 同一事件不会连续触发超过 2 轮

### 配置项（ChatGroup 扩展）

在 `ChatGroup` 模型上加一个可选字段（或存 Hive app_settings）：

```dart
class FunSettings {
  final bool randomEventsEnabled;
  final double eventIntensity; // 0.0 ~ 1.0，控制事件触发概率
  final List<String> disabledEventTypes; // 用户可以选择屏蔽某些事件
}
```

### 边界处理

- 事件注入只在 ≥3 个角色的群聊中触发（DM 不触发），避免一对一场景下突兀。
- 工作模式（agentic）下不触发，避免干扰工具执行流程。
- 事件概率随群聊时长动态调整：前 5 分钟 0.1，5-20 分钟 0.15，20 分钟以上 0.2。

---

## 2. 表情反应系统

### 概述

用户可以对 AI 消息发送表情反应，反应被记录并注入后续对话上下文，影响角色的情绪感知和行为。

### 数据模型

不新增 Hive 模型。表情反应作为 `Message` 的运行时扩展存储：

```dart
class Reaction {
  final String emoji;
  final String reactorId; // 'user' 或 characterId
  final DateTime reactedAt;
}
```

存储方式：在 `Message` 上挂一个 `List<Reaction> reactions` 字段（Hive 字段），或在内存中维护一个 `Map<String, List<Reaction>>`（messageId → reactions）。前者持久化但需要迁移；后者轻量但重启丢失。**推荐前者**，作为 Hive 字段新增。

### UI

- 长按 AI 消息 → action sheet 增加"添加表情"选项 → 弹出表情选择器（8-10 个常用表情：👍 ❤️ 😂 🤔 💢 👏 🙄 🎉）
- 已添加的反应显示在消息气泡下方（小 emoji + 计数）
- 用户可以移除自己的反应

### 上下文注入

在 `_buildApiMessages` 中，最近 3 条有用户反应的消息注入：

```
【最近互动反馈】
你刚才说"xxx" → 用户给了 👍（表示认同）
你刚才说"yyy" → 用户给了 💢（表示不满）
```

不同表情对关系分数的微调（注入 prompt 时附带）：

| 表情 | 对 sender 的影响 | prompt 注入 |
|------|------------------|-------------|
| 👍 | +3 affinity | "用户刚才认同了你的观点" |
| ❤️ | +5 affinity, +2 trust | "用户对你表达了好感" |
| 😂 | +2 affinity | "用户觉得你说的很好笑" |
| 🤔 | -2 friction | "用户似乎在认真思考你说的" |
| 💢 | +8 friction | "用户对你的发言不太满意" |
| 👏 | +3 affinity | "用户为你鼓掌" |
| 🙄 | +5 friction | "用户翻了个白眼" |
| 🎉 | +4 affinity | "用户对你的发言很兴奋" |

### 边界处理

- AI 角色之间也可以互相反应（通过后台批量模拟，低优先级）。
- 反应不影响角色选择逻辑，只影响该角色下一轮发言的语气和内容。
- 同一表情同一用户可以重复添加（算多个，上限 5 个/消息）。

---

## 3. 心情可视化

### 概述

将 `RelationshipState.mood` 字段从纯数据层暴露到 UI，通过消息气泡颜色、头像状态和系统提示让角色"看起来"有情绪。

### 当前数据

`RelationshipState.mood` 已有 6 个枚举值：
- `neutral`、`warm`、`annoyed`、`awkward`、`cold`、`protective`

但目前仅在数据层存储和使用（影响关系分数计算），UI 层完全不可见。

### UI 变更

**消息气泡颜色微调**（基于 sender → 当前用户 的关系 mood）：

| Mood | 气泡边框色 | 头像叠加 |
|------|-----------|---------|
| warm | 💛 暖黄 | 小爱心 |
| annoyed | 💢 暗红 | 小乌云 |
| awkward | 😅 灰蓝 | 小汗滴 |
| cold | 🧊 冰蓝 | 小雪花 |
| protective | 🛡️ 翠绿 | 小盾牌 |
| neutral | (默认) | 无 |

实现方式：在 `ChatBubble` widget 中，根据 `relationships[senderId]?.mood` 动态设置 `Container` 的 `decoration`（边框色）和头像叠加 icon。

**心情变化提示**：
- 当 mood 从 neutral 变为非 neutral 时，在聊天流中插入一条轻量系统提示（非气泡，更像时间戳样式）：
  - "A 看起来有点不爽 👀"
  - "B 心情不错 😊"
- 不需要 LLM 调用，直接本地判断 + 渲染。

**头像状态栏**：
- 在聊天室成员列表（或顶部在线成员区域）显示当前各角色的心情小图标。
- 如果列表空间有限，只在角色头像旁显示一个 8px 的小圆点（颜色对应 mood）。

### prompt 注入增强

现有的 `_persistRelationshipForIntent` 已在 inject humanized context 时加入 relationship lines。在此基础上：

- 当 mood ≠ neutral 时，额外注入一行：
  ```
  【当前情绪】你今天对 {target} 感到 {mood_cn}（{mood_reason}）
  ```
- `mood_reason` 从 `RelationshipState.notes` 中取最近一条（如果 notes 不为空）。

### 边界处理

- DM 场景下 mood 始终为 warm 或 neutral（一对一没有复杂情绪）。
- 心情可视化不改变消息排序或角色选择逻辑，纯展示层。
- 颜色差异要微妙（不能影响暗色模式可读性），在 light/dark theme 下分别定义调色板。

---

## 实施优先级建议

| 优先级 | 功能 | 预估工作量 | 理由 |
|--------|------|-----------|------|
| P0 | 心情可视化 | 小（2-3 天） | 纯 UI 层，基于已有数据，风险最低，效果直观 |
| P0 | 表情反应 | 中（3-5 天） | 需要新增 Hive 字段 + UI，逻辑清晰，用户感知强 |
| P1 | 随机互动事件 | 中（4-6 天） | 需要设计事件策略和 prompt 模板，但架构上最有趣 |

建议先做心情可视化 + 表情反应（它们互相加分：表情改变 mood → mood 改变视觉），再做随机事件系统。

## 测试策略

- **心情可视化**：widget 测试验证不同 mood 下气泡颜色正确；手动切换 relationship mood 观察 UI 变化。
- **表情反应**：单元测试验证 reaction 存储和关系分数微调；widget 测试验证表情选择器和计数显示。
- **随机事件**：mock Random 和 RelationshipState，验证特定关系条件下正确返回/不返回事件描述。

## 回滚策略

三个功能均为增量能力：
- 心情可视化：纯 UI 层，关闭 mood coloring 即可回滚。
- 表情反应：保留 Hive 字段但不在 UI 渲染即可回滚；字段不影响现有数据读取。
- 随机事件：移除 evaluateEvent 调用即可回滚，不修改任何持久化数据。
