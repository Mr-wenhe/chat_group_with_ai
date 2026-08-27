# ADR-001：采用独立可插拔搜索 Provider 与生产 Gateway

## 状态

Accepted（2026-08-26；本地测试与平台门禁已验证，生产 live smoke 待配置凭据后执行）

## 日期

2026-08-22

## 上下文

在 Stage 01–10 实施前，应用把 DuckDuckGo Instant Answer 当作联网搜索源。该接口主要提供百科即时答案，不能稳定覆盖最新版本、新闻、天气、价格和政策等真实网页搜索场景；当时还存在 Android Release 网络权限、错误诊断、整条用户消息外发和同轮重复搜索问题。以下上下文保留这段历史基线，当前实现状态以本 ADR 的决策与仓库测试为准。

应用同时支持 DeepSeek、Qwen、智谱、Moonshot、百度和自定义 OpenAI-compatible 模型。各模型的原生联网协议并不统一，部分模型完全没有原生搜索能力，因此不能把联网搜索绑定到某一个聊天模型 Provider。

完整设计见：

../production_web_search_technical_design.md

## 决策

1. 建立独立 SearchProvider 接口，把搜索能力与聊天模型解耦。
2. 生产分发优先通过后端 Search Gateway 调用 Brave/Tavily 等搜索源；个人和开发模式允许用户自带 Provider Key。
3. DuckDuckGo Instant Answer 仅作为稳定百科查询的低能力兜底，不再作为默认完整搜索源。
4. 搜索归属于用户轮次，同一轮多个 AI 共享同一 WebSearchSnapshot。
5. off/ask/auto 策略在任何 Query Planner 和 Provider 请求之前执行。
6. 搜索结果一律视为不可信外部数据，使用结构化 evidence、来源编号和 Prompt Injection 防护。
7. 搜索凭据使用独立安全存储命名空间，不复用 ApiConfig Hive 字段。

## 备选方案

### 继续增强 DuckDuckGo Instant Answer

优点：

- 无需 Key。
- 改动最小。

缺点：

- 它不是完整网页搜索 API。
- 对中文长问题、新闻、版本、价格等召回极差。
- 增加重试和解析字段仍无法解决数据源能力问题。

结论：拒绝作为主方案，仅保留百科兜底。

### 只使用模型原生联网搜索

优点：

- 某些 Provider 接入代码较少。
- 模型可以直接生成带搜索信息的回答。

缺点：

- 多模型协议不统一。
- 部分 Provider 不支持。
- 来源、审计、缓存、失败分类和成本难以统一。
- 自定义 OpenAI-compatible endpoint 无法安全推断能力。

结论：作为后续可选优化，不能作为统一基础。

### 在 Flutter 客户端内置开发者共享搜索 Key

优点：

- 无需后端。
- 用户开箱即用。

缺点：

- 客户端二进制无法可靠隐藏共享密钥。
- 容易被提取、滥用并耗尽配额。
- 无法实施可靠的全局限流、配额和 Provider 熔断。

结论：拒绝用于正式分发。个人版只允许用户自带 Key。

### 客户端直接抓取搜索结果网页

优点：

- 表面上不需要正式搜索 API。

缺点：

- 容易受反爬、验证码、页面结构变化和服务条款影响。
- HTML 清洗、版权、Prompt Injection 和稳定性风险高。
- 中国大陆和移动网络环境下可靠性差。

结论：拒绝。

## 后果

正面：

- 搜索源可替换和主备降级。
- 多模型共享同一套来源、引用、审计和安全语义。
- 可以对同轮请求去重并控制成本。
- 正式分发时不需要把 Provider Key 放进客户端。

代价：

- 需要新增 Provider 配置、凭据、缓存、诊断和 UI。
- 生产 Gateway 带来部署与运维成本。
- Provider 协议需要契约测试并随官方变更维护。
- 模型原生搜索必须通过显式能力注册，不能自动假设兼容。

## 实施状态

Stage 01–10 的实现已落地，独立 Provider/Gateway、凭据边界、查询规划、同轮去重、审计、备份恢复和 Android Release 权限均已完成本地验证。由于当前环境没有生产 Provider 凭据，live smoke 仍需在具备测试凭据的环境中单独执行；这不改变已采用的架构决策。若未来选择不同搜索架构，应新建 ADR 并将本文标记为 Superseded，不删除本记录。
