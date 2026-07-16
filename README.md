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
- **流式输出（打字机）**：AI 回复逐字实时渲染，生成过程中可随时点击「停止生成」中断。
- **角色人设预设库**：内置 10 套人设模板（毒舌评委 / 杠精 / 好奇宝宝 / 鼓励师 / 冷静分析师 / 戏精 / 老干部 / 治愈邻家 / 硬核极客 / 毒舌御姐），一键套用到角色表单，快速创建。
- **对话导出与分享**：将整组对话导出为 Markdown 或 JSON（**不含任何 API Key / 密钥配置**），保存至本机并可通过系统分享面板发送。
- **引用回复 / 重新生成**：长按消息可引用回复；AI 消息支持重新生成，并保留原消息作为引用上下文。
- **人性化聊天引擎**：基于提及、近期发言、角色兴趣、关系状态和分层记忆选择回复意图，让角色更像在群里自然接话。
- **群聊 / 私聊收件箱与主动联系**：群聊和私聊列表都会显示未读数，群聊额外标出 `@我` 提醒；角色、群聊和对应私聊可置顶。App 前台运行时，私聊过的 AI 或群聊里的角色可按冷却规则主动发起私聊，并通过红点、未读数和浮层提示提醒。
- **主题、语音与用量统计**：设置页支持亮/暗/跟随系统、AI 回复朗读开关，以及按角色/群组累计 token 用量。

---

## 技术栈

| 维度 | 选型 |
|------|------|
| 框架 | Flutter 3.6+ / Dart 3.6 |
| 状态管理 | Riverpod（基于注解、代码生成） |
| 本地存储 | Hive（类型安全适配器，开发态读仓库 `data/`，release 在用户目录创建全新数据） |
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
│   ├── chat_group/               # 群组列表、群聊未读汇总、聊天室页及 providers
│   ├── direct_chat/              # 私聊收件箱、私聊会话键、置顶排序、主动联系策略/服务
│   └── settings/                  # 设置页、API 配置表单页
├── services/
│   ├── chat_api_service.dart      # 统一的 LLM 调用封装
│   └── ai_providers/              # 厂商相关实现
└── providers/providers.dart       # 顶层 provider 统一再导出
```

更多维护视角的模块地图见 [`docs/PROJECT_MAP.md`](docs/PROJECT_MAP.md)。

### 路由

| 路由 | 页面 | 用途 |
|------|------|------|
| `/` | `AICharacterListPage` | 管理 AI 角色 |
| `/groups` | `ChatGroupListPage` | 管理群组、群聊未读与置顶 |
| `/direct-chats` | `DirectChatListPage` | 私聊收件箱、未读提醒、置顶与手动检查主动私聊 |
| `/chat/{groupId}` | `ChatRoomPage` | 群组对话 |
| `/dm/{characterId}` | `ChatRoomPage` | 一对一私聊，会话键为 `dm:{characterId}` |
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
- `AICharacter`：带有 system prompt、头像、每小时回复上限和自我记忆摘要的角色。
- `ChatGroup`：包含一组角色、主题与群主名，消息归属某个群组。
- `Message`：用户或 AI 消息，支持 @ 提及与引用回复。
- `GroupMemory`：每周话题摘要，每轮 AI 对话后自动更新（≥8 条消息时）。
- `CharacterMemory` / `RelationshipState`：按群组保存角色分层记忆，以及 AI 对用户或其他 AI 的关系状态。

### AI 对话流程

1. 用户创建角色并将它们分组到 `ChatGroup`。
2. 在 `ChatRoomPage` 发送消息 → 触发 `_runAiRound`，随机挑选 1~2 个符合条件（未超回复上限）的角色依次回复（最多 3 轮自动对话）。
3. 每次回复优先调用 `ChatApiService.streamChatMessage` 进行流式输出；非流式场景调用 `sendChatMessage`，均使用角色对应的 `ApiConfig`。
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

- 开发态会直接读取仓库根目录下的 `data/*.hive`，其中可以包含完整的 `ApiConfig.apiKey`；release 包不会打入这份真实数据，而是在用户目录创建并读取自己全新的 Hive 数据文件。
- 导出的对话文件为明文文本，保存在本机 `ApplicationDocumentsDirectory/chat_group_exports/` 下；导出内容**仅含展示性字段（角色名 / 头像 / 年龄 / 职业 / 性格标签 + 消息内容），绝不含有 API Key / 密钥配置**。但仍请注意本机文件安全，避免对话内容泄露。
- `custom` 厂商需手动填写 `baseUrl`，其余厂商的 baseUrl 在 `ApiProvider` 中硬编码。
- 所有应用数据均为本地存储，不会上传到任何第三方服务器（除你配置的 LLM 厂商接口本身）。
- 仓库中的 `data/*.hive` 仅用于开发态直接读取；release 只打包空模板清单 `assets/release_templates/seed_manifest.json`，首次启动会据此生成空的本地 Hive 文件。

---

## 发布指南 (Release)

本项目已内置两套 GitHub Actions：

| 工作流 | 文件 | 触发时机 | 作用 |
|--------|------|----------|------|
| **CI** | `.github/workflows/ci.yml` | 推送 / PR 到 `main` | 自动执行 `代码生成 → flutter analyze → flutter test`，作为合并前质量门禁 |
| **Release** | `.github/workflows/release.yml` | 推送 `v*` tag，或手动在 Actions 页面触发 | **仅由 CI 构建 Windows** 并创建 / 追加到 GitHub Release；**macOS / iOS / Android 由开发者本机通过 `scripts/publish_local.sh` 构建并上传到同一 Release**（详见下方「混合发布」） |

> 前置条件：本机需能跑通 `flutter doctor`（各目标平台工具链齐全）。发布覆盖 Windows（CI）/ macOS / iOS / Android 共 4 个平台；其中 `windows/` 目录为本次发布准备时通过 `flutter create --platforms=windows .` 生成并提交。**Web 端因无安全凭据存储、无法保存 API 配置，已不再作为发布目标。**

> **Flutter 版本对齐**：CI 与 Release 工作流已显式钉到 **Flutter 3.24.0 stable**，与你本地自定义 fork（`3.24.0-1.0.pre.538`，同周期、同套旧主题 API）保持代码级一致。因此**同一份代码在你本地和 CI 都能编译**，无需切换你本地的 Flutter 通道。`pubspec.yaml` 的 SDK 约束也已放宽到 `>=3.5.0 <4.0.0` 以同时兼容两端。

---

### 1. 配置签名 Secrets（可选，但生产发布必需）

GitHub 仓库 → **Settings → Secrets and variables → Actions → New repository secret**，按需添加。未配置时仍可构建「未签名」包用于本地调试。

#### Android（发布到应用商店 / 安装 APK 必需）

| Secret 名称 | 说明 |
|-------------|------|
| `ANDROID_KEYSTORE_BASE64` | 签名密钥库 `keystore.jks` 的 Base64（见下方生成命令） |
| `ANDROID_KEY_ALIAS` | 密钥别名 |
| `ANDROID_KEY_PASSWORD` | 密钥密码 |
| `ANDROID_STORE_PASSWORD` | 密钥库密码 |

生成密钥库（仅首次）：

```bash
keytool -genkey -v -keystore upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
# 转为 Base64 填入 Secret（macOS / Linux）
base64 -i upload-keystore.jks
# Windows (PowerShell)
[Convert]::ToBase64String([IO.File]::ReadAllBytes("upload-keystore.jks"))
```

#### iOS / macOS（App Store / TestFlight / 可分发 .app 必需）

| Secret 名称 | 说明 |
|-------------|------|
| `APPLE_CERTIFICATE_BASE64` | 从钥匙串导出的分发证书（`.p12`）的 Base64 |
| `APPLE_CERTIFICATE_PASSWORD` | `.p12` 导出密码 |
| `APPLE_PROVISIONING_PROFILE_BASE64` | `.mobileprovision` 描述文件的 Base64 |
| `APPLE_TEAM_ID` | Apple Developer 团队 ID |
| `APPLE_SIGN_IDENTITY` | 签名身份，如 `Developer ID Application: Your Name (TEAMID)` |

> 未配置上述 Secrets 时：iOS 会回退构建「未签名 .app」（仅可在模拟器 / 越狱设备使用）；macOS 构建未签名的 `.app`（本机可用，但跨设备会触发 Gatekeeper 拦截）。

---

### 2. 混合发布流程（当前推荐）

> **为什么是混合的？** Windows 只能在 Windows Runner 上交叉编译，而 macOS / iOS / Android 你本机就能编。所以：
> - **CI（`release.yml`）**：只构建 **Windows**，并负责「创建 GitHub Release（若不存在）+ 上传 Windows 产物」。
> - **本地（`scripts/publish_local.sh`）**：构建 **macOS / iOS / Android**，并以「幂等」方式创建 Release（若 CI 尚未建）+ 上传这 3 个产物到【同一个 Release】。
>
> 双方都采用 `if ! gh release view <tag>; then gh release create ...; fi` + `gh release upload --clobber`，**谁先跑都行**，后到者只追加，不会冲突。

**一步发布（3 个本地平台）：**

```bash
# 1) 提交版本号改动（pubspec.yaml version），推送
git add pubspec.yaml && git commit -m "chore: 发布 v1.3.8" && git push

# 2) 打 tag 并推送 —— 自动触发 CI 构建 Windows
git tag v1.3.8 && git push origin v1.3.8

# 3) 本机构建并上传 macOS / iOS / Android 到同一 Release
#    （scripts/publish_local.sh 已随仓库提供，clone 后可直接使用，无需自行创建）
./scripts/publish_local.sh 1.3.8
```

脚本会自动：备份并临时写入版本号 → 构建 3 个平台并打包到 `release_artifacts/` → 创建（若不存在）/ 追加产物到 `v1.3.8` Release。**构建结束后会还原 `pubspec.yaml`**，不会污染你的工作区。

> 若你只想手动调某一个平台，也可直接跑对应命令（产物需自行用 `gh release upload vX.Y.Z <文件> --clobber` 上传）：
>
> ```bash
> flutter build apk --release            # build/app/outputs/flutter-apk/app-release.apk
> flutter build appbundle --release      # build/app/outputs/bundle/release/app-release.aab
> flutter build ios --release --no-codesign   # build/ios/Release-iphoneos/*.app（未签名）
> flutter build macos --release          # build/macos/Build/Products/Release/*.app
> # Windows 只能在 Windows 上编：flutter build windows --release → build/windows/x64/runner/Release/
> ```

---

### 3. 自动发布（推荐流程）

只需打一个 `v*` tag 推送到 GitHub，**CI 会自动构建 Windows 并创建 / 追加到 Release**；其余 3 个平台按上文「混合发布流程」用本地脚本发布即可（两步合一就是第 2 节的那段命令）。

```bash
# 1) 先提交版本号改动（pubspec.yaml version）
git add pubspec.yaml && git commit -m "chore: 发布 v1.1.0"
git push

# 2) 打 tag 并推送 —— 自动触发 release.yml
git tag v1.1.0
git push origin v1.1.0
```

或**手动触发**（无需 push tag，CI 仅构建 Windows）：

1. 打开仓库 **Actions → Release → Run workflow**；
2. 填写 `version`（**留空则按 Conventional Commits 自动累加**，见下方约定）；
3. 点击 **Run workflow**。工作流会创建对应 tag、构建 Windows 并创建 Release；
4. 随后在本机运行 `./scripts/publish_local.sh <版本号>` 上传其余 3 个平台。

> 🤖 **自动版本号 + Changelog**
> - `scripts/generate_changelog.py` 解析提交历史中的 Conventional Commits，自动决定下一个版本号：
>   - 含 `feat!` / `fix!` / `BREAKING CHANGE` → 主版本 +1（`x.0.0`）
>   - 含 `feat:` → 次版本 +1（`x.y.0`）
>   - 其余（含 `fix:` / `perf:` 等）→ 修订号 +1（`x.y.z+1`）
> - 每次发布会自动把本次区间内的提交按类型（Features / Bug Fixes / …）生成 Release 说明；并幂等更新仓库根目录 `CHANGELOG.md`（手动触发时还会回写提交到 `main`）。
> - 本地也可直接运行：`python3 scripts/generate_changelog.py --force-version 1.1.0 --changelog-out CHANGELOG.md`。

发布完成后，**同一版本的附件**会同时包含：Windows（CI 构建）+ macOS / iOS / Android（本地脚本上传），全部出现在仓库 **Releases** 页面对应版本下。

---

### 4. 版本号约定

- `pubspec.yaml` 中 `version: 主版本.次版本.修订号+构建号`，如 `1.1.0+5`。
- **推荐提交信息遵循 [Conventional Commits](https://www.conventionalcommits.org) 规范**（`feat:` / `fix:` / `docs:` / `chore:` …），以便自动累加版本号与生成 changelog。
- 自动发布时，工作流会用「输入/ tag 版本号 + GitHub 运行序号」自动写入 `pubspec.yaml`，无需手动改；手动触发且 `version` 留空时，由提交历史自动推导。
- tag 命名统一为 `v` 前缀（如 `v1.1.0`），与 Release 标题一致。

---

## 许可证

本项目当前仅供学习与个人使用，`publish_to: 'none'`，未发布到 pub.dev。如需商用或二次分发，请先联系作者确认授权方式。
