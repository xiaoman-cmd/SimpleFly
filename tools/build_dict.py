#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把小鹤音形（Rime dict.yaml 文本版）合并成引擎用的单表 TSV。

输入：rime-flypy 仓库的 flypy/ 目录
输出：simplefly.dict，每行 `编码<TAB>词条`，文件内顺序即优先级。

用法：
  python3 tools/build_dict.py <flypy目录> -o resources/simplefly.dict
"""

import argparse
import os
import sys
from collections import Counter

# 官方 16 分类，按优先级从高到低排列（先出现的在同码重码时排前面）
CATEGORIES = [
    ("flypy.full.top.dict.yaml",        "置顶词"),
    ("flypy.primary.dict.yaml",         "首选字词"),
    ("flypy.secondary.dict.yaml",       "次选字词"),
    ("flypy.three.dict.yaml",           "三码填空"),
    ("flypy.primary.short.word.dict.yaml", "一简次选"),
    ("flypy.secondary.short.code.dict.yaml", "二简次选"),
    ("flypy.full.char.dict.yaml",       "全码字"),
    ("flypy.full.dict.yaml",            "全码词"),
    ("flypy.fast.symbols.dict.yaml",    "快符"),
    ("flypy.symbols.dict.yaml",         "符号"),
    ("flypy.emoji.dict.yaml",           "表情"),
    ("flypy.wechat.dict.yaml",          "微信表情"),
    ("flypy.web.dict.yaml",             "网站直达"),
    ("flypy.whimsicality.dict.yaml",    "随心所欲"),
]


def parse_dict_yaml(path):
    """返回 [(text, code), ...]，保持文件内原始顺序（= 官方优先级）。"""
    out = []
    in_header = False
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            if line.startswith("---"):
                in_header = True
                continue
            if in_header:
                if line.startswith("..."):
                    in_header = False
                continue
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) < 2:
                continue
            text, code = parts[0].strip(), parts[1].strip()
            if not text or not code:
                continue
            out.append((text, code))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src", help="rime-flypy 的 flypy/ 目录")
    ap.add_argument("-o", "--out", default="resources/simplefly.dict")
    args = ap.parse_args()

    merged = []          # (code, text)
    seen = set()         # (code, text) 去重
    stats = []

    for fname, label in CATEGORIES:
        path = os.path.join(args.src, fname)
        if not os.path.exists(path):
            print(f"  ! 缺少 {fname}，跳过", file=sys.stderr)
            continue
        rows = parse_dict_yaml(path)
        kept = 0
        for text, code in rows:
            key = (code, text)
            if key in seen:
                continue
            seen.add(key)
            merged.append((code, text))
            kept += 1
        stats.append((label, fname, len(rows), kept))

    # 稳定排序：先按编码字典序，同码内保持上面的优先级顺序
    merged.sort(key=lambda x: x[0])

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        for code, text in merged:
            fh.write(f"{code}\t{text}\n")

    codes = Counter(c for c, _ in merged)
    lens = Counter(len(c) for c, _ in merged)
    dup = sum(1 for c, n in codes.items() if n > 1)

    print(f"{'分类':<12}{'文件':<40}{'原始':>8}{'收录':>8}")
    for label, fname, raw, kept in stats:
        print(f"{label:<12}{fname:<40}{raw:>8}{kept:>8}")
    print("-" * 70)
    print(f"总条目 {len(merged)}  去重后 {len(seen)}")
    print(f"不同编码 {len(codes)}  其中重码编码 {dup} 个")
    print("码长分布: " + "  ".join(f"{k}码={lens[k]}" for k in sorted(lens)))
    print(f"最长编码 {max(len(c) for c, _ in merged)}  字符集 {''.join(sorted({ch for c, _ in merged for ch in c}))}")
    print(f"写出 {args.out}")
    print("样例前 5 行:")
    with open(args.out, encoding="utf-8") as fh:
        for _ in range(5):
            print("  " + fh.readline().rstrip())


if __name__ == "__main__":
    main()
