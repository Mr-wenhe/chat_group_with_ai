# 上游来源

黑白棋规则和 Hard 搜索移植自 [boisedude/othello-game](https://github.com/boisedude/othello-game)，基线提交 `ee947aebf43b1efe78a577dc6d5e0f987ed87af4`。

上游版权声明：Copyright (c) 2025 Play Coop Games。完整 MIT 许可见本目录的 `LICENSE`。

本移植只保留 8×8 规则、位置估值与 Hard Minimax 所需逻辑。Dart 版本保留上游候选顺序、估值常量、深度 2–6、1500 ms 搜索预算、完整深度择优和首层中断时的首个排序候选回退；搜索在独立 isolate 中运行。
