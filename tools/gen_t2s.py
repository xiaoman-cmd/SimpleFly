#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""gen_t2s.py —— 生成繁→简单字映射表 resources/t2s.tsv（0.5.6，双向简繁的另一半）。

数据源：OpenCC 的 TSCharacters.txt（单字繁简对照，Apache-2.0 —— 自用无碍，
**将来若开源需在许可文件里注明 OpenCC 及其许可**，见 ../SimpleFly_开源可行性评估.md 的约束）。

规则（与 gen_s2t.py 对称）：
  - 一繁对多简（如 藉→藉借）取**第一个**变体。同一「最简版」取舍：
    能读懂、不保证地道；歧义（乾→干/乾）无上下文无解。
  - 只保留「繁≠简」的映射（同形条目没有意义）。

用法：
    python3 tools/gen_t2s.py [TSCharacters.txt 的路径]
    路径缺省时按顺序找 ./TSCharacters.txt、/tmp/TSCharacters.txt；
    都没有就提示去 OpenCC 仓库下载（raw.githubusercontent.com 直连不通时用
    https://cdn.jsdelivr.net/gh/BYVoid/OpenCC@master/data/dictionary/TSCharacters.txt）。
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "resources", "t2s.tsv")


def main():
    src = None
    if len(sys.argv) > 1:
        src = sys.argv[1]
    else:
        for cand in ("TSCharacters.txt", "/tmp/TSCharacters.txt"):
            if os.path.exists(cand):
                src = cand
                break
    if not src or not os.path.exists(src):
        sys.exit("找不到 TSCharacters.txt。先下载：\n"
                 "  curl -L 'https://cdn.jsdelivr.net/gh/BYVoid/OpenCC@master"
                 "/data/dictionary/TSCharacters.txt' -o /tmp/TSCharacters.txt\n"
                 "然后重跑 python3 tools/gen_t2s.py")

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
            trad, simps = parts[0], parts[1].split()
            if len(trad) != 1 or not simps or len(simps[0]) != 1:
                continue          # 单字表只收一对一的码位映射
            if trad == simps[0]:
                skipped_same += 1
                continue
            pairs.append((trad, simps[0]))

    pairs.sort()                  # 按 Unicode 码位排序，C 端二分查找直接用
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as out:
        out.write("# SimpleFly 繁→简单字映射（生成自 OpenCC TSCharacters.txt，Apache-2.0）\n")
        out.write("# 一繁对多简取第一个变体；繁简同形的条目已剔除。勿手改，重跑本脚本生成。\n")
        for t, s in pairs:
            out.write(f"{t}\t{s}\n")

    print(f"  繁→简映射 {len(pairs)} 对（剔除了 {skipped_same} 个繁简同形）→ {OUT}")


if __name__ == "__main__":
    main()
