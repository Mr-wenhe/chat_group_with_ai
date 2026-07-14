# 阶段 00 技术方案：正式版可用性基线

状态：提议  
对应需求：`00-release-baseline.requirements.md`

## 1. 当前基线

- Android main Manifest 只有媒体权限；INTERNET 位于 debug/profile Manifest。
- Android、Apple 和 Windows 平台仍使用模板包名或公司信息。
- `pubspec.yaml` 当前版本与 CHANGELOG 最新版本不一致。
- CI 执行 analyze/test；Release 工作流主要负责 Windows 构建和上传。

## 2. 技术决策

- INTERNET 放入 main Manifest，因为所有构建类型的核心功能都依赖网络。
- 版本号以发布输入/Tag 为唯一发布源，由脚本写入构建参数，不依赖人工同时修改多个文件。
- 正式包名作为一次不可逆的产品决策；未确认前先完成权限和校验，不贸然改名。
- 发布验证读取最终合并产物，而不只检查源 Manifest。

## 3. 设计方案

### 3.1 Android 配置

- 在 main Manifest 声明 INTERNET。
- 审核 `READ_EXTERNAL_STORAGE` 与 `READ_MEDIA_*` 的 Android 版本条件；能使用系统文件选择器时不主动申请广泛权限。
- 增加检查任务，解析 merged manifest 或 APK manifest，确认 INTERNET、包名和版本。

### 3.2 产品元数据

建立一份产品身份清单，至少包含：

- display name（中文/英文）
- Android applicationId/namespace
- iOS/macOS bundle identifier
- Windows ProductName/CompanyName
- Web name/short_name/description/theme color

所有平台配置必须引用或对齐这份清单。包名一旦改变，需要记录旧包无法原位升级的影响。

### 3.3 版本与发布

- 发布任务从 Tag 或手动输入得到 `version`。
- 构建号使用单调递增值。
- 构建前校验 SemVer、Tag 和 CHANGELOG 标题。
- 上传前执行 analyze、test、代码生成一致性检查和目标平台 release build。
- 产物附带 SHA-256 清单及构建 commit。

### 3.4 冒烟测试

使用 `tool/mock_openai_server.dart` 或等价可控服务验证：

1. 新建测试 API 配置。
2. 测试连接成功。
3. 发送一条消息。
4. 收到 SSE token 和完成事件。
5. 退出并重新进入后消息仍存在。

冒烟数据使用隔离目录，完成后清理。

## 4. 实施任务

### Task 00-1：修复 Android release 网络权限

**验收：** release merged manifest 包含 INTERNET，Mock 请求成功。  
**验证：** `flutter build apk --release`；解析最终 Manifest；真机/模拟器冒烟。  
**依赖：** 无。  
**预计范围：** S，Android 配置与一个校验测试/脚本。

### Task 00-2：确定并统一产品身份

**验收：** 已确认平台清单，所有目标平台不再使用模板元数据。  
**验证：** 平台配置静态检查；安装包/窗口人工检查。  
**依赖：** 需要产品名和包名前缀决策。  
**预计范围：** M，跨平台配置文件。

### Task 00-3：统一版本来源

**验收：** Tag、构建参数、APP 内版本和产物名一致。  
**验证：** 用测试版本执行 dry-run，比较四处版本。  
**依赖：** Task 00-2 可并行。  
**预计范围：** M，发布脚本、设置页和测试。

### Task 00-4：建立发布质量门禁

**验收：** 任一测试或构建失败都会阻止上传；生成校验和与构建摘要。  
**验证：** 故意制造失败进行 workflow dry-run 或分支验证。  
**依赖：** Task 00-1、00-3。  
**预计范围：** M，CI/Release 工作流。

## 5. 阶段检查点

- [ ] analyze/test 全绿。
- [ ] Android release 核心链路通过。
- [ ] 版本和产品身份由负责人确认。
- [ ] 至少完成一次不上传产物的发布 dry-run。

## 6. 风险与回滚

| 风险 | 影响 | 缓解/回滚 |
|---|---|---|
| 修改 applicationId 导致无法覆盖安装 | 高 | 改名前确认正式包是否已有用户；保留旧构建说明 |
| 本地 Flutter fork 与 CI stable 产物差异 | 中 | 两套环境都执行关键构建；记录实际 Flutter revision |
| 重型发布门禁过慢 | 中 | PR 只跑轻门禁；Tag/Release 跑完整构建 |

## 7. 开放问题

- 是否需要把产品身份清单自动生成到各平台，还是先用校验脚本保证一致？
- Android release 冒烟使用本地 emulator，还是专用设备/云真机？
- iOS/macOS 签名和公证是否纳入本阶段的完成定义？
