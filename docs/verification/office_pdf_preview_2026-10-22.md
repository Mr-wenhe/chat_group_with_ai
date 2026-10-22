# Word / PDF / PPT 内嵌预览排查

范围：中文字体、转换、分页、缩放、翻页、原文件保护；不修改用户原文件内容。检查两个 LibreOffice 调用方（附件预览、工作模式页图渲染），PDF 直接走共用查看器。

## 问题与修复

- `office_preview_session.dart` 启动 LibreOffice 时没有系统 fontconfig 配置，中文被替换为 LinuxLibertineG 等西文字体的空字形。截图原 DOCX 和同名 PPTX 均复现。新增 `document_font_environment.dart`，复用原页图渲染器的字体配置查找，增加没有 Homebrew 时的临时系统字体配置。两条转换路径共用；保留自定义 FONTCONFIG_FILE。临时配置及缓存随会话目录清理。未改变宏禁用、原文件只读、大小限制和超时。
- 原有 DOCX/PPTX 夹具只有英文，转换测试只验证 PDF 文件头，无法识别中文消失。现改为两页中英文，并检查页数及两页中文文本。修复前得到“中中中中”“第第第”，修复后通过。
- 用户原 PDF 四页中文正常。修复字体后 DOCX 五页，页面无中文缺失；与 WPS 排版仍可能不同。用户 PPTX 四页：中文恢复，但第二页下方内容溢出、第四页文字与表格重叠。本次不改原稿，不能宣称该 PPT 排版验收通过。

## 校验

- `flutter test test/attachment_preview_test.dart test/flutter_html_preview_test.dart --timeout 30s`：26 项通过，包含真实 LibreOffice 转换、两页中文、原文件字节不变、Excel 和离线边界。
- `flutter test test/attachment_pdf_preview_test.dart --timeout 30s`：通过，mock 原生渲染通道检查页数、第一页边界、缩放、翻页及翻页重置缩放。测试搭建时遇到平台通道与本地图片读取问题，修正 mock 后通过，未因此更改生产 PDF 查看器。
- 对截图对应 DOCX、同名 PPTX 实际转换并用 PDFKit 渲染，与原 PDF 全部页面拼图逐页对比；原 PDF 正常，PPT 仍有上述排版问题。另以临时字体配置完成 DOCX/PPTX 转换，中文恢复。
- 定向静态分析、diff 空白检查；逐行检查共享调用方、临时目录清理、自定义环境兼容、原文件保护及错误路径。无新增依赖、无存储或模型变更。

## 限制

未重启正在使用的桌面 App、未自动操作 WPS、未跑全仓库测试或 Windows/Linux 实机。PDF 翻页缩放以组件测试验证，图像以原生 PDFKit 核对。Office 字体替代仍可影响分页，PPT 源稿溢出未改动。
