# 桌面附件只读预览（2026-10-21）

## 范围与行为

macOS / Windows 的群聊、私聊、工作模式共用 `ChatMessageMedia` 的附件入口，用户上传与 AI 生成文件采用相同的预览窗口。内部工作记录继续采用原有结构化可读视图。移动端维持原有行为；压缩包不提供内容预览。

| 文件 | 预览方式 |
| --- | --- |
| MD / Markdown | 标题、表格、列表、代码块和行内样式，可复制全文 |
| TXT / LOG | 可滚动、复制和调整字号的文本；UTF-8 / UTF-16 |
| 常见代码、JSON / YAML / XML | 语法高亮、横向滚动和复制全文；不执行代码 |
| PDF | 本地页面渲染、翻页与缩放；不执行 PDF 脚本或打开链接 |
| DOC / DOCX / PPT / PPTX / ODT / ODP / RTF | LibreOffice 在私有临时目录转换为 PDF，按页预览 |
| XLS / XLSX / ODS / CSV / TSV | LibreOffice 转换为 HTML，保留表格样式、合并单元格及工作表切换；转换目录内的图片内联后显示 |
| PNG / JPEG / GIF / WebP / BMP / ICO | 图片缩放；SVG 在隔离浏览器显示 |
| 常见音频、视频 | 原生浏览器播放控件，具体编码支持取决于操作系统 |
| 损坏、加密、未知类型 | 说明失败原因，保留“用系统应用打开”“另存为” |

## 依赖与边界

- 缺少 LibreOffice 时，预览窗口提供“下载并安装 LibreOffice”，显示下载进度，完成后自动安装并重新预览，不需要 Microsoft Office。macOS 识别系统及当前用户的 `Applications/LibreOffice.app`；Windows 识别标准安装目录；两端也查找当前进程的 `PATH`。从 Finder 启动不会继承终端临时设置的 `PATH`。
- Windows HTML 与媒体预览需要 Microsoft Edge WebView2 Runtime。PDF 使用固定的 PDFium 8076，覆盖 pdfx 自带的旧默认版本；构建时下载并随应用分发。
- HTML 允许内联 JavaScript 交互。父页面 CSP + 无 `allow-same-origin` 的 iframe sandbox 禁止联网、无关本地文件、父页面控制、表单提交和弹窗；不提供原生桥接。外链图片、脚本、字体及相邻文件资源不会加载。Markdown 图片同样不自动加载。
- 不上传文件；Office 转换使用独立配置，禁用宏与 Calc/Writer 链接更新。只写临时副本，原件路径、聊天记录、Hive 模型和备份格式不变。
- 文件上限 100 MiB，文本预览上限 1 MiB，HTML / 表格正文上限 8 MiB；转换超时 60 秒。关闭预览会请求停止转换、清理临时目录并停止浏览器媒体。
- Office 字体缺失、特殊版式、图表及旧格式可能与原应用存在差异；不提供编辑、公式编辑、PPT 动画或宏执行。

## 验证记录

- `flutter analyze --no-pub lib/features/document lib/features/chat_group/widgets/chat_message_bubble.dart test/attachment_preview_test.dart test/work_mode/work_detail_attachment_bubble_test.dart`
- `flutter test --no-pub test/attachment_preview_test.dart test/chat_attachment_path_actions_test.dart test/work_mode/work_detail_attachment_bubble_test.dart test/architecture/error_surface_guard_test.dart test/core/readable_json_dialog_test.dart --timeout 30s --reporter expanded`：34 项通过。
- `flutter build macos --debug --no-pub`：正式应用编译；另用不访问聊天数据库的独立入口进行原生界面验收。
- macOS 界面实测：Markdown 标题/表格/代码块、Python 高亮、HTML 按钮、Office 两页 PDF 与翻页、CSV 表格和 WAV 控件播放。
- HTML 安全实测：可用的本地 HTTP 服务仅收到 `/control` 对照请求，未收到预览页的 `/forbidden` 请求；页面同时显示本地测试文件读取失败、父页面操作失败。
- 真实 LibreOffice 测试：DOCX / PPTX / RTF 转 PDF、双工作表 XLSX 转 HTML；核对原件字节不变及转换目录清理。测试夹具为合成内容，不含用户文档。
- 未完成 Windows 编译/实机验收、旧版 DOC/PPT/XLS 的真实转换、全部音视频编码与视频界面播放验收；未运行与本次修改无关的全仓测试。不能据此宣称两平台全部格式已验收。

## LibreOffice 自动安装

- 安装版本固定为官方 `26.8.1`，支持 macOS Intel/Apple Silicon、Windows x64/ARM64 对应进程架构。版本常量需随维护更新，官方撤下该版本时会明确失败，不改用未知来源。
- 初始安装包及 SHA-256 元数据地址固定在 `download.documentfoundation.org`。校验元数据禁止重定向至其他主机；安装包只跟随通过地址检查的 HTTPS 镜像，不携带 API Key 等凭据。使用正常 HTTPS/DNS，以兼容用户的 VPN/代理虚拟 DNS；没有禁用 TLS 验证。
- 先校验完整 SHA-256，再运行系统签名检查。macOS 使用 `codesign` 和 Gatekeeper `spctl`，复制到当前用户 `~/Applications` 后原子发布；不覆盖已存在的 LibreOffice。Windows 检查 Authenticode 有效性及 The Document Foundation 签名主体，再运行 `msiexec /passive /norestart`；不自动重启系统。管理员授权在系统窗口完成，应用不收集密码、不移除隔离标记或跳过 Gatekeeper。
- 下载及校验阶段可以取消；安装交给系统后不通过关闭弹窗来强杀 MSI。下载大小上限 1 GiB、无数据等待上限 30 秒、下载/校验总时限 30 分钟。失败可重试，同一应用进程不同时安装两份。
- 新增 9 项测试：包架构映射、元数据格式、成功顺序、坏哈希不安装、下载取消不安装、并发互斥与失败重试、缺失提示按钮、两阶段控件状态。与预览及原有弹窗回归合计 43 项通过。
- 真实联网：四个架构的官方 SHA-256 元数据均已通过生产 HTTPS 客户端读取；官方镜像已实际收到安装包字节，并验证取消与部分文件清理。首次测试发现搜索模块的私网 DNS 限制与当前代理虚拟 DNS 不兼容，下载客户端已改用正常 HTTPS 解析后复测通过；搜索模块限制保持原样。
- 尚未实际执行完整安装包安装，也未验收 Windows UAC / MSI 的实机流程；原生安装步骤目前仅完成代码审查与 macOS 编译，不能宣称已在两平台实装通过。

## 内嵌 HTML 双滚动条修复

- 外层 `iframe` 默认行内排版的基线留白让包装页也发生溢出，因此正文短滑块旁又出现了一条几乎占满轨道的长滑块。包装页现在禁止溢出，`iframe` 采用块级布局，仅沙箱内的正文负责滚动。
- 撤回前次无效的 `EagerGestureRecognizer` 设置：当前 Flutter SDK 的 `RenderAppKitView.updateGestureRecognizers` 是空实现。
- 通过独立临时 Flutter 项目直接引用生产 `AttachmentPreviewDialog`，以合成的 100 段 HTML 进行 macOS 原生界面检查，不初始化聊天数据库。修复前复现两条滚动条；修复后仅一条，拖动可从第 0 段移至第 43 段，点击轨道可继续翻页，可拖至第 99 段，滚轮可回滚。
- 原先“短滑块完全无法拖动”的现象未在合成内容中复现；用户反馈更新布局后已恢复。未据此推断原先失败一定来自 Flutter 手势竞争。
- `flutter analyze --no-pub lib/features/document/offline_preview_browser.dart lib/features/document/offline_preview_html.dart`：无问题。
- `flutter test --no-pub test/attachment_preview_test.dart --timeout 30s --reporter expanded`：8 项通过，包含 HTML 沙箱/CSP、转换与原件不变检查。未做 Windows 实机滚动验证。

## 音视频缺少可操作播放控件修复

- 桌面音视频预览不再只依赖 WebView 内部控件：窗口底部提供 Flutter 的播放、暂停、前后跳转 10 秒、从头播放、静音/恢复声音。群聊、私聊、工作交付附件共用入口；移动端原有 `VideoBubble` 不使用该 WebView，保持原行为。
- 仅应用生成的音视频页面接收来自父窗口的固定指令。WKWebView 对该页面允许程序触发播放，iframe 单独授予媒体播放能力；HTML/SVG 默认行为、opaque sandbox 与离线 CSP 保持原约束。没有自动播放，播放仍由用户点击触发。
- `flutter analyze --no-pub lib/features/document/attachment_media_preview.dart lib/features/document/attachment_preview_dialog.dart lib/features/document/offline_preview_browser.dart lib/features/document/offline_preview_html.dart test/attachment_media_preview_test.dart`：无问题。
- `flutter test --no-pub test/attachment_media_preview_test.dart test/attachment_preview_test.dart --timeout 30s --reporter expanded`：11 项通过。覆盖 Flutter 按钮点击、MOV 大写扩展名/MIME、音频、指令来源限制、跳转边界、静音、失败提示与既有附件回归。
- `flutter build macos --debug`：成功。
- 原生 WKWebView 临时验收：在 `/tmp/chat-group-media-smoke` 生成 WAV 与 H.264 MOV，使用生产页面模板、离线包装页和相同 `postMessage` 控制通道；WAV 播放时间推进至 1.35 秒、MOV 至 1.98 秒，两者 `paused=false`、无错误；发送暂停后均为 `paused=true`。合成文件不含用户数据，验收未访问聊天数据库。
- 未取得用户原始 MOV，未做该文件编码验收；未做完整 Flutter 应用鼠标界面验收或 Windows 实机验收。MOV 为容器格式，实际编码仍须受系统支持；本次未增加转码能力，也未运行全仓测试。
