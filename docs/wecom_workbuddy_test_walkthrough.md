# 企业微信 / WorkBuddy 测试走查记录

## 环境与方法

- 日期：2026-07-12
- 主走查平台：Chrome / Flutter Web，`http://127.0.0.1:7357`
- 桌面验证：macOS debug 成功启动，本地 Agentic bridge 正常监听。
- AI 回复：本地 OpenAI 兼容 SSE mock，用于可重复验证流式/非流式 UI。
- 电脑控制：原生 computer-use pipe 两次连接失败，改用 Playwright 真实浏览器点击、输入、上传和截图；不是仅静态渲染。

## 核心链路

| 步骤 | 结果 | 截图 | 发现/修复 |
|---|---|---|---|
| 首页基线 | 通过 | [01-home-baseline.png](../output/playwright/01-home-baseline.png) | 记录改造前的导航与空状态。 |
| 设置页 | 通过 | [02-settings-empty.png](../output/playwright/02-settings-empty.png) | 发现 Web 调用本地目录 API；已改为浏览器存储提示和禁用态。 |
| 配置 ApiConfig | 通过 | [03-api-config-created.png](../output/playwright/03-api-config-created.png) | API Key 在截图中为掩码。 |
| 选角色预设 | 通过 | [04-preset-dialog.png](../output/playwright/04-preset-dialog.png) | 预设弹窗可用。 |
| 建角色 | 通过 | [05-character-created.png](../output/playwright/05-character-created.png) | 角色成功关联 API 配置。 |
| 建群 | 通过 | [06-group-created.png](../output/playwright/06-group-created.png) | 成员选择和保存正常。 |
| 群列表 | 通过 | [07-group-list.png](../output/playwright/07-group-list.png) | 可进入新群。 |
| 企微聊天初始页 | 通过 | [08-chat-initial-wecom.png](../output/playwright/08-chat-initial-wecom.png) | 背景、输入区、空状态正常。 |
| 发消息 + 流式 AI 回复 | 通过 | [09-streaming-in-progress.png](../output/playwright/09-streaming-in-progress.png), [10-streaming-complete.png](../output/playwright/10-streaming-complete.png) | 流式光标和“停止生成”控件可见；该轮完整收尾。 |
| 浅色企微视觉 | 通过 | [11-wecom-light-chat.png](../output/playwright/11-wecom-light-chat.png) | 绿色自己气泡、白色 AI 气泡、时间胶囊、矩形头像和蓝色 `@` 正常。 |
| 引用 / `@` | 通过 | [12-quote-reply.png](../output/playwright/12-quote-reply.png), [13-quote-reply-settled.png](../output/playwright/13-quote-reply-settled.png) | 引用在气泡内部展示，发送后排版稳定。 |
| Web 附件选择/发送 | 通过 | [14-web-attachment-preview.png](../output/playwright/14-web-attachment-preview.png), [15-web-attachment-sent.png](../output/playwright/15-web-attachment-sent.png) | 首轮发现 `PlatformFile.path` 崩溃，已改为 bytes/data URI；后续 review 又修复图片预览和 10 MB 上限。 |
| 私聊/回执 | 通过 | [16-direct-chat-read.png](../output/playwright/16-direct-chat-read.png) | 私聊路由和发送正常；review 后回执改为有后续 AI 回复才显示“已读”。 |
| 停止生成可用性 | 部分交互验证 | [17-before-stop.png](../output/playwright/17-before-stop.png), [17-stop-probe.png](../output/playwright/17-stop-probe.png) | 真实走查确认生成中控件可见；自动化未在该次请求结束前稳定命中点击，取消逻辑保留原有 stream subscription/completer 路径。 |
| 导出预览/确认 | 通过 | [19-export-preview.png](../output/playwright/19-export-preview.png) | 预览、确认操作完成，控制台 0 error / 0 warning。 |
| WorkBuddy 文件任务 | 通过（自动化） | 无 UI 截图 | `AgentRuntime` 全量测试中真实走通规划→批准→`workspace.patch`→读回校验→附件交付，并验证回执包含“结论/交付物/验证/自检/风险”。Web 不具备本地 bridge，因此浏览器走查不伪造本地文件成功。 |
| Web data URI 视频 | 通过 | [21-web-data-uri-video-playing.png](../output/playwright/21-web-data-uri-video-playing.png) | 2.7 MB / 5 秒 MP4 通过视频选择器发送，`video_player` 正确初始化时长并播放出实际画面；无媒体加载错误。 |

## 走查后修复的实际问题

1. Web 设置页原生目录 API 崩溃。
2. Web FilePicker 依赖不可用的本地路径。
3. Web 待发送图片预览错用 `Image.file`。
4. Web 附件未统一限制大小。
5. 私聊“已读”无条件显示。
6. “总结这份电影”类普通聊天误进 AgentRuntime。

## 自动验证

- `flutter analyze`：通过，`No issues found!`
- `flutter test`：通过，416 项测试，`All tests passed!`
- `flutter build web --release`：通过，产物 `build/web`。
- `flutter build macos --release`：通过，产物 `build/macos/Build/Products/Release/chat_group.app`（61.5 MB）。
- `flutter build apk --release`：工程已进入 Gradle `assembleRelease`，但本机系统卷只剩 113 MB，Gradle 用户缓存写入因 `No space left on device` 中止；同时现有 `desktop_drop` 还警告要求 compileSdk 36，而工程按现有约束使用 34。此项不是本次 Dart 改动的编译错误。
- iOS：本机系统卷空间不足，为避免 Xcode/CocoaPods 中间产物写满磁盘未继续发布构建；macOS 的同一 Xcode/Pods 依赖链已构建通过。
- Windows：macOS 主机无法原生构建；平台文件未改动，公共 Dart 代码已由 analyze/test 覆盖。
