# 产物清单

本目录只收录本次验收的合成文件和渲染结果。没有真实用户文件，也没有工作模式正式交付物。

## 产品 Release

- App：`/Volumes/new_disk/work/flutter/chat_group/chat_group/build/macos/Build/Products/Release/伴伴.app`
- `bundleId`: `com.example.chatGroup`；`version`: `2.1.0+225`。
- 当前可执行文件 SHA-256：`82824c65516c19de6fea91514f5ed88abb50bac0c297e9bf8db66425682ea3ef`。
- 当前 PID：`62732`；进程命令行指向上述 Release 包内 `Contents/MacOS/伴伴`。
- 代码签名深度校验通过；这仅证明本地构建/签名，不证明用户任务或候选交付通过。

## 文档渲染

输入是合成语料 `review-before.docx`，SHA-256 `65419f649948fe25c82b8a70c8ea77b48a7825eed16881b13b48facdfb6cf657`。原始测试源来自 `docs/autonomous_group_work/p3-evidence/generated/`，本批副本位于 `artifacts/document-render-fontconfig/source.docx`。

- 正确 `FONTCONFIG_FILE=/opt/homebrew/etc/fonts/fonts.conf` 下使用 LibreOffice 和 Poppler 渲染为 4 页，产出 PDF 与 4 张页图，见 `document-render-fontconfig/`。
- 产品 `WorkDocumentTool` / `DocumentPageRenderer` 用例在 `/tmp/chat-group-acceptance-shadow-g4ItNG` 的临时副本运行，5/5 通过；16 页 PNG 与 16 份 manifest 已复制到 `document-tool-render/tool-render/`。
- 四份原始合成输入均复制到 `document-tool-render/sources/`，以便对照各 manifest 的 `documentSha256` 和 `documentPath`；它们不是本轮产品生成的修订文件。
- manifest 记录 `LibreOfficeDev 26.8.0.0.alpha0`、`pdftoppm/pdfinfo 26.05.0`、4 页及 PingFang SC 字体覆盖。隔离副本保留在上述 `/tmp` 路径，因为 manifest 的 `documentPath` 指向那里。
- 视觉检查确认中文字形正常、AC-18 的“实际记录”单元格为空白，以及输入文档中的错字/模板占位语。它们是合成测试夹具的已知缺陷，不是产品输出，也没有由 AI 角色发现或修复。
- 早先一次没有设置 `FONTCONFIG_FILE` 的诊断渲染出现方框字；其 PDF/页图留在 `document-render/`，只作环境差异记录，不作为产品输出。生产代码会设置该字体环境变量；匹配产品环境后渲染正常，因此不作为产品字体故障。

## P0 桌面样本

- Bug 样本：`build/p0_macos/bug/P0Sample.app`；可执行文件 SHA-256 `d8a449421e97fcef916617c935160eba92d11f5ff9398b5896737a0d37d5f9cd`。
- Fixed 样本：`build/p0_macos/fixed/P0Sample.app`；可执行文件 SHA-256 `cdc376a2567dc0ca94d3bb730638abb72a6ec4a4b4aebdd9dadaf5d65906b1fd`。
- CUA 实际操作并重启后分别读回错误/正确的持久化样本。对应构建日志在 `commands/p0-build-bug.log` 和 `commands/p0-build-fixed.log`；窗口截图仅以 CUA 输出显示，未保存为本地文件。
- 这是独立可信样本 App 的 UI 路径，不是伴伴工作模式，不可当作 A13 或完整验收通过。
