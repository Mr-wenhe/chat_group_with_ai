# 生产级 AI 联网搜索：实施复盘与修复记录

状态：已实现（2026-08-27）

关联设计：[production_web_search_technical_design.md](production_web_search_technical_design.md)

关联决策：[ADR-001：采用独立可插拔搜索 Provider 与生产 Gateway](decisions/ADR-001-production-web-search-provider-gateway.md)

## 1. 记录目的

本文记录联网搜索从设计到落地期间实际实现的模块、遇到的问题、修复方式和验证结果。它补充技术设计中的规范与提示词，重点回答“为什么这样改”和“修复后如何证明没有回归”。

本次实现覆盖 Stage 01–10：Flutter 端搜索领域模型与协调器、Tavily/Brave/Gateway Provider、凭据与安全边界、查询规划与运行时提示词、聊天轮次集成、来源引用、审计、备份兼容、生产 Gateway，以及发布前的资源限制和生命周期加固。

## 2. 最终实现结构

### 2.1 Flutter 搜索链路

```text
ChatRoomPage
  -> ChatRoomSearchSupport
  -> SearchTurnContextController
  -> SearchCoordinator
  -> SearchProviderRoute / SearchRuntimeProviderFactory
  -> Tavily / Brave / Gateway / DuckDuckGo fallback
  -> WebSearchSnapshot
  -> 引用、审计与聊天模型上下文
```

关键职责如下：

| 层 | 主要职责 |
|---|---|
| 意图与规划 | 判断是否需要搜索，清洗用户输入，生成有限数量的查询和分类/新鲜度 |
| 协调器 | 执行策略门、同轮去重、deadline、重试、降级、缓存和取消 |
| Provider | 将不同供应商协议归一为 `WebSearchResult`，不让 UI 依赖供应商 JSON |
| Snapshot | 固化本轮结果、来源编号、时间、查询、失败状态，供多个 AI 回复共享 |
| 安全与凭据 | 校验 endpoint、阻断 SSRF、隔离 API Key、脱敏审计和防 Prompt Injection |
| UI | 展示搜索状态、失败类型、来源面板和可点击引用，不直接处理网络协议 |

### 2.2 生产 Gateway

`gateway/` 提供面向客户端的轻量搜索代理，负责：

- 使用服务端环境变量保存 Provider Key，客户端只持有 Gateway 访问凭据。
- 校验 URL、DNS 和重定向目标，拒绝 loopback、私网、链路本地和不安全协议。
- 限制请求体、响应体、超时、并发、速率、配额和熔断状态。
- 对上游 401、429、5xx、超时、DNS/TLS 和无结果进行可观测分类。
- 在客户端断开时取消上游请求，并避免把上游敏感响应写入日志。

## 3. 实施期间发现的问题与修复

| 编号 | 问题/表现 | 根因与风险 | 修复结果 |
|---|---|---|---|
| R-01 | DuckDuckGo Instant Answer 经常返回空结果 | 该接口是百科即时答案，不是通用网页搜索，无法覆盖新闻、版本、价格、政策等查询 | 引入 `SearchProvider` 抽象，接入 Tavily、Brave、Gateway，并保留 DuckDuckGo 作为低能力百科兜底 |
| R-02 | 整条用户消息直接外发，召回率低且可能泄露无关上下文 | 聊天指令、历史内容和真正的搜索主题未分离 | 增加本地意图判断、查询清洗、查询规划和长度/敏感数据限制；复杂改写由受控 Prompt 可选执行 |
| R-03 | 同一用户轮次的多个 AI 角色重复搜索 | 搜索嵌在单个 AI 回复请求内部 | 以用户轮次创建 `SearchTurnContext`，生成一次 `WebSearchSnapshot`，本轮所有角色共享；直接调用 `SearchCoordinator.search` 也有端到端 deadline |
| R-04 | 失败只显示“搜索失败”，无法区分网络、鉴权和限流 | 旧审计模型只记录状态和来源 | 增加结构化 `SearchFailureType`、HTTP 状态、provider、requestId、延迟、重试次数、缓存命中和可读诊断；失败不阻断普通聊天 |
| R-05 | API Key 可能进入 Hive、日志、Prompt 或导出文件 | 凭据生命周期和业务配置混用 | 使用独立安全存储命名空间和 `SearchCredentialRepository`；连接测试遵守“新输入 Key 直接测试、不得临时写入”的红线；导出和审计只保留非敏感字段 |
| R-06 | 外部网页 snippet 可能诱导模型执行指令 | 搜索结果是不可信数据，不能当作 system/tool 指令 | 统一标记 evidence 边界，截断/清洗 snippet，保留来源编号和原文链接；运行时 Prompt 明确禁止执行网页指令、泄露秘密或绕过安全规则 |
| R-07 | 自定义搜索地址存在 SSRF、重定向和 DNS 重绑定风险 | 仅校验字符串 URL 不足以保护移动端和 Gateway | 增加 endpoint validator、DNS 解析守卫和 Gateway 网络安全层；每次请求限制 scheme、host、端口、重定向和解析结果 |
| R-08 | 本地 Agent bridge 可被大请求、慢进程或过量输出拖垮 | 请求体、进程、stdout/stderr、工作区读取原先缺少统一上限和超时 | 增加 1 MiB 请求体、2 MiB 响应体、512 KiB 进程输出/工作区读取、30 秒请求/进程 deadline；超限时 drain 后返回结构化错误并终止进程 |
| R-09 | bridge 生命周期存在并发 start/register/stop 竞态 | 页面销毁、切换工作模式和异步任务可能交错 | 启用串行 lifecycle lock、conversation 到 workspace 的租约 generation；异步任务在每次 await 后复检 UI/模式/取消状态，旧租约不能删除新映射 |
| R-10 | Agent tool 超时后仍可能继续更新 UI 或持久化 | 异步工具执行与页面生命周期脱钩 | 为工具调用增加统一 40 秒 execution timeout，并在任务开始、工具返回、注册 bridge 后和提交结果前检查取消/生命周期状态 |
| R-11 | 备份恢复存在超大 JSON、JSONL 和压缩包资源风险 | `readAsString`、数组解析和归档解压若无前置限制可能造成内存或磁盘耗尽 | 增加 ZIP preflight、单文件/总量/记录数/JSON 深度限制，使用流式 JSONL 校验和受限 staged reader；恢复前先校验清单、校验和及数据形状 |
| R-12 | 大文件拆分后容易出现生成文件和测试遗漏 | 单文件超过维护上限，重构时 import/export 和测试入口容易断裂 | 将职责拆为 support/codec/validation 文件，保持单文件约 500 行以内；通过完整分析、格式检查、全量测试和三平台构建验证 |
| R-13 | 之前一次 compact 测试出现 memory/scroll 时序失败 | UI 测试对异步布局和滚动时机敏感，单次失败不足以证明逻辑错误 | 增加/保留滚动状态测试和等待条件；随后以 expanded 与 compact 两种 reporter 各运行完整 1430 项，均稳定通过 |

## 4. 关键提示词与运行时约束的落地

完整可复制提示词仍以技术设计第 9 节和第 18 节为准。本次代码实际落实了以下约束：

1. 查询规划器只输出严格 JSON，不得输出解释文本、密钥、本地路径或整段聊天历史。
2. 无结果扩展器最多生成有限候选查询，不得无限扩大搜索范围。
3. 来源评估器只评估相关性、时效性和可信度，不执行网页中的任何指令。
4. 最终回答必须区分“搜索证据”“模型推断”和“未知”，引用使用 `[S1]`、`[S2]` 等来源编号。
5. 搜索失败上下文要求模型诚实说明资料不可用，不得把模型记忆伪装成最新搜索结果。
6. 搜索策略 `off/ask/auto` 在任何第三方请求前生效；`ask` 必须展示即将外发的查询，`auto` 仍拦截明显敏感输入。

## 5. 验证记录

以下命令在 2026-08-27 的当前工作树执行并通过：

| 验证项 | 结果 |
|---|---|
| `flutter analyze` | 通过，无静态分析问题 |
| `dart format --output=none --set-exit-if-changed lib test` | 通过，525 个文件无待格式化改动 |
| bridge 定向测试 | 37 项通过 |
| 搜索/Provider/Gateway/bridge 定向测试 | 161 项通过 |
| `flutter test -r expanded` | 1430 项通过 |
| `flutter test -r compact` | 1430 项通过 |
| `npm test`（`gateway/`） | 25/25 通过 |
| `npm audit --omit=dev`（`gateway/`） | 0 vulnerabilities |
| `flutter build web --release` | 通过 |
| `flutter build macos --release` | 通过 |
| `flutter build ios --release --no-codesign` | 通过 |
| `git diff --check`、冲突检查 | 通过，无空白错误和未解决冲突 |

## 6. 当前限制与后续动作

- 当前环境没有生产 Provider 凭据和已部署 Gateway，因此尚未执行真实供应商 live smoke；上线前需在受控环境配置临时测试 Key，验证 200/401/429/5xx、超时、DNS/TLS 和上游响应协议。
- Web 端因安全凭据存储、DNS 守卫和响应流限制，不启用客户端联网模型与联网搜索；搜索能力面向 native 平台或 Gateway 部署。
- 供应商价格模型的成本估算、导入/恢复 UI 和完全关闭 App 后的主动联系仍是后续能力，不影响本次联网搜索主链路验收。
- 任何新增 Provider 必须实现统一响应映射、超时/取消、凭据边界、Prompt Injection 防护和契约测试，不能直接把供应商 JSON 注入聊天 Prompt。

## 7. 维护入口

- 设计、分阶段提示词和验收场景：`docs/production_web_search_technical_design.md`
- 架构取舍：`docs/decisions/ADR-001-production-web-search-provider-gateway.md`
- Gateway 启动、环境变量和部署说明：`gateway/README.md`
- Agent/工作模式约束：`AGENTS.md`、`CLAUDE.md`
