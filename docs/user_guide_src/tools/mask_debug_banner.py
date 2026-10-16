#!/usr/bin/env python3
"""抹掉 Flutter debug 构建右上角的红色 DEBUG 角标。

只在上方靠右的小范围内找红色像素，避免误伤界面里其它红色元素
（未读红点、错误提示等都在画面中下部）。

用法: python3 mask_debug_banner.py <in> <out>
"""

import sys

from PIL import Image

# 只在画面宽度右侧 12%、高度上方 18% 的角落区域里找角标
CORNER_X_RATIO = 0.88
CORNER_Y_RATIO = 0.18
RED_MIN = 110
GREEN_MAX = 95
BLUE_MAX = 95
PADDING = 6


def find_banner_box(img):
    w, h = img.size
    x0 = int(w * CORNER_X_RATIO)
    y0 = 0
    x1, y1 = w, int(h * CORNER_Y_RATIO)

    px = img.convert("RGB").load()
    min_x, min_y, max_x, max_y = w, h, -1, -1
    for y in range(y0, y1):
        for x in range(x0, x1):
            r, g, b = px[x, y]
            if r >= RED_MIN and g <= GREEN_MAX and b <= BLUE_MAX:
                min_x = min(min_x, x)
                min_y = min(min_y, y)
                max_x = max(max_x, x)
                max_y = max(max_y, y)

    if max_x < 0:
        return None
    return (min_x, min_y, max_x, max_y)


def background_color(img, box):
    """从角标左侧同一高度取样，拿到它所在的那块背景色。"""
    min_x, min_y, _, max_y = box
    mid_y = (min_y + max_y) // 2
    sample_x = max(0, min_x - PADDING - 4)
    px = img.convert("RGB").load()
    return px[sample_x, mid_y]


def main():
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    in_path, out_path = sys.argv[1], sys.argv[2]

    img = Image.open(in_path)
    box = find_banner_box(img)
    if box is None:
        print(f"no debug banner found in {in_path}; copying as-is")
        img.save(out_path)
        return 0

    min_x, min_y, max_x, max_y = box
    fill = background_color(img, box)
    # 把方形区域补成覆盖整个角标的矩形（角标是斜的，矩形能完整盖住）
    cover = (min_x, 0, max_x, max_y + PADDING)
    rgb = img.convert("RGB")
    rgb.paste(fill, cover)
    rgb.save(out_path)
    print(f"masked banner {box} with {fill} -> {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
