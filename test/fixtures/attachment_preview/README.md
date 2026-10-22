# 合成附件预览夹具

`sample.docx` 用 python-docx 生成，包含两页中英文测试文字；`sample.pptx` 用 python-pptx 生成，包含两张中英文测试幻灯片。不包含用户数据、宏、外链或个人信息。

`attachment_preview_test.dart` 使用它们验证本地 Office 转换及源文件不被改写；双工作表 XLSX 在测试中以最小 Open XML 包动态生成。
