#!/usr/bin/env python3
"""用小鹤官方码表 + pypinyin 交叉验证「全拼 -> 小鹤双拼」的键位表。

思路：码表里每个单字都有音码（2 码条目，或 3/4 码条目的前 2 位），
把它和该字的拼音对照，就能反推出韵母键位表，而不必相信任何第三方教程。

用法：
    python3 tools/verify_pinyin.py            # 验证内置表
    python3 tools/verify_pinyin.py --dump     # 额外打印全部不一致样本
"""
import sys
import collections
from pypinyin import pinyin, Style

DICT = "resources/simplefly.dict"

# ---- 待验证的键位表（与 src/pinyin.c 保持一致） -------------------------
INITIAL_MAP = {"zh": "v", "ch": "i", "sh": "u"}

# 按长度降序匹配，长韵母优先
FINALS = [
    ("uang", "l"), ("iang", "l"), ("iong", "s"), ("uai", "k"), ("uan", "r"),
    ("ian", "m"), ("iao", "n"), ("ang", "h"), ("eng", "g"), ("ing", "k"),
    ("ong", "s"), ("ai", "d"), ("ei", "w"), ("ui", "v"), ("ao", "c"),
    ("ou", "z"), ("iu", "q"), ("ie", "p"), ("ue", "t"), ("ve", "t"),
    ("er", "r"), ("an", "j"), ("en", "f"), ("in", "b"), ("un", "y"),
    ("vn", "y"), ("ia", "x"), ("ua", "x"), ("uo", "o"),
    ("a", "a"), ("o", "o"), ("e", "e"), ("i", "i"), ("u", "u"), ("v", "v"),
]

# 零声母音节特例（a/o/e 开头）。key = 全拼，value = 双拼码。
# 之所以要特例而不是算：小鹤对零声母的定义不是「首字母 + 韵母键」，
# 例如 an 就是 an（不是 a+j），ang 却是 ah（不是 ang）。
ZERO_INITIAL = {
    "a": "aa", "o": "oo", "e": "ee",
    "ai": "ai", "ei": "ei", "ao": "ao", "ou": "ou",
    "an": "an", "en": "en", "er": "er",
    "ang": "ah", "eng": "eg",
}


def to_double(py: str):
    """全拼 -> 小鹤双拼码；无法解析返回 None。py 里的 ü 已写成 v。"""
    py = py.replace("ü", "v").lower()
    if not py.isalpha():
        return None
    if py[0] in "aoe":
        return ZERO_INITIAL.get(py)
    for ini in ("zh", "ch", "sh"):
        if py.startswith(ini):
            rest = py[len(ini):]
            for f, k in FINALS:
                if rest == f:
                    return INITIAL_MAP[ini] + k
            return None
    ini, rest = py[0], py[1:]
    if ini in "bpmfdtnlgkhjqxrzcswy":
        k = _final_key(rest)
        return (ini + k) if k else None
    return None


def _final_key(rest: str):
    for f, k in FINALS:
        if rest == f:
            return k
    return None


def load_codes():
    """字 -> {音码集合}"""
    by_char = collections.defaultdict(set)
    with open(DICT, encoding="utf-8") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line or line.startswith("#") or "\t" not in line:
                continue
            code, text = line.split("\t", 1)
            if len(text) != 1 or len(code) > 4:
                continue
            if len(code) >= 2:
                by_char[text].add(code[:2])
    return by_char


def main():
    dump = "--dump" in sys.argv
    by_char = load_codes()
    print(f"单字样本：{len(by_char)} 个")

    ok = bad = skip = 0
    mismatches = []
    for ch, codes in by_char.items():
        py = pinyin(ch, style=Style.NORMAL, errors="ignore")
        if not py or not py[0]:
            skip += 1
            continue
        got = to_double(py[0][0])
        if got is None:
            skip += 1
            continue
        if got in codes:
            ok += 1
        else:
            bad += 1
            mismatches.append((ch, py[0][0], got, sorted(codes)))

    print(f"一致 {ok} / 不一致 {bad} / 跳过 {skip}")
    if mismatches:
        # 按拼音归类，方便一眼看出是哪个韵母的规则错了
        by_py = collections.defaultdict(list)
        for ch, py, got, codes in mismatches:
            by_py[py].append((ch, got, codes))
        print(f"\n不一致共 {len(by_py)} 种拼音：")
        for py in sorted(by_py):
            items = by_py[py]
            sample = "  ".join(f"{c}:算{got}/表{'|'.join(cs)}" for c, got, cs in items[:3])
            print(f"  {py:<8} x{len(items):<4} {sample}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
