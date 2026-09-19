#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从码表里抽出「非汉字」内容，生成 docs/符号速查.md。

为什么要有这个脚本：
    码表里塞了快符 / 特殊符号 / Emoji 三大类非汉字内容，全是已经能打的东西，
    但码表本身是给人查表用的、没有任何说明，用户根本不知道它们的存在。
    这里按编码前缀分好类、排好版，生成一份能直接看的速查表。
    码表换版本时重跑一次即可（./build.sh --symbols），不要手改生成的 md。

分类口径（按「文本的字符构成」判，不按编码猜）：
    纯汉字（含 CJK 扩展区）→ 不算，本脚本不输出
    含 emoji / 图形符号    → Emoji 与图形符号
    含拉丁字母或数字        → 含字母数字的词条（AA制 / GDP / Excel 这类）
    其余                   → 符号（; 快符、中文标点、of 命名空间里的特殊符号…）
"""
import os
import re
import sys
import collections

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DICT = os.path.join(ROOT, "resources", "simplefly.dict")
OUT = os.path.join(ROOT, "docs", "符号速查.md")

# 汉字 = CJK 基本区 + 扩展 A/B… + 兼容表意文字 + 部首扩展 + 〇
def is_han(ch: str) -> bool:
    o = ord(ch)
    return (0x3400 <= o <= 0x4DBF or 0x4E00 <= o <= 0x9FFF or 0xF900 <= o <= 0xFAFF
            or 0x20000 <= o <= 0x323AF or 0x2E80 <= o <= 0x2EFF or o == 0x3007)

# emoji 与图形符号。区间要放宽到「杂项符号与箭头」整片，只写 1F000-1FAFF 会漏掉
# ⌚ ⏰ ⏳（U+23xx）、⬀ 系列（U+2Bxx）、以及 ○●◎◆◇（U+25xx）这批常用的。
EMOJI = re.compile("[\U0001F000-\U0001FAFF←-⇿⌀-⏿"
                   "─-◿☀-➿⬀-⯿️]")
LATIN = re.compile("[A-Za-z0-9]")
# 微信表情名：码表里是一串 [微笑] [捂脸] 这样的方括号文字，打出来就是字面文本
WXEMOJI = re.compile(r"^\[.+\]$")


def load():
    rows = []
    with open(DICT, encoding="utf-8") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if "\t" not in line:
                continue
            code, text = line.split("\t", 1)
            rows.append((code, text))
    return rows


def classify(rows):
    """先按**编码前缀**归位，再按内容判。

    顺序不能反：内容优先会把几类东西放错地方 ——
      `;x` 是「→」，落在箭头区里会被当成 emoji，快符表就少一条；
      `ofdw`（单位符号）里混了 "nm"，会被当成含字母数字的词条；
      `ofxk` 是「偶发性」这个普通词，会被当成汉字。
    这三处的共同点是「看内容猜类别不可靠」，所以 `;` 快符和 `of` 命名空间按编码认。
    """
    han, emoji, latin, symbol = 0, [], [], []
    quick, ofsym = [], []
    for code, text in rows:
        if len(code) == 2 and code[0] == ";":
            quick.append((code, text))
        elif code.startswith("of") and len(code) in (3, 4):
            # 4 码是符号组本体，3 码是「分类菜单行」（如 ofr →「日大d」，提示下一键）
            ofsym.append((code, text))
        elif text and all(is_han(c) for c in text):
            han += 1
        elif EMOJI.search(text):
            emoji.append((code, text))
        elif LATIN.search(text):
            latin.append((code, text))
        else:
            symbol.append((code, text))
    return han, emoji, latin, symbol, quick, ofsym


def of_labels(symbol):
    """of 命名空间的分类标签。

    码表里有一批「菜单行」：三码 of? 的词条本身就是提示文字，形如
        ofb    标点d        ← 意思是「再按 d → ofbd = 全角标点」
        ofr    日大d        ← 再按 d → ofrd = 日文片假名
    把这些标签抽出来，就能给每个四码符号组一个人类可读的名字。
    """
    labels = {}          # 'ofbd' -> '标点'
    menu = []            # (三码, 标签原文)
    for code, text in symbol:
        if len(code) == 3 and code.startswith("of") and len(text) >= 2:
            menu.append((code, text))
            # 标签末位是字母 → 它就是下一键（「标点d」→ ofbd）。
            # 有的标签没写键位（「括数」），交给调用方按「同前缀下尚未认领的组」补。
            if text[-1].isalpha() and text[-1].isascii():
                labels[code + text[-1]] = text[:-1]
    return labels, menu


def of_groups(ofsym, labels):
    """四码 of?? 的符号组，一组一个编码，内容连成一串展示。"""
    groups = collections.OrderedDict()
    for code, text in ofsym:
        if len(code) == 4:
            groups.setdefault(code, []).append(text)
    return [(code, texts, labels.get(code, ""))
            for code, texts in sorted(groups.items())]


def other_symbols(symbol):
    """既不是 ; 快符、也不在 of 命名空间、也不是微信表情名的符号（中文标点、罗马数字等）。

    硬性要求「一个汉字都不能有」：否则「达·芬奇」「病从口入，祸从口出」这类
    含标点的普通词条会混进来，把符号表冲淡。
    """
    out = []
    for code, text in symbol:
        if code.startswith(";") or code.startswith("of"):
            continue
        if WXEMOJI.match(text):
            continue
        if any(is_han(c) for c in text):
            continue
        if len(text) > 6:            # 长的是俗语/词组，不是符号
            continue
        out.append((code, text))
    return sorted(set(out), key=lambda x: (len(x[0]), x[0]))


def wx_emoji(symbol):
    """微信表情名（[微笑] [捂脸] …）：打出来是字面文本，不是真 emoji 字符。"""
    return sorted(set((c, t) for c, t in symbol if WXEMOJI.match(t)))


def fill_missing_labels(groups, labels, menu):
    """补上「标签里没写键位」的那些组（如 ofk →「括数」，实际编码 ofku）。

    判据：该三码前缀下、还没被认领的四码组。只在前缀下**恰好剩一组**时才补，
    有多个就不猜 —— 猜错了比留空更有害。
    """
    claimed = set(labels)
    for code, _ in menu:
        rest = [g[0] for g in groups if g[0].startswith(code) and g[0] not in claimed]
        if len(rest) != 1:
            continue
        for text in [t for c, t in menu if c == code]:
            if not (text[-1].isalpha() and text[-1].isascii()):
                labels[rest[0]] = text
    return labels


def main():
    if not os.path.exists(DICT):
        sys.exit("找不到码表：%s" % DICT)

    rows = load()
    han, emoji, latin, symbol, quick, ofsym = classify(rows)
    labels, menu = of_labels(ofsym)
    groups = of_groups(ofsym, labels)
    labels = fill_missing_labels(groups, labels, menu)
    groups = of_groups(ofsym, labels)
    quick = sorted(quick, key=lambda x: x[0])
    others = other_symbols(symbol)
    wx = wx_emoji(symbol)

    L = []
    w = L.append
    w("# SimpleFly 符号速查\n")
    w("> 由 `tools/gen_symbols.py` 从 `resources/simplefly.dict` **自动生成**，"
      "码表换版本后重跑 `./build.sh --symbols`。**不要手改本文件**。\n")
    w("码表共 %d 条，其中纯汉字（含扩展区）%d 条；非汉字内容 %d 条，"
      "按类别列在下面。\n" % (len(rows), han, len(rows) - han))
    w("| 类别 | 条数 | 怎么打 |")
    w("|---|---|---|")
    w("| `;` 快符 | %d | `;` + 一个字母，**打满两码自动上屏**，不用按空格 |" % len(quick))
    w("| `of` 特殊符号 | %d 组 / %d 个 | `of` 先出分类菜单，再按菜单末位的字母 |"
      % (len(groups), sum(len(g[1]) for g in groups)))
    w("| Emoji / 图形符号 | %d | 绝大多数挂 `oi` 前缀（`oi` → 😊，往后加字母细分） |" % len(emoji))
    w("| 微信表情名 | %d | 挂 `ow` 前缀，**打出来是 `[微笑]` 这样的字面文本**，不是真 emoji |" % len(wx))
    w("| 含字母数字的词条 | %d | 正常音形码，如 `aav` → AA制、`gdp` → GDP |" % len(latin))
    w("| 其他符号 | %d | 中文标点、罗马数字、带声调字母等 |" % len(others))
    w("")

    # ---- 1. ; 快符 ----
    w("## 1. `;` 快符（打满两码自动上屏）\n")
    w("官方 `auto_select_pattern` 的 `^;.$` 那一半：敲完 `;x` 直接上屏，省一次空格。\n")
    w("⚠️ 单敲 `;` **不会**上屏 —— 它在码表里有 2 个候选（`：` 和 `；`），要按空格选。\n")
    w("| 编码 | 符号 | 编码 | 符号 | 编码 | 符号 |")
    w("|---|---|---|---|---|---|")
    for i in range(0, len(quick), 3):
        chunk = quick[i:i + 3]
        cells = []
        for code, text in chunk:
            cells += ["`%s`" % code, "`%s`" % text]
        while len(cells) < 6:
            cells.append("")
        w("| " + " | ".join(cells) + " |")
    w("")

    # ---- 2. of 特殊符号 ----
    w("## 2. `of` 特殊符号（%d 组 / %d 个）\n" % (len(groups), sum(len(g[1]) for g in groups)))
    w("这是码表里**最有价值也最不为人知**的一块。用法是两级：\n")
    w("```text")
    w("打 of      → 候选窗列出下面这些「分类标签」，每个标签的最后一个字就是下一键")
    w("打 ofrd    → 日文片假名 89 个（ofr 是「日大」，d = 大写的第一个字母）")
    w("打 ofvy    → 注音符号 37 个")
    w("```\n")
    if menu:
        w("分类菜单（打 `of` 看到的就是这些）：\n")
        w("| 三码 | 标签 | → 四码 |")
        w("|---|---|---|")
        for code, text in sorted(menu):
            # 四码反查：标签可能没写键位（「括数」），从认领结果里反推比拼字符串可靠
            # 两种标签形态都要认：写了键位的（「标点d」，labels 里存的是去掉末位的「标点」）
            # 和没写键位的（「括数」，labels 里就是原样）。
            full = next((k for k, v in sorted(labels.items())
                         if k.startswith(code) and (v == text or text == v + k[-1])), None)
            w("| `%s` | %s | `%s` |" % (code, text, full or "—"))
        w("")
    w("各组的实际内容：\n")
    w("| 编码 | 分类 | 个数 | 内容 |")
    w("|---|---|---:|---|")
    for code, texts, name in groups:
        # 个数用**条目数**而不是字符数 —— 有的符号是 2 个字符（如「……」），混着算会偏大
        joined = "".join(texts)
        shown = joined if len(joined) <= 60 else joined[:57] + "…"
        w("| `%s` | %s | %d | %s |" % (code, name or "—", len(texts), shown))
    w("")

    # ---- 3. Emoji ----
    w("## 3. Emoji / 图形符号（%d 条）\n" % len(emoji))
    by_prefix = collections.Counter(c[:2] for c, _ in emoji)
    w("前缀分布：" + "、".join("`%s` %d 条" % (k, v) for k, v in by_prefix.most_common()) + "。\n")
    w("> 候选窗没有翻页，%d 个 emoji 挤在一屏里是看不完的。"
      "真要日常用它，应当走一个**独立的符号面板**（见 `小鹤输入法_优化与扩展建议.md` §2.3），"
      "而不是往主输入路径上加翻页。\n" % len(emoji))
    for prefix, cnt in by_prefix.most_common():
        items = sorted(((c, t) for c, t in emoji if c.startswith(prefix)))
        w("### `%s` 前缀（%d 条）\n" % (prefix, cnt))
        w("| 编码 | 符号 | 编码 | 符号 | 编码 | 符号 |")
        w("|---|---|---|---|---|---|")
        for i in range(0, len(items), 3):
            cells = []
            for code, text in items[i:i + 3]:
                cells += ["`%s`" % code, text]
            while len(cells) < 6:
                cells.append("")
            w("| " + " | ".join(cells) + " |")
        w("")

    # ---- 4. 含字母数字 ----
    w("## 4. 含字母数字的词条（%d 条）\n" % len(latin))
    w("正常音形码，跟汉字一样打。\n")
    w("| 编码 | 词条 | 编码 | 词条 |")
    w("|---|---|---|---|")
    items = sorted(set(latin), key=lambda x: x[0])
    for i in range(0, len(items), 2):
        cells = []
        for code, text in items[i:i + 2]:
            cells += ["`%s`" % code, text]
        while len(cells) < 4:
            cells.append("")
        w("| " + " | ".join(cells) + " |")
    w("")

    # ---- 5. 微信表情名 ----
    w("## 5. 微信表情名（%d 条）\n" % len(wx))
    w("挂 `ow` 前缀。⚠️ 打出来的是 `[微笑]` 这种**中括号字面文本**，不是真正的 emoji 字符 —— "
      "在微信里会被自动渲染成表情，在其他应用里就是方括号文字。\n")
    w("| 编码 | 文本 | 编码 | 文本 | 编码 | 文本 |")
    w("|---|---|---|---|---|---|")
    for i in range(0, len(wx), 3):
        cells = []
        for code, text in wx[i:i + 3]:
            cells += ["`%s`" % code, "`%s`" % text]
        while len(cells) < 6:
            cells.append("")
        w("| " + " | ".join(cells) + " |")
    w("")

    # ---- 6. 其他符号 ----
    w("## 6. 其他符号（%d 条）\n" % len(others))
    w("中文标点、罗马数字、带声调的字母等。含汉字的普通词条（含标点也一样）不在这里。\n")
    w("| 编码 | 符号 | 编码 | 符号 | 编码 | 符号 |")
    w("|---|---|---|---|---|---|")
    for i in range(0, len(others), 3):
        cells = []
        for code, text in others[i:i + 3]:
            cells += ["`%s`" % code, "`%s`" % text]
        while len(cells) < 6:
            cells.append("")
        w("| " + " | ".join(cells) + " |")
    w("")

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as fh:
        fh.write("\n".join(L))
    print("已生成 %s" % OUT)
    print("  纯汉字 %d / ; 快符 %d / of 符号组 %d / emoji %d / 微信表情名 %d / "
          "字母数字 %d / 其他符号 %d"
          % (han, len(quick), len(groups), len(emoji), len(wx), len(latin), len(others)))


if __name__ == "__main__":
    main()
