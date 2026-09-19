#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""gen_s2t.py —— 生成简→繁单字映射表 resources/s2t.tsv（§3.3 最简版）。

数据源：OpenCC 的 STCharacters.txt（单字简繁对照，Apache-2.0 —— 自用无碍，
**将来若开源需在许可文件里注明 OpenCC 及其许可**，见 ../SimpleFly_开源可行性评估.md 的约束）。

规则：
  - 一简对多繁（如 签→簽籤）取**第一个**变体。这是「最简版」的既定取舍：
    能读懂、不保证地道，「干/乾/幹」类歧义本来就需要词组级上下文，不在范围内。
  - 只保留「简≠繁」的映射（简繁同形的条目没有意义，还浪费查表时间）。

用法：
    python3 tools/gen_s2t.py [STCharacters.txt 的路径]
    路径缺省时按顺序找 ./STCharacters.txt、/tmp/STCharacters.txt；
    都没有就提示去 OpenCC 仓库下载。
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "resources", "s2t.tsv")


def main():
    src = None
    if len(sys.argv) > 1:
        src = sys.argv[1]
    else:
        for cand in ("STCharacters.txt", "/tmp/STCharacters.txt"):
            if os.path.exists(cand):
                src = cand
                break
    if not src or not os.path.exists(src):
        sys.exit("找不到 STCharacters.txt。先下载：\n"
                 "  curl -L https://raw.githubusercontent.com/BYVoid/OpenCC/master/"
                 "data/dictionary/STCharacters.txt -o /tmp/STCharacters.txt\n"
                 "然后重跑 python3 tools/gen_s2t.py")

    pairs = []
    skipped_same = 0
    with open(src, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) != 2:
                continue
            simp, trads = parts[0], parts[1].split()
            if len(simp) != 1 or not trads or len(trads[0]) != 1:
                continue          # 单字表只收一对一的码位映射
            if simp == trads[0]:
                skipped_same += 1
                continue
            pairs.append((simp, trads[0]))

    pairs.sort()                  # 按 Unicode 码位排序，C 端二分查找直接用
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as out:
        out.write("# SimpleFly 简→繁单字映射（生成自 OpenCC STCharacters.txt，Apache-2.0）\n")
        out.write("# 一简对多繁取第一个变体；简繁同形的条目已剔除。勿手改，重跑本脚本生成。\n")
        for s, t in pairs:
            out.write(f"{s}\t{t}\n")

    print(f"  简→繁映射 {len(pairs)} 对（剔除了 {skipped_same} 个简繁同形）→ {OUT}")


if __name__ == "__main__":
    main()
