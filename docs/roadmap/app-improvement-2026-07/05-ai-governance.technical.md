# 阶段 05 技术方案：模型能力、成本与联网治理

状态：提议  
对应需求：`05-ai-governance.requirements.md`

## 1. 架构决策

- 将 `ApiProvider.supportsVision` 替换为可版本化的 `ModelCapabilityRegistry`。
- 请求统一经过 `AiRequestGateway`，在此完成能力校验、预算预检、执行、用量记账和脱敏诊断。
- 价格表与历史账本解耦；每条账目保存计算时使用的 price snapshot/version。
- 搜索策略作为显式 conversation setting，不再只由触发词决定是否发送第三方请求。

## 2. 数据模型建议

### ModelCapability

- provider/model pattern
- supportsStreaming/vision/tools
- contextWindow/maxOutput
- input/cachedInput/output price
- currency/unit
- source/version/updatedAt

### UsageLedgerEntry

- requestId/timestamp
- provider/model/characterId/conversationId
- purpose：reply/autoChat/proactive/summary/agent/retry/search
- token counts
- estimatedCostMinorUnits/currency
- priceVersion
- latency/status/retryCount

### BudgetPolicy

- scope/type/id
- period/duration
- softLimit/hardLimit
- allowedPurposes/overridePolicy

账本数据增长较快，需要按月聚合并设置明细保留期限。

## 3. AiRequestGateway 流程

1. 解析模型能力。
2. 根据 payload 预估 Token/图片能力/上下文上限。
3. 预算服务返回 allow/warn/block。
4. 执行请求和重试。
5. 收集 provider usage；缺失时标记未精确统计。
6. 写入账本和脱敏诊断。
7. 返回统一结果。

重试应产生同一 root request ID 下的 attempt 明细，费用按实际 attempt 累积。

## 4. 搜索策略

新增 `WebSearchPolicy`：off/ask/auto。`shouldSearch` 只负责判断“是否建议搜索”，无权直接发请求。

`SearchCoordinator` 负责：

- 展示/获取本次同意。
- 执行 provider。
- 规范化结果和来源。
- 给 prompt 注入明确的不可信外部资料边界。
- 记录查询时间、来源和失败状态。

搜索查询日志遵循可清除和保留期限规则。

## 5. 实施任务

### Task 05-1：模型能力注册表

**验收：** 已知模型能力按 modelId 判断；未知模型保守降级。  
**验证：** provider/model 参数化测试。  
**依赖：** 阶段 01。  
**预计范围：** M。

### Task 05-2：统一 AiRequestGateway

**验收：** 普通聊天、摘要、主动消息和 Agent 调用逐步经统一入口。  
**验证：** fake provider 测试；调用用途标记测试。  
**依赖：** 05-1；建议阶段 03 controller 完成。  
**预计范围：** 多个 M 垂直切片。

### Task 05-3：费用账本与设置页明细

**验收：** Token/费用按用途、模型、会话和日期查询。  
**验证：** 价格版本、缓存 Token、未知价格和聚合测试。  
**依赖：** 05-2。  
**预计范围：** M。

### Task 05-4：预算预检与阻断

**验收：** soft/hard 阈值正确；后台调用不会绕过预算。  
**验证：** fake clock、多用途和越界测试。  
**依赖：** 05-3。  
**预计范围：** M。

### Task 05-5：联网搜索策略和 UI

**验收：** off/ask/auto 可用，搜索状态和来源可见。  
**验证：** 无同意不发请求测试；失败/空结果测试。  
**依赖：** 05-2，可与 05-3 并行。  
**预计范围：** M。

### Task 05-6：脱敏诊断中心

**验收：** 可按 request ID 查看非正文诊断并清除。  
**验证：** 敏感标记扫描、保留上限测试。  
**依赖：** 05-2。  
**预计范围：** M。

## 6. 检查点

- [ ] 所有请求都有 purpose 和 root request ID。
- [ ] 能力和预算预检发生在网络调用前。
- [ ] 搜索 off 模式经网络 mock 证明零请求。
- [ ] 费用聚合、价格版本和未知价格行为通过测试。

## 7. 风险与缓解

| 风险 | 影响 | 缓解 |
|---|---|---|
| 模型价格频繁变化 | 中 | 价格版本化，显示更新时间，不承诺绝对账单准确 |
| provider 不返回 usage | 中 | 标为估算/未知，不把估算伪装为精确值 |
| 统一 Gateway 改动面过大 | 高 | 按调用用途逐个迁移，保留 facade 兼容层 |
| 自动搜索误发隐私查询 | 高 | 默认策略由产品明确；off/ask 在 coordinator 层硬约束 |

## 8. 开放问题

- 是否允许从远程签名配置更新价格/能力，还是随 APP 版本发布？
- 预算账本保存多久，是否支持导出 CSV？
- 搜索 provider 是否需要可插拔接口，以支持不同地区服务？
