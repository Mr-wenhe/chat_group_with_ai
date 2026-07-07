# AI 群聊模拟器 (chat_group)

> 一个 Flutter 应用，用于创建多个 AI 角色并让它们在同一群组里自动互动、对话，观察不同人设的 AI 之间会擦出什么火花。

支持接入多家大语言模型厂商（DeepSeek、通义千问、智谱 AI、Moonshot、百度文心、讯飞星火或自定义 OpenAI 兼容接口），每个角色可独立配置人设、模型与回复频率。

---

## 目录

- [功能特性](#功能特性)
- [技术栈](#技术栈)
- [支持的 AI 厂商](#支持的-ai-厂商)
- [环境要求](#环境要求)
- [安装步骤](#安装步骤)
- [使用示例](#使用示例)
- [项目结构](#项目结构)
- [开发指南](#开发指南)
- [贡献指南](#贡献指南)
- [安全与隐私](#安全与隐私)
- [许可证](#许可证)

---

## 功能特性

- **多角色群聊**：在同一群组里添加多个 AI 角色，发一条消息即可触发 1~2 个符合条件的角色依次自动回复（最多 3 轮自动对话）。
- **人设系统**：为每个 AI 角色定义姓名、头像、年龄、职业、性格标签与系统提示词（system prompt）。
- **多厂商接入**：内置 7 家主流厂商，并支持自定义 OpenAI 兼容接口。
- **分组 API 配置**：`ApiConfig` 与角色一对多共享，便于统一管理密钥与模型。
- **群组内记忆**：每轮对话后自动生成按「年-周」归档的话题摘要（`GroupMemory`），让 AI 在后续回复中保持上下文连贯。
- **回复频率限制**：每个角色可设置每小时回复上限，避免刷屏。
- **本地存储**：所有数据通过 Hive 本地持久化，无需后端服务器。

---

## 技术栈

| 维度 | 选型 |
|------|------|
| 框架 | Flutter 3.6+ / Dart 3.6 |
| 状态管理 | Riverpod（基于注解、代码生成） |
| 本地存储 | Hive（类型安全适配器）+ flutter_secure_storage |
| 网络请求 | Dio |
| JSON 序列化 | json_annotation / json_serializable |
| UI 组件 | Material Design（默认深色主题）、flutter_slidable |

---

## 支持的 AI 厂商

| 厂商 | provider 标识 | 默认模型 |
|------|---------------|----------|
| DeepSeek | `deepseek` | `deepseek-chat` |
| 通义千问 | `qwen` | `qwen-plus` |
| 智谱 AI | `zhipu` | `glm-4-plus` |
| Moonshot | `moonshot` | `moonshot-v1-32k` |
| 百度文心 | `baidu` | `ernie-4.0-turbo-8k` |
| 讯飞星火 | `xfyun` | 需手动填写 |
| 自定义 | `custom` | 需手动填写 baseUrl 与模型 |

> 所有厂商均使用 `/chat/completions` 路径，遵循 OpenAI Chat Completions 请求格式。

---

## 环境要求

- **Flutter SDK**：`>=3.6.0`（当前约束 `^3.6.0-134.0.dev`）
- **Dart SDK**：随 Flutter 一同安装
- **开发机**：macOS / Windows / Linux
- **目标平台工具链**（按需）：
  - Android：Android SDK + Android Studio
  - iOS / macOS：Xcode（仅 macOS 可用）
- 一台已连接设备或模拟器（运行 `flutter devices` 查看）

---

## 安装步骤

### 1. 克隆仓库

```bash
git clone <your-repo-url> chat_group
cd chat_group
```

### 2. 检查 Flutter 环境

```bash
flutter doctor
```

确保没有出现红叉（尤其是对应目标平台的 toolchain）。若需修复，`flutter doctor --android-licenses` 或安装 Xcode 命令行工具。

### 3. 安装依赖

```bash
flutter pub get
```

### 4. 生成代码（重要）

本项目所有 `*.g.dart` 文件（Hive 适配器、Riverpod provider、JSON 序列化）均为自动生成。首次拉取代码或改动模型类后必须执行：

```bash
dart run build_runner build --delete-conflicting-outputs
```

> 若只想在改动后持续监听生成，可加 `--watch`：
> ```bash
> dart run build_runner watch --delete-conflicting-outputs
> ```

### 5. 运行应用

```bash
# 选择一个已连接设备/模拟器
flutter run
```

应用默认以**深色主题**启动。首次进入会看到角色列表页（`AICharacterListPage`）。

---

## 使用示例

### A. 应用内使用流程

1. **创建 AI 角色**：进入角色列表页 → 新增角色，填写姓名、人设（system prompt）、选择厂商与模型。
2. **配置 API**：在「设置」页添加 `ApiConfig`（厂商 + API Key），或在角色中直接填写密钥。
3. **创建群组**：进入群组页 → 新建群组，选择主题并加入若干角色。
4. **开始群聊**：进入群组聊天室，发送一条消息，观察 1~2 个角色自动接力回复（每轮最多 3 次）。
5. **长期记忆**：群内消息累积 ≥8 条后，系统自动生成话题摘要，供后续回复参考。

### B. 代码示例（开发者视角）

**定义并保存一个 AI 角色 + 群组：**

```dart
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/providers/providers.dart';

// 1. 创建一个 API 配置（可多个角色共享）
final apiConfig = ApiConfig(
  name: '我的 DeepSeek',
  provider: 'deepseek',
  apiKey: 'sk-xxxxxxxx',
);
ref.read(databaseServiceProvider).apiConfigBox.put(apiConfig.id, apiConfig);

// 2. 创建一个 AI 角色
final character = AICharacter(
  name: '诸葛小亮',
  avatar: '🧠',
  age: 28,
  role: '策略分析师',
  personalityTags: ['理性', '毒舌', '幽默'],
  systemPrompt: '你是一位毒舌但靠谱的策略分析师，说话简短有力。',
  apiKey: 'sk-xxxxxxxx',
  apiProvider: 'deepseek',
  apiConfigId: apiConfig.id,
  hourlyReplyLimit: 5,
);
ref.read(databaseServiceProvider).aiCharacterBox.put(character.id, character);

// 3. 把角色放进一个群组
final group = ChatGroup(
  name: '脑暴小分队',
  theme: '产品创意发散',
  aiCharacterIds: [character.id],
);
ref.read(databaseServiceProvider).chatGroupBox.put(group.id, group);
```

**直接调用聊天服务（不依赖 UI）：**

```dart
import 'package:chat_group/services/chat_api_service.dart';
import 'package:chat_group/core/models/api_provider.dart';

final service = ChatApiService();
final result = await service.sendChatMessage(
  apiKey: 'sk-xxxxxxxx',
  provider: ApiProvider.deepseek,
  model: 'deepseek-chat',
  messages: [
    {'role': 'system', 'content': '你是一个乐于助人的助手。'},
    {'role': 'user', 'content': '用一句话介绍 Flutter。'},
  ],
  temperature: 0.85,
);

if (result['success'] == true) {
  print(result['message']); // AI 回复内容
} else {
  print('调用失败：${result['message']}');
}
```

**常用命令速查：**

| 命令 | 作用 |
|------|------|
| `flutter pub get` | 安装/更新依赖 |
| `flutter run` | 运行应用 |
| `flutter analyze` | 静态分析与 Lint |
| `flutter test` | 运行全部测试 |
| `dart run build_runner build --delete-conflicting-outputs` | 生成代码 |
| `dart run build_runner watch --delete-conflicting-outputs` | 监听并持续生成 |

---

## 项目结构

```
lib/
├── main.dart                      # 入口，初始化数据库并注册路由
├── core/
│   ├── database/database_service.dart   # Hive 初始化与各 Box 访问
│   ├── models/                    # 数据模型（AICharacter / ApiConfig / ChatGroup / Message / GroupMemory / ApiProvider）
│   ├── storage/                   # 安全存储封装
│   └── theme/                     # 亮/暗主题与厂商配色
├── features/
│   ├── ai_character/              # 角色列表页、表单页及 providers
│   ├── chat_group/               # 群组列表、聊天室页及 providers
│   └── settings/                  # 设置页、API 配置表单页
├── services/
│   ├── chat_api_service.dart      # 统一的 LLM 调用封装
│   └── ai_providers/              # 厂商相关实现
└── providers/providers.dart       # 顶层 provider 统一再导出
```

### 路由

| 路由 | 页面 | 用途 |
|------|------|------|
| `/` | `AICharacterListPage` | 管理 AI 角色 |
| `/groups` | `ChatGroupListPage` | 管理群组 |
| `/chat/{groupId}` | `ChatRoomPage` | 群组对话 |
| `/settings` | `SettingsPage` | API 配置与数据管理 |

---

## 开发指南

### 数据模型关系

```
ApiConfig (1) ────< (多) AICharacter (多) ────< (多) ChatGroup
                                      │
                                      └──< (多) Message
GroupMemory (按 群组 + 年周 归档)
```

- `ApiConfig`：共享的密钥/URL/模型配置，与角色一对多。
- `AICharacter`：带有 system prompt、头像、每小时回复上限的角色。
- `ChatGroup`：包含一组角色与主题，消息归属某个群组。
- `Message`：用户或 AI 消息，支持 @ 提及。
- `GroupMemory`：每周话题摘要，每轮 AI 对话后自动更新（≥8 条消息时）。

### AI 对话流程

1. 用户创建角色并将它们分组到 `ChatGroup`。
2. 在 `ChatRoomPage` 发送消息 → 触发 `_runAiRound`，随机挑选 1~2 个符合条件（未超回复上限）的角色依次回复（最多 3 轮自动对话）。
3. 每次回复调用 `ChatApiService.sendChatMessage`，使用角色对应的 `ApiConfig`。
4. 每轮结束后，若群内消息 ≥8 条，生成摘要并存入 `GroupMemory`。
5. 每个角色在模型上维护每小时回复计数（`lastReplyTimestamp` / `hourlyReplyCount`）。

### 代码生成约定

- 所有 `.g.dart` 文件**禁止手改**，均由 `build_runner` 生成。
- 修改任何带 `@HiveType` / `@HiveField` 的模型类，或新增 Riverpod provider 后，必须重新执行生成命令（见 [安装步骤](#4-生成代码重要)）。
- Provider 统一放在 `lib/features/*/providers/`，并通过 `lib/providers/providers.dart` 再导出。

---

## 贡献指南

欢迎 Issue 与 PR！在提交前请遵循以下约定。

### 提交 Issue

- 使用清晰标题描述问题或建议。
- Bug 请附：复现步骤、期望行为、实际行为、设备/系统信息、`flutter doctor -v` 输出。
- 新功能建议请说明使用场景与动机。

### 开发流程

1. Fork 本仓库并克隆到本地。
2. 基于 `main`（或约定的开发分支）创建特性分支：
   ```bash
   git checkout -b feat/your-feature
   # 或 fix/your-bug
   ```
3. 安装依赖并生成代码：
   ```bash
   flutter pub get
   dart run build_runner build --delete-conflicting-outputs
   ```
4. 编码时遵守 `flutter analyze` 与 `flutter_lints` 规则（无新增 warning）。
5. 为关键逻辑补充测试：`flutter test`。
6. 提交前自检：
   ```bash
   flutter analyze
   flutter test
   ```

### 代码规范

- 中文注释，详细清晰，解释「为什么」而非「是什么」。
- 方法过长请拆分封装，单一职责。
- 模型变更必须同步更新 `@HiveField` 序号（**不要复用或重排已有序号**，避免旧数据解析错误）。
- Provider 按 feature 组织，避免跨层直接依赖。

### 提交信息（Commit Message）

建议采用约定式提交（Conventional Commits）：

```
feat: 新增角色批量导入
fix: 修复群组记忆摘要为空时崩溃
docs: 完善 README 安装步骤
refactor: 抽离 ChatApiService 超时配置
```

### PR 规范

- 一个 PR 聚焦一件事，标题概括改动。
- 在 PR 描述中说明「改了什么 / 为什么 / 如何验证」。
- 关联对应 Issue（如 `Closes #12`）。
- 确保 CI（analyze + test）通过后再请求 review。

---

## 安全与隐私

- ⚠️ **`ApiConfig.apiKey` 目前以明文存储在 Hive 本地数据库中，未做加密层**。请勿在公共/越狱设备上使用，并妥善保管导出文件。
- `custom` 厂商需手动填写 `baseUrl`，其余厂商的 baseUrl 在 `ApiProvider` 中硬编码。
- 所有数据均为本地存储，不会上传到任何第三方服务器（除你配置的 LLM 厂商接口本身）。

---

## 许可证

本项目当前仅供学习与个人使用，`publish_to: 'none'`，未发布到 pub.dev。如需商用或二次分发，请先联系作者确认授权方式。
