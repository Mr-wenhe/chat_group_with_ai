# 阶段 00 需求文档：正式版可用性基线

状态：草案  
目标版本：待定

## 1. 阶段目标

确保用户拿到的正式安装包具备与开发环境一致的核心能力：能够联网调用 LLM、显示正确的产品身份和版本，并在发布前由自动门禁发现平台配置缺失。

## 2. 背景与问题

- Android 的网络权限当前只出现在 debug/profile Manifest，正式版存在无法联网的风险。
- Android、iOS、macOS、Windows 和 Web 仍有 `com.example`、`chat_group`、Flutter 模板描述等占位信息。
- `pubspec.yaml`、Tag、CHANGELOG 和最终产物版本可能不一致。
- CI 的 analyze/test 无法发现 Manifest、签名、包名或 release 构建问题。

## 3. 用户价值

- 安装正式版后能够完成“配置 API → 测试连接 → 发送消息 → 收到流式回复”的核心流程。
- 系统设置、安装包、窗口标题和关于信息显示同一产品名称与版本。
- 发布失败在交付用户之前被发现。

## 4. 范围

### 必须包含

- Android release 具备网络访问权限。
- 明确 Android 运行时媒体权限策略，避免请求不必要的广泛权限。
- 统一产品显示名、包标识、版本名和构建号来源。
- Web Manifest、页面标题和描述去除模板占位内容。
- 增加正式版核心链路冒烟检查清单。
- 发布流程在上传产物前执行静态分析、测试和至少一个 release 构建验证。

### 本阶段不包含

- API Key 存储迁移。
- 本地 Agent 桥接安全改造。
- Git 中数据文件的存储与追踪策略。
- App Store/TestFlight 的完整上架材料和商业合规文本。

## 5. 用户故事

- 作为 Android 正式版用户，我希望 API 连接测试能够成功，而不是仅 debug 包可用。
- 作为安装用户，我希望系统显示的 APP 名称、版本和图标一致，便于识别和反馈问题。
- 作为发布者，我希望流水线在上传前拦截缺失权限、版本错配或构建失败。

## 6. 功能需求

### R00-01 Android 正式版联网

- 正式版合并 Manifest 必须包含 `android.permission.INTERNET`。
- release APK/AAB 的连接测试能够到达可控 Mock 服务或测试端点。
- 网络失败必须区分权限/连接、超时、认证和服务端错误。

### R00-02 产品身份统一

- 所有平台使用经确认的产品显示名。
- 正式包名不得继续使用 `com.example`。
- Web Manifest 和 HTML 元信息使用正式名称与描述。
- 包名变更的升级影响必须在技术文档中说明。

### R00-03 版本一致性

- Tag、CHANGELOG、Flutter build name/build number 和产物文件名必须可追溯。
- APP 内提供可复制的版本信息，至少包含版本名和构建号。
- 同一 Release 下的多平台产物必须使用同一版本名。

### R00-04 发布门禁

- 发布前自动执行 analyze 和全量 test。
- Android release 至少验证最终合并 Manifest。
- Windows/Web/macOS/Android 的构建状态必须在 Release 说明中明确，不得把未验证平台标为已验证。

## 7. 非功能需求

- 不因新增 release 校验显著增加普通 PR 的等待时间；重型多平台构建可放在发布流程。
- 未配置生产签名时必须明确标记产物为测试用途。
- 平台配置变化应可通过脚本或 CI 重复验证。

## 8. 验收标准

- [ ] Android release 合并 Manifest 包含 INTERNET 权限。
- [ ] Android release 安装后可完成一次 Mock LLM 流式对话。
- [ ] 所有平台不再展示 Flutter 模板名称或 `com.example` 身份。
- [ ] APP 内版本与 Release Tag 一致。
- [ ] 发布流程在测试失败或 release 构建失败时不会上传产物。
- [ ] `flutter analyze` 与全量 `flutter test` 通过。

## 9. 成功指标

- 正式版“无法连接但 debug 正常”的发布事故为 0。
- 每个 Release 均能追溯到 commit、Tag、版本号和构建结果。
- 用户反馈中不再出现模板名称或版本无法确认的问题。

## 10. 待确认问题

- 正式产品中文名、英文名和反向域名包名前缀是什么？
- 是否要求本阶段完成 Android 正式签名，还是只建立可配置签名门禁？
- 是否需要在设置页新增“关于”页面，还是先在现有设置页展示版本信息？
