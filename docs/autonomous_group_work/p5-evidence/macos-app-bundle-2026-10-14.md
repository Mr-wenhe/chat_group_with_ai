# macOS 产品包归档复测

日期：2026-10-14（Asia/Shanghai）。

使用仓库当前 Release 产物运行：

```text
CHAT_GROUP_P2_APP_PATH='/Volumes/new_disk/work/flutter/chat_group/chat_group/build/macos/Build/Products/Release/伴伴.app' flutter test --no-pub --concurrency=1 --timeout 30s --reporter expanded test/work_mode/macos_app_bundle_archive_test.dart
```

退出码 0，4 项通过：3 项包边界 fixture，以及 1 项真实 Flutter `.app` 打包、摘要核对和解包测试。测试核验 `CFBundleIdentifier=com.example.chatGroup`，并确认解包后 `Contents/MacOS/伴伴` 存在。测试只读构建包，归档和副本位于临时目录；没有启动产品包或尝试 Appium/WDA 控制。

另用既有隔离副本 `伴伴-P3-隔离验收.app` 检查了实际设置表单：当前显示聊天/语音/图像/搜索均未配置，未创建、保存或测试 API 配置。自定义上游表单要求配置名称、上游协议、Base URL、模型名和 API Key。界面明确说明 macOS Key 保存在本地 Hive 明文；未读取或输入 Key。

这证明包归档和元数据路径可运行，不证明签名链发布合格、产品原生控件可操作、测试数据目录隔离了应用自己的持久化，或真实模型任务可运行。
