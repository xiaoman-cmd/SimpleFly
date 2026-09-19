#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""suggest_phrases.py —— 从打错日志生成短语建议（§3.2 的分析端）。

输入 mislog.tsv（SimpleFly 打错日志，LogMisses 开关产出，格式：时间戳\\t废弃码\\t最终上屏词），
统计最近 N 天里被废弃 ≥ min 次的编码，输出可直接贴进 phrase.txt 的建议行。

用法：
    tools/suggest_phrases.py                       # 用默认路径
    tools/suggest_phrases.py --min 3 --days 14     # 调阈值
    tools/suggest_phrases.py --phrase-file ...     # 排除已有短语（默认读用户的 phrase.txt）

隐私：只读本地文件，不联网。日志本身只在你显式开启 LogMisses 后才产生。
"""
import argparse
import collections
import os
import sys
import time

APPSUPPORT = os.path.expanduser(
    "~/Library/Application Support/SimpleFly")

DEFAULT_LOG = os.path.join(APPSUPPORT, "mislog.tsv")
DEFAULT_PHRASE = os.path.join(APPSUPPORT, "phrase.txt")


def load_log(path, days):
    """读日志，返回 [(code, word)]，只保留最近 days 天的行。"""
    cutoff = time.time() - days * 86400
    rows = []
    if not os.path.exists(path):
        return rows
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) < 2 or not parts[1]:
                continue
            try:
                ts = int(parts[0])
            except ValueError:
                continue
            if ts < cutoff:
                continue
            word = parts[2] if len(parts) > 2 else ""
            rows.append((parts[1], word))
    return rows


def existing_phrase_codes(path):
    """phrase.txt 里已有的编码（= 或 TAB 分隔都认），用于排除建议。"""
    codes = set()
    if not os.path.exists(path):
        return codes
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            for sep in ("=", "\t"):
                if sep in line:
                    codes.add(line.split(sep, 1)[0].strip())
                    break
    return codes


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--log", default=DEFAULT_LOG, help="mislog.tsv 路径")
    ap.add_argument("--phrase-file", default=DEFAULT_PHRASE,
                    help="phrase.txt 路径（排除已有短语）")
    ap.add_argument("--days", type=int, default=30, help="只统计最近 N 天（默认 30）")
    ap.add_argument("--min", type=int, default=5,
                    help="被废弃至少几次才给建议（默认 5）")
    ap.add_argument("--top", type=int, default=20, help="最多输出几条（默认 20）")
    args = ap.parse_args()

    rows = load_log(args.log, args.days)
    if not rows:
        print(f"（{args.log} 里最近 {args.days} 天没有记录 —— "
              f"先 defaults write com.simplefly.inputmethod.SimpleFly LogMisses -bool YES，"
              f"正常打几天字再回来）")
        return 0

    freq = collections.Counter(code for code, _ in rows)
    # 每个废弃码的「最终上屏词」取最常见的非空值
    words = collections.defaultdict(collections.Counter)
    for code, word in rows:
        if word:
            words[code][word] += 1

    have = existing_phrase_codes(args.phrase_file)

    suggestions = []
    for code, n in freq.most_common():
        if n < args.min:
            break
        counter = words[code]
        word = counter.most_common(1)[0][0] if counter else ""
        status = "已存在，忽略" if code in have else None
        suggestions.append((code, n, word, status))

    if not suggestions:
        print(f"最近 {args.days} 天没有任何编码被废弃 ≥ {args.min} 次。手顺很稳。")
        return 0

    print(f"# 以下生成于 {time.strftime('%Y-%m-%d %H:%M')}，"
          f"基于最近 {args.days} 天的打错日志（阈值：废弃 ≥ {args.min} 次）")
    print("# 用法：确认后把没被忽略的行贴进 phrase.txt 即可。")
    for code, n, word, status in suggestions[: args.top]:
        if status:
            print(f"{code}\t废弃 {n} 次，最终上屏「{word}」→ {status}")
        else:
            print(f"{code}\t废弃 {n} 次，最终上屏「{word}」→ 建议：{code}={word}"
                  if word else
                  f"{code}\t废弃 {n} 次，但没记到最终上屏的词 → 想想这个码你想打什么")
    return 0


if __name__ == "__main__":
    sys.exit(main())
