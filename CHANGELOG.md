# Changelog

All notable changes are documented here, following [Conventional Commits](https://www.conventionalcommits.org).

---

## v1.5.2 - 2026-07-12

### 🧪 Tests
- 新增 `agent_progress_message_test`：验证 agent 进度消息含「规划中」与「已完成第 N 步」信息
- 新增 `full_agent_workflow_test`：5 个内置角色经本地 Mock Server（`tool/mock_openai_server.dart`，运行前需先 `dart run tool/mock_openai_server.dart` 启动）生成文件并带持久进度

## v1.5.1 - 2026-07-12

### 🚀 Features / 新功能
- (`chat`) AI 回复支持「非 agentic 文件恢复」：当角色以纯文本请求生成文件（如"生成一个 html 文件作为附件"）时，从请求推断文件路径并从回复中提取代码块，自动落盘为附件
- (`tool`) 新增 `tool/mock_openai_server.dart` 本地 Mock OpenAI 兼容服务，便于离线联调

### 🧪 Tests
- 补充 `non_agentic_file_recovery_test` 覆盖文件路径推断与内容提取

## v1.5.0 - 2026-07-12

### 🚀 Features / 新功能
- (`chat`) 聊天 UI 向企业微信对齐（气泡配色/布局、引用卡片、@提及高亮、输入栏），保留无描边边框的既有审美
- (`agentic`) AI 角色工作模式贴近 WorkBuddy：先诊断→拆解→调工具→交付，并增强多步骤任务的交付落地

### 🐛 Bug Fixes / 修复
- (`web`) 附件在 web 端以 data URI 内联存储，补全此前丢失的 MIME 类型
- (`agentic`) 收尾阶段对无法解析为 ToolRequest 的正文复用文件恢复，使生成内容真正落盘

### 🧹 Chores
- (`.gitignore`) 追加 `output/` 避免本地生成产物误提交

## v1.4.0 - 2026-07-11

### 🚀 Features / 新功能
- (`agentic`) implement skill system, retry, context window, and task persistence
- (`agentic`) enhance tool execution robustness, file content leak guards, and attachment delivery

### 🐛 Bug Fixes / 修复
- (`agentic`) harden bridge and file validation

## v1.0.0 - 2026-07-08

### 🚀 Features / 新功能
- 数据存储从沙盒迁移到项目data目录
- wire humanized chat engine
- update humanized memory state
- build humanized reply prompts
- select humanized reply intents
- register humanized memory storage
- add humanized memory models
- 聊天策略优化 + SSE改进 + 设置页面更新 + 数据库改进
- @弹窗修复(全成员/搜索/滚动) + dispose崩溃修复 + print→debugPrint
- (`chat-enhancements`) 8项群聊体验增强（重新生成/引用回复/场景模式/语音朗读/主题切换/Token统计/搜索/单元测试）
- (`secure-storage + chat-optimizations`) API Key加密存储/连接测试/聊天策略/单元测试
- (`chat-room`) 9项群聊体验修复/优化（输入框换行/@弹窗/自动聊天/成员列表/群主等）
- (`settings`) 新增对话导出与系统分享页面
- (`character`) 接入角色人设预设库快速创建
- (`chat`) 接入 SSE 流式输出与「停止生成」打字机效果
- (`core`) 新增流式事件、SSE 解析、角色预设库与对话导出服务（含单测）
- 70 characters with xfyun support + data sync fix
- add API config management + seed 50 characters
- add @mention popup, AI auto-chat, forced @reply, and user message color fix
- add state variables and helper methods for @mention and auto-chat

### 🐛 Bug Fixes / 修复
- restore focus after @mention insertion
- review fixes — API key migration compat, GroupMemory key compat, race fixes, cache improvements
- 动态查找项目根目录，修复 _getDataDir 路径计算错误
- add agents.md
- (`bugfix-r2`) 修复角色编辑崩溃/统一配置语义/SnackBar样式/卡片标签显示
- (`character`) 所有角色每小时回复上限统一改为 60
- (`character`) 彻底移除下拉菜单Row布局避免overlay无界约束崩溃
- (`character`) 修复角色表单页点击崩溃并默认选用讯飞星火
- add orElse guard to firstWhere in _parseMentions

### 📝 Docs / 文档
- plan humanized chat engine
- refine humanized chat engine design
- 标注三项增强已实现并修正局限说明；纳入 QA 加固测试
- 在 README 补充三项新功能与导出安全提示

### 🔧 Chore / 杂项
- verify humanized chat engine
- (`data`) 整合沙箱与工程源数据为单一数据源并提交 git

### 👷 CI / 构建
- 添加 GitHub Actions CI 与多平台 Release 工作流

### 🎨 Style / 样式
- 修复 lint 提示以达成 flutter analyze 0 issue 并保障单测全绿

### ✅ Test / 测试
- cover humanized export safety

### 📋 Other / 其他
- fix/ui: 修复测试加载对话框、隐藏API Key测试模块、角色模型批量更换与默认自定义优先
- Merge feat/chat-enhancements: 流式输出/角色预设库/对话导出
- Initial commit: Flutter chat group app

