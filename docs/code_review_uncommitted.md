# 代码审查报告：chat_group 全部未提交改动

> 审查时间：2026-07-12 ｜ 工具：`flutter analyze`（已通过）+ 静态审查（code-reviewer 代理）
> 范围：所有未提交改动（`git diff HEAD` 的 modified + 全部 untracked 新文件/测试）

## 总体结论：**Ship-with-fixes（修复后合并）**

- `flutter analyze`：**EXIT=0，No issues found!**（无编译/静态错误）
- 🔴 阻塞项：**无**
- 🟠 Major：1 项（web 附件 data URI 持久化进 IndexedDB 的体积隐患，确定存在）
- 🟡 Minor：若干（见下）
- 无资源泄漏、无并发竞态、平台分支正确、3.24 fork 兼容（未引入 `withValues` 等 3.25+ API）

---

## 范围澄清（重要）

`git diff HEAD` 显示 `chat_room_page.dart` 的实际改动集中在 **3720 行之后**：消息气泡渲染、web 附件 data URI 平台分支、附件选择/缩略图、设置页 web 目录文案、颜色 token。

以下**既有代码本次未改动**（非本次回归来源）：
- `@mention` 弹层（217–3485 行）
- auto-chat 循环（601–729 行）
- streaming/stop（1260–1347、2280–2295 行）

---

## 逐文件发现

### 新文件

| 文件 | 级别 | 问题 / 结论 |
|---|---|---|
| `lib/core/models/attachment_data_uri.dart` | ⚪ Nit | `decodeAttachmentDataUri` 仅支持 `;base64` 形式；非 base64 返回 null。因永远用 base64，无风险。建议补注释。 |
| `lib/features/chat_group/picked_attachment_payload.dart` | ⚪ Nit | web 端 `bytes.isEmpty` 返回 null 静默丢弃 0 字节文件，合理。可选 toast 提示。 |
| `lib/features/chat_group/attachment_opener.dart` + `_io` / `_web` | ⚪ Nit | 条件导入 `if (dart.library.html)` 正确，无跨平台泄漏。✅ |
| `lib/features/chat_group/attachment_opener_web.dart` | ⚪ Nit | anchor 先 append 再 click 再 remove，极快连续点击有理论竞态，影响可忽略。 |
| `lib/features/chat_group/widgets/wecom_chat_components.dart:87` | 🟡 Minor | `buildWeComMentionSpans` 正则会匹配 email 中 `@host`（若 host 恰为角色名）。建议左边界 `(?<=^|\s)`。 |
| `lib/features/chat_group/widgets/wecom_chat_components.dart:112` | ⚪ Nit | `WeComBubbleSurface` 每次 build 构造 BoxShadow，开销正常。 |
| `lib/features/settings/ai_processing_directory_policy.dart` | ⚪ Nit | 设计干净，web 时返回文案不调用 native loader（测试覆盖）。✅ |

### 修改文件

| 文件:行 | 级别 | 问题 / 结论 |
|---|---|---|
| `lib/core/database/database_service.dart:399` | 🟠 **Major** | web 端 `copyBytesToMedia` 把完整 base64 data URI 写入 `MediaAttachment.localPath` 并持久化进 IndexedDB。多张 10MB 图片/视频 = 单次会话数十 MB 字符串进 IndexedDB，长期触发配额错误、读取变慢。**建议**：预览用 `Url.createObjectUrlFromBlob` 的 object URL（仅会话内有效），持久化只存 blob 引用或压缩后存；或限制 web 附件总量。 |
| `lib/core/database/database_service.dart`（file-picker web 分支） | 🟡 Minor | web 分支只传 `fileName` 未传 `picked.mimeType`，丢失浏览器真实 MIME。建议 `copyBytesToMedia(..., mimeType: picked.mimeType)`。 |
| `lib/features/agentic/agentic_task_classifier.dart:38` | 🟡 Minor | 新增 `总结` 到 create/edit 正则 + 关键字。已确认 `requiresAgenticWork` 仍要求 `_artifactIntent` 或显式路径才触发，不会误触发闲聊。✅ |
| `lib/features/chat_group/multimodal_content.dart:137` | 🟡 Minor | `_defaultFileReader` 对 data URI 同步 `base64Decode`，UI build 路径上大文件会同步阻塞。建议异步/缓存。 |
| `lib/features/chat_group/widgets/message_selectable_text.dart:75` | ⚪ Nit | `SelectableText.rich` 当 spans 非空时父 text=null，但 spans 含完整文本，`toPlainText` 一致。✅ |
| `lib/features/settings/settings_page.dart:259/:958` | ⚪ Nit | web 端隐藏工作根目录选择改文案；`_SettingTile.onTap` 改可空。逻辑正确。✅ |
| `lib/features/chat_group/chat_room_page.dart:6249` (`_buildContent`) | 🟡 Minor | **行为变更**：原先显式渲染 @提及 Chip，现改为纯视觉内联高亮 `@name`（基于角色名+owner 名集合）。AI 回复路由仍由 `mentionedAiIds` 驱动（未改）。需与作者确认是预期 WeCom 化视觉。 |
| `lib/features/chat_group/chat_room_page.dart:640/854/920` | 🟡 Minor | `_buildPendingAttachmentThumb` / `_buildImageThumb` / `_openImageFullscreen` 每次 build 调 `decodeAttachmentDataUri`（web 即每帧 `base64Decode` 大图）。建议缓存解码结果或复用 `Uint8List`。 |
| `lib/features/chat_group/chat_room_page.dart:6015` (`_VideoBubbleState.initState`) | 🟡 Minor | web 端 data URI 视频用 `VideoPlayerController.networkUrl`。`data:` URI 大概率可用但 `video_player` web 支持未验证。建议浏览器实测，必要时改用 Blob URL。 |
| `lib/features/chat_group/chat_room_page.dart:3478` (`readReceiptText`) | 🟡 Minor | 私聊已读状态每条用户消息做后缀扫描 → 整体 O(n²)。建议预计算布尔数组改 O(n)。 |
| `lib/features/chat_group/chat_room_page.dart:3720` (`_senderColor`) | 🟡 Minor | 改为基于 `sender.id` 哈希取 7 色板，不再区分 provider。视觉变化，`hash % 7` 可能碰撞，可接受。 |
| `lib/features/chat_group/chat_room_page.dart:318` (`dispose`) | ⚪ Nit (by design) | 已正确调用 `_hideMentionOverlay()` 并 cancel 所有 Timer/Controller；`_streamSub` 故意不 cancel（后台收尾落库），有 `_canTouchUi` 守护，dispose 后不 `setState`，安全。✅ |
| `.gitignore` | 🟡 Minor（流程） | 新增 `.playwright-cli/` 很好，但 `output/`（含 1.1MB 截图）仍 untracked 且未被忽略，易误提交。建议追加 `output/`。 |
| `analysis_options.yaml:21` | ⚪ Nit | 新增 `exclude: scripts/**`，合理。✅ |

---

## 跨维度核查

1. **资源泄漏**：`Timer`（`_autoChatTimer`/`_searchDebounceTimer`/`_streamUiFlushTimer`/`_mentionHighlightTimer`）、`OverlayEntry`、`Controller`/`FocusNode` 均已正确 dispose。✅
2. **并发/时序**：auto-chat 由 `_isAiReplying` 同步置位守卫，不会重叠；streaming `done` Completer 协调「流结束/用户停止」两条收尾路径，无竞态。✅
3. **平台分支**：`attachment_opener` 条件导入正确，无 `dart:html` 泄漏到 io；`kIsWeb` 已 import。`withData: kIsWeb` 保证 web 端 `FilePicker` 返回 bytes。✅
4. **3.24 fork 兼容**：仅用 `withOpacity` / `Color(0xFF…)` / `SelectableText.rich` / `contextMenuBuilder` / `Color.alphaBlend` —— 全部存在于 3.24，未引入 3.25+ API。✅
5. **Hive/持久化**：`decodeAttachmentDataUri` 对非法 base64 有 `try/catch (FormatException)` 兜底返回 null。⚠️ 唯一隐患即 🟠（web data URI 体积）。

---

## 测试核查

- `test/wecom_chat_components_test.dart`、`web_attachment_payload_test.dart`、`ai_processing_directory_policy_test.dart`：均为**行为级**断言（token 值、时间胶囊阈值、mention span 文本/颜色、data URI 往返、web 不调用 native loader），非 trivial。✅
- `test/chat_message_interaction_test.dart` 新增 mention 高亮 widget 测试，断言正确。✅
- `agent_*` 测试随 prompt 文案/分类器变更同步更新。✅
- 无 `pumpAndSettle` 死循环、`/tmp` 实际文件 I/O。✅

---

## 合并前必须修复清单

- 🟠 **web 附件持久化体积**（`database_service.dart:399`）：data URI 全量进 IndexedDB，需评估 object URL / 压缩 / 总量上限。
- 🟡 **`output/` 加入 `.gitignore`**：避免 1.1MB 截图被提交。
- 🟡 **file-picker web 分支丢失 MIME**（`database_service` file-picker 分支）：补传 `picked.mimeType`。
- 🟡 **web 缩略图每帧 `base64Decode`**（`chat_room_page.dart:640/854/920`）：缓存解码结果。
- 🟡 **web 视频 data URI 播放**（`chat_room_page.dart:6015`）：浏览器实测一次，必要时改用 Blob URL。
- 🟡 **`_buildContent` 提及 Chip 被内联高亮取代**（`chat_room_page.dart:6249`）：与作者确认是预期行为（WeCom 化）。

---

## 验证记录

- `flutter analyze` → **No issues found! (EXIT=0)**
- `flutter test test/wecom_chat_components_test.dart test/web_attachment_payload_test.dart test/ai_processing_directory_policy_test.dart` → **All tests passed! (EXIT=0，共 11 个用例)**

---

## 复核与处理结果（2026-07-12）

| Review 项 | 复核结论 | 处理 |
|---|---|---|
| Web data URI 持久化体积 | 合理 | 保留可刷新持久化的 data URI，增加 **Web 单条消息附件总量 10 MB** 上限。Object URL 只在当前页面会话有效，不能作为 Hive 持久化引用，因此不采用。 |
| Web 文件 MIME 丢失 | 不成立 | 当前 `file_picker 8.3.7` 的 `PlatformFile` 没有 `mimeType` 字段；`copyBytesToMedia` 已使用文件扩展名推断 MIME。未引入不存在的 API。 |
| UI 重复 `base64Decode` | 合理 | 增加 24 项 / 20 MB 的有界 LRU 解码缓存；仅 UI 预览使用，Agent/工具读取不常驻缓存。仅需判断 data URI 时不再解码全量字节。 |
| Web data URI 视频播放 | 需实测 | 已用 Chrome + Playwright 实测 2.7 MB / 5 秒 MP4，成功初始化、显示 `00:00 / 00:05` 并播放出实际画面；证据见 [`21-web-data-uri-video-playing.png`](../output/playwright/21-web-data-uri-video-playing.png)。无需改 Blob URL。 |
| 私聊回执 O(n²) | 合理 | 改为一次从后向前扫描预计算已读用户消息 ID，整体 O(n)。 |
| mention 误匹配 email | 合理 | 不使用可能不兼容的变长 lookbehind；通过检查 `@` 前一个字符，排除 email local-part 字符，同时保留中文紧邻 `@`的聊天写法。 |
| `output/` 加入 `.gitignore` | 不采用 | 原需求硬性要求“核心链路每步截图 + 测试走查记录”；忽略该目录会让交付文档的截图链接失效。本次选择性提交 `output/playwright/*.png`。 |
| 提及 Chip 改为内联高亮 | 预期行为 | 需求明确要求企微式气泡内 `@name` 蓝色高亮，因此不回退 Chip。AI 路由仍由 `mentionedAiIds` 驱动。 |

新增了 Web 附件总量边界、解码缓存复用、email mention 边界和线性回执策略的回归测试。
