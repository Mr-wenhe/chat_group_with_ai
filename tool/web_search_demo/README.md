# 伴伴联网工具 Demo

独立验证：**现有聊天 Key → 模型生成搜索词 → 免 Key 搜索 → 模型选择来源 → 阅读正文 → 模型选择文件 → 下载落盘 → 模型汇报**。

在仓库根目录运行（复用已安装的 Dart 与项目依赖）：

```sh
dart --enable-asserts tool/web_search_demo/self_check.dart
dart run tool/web_search_demo/server.dart
```

打开终端输出的 `DEMO_URL`。可传入一个输出目录作为命令参数；否则使用独立临时目录。每轮生成文件与 `report.json`。服务只监听 `127.0.0.1`，按 Ctrl+C 停止。

- 读取本机伴伴前五套已保存的聊天配置。Hive 文件以只读内存快照加载，不迁移或修改配置；当前凭据读取仅实现 macOS。页面与搜索站点不会收到 Key。模型请求只发往原配置来源，禁止自动跟随重定向。
- 一轮最多四次聊天模型请求，每次 `max_tokens=2048`，消耗原聊天账号 Token。没有调用付费搜索 API，也没有新增搜索 Key 或平台登录。上游实际计费以原服务商账单为准。
- 免 Key 来源为 DuckDuckGo HTML、Bing HTML。搜索引擎可能返回验证码、限流或更改页面，因此不保证长期可用；失败会显示并记录，不伪造结果。
- 网页与文件只允许公开 HTTPS；逐跳验证重定向，拒绝私网地址，固定公网 IPv4 连接并保留 TLS 主机校验。本机 DNS 返回 Fake-IP 等非公网 IPv4 时，Demo 使用固定 Google HTTPS DNS 查询真实 A 记录，查询不带聊天 Key。
- 阅读支持 HTML / Markdown / 文本，响应上限 2 MiB，模型正文最多 12,000 字符；搜索响应上限 512 KiB；下载上限 8 MiB，每次公网请求总时限 25 秒。未实现登录、验证码、付费墙、PDF 正文解析和断点续传。
- GitHub 文件链接可转换为对应公开 raw 地址；只从真实搜索结果、所读页面或当前正文文件选择下载链接。

此 Demo 不改伴伴正式搜索路由、不关闭正式版私网拦截、不依赖 Codex / Claude Code / WorkBuddy。正式接入仍须遵守 `CLAUDE.md` 的 `gateway/` 边界，并另做 Windows、工作模式和旧搜索兼容验收。
