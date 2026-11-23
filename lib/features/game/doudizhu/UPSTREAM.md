# 斗地主上游来源

- 仓库：[`justa-cai/doudizhu`](https://github.com/justa-cai/doudizhu)
- 基线提交：`360b5708219561abfe66e68578d37ead848f0845`
- 许可证：MIT，版权 `Copyright (c) 2026 justa-cai`；见本目录 `LICENSE`。

## 移植文件

| 上游文件 | Dart 文件 | 移植内容 |
| --- | --- | --- |
| `js/rules.js` | `doudizhu_rules.dart` | 54 张牌、14 类牌型、比较、实体牌校验、结算状态。 |
| `js/rules.js` | `doudizhu_move_generator.dart` | 有界 AI 候选、翅膀枚举、最少手数 DP 与 20,000 节点预算。 |
| `js/ai/engine.js` | `doudizhu_engine.dart` | 评分常量、记牌、农民协作、残局、候选压缩及稳定排序。 |
| `js/difficulty.js` | `doudizhu_difficulty.dart` | 第 6 档「宗师」：`wingChoices=3`、`remember/teamwork/endgame=true`、`temperature=0`、`blunder=0`。 |
| `js/app.js` | `doudizhu_game_state.dart`、`doudizhu_game_director.dart`、`doudizhu_ai_player.dart` | 叫分阈值与 applyBid 语义、动作提交、回合调度和角色模型优先。按产品要求不移植浏览器切后台暂停行为。 |
| `js/ui/table.js` | `doudizhu_setup_view.dart`、`doudizhu_table_view.dart`、`doudizhu_game_page.dart` | 参考绿毡三席布局、手牌/出牌区、提示循环和侧栏信息结构；用 Flutter 原生组件实现响应式界面。 |

## 有意适配

1. 上游按点数数量扣牌；Flutter 的真人提交和引擎候选都保留真实卡牌 ID。规则层先校验手牌归属、重复 ID、ID 范围、牌型与压制，再扣除提交的实体牌。
2. AI 候选仍受上游枚举上限约束；真人组合使用独立规则校验。界面不会把候选上限当作唯一合法动作的证明。
3. 三席模型输入由席位投影生成，只包含本席手牌与公开信息。叫分期间不传底牌。宗师引擎运行在独立 isolate。
4. 上游 DOM 牌桌由 Flutter 原生界面替代；模型和引擎动作都经同一牌局提交入口。
5. 上游提示按牌数、牌点升序循环候选，跟牌时最后提示“不出”；Flutter 按此逻辑实现。上游手牌只处理点击和鼠标悬停光标，不含拖动选择；Flutter 额外支持按住鼠标划过连续选牌。

## UI 对照审计

Flutter 已覆盖模式/角色开局、三席牌桌、叫分/出牌/过牌、提示/重置、公开动态和结算。当前出牌与“不出”记录靠近对应席位；中心仅显示待压状态。真人模式记牌器按“总牌数 - 自己手牌 - 已公开出牌”统计外面各点数，叫分阶段不泄露底牌；上帝视角不显示冗余计数。动态显示角色模型、宗师直连/兜底来源、模型回复原因和累计次数。

牌桌布局另外参考了 [Sanotsu/landlord](https://github.com/Sanotsu/landlord) 的 Flutter 三席牌区与记牌器、[arcxya09/doudizhu](https://github.com/arcxya09/doudizhu) 的三家出牌区，以及 [qy527145/ddz](https://github.com/qy527145/ddz) 的按自己手牌和公开牌扣减剩余点数思路。它们是 UI 参考，不是规则或引擎来源。

Flutter **没有完成上游 UI 的像素级复刻**。上游的 Canvas 手牌扇形、原始侧栏布局、逐手 AI 决策表和主菜单/说明/结算弹层没有逐项复刻；Flutter 使用 Material 原生响应式布局与历史记录弹窗。模型实际耗时也未像上游引擎耗时一样显示为逐手统计。这些是已知视觉/记录差异，不影响规则和 AI 引擎移植。

上游 `NOTICE.md`、`README_CN.md`、规则、AI、难度、牌桌交互与应用叫分/恢复路径均按上述基线阅读并作为移植依据。
