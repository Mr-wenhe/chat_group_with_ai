# chat_room 拆分重构代码审查（2026-07-13）

## 结论：✅ 可安全提交

## 改动概览
- `chat_room_page.dart` 从 ~3700 行抽薄：删除 1247 行 / 新增 247 行。
- 抽出 9 个新文件：
  - `chat_room_loader.dart` —— 数据加载（群聊/私聊统一入口 + 已读回执）
  - `chat_room_repository.dart` —— 高频消息持久化 façade
  - `reply_eligibility_policy.dart` —— 回复资格判定 + 用量计数
  - `widgets/chat_message_list.dart`、`chat_room_composer.dart`、`chat_room_app_bar.dart`、`chat_room_banners.dart`、`member_sheet.dart`、`attachment_preview_strip.dart`
  - `models/chat_room_models.dart`（+46 行，承载 `ChatRoomLoadContext` 等）
- 新增 2 个测试：`test/chat_room_composer_test.dart`、`test/reply_eligibility_policy_test.dart`

## 发现

### 🔴 已修复：1 个编译错误
- `widgets/chat_message_list.dart:11`：`GlobalObjectKey<(Object, String)>` 泛型不满足 bound
  （`GlobalObjectKey<T extends State<StatefulWidget>>`）。
- 修复：`GlobalObjectKey((_scope, messageId))`（去掉非法类型参数）。
- 语义不变：每条消息仍用稳定的 `(scope, id)` 作 identity 挂到 `KeyedSubtree`，
  供 `currentContext` 做滚动定位。修复后 `flutter analyze` → No issues。

### ✅ 行为一致性核对（重构前 HEAD vs 重构后）
1. **消息持久化顺序一致**：`_appendMessage` 仍为
   `messageBox.put → addMessageToGroupIndex → (ai) markRead → setState 追加 → scrollToBottom`。
   `ChatRoomRepository.persistNewMessage` 内部即此顺序，无差异 → 消息不会丢/重。
2. **build 组装完整**：AppBar（搜索/导出/成员）、ChatMessageList（合并 all+active 角色，
   流式/重生成/提及高亮/已读回调全接）、MemberSheet、Composer（键盘/拖拽/附件/粘贴回调全接）、
   ApiWarning / Announcement / UserMention 三个 Banner、`停止生成` 按钮 —— 回调链路完整。
3. **核心逻辑未动**：`_runAiRound` / `_generateAiReply`（流式订阅 + 停止生成 + 去重 +
   非 agentic 文件恢复清洗）/ `_startAutoChat` / `_tryAutoChatRound` / 并发兜底
   `_agenticRunningCharacterIds` 全部保留在 `_ChatRoomPageState`。

### ✅ 资源释放（无泄漏）
- 父页面 `_ChatRoomPageState.dispose()` 仍释放 `_textController` / `_scrollController` /
  `_inputFocusNode` / `_searchController` / `_autoChatTimer` / `_mentionHighlightTimer` /
  `_mentionSearchController` / `_speech` / `_streamUiFlushTimer` / `_searchDebounceTimer`。
- 子 widget：composer / app_bar / message_list 的 controller **由父页面传入**（不自己创建），
  无重复释放风险；`member_sheet` 自建 `_searchController` 并已 `dispose()`；
  `blinking_cursor` / `video_bubble` 各自 `dispose` 自管资源。

### ✅ 测试
- `flutter analyze`：**No issues found!**
- `flutter test`（全量）：**All tests passed!（374 用例）**
- 新增测试：chat_room_composer_test（3 用例）、reply_eligibility_policy_test（2 用例）均通过。

## 🟡 可选优化（非阻塞）
1. `ChatRoomRepository` 是薄 façade（方法多为单行转发），是否独立成文件属个人偏好，不影响正确性。
2. `ChatMessageList` 的 `characters` 在 build 内每次合并
   `[..._allGroupCharacters, ..._characters.where(...)]` 产生新列表；消息量大时每帧重建，
   可在父页面预计算一次（性能微调）。

## 建议
可直接 `git commit` 提交本次重构；无需额外修复。
