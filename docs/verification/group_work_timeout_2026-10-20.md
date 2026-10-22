# 群工作请求超时现场（2026-10-20）

## 17:52 补充：孙梦琪的停滞判据缺陷

孙梦琪在正式方案已采纳、程序媛已表态后触发相同的 180 秒保护（事件 6282–6285）。代码复查发现计时器只计正文，而 OpenAI 兼容解析器会忽略私有 `reasoning` 字段。此前“零正文”不能推出“没有响应活动”，因而不能只归因于模型服务。

本轮给 SSE 解析器增加可选、不含内容的生成活动回调，经现有服务与治理网关只接入群讨论。收到非空正文或 reasoning/reasoning_content 数据即撤销首字节保护；不输出、发布或采纳私有推理，300 秒总时限保持不变。普通私聊未传入回调，原行为保持。

17:49:57 DEBUG 在原任务复测：需求 70、候选 11 保留；17:51:48 发起孙梦琪请求，17:51:53 记录“模型已有响应活动”（6291），即约 4 秒收到活动。完整正文和采纳结果仍待核对，不能据此宣称整体验收通过。

解析器与群讨论 188 项测试通过，协议/流式/私聊/治理兼容 63 项通过，8 个改动相关文件 analyze 无问题。新增用例覆盖私有推理不进入正文、活动撤销首字节计时但不取消总时限，以及服务层回调透传。

本次最终结果：17:56:48 达到 300 秒总时限，最终正文仍为 0（6292），随后只产生一项恢复决策（6293）。本轮证明已避免 180 秒首字节误判，**没有证明模型最终响应时延已解决**。暂停现场、需求 70、候选 11 均保留，不再盲目重试。后续超时文案明确区分“已收到生成活动但完整响应超时”，不回写、遮盖旧事件。

## 范围与结论

群「干活的群」，原任务 `3c125ee6-83fe-4f6f-b5e6-368f69b007ab`。本轮未删除任务、聊天、配置、候选或材料，未写数据库伪造状态。**整体验收未通过**。

最新 DEBUG 构建时间 17:23:01，17:31:05 启动，界面保留需求版本 69、候选 11，等待成员请求恢复选择。没有活动的模型请求。

## 本轮修复

- 群 v2 请求：能力已声明支持流式时使用现有治理网关流式通道；其他调用默认行为保留。正文字符数每 15 秒最多记录一次，不公开推理或未采纳提案。
- 零正文 180 秒与整次 300 秒分开收口；取消请求，分别记录 `modelFirstByteStall`、`modelCompletionTimeout`。未完整结束的正文不采纳。
- 限制流式正文大小；流式完整结束但正文为空，只允许一次非流式兼容回退，仍受同一次总时限约束。
- 定向字段修复：只替换指定的 workItems、acceptances 或 usageAssignments，合并后经过完整协议与状态校验，不能夹带改写其他方案字段。
- 已有阻塞恢复选择时不再为同一失败追加通用无进展问题。
- Step 5 群讨论显式传入官方 `reasoning_effort=low`；普通调用不传，其他模型不传，不改变用户保存的模型配置或输出预算。

主要实现：`work_discussion_group_stream.dart`、`work_discussion_runner_model_io.dart`、`work_discussion_v2_requests.dart`、`work_discussion_v2_session.dart`、`work_discussion_v2_protocol.dart`。共享传参涉及 `ai_request_gateway.dart`、`chat_api_service.dart`、`chat_api_protocol_support.dart`，现有调用默认不发送新参数。

## 真实运行证据

设备本地事件：`work_mode_agent/events/3c125ee6-83fe-4f6f-b5e6-368f69b007ab.jsonl`（App Support）。

- 6217–6223：恢复原任务，96243 字符请求，其中协作台账 81976、问题 33559、决策 20534；流式 300 秒零正文，暂停。
- 6227–6232：明确模型 `step-5-preview`、流式通道、180 秒正文首字节保护；180 秒零正文暂停。旧代码还追加了一项无进展问题，本轮已修复其重复入口。
- 用户通过界面答复旧问题，未删除或重开任务。
- 6237–6242：使用 low 档，99535 字符请求；收到真实流式正文，约 133 秒后返回 5155 字符提案，但缺少 usageAssignments，未采纳。
- 6243–6247：定向修复请求缩小到 11017 字符，仍 180 秒零正文并暂停。low 档没有消除本轮停滞。现有证据无法区分上游排队、推理或传输停滞，不能断言单一服务端根因。

## 校验

- 群讨论全套 161 项通过；新守卫边界 4 项通过。
- 群讨论/聊天协议/流式聊天组合 196 项通过；增加 low 参数覆盖后聊天协议 14 项通过。
- 私聊空回复回退/治理网关 27 项通过；群消息可见性/旧讨论兼容 36 项通过。
- 全仓 analyze 无错误或警告；3 条已有 info（角色批量模型替换的 async context、API bundle 测试的 const 建议）。
- `git diff --check` 通过；macOS DEBUG 构建通过。未修改 Hive/JsonSerializable 模型，无需生成代码。

## 尚未完成

当前模型修复请求没有正文，正式方案的最新重排尚未采纳；新候选、独立测试成员完整实玩、失败返修复测、最终浏览器验收均未完成。不能用本轮代码测试代替上述验收。

旧进程退出曾挂起，已保存 `/tmp/chat_group_debug_hang_1719.txt` 后结束该暂停进程；最新进程正常恢复同一任务。Flutter 退出栈的根因尚未完成定位。

## 18:21 实测与完成事件审计

原任务保持需求70、候选11。18:16:12–18:21:12 的请求收到7253次生成活动，最后活动300011ms，正文0字符；这只能证明通道持续生成，不能证明最终正文或done已到达。已保留待决，不自动重试。

发现可独立复现缺陷：`_completeGroupStream` 收到done只赋值结果，仍等待流关闭；连接保持时总计时器将完整响应错误归为modelCompletionTimeout。收到done后立即退出群讨论消费循环，既有空结果回退、长度限制、截断与协议校验保留。新增保持流打开的回归用例；临时恢复旧逻辑时失败(exit1)，新逻辑通过。未将此缺陷冒充上次零正文的唯一原因。暂撤未实测的JSON模式改变。

### 完成事件修复校验及恢复

- `flutter test` v2群讨论、streaming、protocol、gateway、私聊空回应兼容：226项通过（`/tmp/group_done_finaltests.log`）。单用例30s。
- 全量analyze无error/warning，3条既有info（`/tmp/group_done_finalanalyze.log`）。
- `flutter build macos --debug`通过，当前二进制19:37:16；CUA在文件追加的真实原子提交收据之后停止旧进程，重启原任务，继续需求72/候选11。
- 19:44:07 App workspace.patch已真实提交目标飞行棋/飞行棋.html（事件6789）。尚未冻结新候选或证明独立验收通过。
- `[DONE]`在ChatApiService流入口转为done并return；最终正文content由token累计，原生reasoning仅活动计数，不作为可采纳正文；群消费done立即break，不再等待EOF。协议拒绝发生在完整响应返回之后，不会把被拒的JSON误算为0正文。

## 跨模型、跨协议同类路径

群请求显式启用finishOnTerminalFrame，默认调用保持false。OpenAI兼容stop/length/tool_calls/content_filter、Gemini STOP/MAX_TOKENS可在正式结束帧后退出，不再等待DONE或EOF；Anthropic message_stop、Responses response.completed/done沿用既有完成事件。群Gemini MAX_TOKENS保留truncated=true，私聊默认行为保留。群完成仍经字节上限、截断和完整v2校验，不把思考当答案。

生成活动回调扩展到Anthropic thinking、Responses reasoning和Gemini thought；群Gemini thought从正文中分离，私有文本不落日志。只计活动、不计协作进展。四协议使用arbitrary-model、保持传输流打开、尾帧与正文同帧、截断结尾和私有活动隔离均有回归；普通调用保留尾部usage测试。群提前收尾可能缺独立尾帧usage，沿用网关估算，不能伪称精确。

跨协议/streaming/gateway/私聊/v2/parser测试通过（/tmp/terminal_actualtests.log）；analyze仍3条既有info。一次测试路径误写test/core/streaming/sse_parser_test.dart导致装载失败，已更正为test/sse_parser_test.dart并完整复跑通过。构建成功。CUA曾检测到用户正在操作，因此停止动作被拒，没有抢占或改写现场；本轮通用修复的真实模型服务尚未全部逐家实测。
