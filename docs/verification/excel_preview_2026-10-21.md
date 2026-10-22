# Excel 预览修复验证（2026-10-21）

范围：Excel 转换、工作表拆分、Flutter 表格渲染及截图对应的两份原文件；同时检查其生成脚本。未更改已有 XLSX。

## 发现与处理

- 应用内表头消失：`lib/features/document/flutter_html_preview.dart:283` 未显示 Calc HTML 的 `bgcolor`，但子元素保留白色字体。已添加单元格底色，并按单元格、行、表格的顺序继承。仅接收六位十六进制颜色，不恢复外部 CSS。公共 HTML 阅读模式共用此修复，离线边界保持。
- 排名表没有数据：桌面 `chat_group_out/大模型排名.xlsx` 的 XML 只有一行、六个表头。对应生成脚本未检查 HTTP 错误和空结果；已在 `/Users/fengye/Desktop/chat_group_out/generate_llm_ranking.py:8` 添加失败检查，避免继续保存空表。未查询或编造排名数据，未重写旧文件。

## 验证证据

- 回归用例先失败：白字表头没有对应底色；修复后通过。
- `flutter test test/flutter_html_preview_test.dart test/attachment_preview_test.dart --timeout 30s`：26 项通过，包含 LibreOffice 实际转换、原文件不变、工作表、合并单元格、离线安全、缩放和滚动。
- 两份真实 XLSX 经本地 LibreOffice 转换，SHA-256 前后相同；临时 widget 用例验证全部三个工作表的表头存在且具有非白色底色，通过后移除依赖本机文件路径的临时用例。首次临时用例因测试虚拟时钟下异步文件读取未结束而主动中止，改用同步读取后通过。
- 排名脚本响应验证：六项 assert 自检通过，覆盖 HTTP 错误、空列表、缺字段、错误类型和两种有效响应；无网络访问或工作簿写入。
- `flutter analyze lib/features/document/flutter_html_preview.dart test/flutter_html_preview_test.dart`：无问题。
- 逐行检查：无新依赖、无模型/接口变更，已有调用者兼容；不改原文件、凭据、导出或工作任务状态。颜色仅解析受限值，保留已有表格容量及嵌套限制。

## 未验证与限制

未重启正在使用的桌面 App，未做系统 Excel 自动化或全仓库测试；需重新运行应用加载代码。未验证排行榜在线接口的当前可用性，未补齐旧排名文件。预览仍采用等宽列及现有合并单元格近似方式，不能保证与 Excel 排版完全一致。
