# -*- coding: utf-8 -*-
"""Build the 伴伴 roadshow deck from the outline.

Run: python docs/business_plan/build_pptx.py
"""

from __future__ import annotations

import os

from lxml import etree
from pptx import Presentation
from pptx.dml.color import RGBColor
from pptx.enum.shapes import MSO_SHAPE
from pptx.enum.text import MSO_ANCHOR, PP_ALIGN
from pptx.oxml.ns import qn
from pptx.util import Inches, Pt

# ---------------------------------------------------------------- palette
NAVY = RGBColor(0x0B, 0x12, 0x20)
INK = RGBColor(0x0F, 0x17, 0x2A)
SLATE = RGBColor(0x47, 0x55, 0x69)
MUTED = RGBColor(0x64, 0x74, 0x8B)
LIGHT = RGBColor(0xF1, 0xF5, 0xF9)
WHITE = RGBColor(0xFF, 0xFF, 0xFF)
ORANGE = RGBColor(0xFF, 0x6B, 0x35)
ORANGE_SOFT = RGBColor(0xFF, 0xED, 0xE6)
TEAL = RGBColor(0x0E, 0xA5, 0xA4)
TEAL_SOFT = RGBColor(0xE6, 0xF7, 0xF6)
GOLD = RGBColor(0xF5, 0xB3, 0x00)
RED = RGBColor(0xE1, 0x1D, 0x48)
GREEN = RGBColor(0x16, 0xA3, 0x4A)
LINE = RGBColor(0xE2, 0xE8, 0xF0)

FONT = "Microsoft YaHei"
SW, SH = 13.333, 7.5


# ---------------------------------------------------------------- helpers
def set_font(run, size=18, bold=False, color=INK, font=FONT):
    run.font.name = font
    run.font.size = Pt(size)
    run.font.bold = bold
    run.font.color.rgb = color
    rpr = run._r.get_or_add_rPr()
    ea = rpr.find(qn("a:ea"))
    if ea is None:
        ea = etree.SubElement(rpr, qn("a:ea"))
    ea.set("typeface", font)


def add_text(
    slide,
    left,
    top,
    width,
    height,
    text,
    size=18,
    bold=False,
    color=INK,
    align=PP_ALIGN.LEFT,
    anchor=MSO_ANCHOR.TOP,
    line_spacing=1.12,
    font=FONT,
):
    box = slide.shapes.add_textbox(Inches(left), Inches(top), Inches(width), Inches(height))
    tf = box.text_frame
    tf.word_wrap = True
    tf.margin_left = 0
    tf.margin_right = 0
    tf.margin_top = 0
    tf.margin_bottom = 0
    tf.vertical_anchor = anchor
    for i, line in enumerate(text.split("\n")):
        p = tf.paragraphs[0] if i == 0 else tf.add_paragraph()
        p.alignment = align
        p.line_spacing = line_spacing
        p.space_after = Pt(0)
        r = p.add_run()
        r.text = line
        set_font(r, size=size, bold=bold, color=color, font=font)
    return box


def add_rect(slide, left, top, width, height, fill=LIGHT, line=None, shape=MSO_SHAPE.ROUNDED_RECTANGLE, radius=0.08):
    shp = slide.shapes.add_shape(shape, Inches(left), Inches(top), Inches(width), Inches(height))
    shp.fill.solid()
    shp.fill.fore_color.rgb = fill
    if line is None:
        shp.line.fill.background()
    else:
        shp.line.color.rgb = line
        shp.line.width = Pt(1)
    try:
        shp.shadow.inherit = False
    except Exception:
        pass
    if shape == MSO_SHAPE.ROUNDED_RECTANGLE:
        try:
            shp.adjustments[0] = radius
        except Exception:
            pass
    return shp


def add_line(slide, x1, y1, x2, y2, color=LINE, width=1.5):
    from pptx.enum.shapes import MSO_CONNECTOR
    conn = slide.shapes.add_connector(MSO_CONNECTOR.STRAIGHT, Inches(x1), Inches(y1), Inches(x2), Inches(y2))
    conn.line.color.rgb = color
    conn.line.width = Pt(width)


def add_footer(slide, page, dark=False):
    color = MUTED if not dark else RGBColor(0x94, 0xA3, 0xB8)
    if not dark:
        add_line(slide, 0.7, 7.05, 12.63, 7.05, LINE, 1)
    add_text(slide, 0.7, 7.12, 5.0, 0.25, "伴伴 · Oray 子品牌", 9, False, color)
    add_text(slide, 5.2, 7.12, 3.0, 0.25, "内部孵化 · 2026-11", 9, False, color, PP_ALIGN.CENTER)
    add_text(slide, 11.6, 7.12, 1.03, 0.25, f"{page:02d}", 9, False, color, PP_ALIGN.RIGHT)


def add_title(slide, kicker, title, subtitle=None):
    add_rect(slide, 0.7, 0.52, 0.18, 0.18, ORANGE, shape=MSO_SHAPE.RECTANGLE)
    add_text(slide, 1.0, 0.45, 9.0, 0.3, kicker.upper(), 10, True, ORANGE)
    add_text(slide, 0.7, 0.78, 11.9, 0.7, title, 30, True, INK)
    if subtitle:
        add_text(slide, 0.7, 1.48, 11.9, 0.4, subtitle, 14, False, MUTED)


def add_notes(slide, text):
    slide.notes_slide.notes_text_frame.text = text


def content_slide(prs, page, kicker, title, subtitle=None):
    slide = prs.slides.add_slide(prs.slide_layouts[6])
    bg = slide.background.fill
    bg.solid()
    bg.fore_color.rgb = WHITE
    add_title(slide, kicker, title, subtitle)
    add_footer(slide, page)
    return slide


def add_table(slide, left, top, width, height, headers, rows, col_widths=None, font_size=13):
    shape = slide.shapes.add_table(len(rows) + 1, len(headers), Inches(left), Inches(top), Inches(width), Inches(height))
    table = shape.table
    table.first_row = True
    table.horz_banding = False
    if col_widths:
        for i, w in enumerate(col_widths):
            table.columns[i].width = Inches(w)
    for c, h in enumerate(headers):
        cell = table.cell(0, c)
        cell.fill.solid()
        cell.fill.fore_color.rgb = NAVY
        cell.margin_left = Inches(0.1)
        cell.margin_right = Inches(0.1)
        cell.margin_top = Inches(0.04)
        cell.margin_bottom = Inches(0.04)
        cell.vertical_anchor = MSO_ANCHOR.MIDDLE
        tf = cell.text_frame
        tf.word_wrap = True
        p = tf.paragraphs[0]
        p.alignment = PP_ALIGN.LEFT
        r = p.add_run()
        r.text = h
        set_font(r, size=font_size, bold=True, color=WHITE)
    for ri, row in enumerate(rows):
        table.rows[ri + 1].height = Inches(0.55)
        for ci, val in enumerate(row):
            cell = table.cell(ri + 1, ci)
            cell.fill.solid()
            cell.fill.fore_color.rgb = WHITE if ri % 2 == 0 else LIGHT
            cell.margin_left = Inches(0.1)
            cell.margin_right = Inches(0.1)
            cell.margin_top = Inches(0.04)
            cell.margin_bottom = Inches(0.04)
            cell.vertical_anchor = MSO_ANCHOR.MIDDLE
            tf = cell.text_frame
            tf.word_wrap = True
            p = tf.paragraphs[0]
            p.alignment = PP_ALIGN.LEFT
            r = p.add_run()
            r.text = str(val)
            set_font(r, size=font_size, bold=(ci == 0), color=INK)
    return table


def stat_card(slide, left, top, width, height, value, label, accent=ORANGE):
    add_rect(slide, left, top, width, height, LIGHT)
    add_rect(slide, left, top, 0.08, height, accent, shape=MSO_SHAPE.RECTANGLE)
    add_text(slide, left + 0.22, top + 0.16, width - 0.34, 0.55, value, 26, True, accent)
    add_text(slide, left + 0.22, top + 0.78, width - 0.34, 0.4, label, 11, False, MUTED)


# ---------------------------------------------------------------- deck
def build(out_path: str):
    prs = Presentation()
    prs.slide_width = Inches(SW)
    prs.slide_height = Inches(SH)

    # ---------- 1. cover
    s = prs.slides.add_slide(prs.slide_layouts[6])
    bg = s.background.fill
    bg.solid()
    bg.fore_color.rgb = NAVY
    add_rect(s, 0, 0, SW, 0.12, ORANGE, shape=MSO_SHAPE.RECTANGLE)
    add_text(s, 0.9, 0.9, 9.0, 0.3, "INTERNAL INCUBATION · 2026-11", 11, True, ORANGE)
    add_text(s, 0.9, 1.45, 9.0, 1.0, "伴伴", 58, True, WHITE)
    add_text(s, 0.9, 2.55, 11.0, 0.6, "Oray 的 AI 入口", 30, True, WHITE)
    add_text(s, 0.9, 3.28, 11.0, 0.9, "一个会长大的 AI 伙伴，一句话连接设备、内网、网络与账号。", 18, False, RGBColor(0xCB, 0xD5, 0xE1))
    add_text(s, 0.9, 5.55, 11.0, 0.35, "Oray 子品牌  ·  授权 / 商标 / 角色 IP 归贝锐", 12, False, RGBColor(0x94, 0xA3, 0xB8))
    chips = ["向日葵", "花生壳", "蒲公英", "洋葱头"]
    x = 0.9
    for chip in chips:
        add_rect(s, x, 6.15, 1.85, 0.5, RGBColor(0x1E, 0x29, 0x3B), shape=MSO_SHAPE.ROUNDED_RECTANGLE)
        add_text(s, x, 6.24, 1.85, 0.3, chip, 12, True, WHITE, PP_ALIGN.CENTER)
        x += 2.0
    add_notes(s, "各位评委，大家好。Oray 做了 20 年连接，让 1 亿用户连上了设备、内网、网络和账号。但在 AI 时代，用户不想再打开四个工具、配置连接——他们想跟一个懂他的人说一句话。伴伴，就是这句话的入口。")

    # ---------- 2. scenario
    s = content_slide(prs, 2, "WHY NOW · 01", "四个场景", "用户不想打开四个工具，只想把事办成。")
    cards = [
        ("「帮我看看我妈的电脑，\n怎么又连不上网了。」", "向日葵 · 远程协助"),
        ("「打开家里 NAS，\n我找一下去年的照片。」", "花生壳 · 内网访问"),
        ("「把两个店面的网络连起来，\n别老断。」", "蒲公英 · 异地组网"),
        ("「给外包同事开个临时权限，\n只让他看订单。」", "洋葱头 · 账号与权限"),
    ]
    x = 0.68
    for quote, label in cards:
        add_rect(s, x, 2.08, 2.85, 3.35, LIGHT)
        add_text(s, x + 0.18, 2.3, 2.5, 1.55, quote, 15, True, INK)
        add_text(s, x + 0.18, 4.55, 2.5, 0.35, label, 10, True, ORANGE)
        x += 3.07
    add_rect(s, 0.68, 5.85, 11.97, 0.7, ORANGE_SOFT)
    add_text(s, 0.93, 6.02, 11.4, 0.35, "共同点：用户不想学工具，只想把事办成。", 15, True, ORANGE)
    add_notes(s, "我先不讲技术，讲四个场景。第一个，爸妈电脑坏了，以前你要打电话教他们装向日葵、输识别码；现在你说一句话，伴伴发起远程协助。第二个，你想找家里 NAS 的照片，以前要配花生壳、记域名；现在一句话。第三个，两个店面的网络老断，以前要找工程师配蒲公英；现在你说一句，伴伴帮你把组网方案列出来。第四个，电商团队要给外包开临时权限，以前要进洋葱头后台；现在一句话，而且有审计。四个场景的共同点是：用户不想学工具，只想把事办成。")

    # ---------- 3. pain / shift
    s = content_slide(prs, 3, "THE SHIFT · 02", "用户的使用方式在变", "任务型、低频的工具，缺一个一直在线的对话入口。")
    add_rect(s, 0.7, 2.15, 5.65, 3.45, LIGHT)
    add_text(s, 1.0, 2.4, 5.0, 0.35, "工具型入口", 17, True, SLATE)
    add_text(s, 1.0, 2.95, 5.0, 1.2, "打开 App → 找功能 → 配置 → 使用", 20, True, INK)
    add_text(s, 1.0, 4.25, 5.0, 0.8, "低频、任务驱动\n用户要学", 15, False, MUTED)
    add_rect(s, 6.98, 2.15, 5.65, 3.45, TEAL_SOFT)
    add_text(s, 7.28, 2.4, 5.0, 0.35, "对话型入口", 17, True, TEAL)
    add_text(s, 7.28, 2.95, 5.0, 1.2, "说一句话 → AI 调用 → 完成", 20, True, INK)
    add_text(s, 7.28, 4.25, 5.0, 0.8, "高频、关系驱动\n用户被理解", 15, False, MUTED)
    add_text(s, 0.7, 5.95, 11.9, 0.6, "但市面上的 AI 角色，聊三天就失忆、串味、变成客服腔。", 17, True, INK)
    add_text(s, 0.7, 6.45, 11.9, 0.35, "向日葵、花生壳、蒲公英、洋葱头，都是任务型入口。", 12, False, MUTED)
    add_notes(s, "Oray 过去二十年做的是连接：向日葵连设备、花生壳连内网、蒲公英连网络、洋葱头连账号。但这些都是任务型入口。用户有事才打开，没事就关掉。AI 时代，入口在从 App 转向对话。用户不想学四个工具，只想说一句话。而市面上的 AI 角色，聊三天就失忆、串味、变成客服腔。所以 Oray 缺的不是连接能力，是一个一直在线的对话入口。")

    # ---------- 4. opportunity
    s = content_slide(prs, 4, "MARKET · 03", "市场：陪伴和连接，是两件事", "不是从零开始的创业，是一次入口尝试。")
    stats = [
        ("¥4.5 亿", "SAM / 年（基准假设）", ORANGE),
        ("1 亿+", "Oray 注册用户", TEAL),
        ("120 万+", "企业客户", TEAL),
        ("20 亿+", "接入设备", TEAL),
    ]
    x = 0.7
    for value, label, accent in stats:
        stat_card(s, x, 2.0, 2.85, 1.3, value, label, accent)
        x += 3.03
    add_text(s, 0.7, 3.42, 9.2, 0.3, "四条产品线：向日葵、花生壳、蒲公英、洋葱头", 11, True, TEAL)
    add_text(s, 0.7, 3.75, 5.0, 0.35, "从 1 亿+ 用户到 100–300 万可触达种子", 14, True, SLATE)
    # funnel
    layers = [("1 亿+  Oray 用户", 9.2, TEAL_SOFT), ("100–300 万  可触达种子", 7.0, ORANGE_SOFT), ("100–300  名种子测试", 4.8, ORANGE)]
    y = 4.25
    for text, w, color in layers:
        add_rect(s, 0.7 + (9.2 - w) / 2, y, w, 0.65, color)
        add_text(s, 0.7 + (9.2 - w) / 2, y + 0.17, w, 0.35, text, 13, True, WHITE if color == ORANGE else INK, PP_ALIGN.CENTER)
        y += 0.8
    add_rect(s, 10.55, 4.2, 2.05, 2.7, LIGHT)
    add_text(s, 10.75, 4.4, 1.65, 0.3, "关系层 × 能力层", 12, True, ORANGE)
    add_text(s, 10.75, 4.8, 1.65, 1.9, "人格\n关系\n记忆\n陪伴\n×\n远控\n内网\n组网\n账号", 13, False, INK)
    add_notes(s, "市场测算我们做得比较粗。按基准假设，AI 角色用户大约 4,500 万，付费率 5%，年客单价 200 元，年市场大约 4.5 亿元。这是假设，不是调研结论。更重要的是 Oray 的用户基础：1 亿+ 注册用户、120 万+ 企业客户、20 亿+ 设备，还有向日葵、花生壳、蒲公英、洋葱头四条产品线。按 1% 到 3% 估算，可触达的种子是 100 万到 300 万。但工具用户不等于陪伴用户，这中间有多大的重叠，是阶段 1 要验证的事。")

    # ---------- 5. solution architecture
    s = content_slide(prs, 5, "SOLUTION · 04", "产品：人设、关系、记忆、陪伴", "人设是锚，记忆是年轮；上面再加一层 Oray 的连接能力。")
    caps = [("人格保真", "人设是权威源"), ("关系情绪", "有方向、有阶段"), ("长期记忆", "记得住、改得掉"), ("主动陪伴", "它会来找你")]
    x = 0.7
    for title, sub in caps:
        add_rect(s, x, 1.95, 2.85, 0.95, ORANGE_SOFT)
        add_text(s, x + 0.15, 2.08, 2.55, 0.3, title, 14, True, ORANGE)
        add_text(s, x + 0.15, 2.42, 2.55, 0.3, sub, 10, False, MUTED)
        x += 3.03
    add_rect(s, 0.7, 3.1, 11.93, 0.62, LIGHT)
    add_text(s, 0.95, 3.24, 11.4, 0.35, "投喂三通道：人物信息卡  /  对话式「记住」  /  多模态素材", 13, True, INK)
    add_rect(s, 0.7, 3.82, 11.93, 0.62, LIGHT)
    add_text(s, 0.95, 3.96, 11.4, 0.35, "可纠正：记忆审计  /  冲突消解  /  关系编辑  /  钉定与遗忘", 13, True, INK)
    add_rect(s, 0.7, 4.54, 11.93, 0.72, TEAL_SOFT)
    add_text(s, 0.95, 4.7, 11.4, 0.35, "连接能力：向日葵  /  花生壳  /  蒲公英  /  洋葱头", 14, True, TEAL)
    add_rect(s, 0.7, 5.36, 11.93, 0.62, NAVY)
    add_text(s, 0.95, 5.5, 11.4, 0.35, "基座：多模型  /  本地优先  /  凭据安全  /  可审计", 12, True, WHITE)
    add_text(s, 0.7, 6.2, 11.9, 0.5, "成长四层：L1 记忆 → L2 关系 → L3 人格微调 → L4 反思主动", 12, False, MUTED)
    add_notes(s, "伴伴的做法可以拆成四块。人设是权威来源，记忆只能补充，不能覆盖，所以聊得再久它还是它。关系有亲近、信任、摩擦、熟悉，加上关系阶段和三十分钟情绪。记忆分七类，按角色隔离，带重要度、置信度、取代链和证据；用户能审计、纠正、删除。陪伴是它会主动找你，而不是你每次去找它。再往下是投喂和纠正，最下面是连接能力，连接的就是向日葵、花生壳、蒲公英、洋葱头。")

    # ---------- 6. experience
    s = content_slide(prs, 6, "EXPERIENCE · 05", "用户会在什么场景里用它", "从第一次见面，到三个月后的默契。")
    stories = [
        ("第一次见面", "「你终于来了，\n我还以为你今天不来了。」", "人设 + 主动陪伴"),
        ("三个月后的默契", "「老样子。」\n它知道是哪家店、哪杯咖啡。", "长期记忆 + 关系成长"),
        ("一次远程求助", "「帮我看看我妈的电脑。」\n→ 向日葵远控 → 记得路由器位置。", "关系层 + 连接能力"),
    ]
    x = 0.7
    for title, body, proof in stories:
        add_rect(s, x, 2.1, 3.85, 3.5, LIGHT)
        add_text(s, x + 0.25, 2.3, 3.35, 0.35, title, 14, True, ORANGE)
        add_text(s, x + 0.25, 2.85, 3.35, 1.75, body, 15, False, INK)
        add_text(s, x + 0.25, 4.85, 3.35, 0.35, proof, 10, True, MUTED)
        x += 4.05
    add_text(s, 0.7, 5.85, 11.9, 0.5, "同一套关系，可以发生在向日葵、花生壳、蒲公英、洋葱头任意一个入口。", 13, True, MUTED)
    add_notes(s, "我只讲三个瞬间。第一次见面，它不是「你好我是 AI 助手」，而是「你终于来了，我还以为你今天不来了」。三个月后，它记得你不吃香菜、周三要加班、最近在准备考试；你说「老样子」，它知道是哪家店、哪杯咖啡。第三个瞬间，你说「帮我看看我妈的电脑」，它先安抚你，再用向日葵发起远程协助；修好后，它记得「妈妈家路由器在客厅角落」。这些事可以发生在向日葵、花生壳、蒲公英、洋葱头任意一个产品线上。关系是同一套，连接能力是四个入口。")

    # ---------- 7. why Oray
    s = content_slide(prs, 7, "WHY ORAY · 06", "为什么由 Oray 来做", "伴伴是 Oray 子品牌；授权、商标、角色 IP 归贝锐。")
    pillars = [
        ("用户基础", "1 亿+ 注册用户\n120 万+ 企业客户\n20 亿+ 接入设备", TEAL),
        ("能力基座", "向日葵 · 远控\n花生壳 · 内网\n蒲公英 · 组网\n洋葱头 · 账号", ORANGE),
        ("信任基础", "20 年连接安全\n等保三级\nISO27001\n加密与审计", NAVY),
    ]
    x = 0.7
    for title, body, color in pillars:
        add_rect(s, x, 2.0, 3.85, 3.35, LIGHT)
        add_rect(s, x, 2.0, 3.85, 0.08, color, shape=MSO_SHAPE.RECTANGLE)
        add_text(s, x + 0.25, 2.25, 3.35, 0.35, title, 16, True, color)
        add_text(s, x + 0.25, 2.8, 3.35, 2.2, body, 14, False, INK)
        x += 4.05
    add_rect(s, 0.7, 5.7, 11.93, 0.75, ORANGE_SOFT)
    add_text(s, 0.95, 5.88, 11.4, 0.35, "伴伴负责关系，四大产品线负责能力，两者相乘。", 16, True, ORANGE)
    add_notes(s, "为什么由 Oray 来做？这件事需要三样东西，Oray 刚好都有。第一，用户基础：1 亿+ 注册用户、120 万+ 企业客户、20 亿+ 设备，伴伴不用从零获客。第二，能力基础：向日葵、花生壳、蒲公英、洋葱头，覆盖设备、内网、网络、账号四层连接，这是纯陪伴创业公司没有的。第三，信任基础：二十年连接安全、等保三级、ISO27001，这跟伴伴本地优先、可审计的做法是同一种基因。还有一点，伴伴是 Oray 子品牌，授权、商标、角色 IP 都归贝锐，不存在权属障碍。")

    # ---------- 8. product lines
    s = content_slide(prs, 8, "PRODUCT LINES · 07", "四条产品线怎么接", "设备、内网、网络、账号，各有一个对话入口。")
    add_table(
        s, 0.7, 1.95, 11.93, 3.75,
        ["产品线", "能力", "伴伴场景", "用户价值"],
        [
            ["向日葵", "远程控制 / 协助", "「帮我看看我妈的电脑」", "一句话找人帮忙"],
            ["花生壳", "内网穿透 / DDNS", "「打开家里 NAS」", "对话式访问内网"],
            ["蒲公英", "SD-WAN / 异地组网", "「把两个店面的网络连起来」", "小微企业 IT copilot"],
            ["洋葱头", "企业账号 / 4A", "「登录抖店 / 给外包开权限」", "对话式权限，保留审计"],
        ],
        col_widths=[1.5, 2.5, 4.4, 3.53],
        font_size=13,
    )
    add_rect(s, 0.7, 5.95, 11.93, 0.65, ORANGE_SOFT)
    add_text(s, 0.95, 6.12, 11.4, 0.35, "首个试点：向日葵（4–8 周）；花生壳为第二候选。接入原则：授权、审计、本地优先、场景触发、可退出。", 12, True, ORANGE)
    add_notes(s, "四条产品线怎么接？设备、内网、网络、账号，各有一个对话入口。向日葵是设备，帮爸妈修电脑、连公司测试机。花生壳是内网，打开家里 NAS、访问公司 OA。蒲公英是网络，把两个店面的网络连起来，或者看看工厂设备。洋葱头是账号，登录抖店、给外包开临时权限，而且保留审计。接入原则有六条：用户授权、可审计、本地优先、场景触发、可退出、失败时说明原因。我们不建议一上来四条全做，第一个试点选向日葵，四到八周把「对话、授权、调用、回执」跑通，再复制到花生壳、蒲公英、洋葱头。")

    # ---------- 9. tech
    s = content_slide(prs, 9, "TECH · 08", "现有的技术底子", "项目已经做了不少东西。")
    stats = [
        ("626", "Dart 文件"), ("180,303", "行代码"), ("338", "测试文件"),
        ("3,766", "测试用例"), ("4", "端可运行"), ("8 / 4", "厂商 / 协议"),
    ]
    x, y = 0.7, 1.95
    for i, (value, label) in enumerate(stats):
        add_rect(s, x, y, 1.85, 1.15, LIGHT)
        add_text(s, x + 0.18, y + 0.14, 1.5, 0.45, value, 22, True, ORANGE)
        add_text(s, x + 0.18, y + 0.68, 1.5, 0.3, label, 9, False, MUTED)
        x += 1.98
        if i == 2:
            x, y = 0.7, 3.3
    add_text(s, 0.7, 4.7, 11.9, 0.35, "关键能力", 13, True, SLATE)
    moat = ["人格保真", "观察者级记忆隔离", "关系状态与情绪衰减", "本地优先", "凭据安全", "可审计、可恢复"]
    x, y = 0.7, 4.95
    for i, m in enumerate(moat):
        add_rect(s, x, y, 1.85, 0.5, TEAL_SOFT)
        add_text(s, x, y + 0.12, 1.85, 0.3, m, 9, True, TEAL, PP_ALIGN.CENTER)
        x += 1.98
        if i == 2:
            x, y = 0.7, 5.55
    add_text(s, 0.7, 6.25, 11.9, 0.5, "这些看起来不酷，但它们是「聊得久」的前提。", 15, True, INK)
    add_notes(s, "项目已经做了不少东西。626 个 Dart 文件、18 万行代码、338 个测试文件、大约 3,766 个测试用例，四端能跑。这些数字本身不说明产品会成功，但能说明很多坑已经踩过了。比如 2026 年 7 月，我们的诊断记录里 131 次失败全是超时，最后发现不是模型的问题，是客户端一个 30 秒的 receiveTimeout 把正常请求杀了。这种事情如果不写下来，下一次还会再犯。")

    # ---------- 10. competition 2x2
    s = content_slide(prs, 10, "COMPETITION · 09", "竞争格局：伴伴在右上角", "大厂做通用助手，我们做连接场景的入口。")
    # axes
    add_line(s, 6.55, 1.95, 6.55, 6.05, SLATE, 1.5)
    add_line(s, 1.6, 4.0, 11.7, 4.0, SLATE, 1.5)
    add_text(s, 9.9, 6.1, 2.0, 0.3, "情感深度 →", 11, True, SLATE)
    add_text(s, 6.65, 1.75, 3.5, 0.3, "数据主权 / 可控性 ↑", 11, True, SLATE)
    # quadrant labels
    add_text(s, 1.8, 1.95, 2.5, 0.3, "高可控 · 低情感", 10, False, MUTED)
    add_text(s, 9.1, 1.95, 2.6, 0.3, "高可控 · 高情感", 10, True, ORANGE)
    add_text(s, 1.8, 5.65, 2.5, 0.3, "低可控 · 低情感", 10, False, MUTED)
    add_text(s, 9.1, 5.65, 2.6, 0.3, "低可控 · 高情感", 10, False, MUTED)
    # points
    add_text(s, 8.8, 2.45, 3.2, 0.4, "★ 伴伴（Oray）", 16, True, ORANGE)
    add_text(s, 3.0, 2.55, 2.6, 0.4, "SillyTavern", 12, True, INK)
    add_text(s, 8.4, 4.55, 3.2, 0.4, "Character.AI / Replika", 12, True, INK)
    add_text(s, 5.2, 5.15, 2.8, 0.4, "星野 / 筑梦岛 / 猫箱", 12, True, INK)
    add_text(s, 12.0, 4.55, 1.0, 0.4, "", 12)
    add_rect(s, 0.7, 6.25, 11.93, 0.55, LIGHT)
    add_text(s, 0.95, 6.38, 11.4, 0.3, "难被复制的地方：用户的记忆和关系迁移不走；向日葵、花生壳、蒲公英、洋葱头是纯陪伴产品没有的。", 10, True, INK)
    add_notes(s, "竞争格局可以用两个轴看：情感深度，和数据主权/可控性。Character.AI、Replika 情感强，但云端、封闭；星野、筑梦岛社区强，但依赖平台；SillyTavern 本地、可自定义，但门槛高。伴伴在右上角：既有情感深度，又有数据主权，还有 Oray 的连接能力。大厂做通用助手，我们做连接场景的 AI 入口——这是他们不容易抄的。")

    # ---------- 11. business model
    s = content_slide(prs, 11, "BUSINESS MODEL · 10", "收入从哪来", "订阅是主线，产品线交叉销售是 Oray 独有的增量。")
    rev = [
        ("订阅", "Free / Pro\n¥30/月 或 ¥198–298/年", ORANGE),
        ("产品线交叉销售", "向日葵、花生壳、蒲公英、洋葱头\n打包或分成", TEAL),
        ("角色/模板市场", "创作者分成", NAVY),
        ("IP 孵化与授权", "联名 / 周边 / 内容改编", GOLD),
    ]
    x = 0.7
    for title, body, color in rev:
        add_rect(s, x, 2.0, 2.85, 2.35, LIGHT)
        add_rect(s, x, 2.0, 0.08, 2.35, color, shape=MSO_SHAPE.RECTANGLE)
        add_text(s, x + 0.22, 2.2, 2.45, 0.35, title, 13, True, color)
        add_text(s, x + 0.22, 2.7, 2.45, 1.4, body, 12, False, INK)
        x += 3.03
    add_rect(s, 0.7, 4.75, 11.93, 1.55, ORANGE_SOFT)
    add_text(s, 0.95, 4.95, 11.4, 0.35, "单位经济：年付 ¥298 × 毛利率 70% × 生命周期 12 个月", 14, True, ORANGE)
    add_text(s, 0.95, 5.4, 11.4, 0.7, "LTV ≈ ¥209   ·   CAC 上限 ≈ ¥70   ·   留存是一号指标；CAC 高于区间就不能买量。", 14, False, INK)
    add_notes(s, "商业模式四条线。第一条订阅，Free 用 BYOK 降低门槛，Pro 提供多角色、大记忆、语音、多模态。第二条是 Oray 独有的：产品线交叉销售——用户在伴伴里调用向日葵、花生壳、蒲公英、洋葱头，我们打包订阅或按效果分成。第三条是角色和模板市场，创作者分成。第四条是 IP 孵化与授权。单位经济我算过：年付 298、毛利 70%、生命周期 12 个月，LTV 是 209，CAC 上限 70。所以留存是一号指标；CAC 高于这个数，就不能买量。")

    # ---------- 12. cold start
    s = content_slide(prs, 12, "GO-TO-MARKET · 11", "怎么获取第一批用户", "不假设工具用户会自然转化，先做 4 周验证。")
    funnel = [
        ("1 亿+  Oray 用户", 9.2, TEAL_SOFT, INK),
        ("100–300 万  可触达种子", 7.0, ORANGE_SOFT, INK),
        ("100–300  名种子测试", 4.8, ORANGE, WHITE),
    ]
    y = 1.95
    for text, w, color, txt_color in funnel:
        add_rect(s, 0.7 + (9.2 - w) / 2, y, w, 0.75, color)
        add_text(s, 0.7 + (9.2 - w) / 2, y + 0.2, w, 0.35, text, 13, True, txt_color, PP_ALIGN.CENTER)
        y += 0.9
    add_text(s, 0.7, 4.85, 6.0, 0.3, "四个种子场景", 12, True, ORANGE)
    seeds = [
        ("向日葵 · 远程协助", 0.7),
        ("花生壳 · NAS/内网", 2.85),
        ("蒲公英 · 门店组网", 5.0),
        ("洋葱头 · 账号权限", 7.15),
    ]
    for text, x in seeds:
        add_rect(s, x, 5.2, 2.0, 0.5, TEAL_SOFT)
        add_text(s, x, 5.33, 2.0, 0.3, text, 9, True, TEAL, PP_ALIGN.CENTER)
    add_rect(s, 9.9, 1.95, 2.75, 4.55, LIGHT)
    add_text(s, 10.1, 2.15, 2.35, 0.35, "4 周看什么", 13, True, ORANGE)
    metrics = ["D30 留存 ≥ 20%", "付费意愿 ≥ 3%", "记忆召回 ≥ 85%", "人设一致性 ≥ 85", "产品线调用率 ≥ 20%"]
    yy = 2.65
    for m in metrics:
        add_text(s, 10.1, yy, 2.35, 0.35, "• " + m, 11, False, INK)
        yy += 0.55
    add_text(s, 10.1, 5.95, 2.35, 0.4, "阈值待校准", 9, False, MUTED)
    add_notes(s, "冷启动不是从零获客。Oray 有 1 亿+ 用户，按 1% 到 3% 估算，可触达种子是 100 万到 300 万。我们不假设工具用户会自然变成陪伴用户，所以先做 4 周验证。四个场景各找一批人：向日葵的远程协助和 IT 运维、花生壳的 NAS 和内网、蒲公英的门店组网、洋葱头的电商账号。看 D7 和 D30 留存、日均对话轮次、记忆召回、人设一致性、付费意愿，还有产品线调用率。至少两项达标，才进入下一阶段。")

    # ---------- 13. roadmap
    s = content_slide(prs, 13, "ROADMAP · 12", "路线图与门禁", "三个阶段，三个门禁。")
    add_line(s, 1.1, 2.55, 12.2, 2.55, LINE, 3)
    stages = [
        ("阶段 1", "0–6 月", "AI 伙伴", "验证留存、付费、人格保真、工具用户转化", "G1"),
        ("阶段 2", "6–18 月", "Oray AI 入口", "接入向日葵，扩展花生壳/蒲公英/洋葱头 + 社区", "G2"),
        ("阶段 3", "18 月+", "AI 连接生态", "平台化、IP 授权、海外", "G3"),
    ]
    x = 0.9
    for i, (stage, time, title, body, gate) in enumerate(stages):
        color = ORANGE if i == 0 else (TEAL if i == 1 else NAVY)
        add_rect(s, x, 2.35, 0.4, 0.4, color, shape=MSO_SHAPE.OVAL)
        add_text(s, x + 0.6, 2.1, 3.3, 0.3, stage + " · " + time, 12, True, color)
        add_text(s, x + 0.6, 3.0, 3.3, 0.4, title, 16, True, INK)
        add_text(s, x + 0.6, 3.5, 3.3, 1.2, body, 11, False, MUTED)
        add_rect(s, x + 0.6, 4.85, 0.75, 0.35, color)
        add_text(s, x + 0.6, 4.92, 0.75, 0.25, gate, 9, True, WHITE, PP_ALIGN.CENTER)
        x += 4.0
    add_rect(s, 0.7, 5.65, 11.93, 0.9, ORANGE_SOFT)
    add_text(s, 0.95, 5.82, 11.4, 0.55, "G1 指标：D30 ≥ 20% · 付费 ≥ 3% · 记忆召回 ≥ 85% · 人设一致性 ≥ 85 · 产品线调用率 ≥ 20%（假设阈值）", 11, True, ORANGE)
    add_notes(s, "路线图分三段。前六个月只验证一件事：工具用户会不会变成陪伴用户。指标是 D30 留存 20%、付费意愿 3%、记忆召回 85%、人设一致性 85 分、产品线调用率 20%。这些是假设，会在种子里校准。达标，进入阶段 2，接向日葵，再扩展花生壳、蒲公英、洋葱头，做角色社区和 IP 孵化器。再达标，阶段 3 做成 Oray 的 AI 入口。如果阶段 1 不达标，我们不硬撑，把记忆和关系引擎复用到 Oray 的现有产品里。")

    # ---------- 14. resources
    s = content_slide(prs, 14, "ASK · 13", "需要什么资源", "现有核心 3–5 人（估算），阶段 1 补齐到 6–7 人。")
    add_table(
        s, 0.7, 1.95, 11.93, 3.55,
        ["资源", "诉求"],
        [
            ["人", "6–7 人：产品 1、Flutter 2、AI/后端 1、设计 1、运营 1、QA 0.5"],
            ["钱", "¥350 万/年（基准；区间 ¥270–435 万）"],
            ["产品线", "向日葵试点，4–8 周；花生壳第二候选；蒲公英、洋葱头随后复制"],
            ["法务", "子品牌授权、仓库 LICENSE 更新、隐私与内容合规"],
            ["渠道", "应用商店账号、站内导流、品牌/PR"],
        ],
        col_widths=[2.2, 9.73],
        font_size=13,
    )
    add_rect(s, 0.7, 5.85, 11.93, 0.65, LIGHT)
    add_text(s, 0.95, 6.0, 11.4, 0.35, "我们不要公司现在就 all in，只要这一小步。", 14, True, INK)
    add_notes(s, "资源诉求很克制：六到七个人，350 万一年，向日葵做四到八周试点，花生壳第二候选，蒲公英和洋葱头随后复制。法务把子品牌授权、仓库 LICENSE 和内容合规理清。现有核心三到五个人，阶段 1 补齐产品、设计、运营和 QA。我们不要公司现在就 all in，只要这一小步。")

    # ---------- 15. decision
    s = prs.slides.add_slide(prs.slide_layouts[6])
    bg = s.background.fill
    bg.solid()
    bg.fore_color.rgb = NAVY
    add_rect(s, 0, 0, SW, 0.12, ORANGE, shape=MSO_SHAPE.RECTANGLE)
    add_text(s, 0.9, 0.85, 9.0, 0.3, "DECISION · 14", 11, True, ORANGE)
    add_text(s, 0.9, 1.3, 11.5, 0.8, "请批准阶段 1", 38, True, WHITE)
    add_text(s, 0.9, 2.2, 11.5, 0.5, "先批准这一小步，再看下一步。", 18, False, RGBColor(0xCB, 0xD5, 0xE1))
    decisions = [
        ("01", "立项与预算", "6–7 人  ·  ¥350 万/年（基准）"),
        ("02", "向日葵试点", "4–8 周  ·  花生壳第二候选\n蒲公英、洋葱头随后复制"),
        ("03", "6 个月复盘", "达标加注  ·  未达标止损"),
    ]
    x = 0.9
    for num, title, body in decisions:
        add_rect(s, x, 3.35, 3.75, 1.75, RGBColor(0x1E, 0x29, 0x3B))
        add_text(s, x + 0.25, 3.55, 3.2, 0.35, num, 12, True, ORANGE)
        add_text(s, x + 0.25, 3.95, 3.2, 0.4, title, 17, True, WHITE)
        add_text(s, x + 0.25, 4.45, 3.2, 0.5, body, 11, False, RGBColor(0xCB, 0xD5, 0xE1))
        x += 4.0
    add_text(s, 0.9, 6.05, 11.5, 0.5, "谢谢。", 16, True, WHITE)
    add_notes(s, "所以我请公司批三件事：第一，阶段 1 立项和预算，6 到 7 个人、350 万一年；第二，批向日葵做 4 到 8 周试点；第三，6 个月后按门禁复盘，达标加注，不达标止损。伴伴不是从零开始的创业，而是 Oray 在 AI 时代的入口升级。我们不需要现在就 all in，只需要先证明一件事：工具用户，会不会变成陪伴用户。谢谢。")

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    prs.save(out_path)
    print("saved:", out_path)
    print("slides:", len(prs.slides))


if __name__ == "__main__":
    build(os.path.join("docs", "business_plan", "伴伴_路演PPT_v1.pptx"))
