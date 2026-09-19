/* punct_test.c —— 标点模块单测
 *
 * 编译：
 *   clang -O2 -Wall -Wextra src/punctuation.c tools/punct_test.c -o /tmp/punct_test
 * 运行：
 *   /tmp/punct_test            跑断言
 *   /tmp/punct_test --dump     打印全表（人工对照 punctuation.yaml）
 */
#include "../src/punctuation.h"

#include <stdio.h>
#include <string.h>

static int g_pass = 0;
static int g_fail = 0;

#define CHECK(cond, fmt, ...) do {                                    \
    if (cond) { g_pass++; printf("  \xe2\x9c\x93 " fmt "\n", ##__VA_ARGS__); }  \
    else      { g_fail++; printf("  \xe2\x9c\x97 " fmt "\n", ##__VA_ARGS__); }  \
} while (0)

/* 把单段候选取出来比较（段内不含 \x1f） */
static int one_is(SFPunctStyle st, unsigned char key, const char *want)
{
    int pair = 0;
    const char *c = sf_punct_lookup(st, key, &pair);
    if (!c) return 0;
    if (sf_punct_count(c) != 1) return 0;
    size_t len = 0;
    const char *s = sf_punct_nth(c, 0, &len);
    return s && len == strlen(want) && memcmp(s, want, len) == 0;
}

/* 第 n 段是否等于 want */
static int nth_is(SFPunctStyle st, unsigned char key, int n, const char *want)
{
    const char *c = sf_punct_lookup(st, key, NULL);
    if (!c) return 0;
    size_t len = 0;
    const char *s = sf_punct_nth(c, n, &len);
    return s && len == strlen(want) && memcmp(s, want, len) == 0;
}

static void test_single(void)
{
    puts("== 单候选：直接上屏 ==");
    CHECK(one_is(SF_PUNCT_CN, ',', "，"),    "中文标点 , → ，");
    CHECK(one_is(SF_PUNCT_CN, '.', "。"),    "中文标点 . → 。");
    CHECK(one_is(SF_PUNCT_CN, '?', "？"),    "中文标点 ? → ？");
    CHECK(one_is(SF_PUNCT_CN, ':', "："),    "中文标点 : → ：");
    CHECK(one_is(SF_PUNCT_CN, '!', "！"),    "中文标点 ! → ！");
    CHECK(one_is(SF_PUNCT_CN, '(', "（"),    "中文标点 ( → （");
    CHECK(one_is(SF_PUNCT_CN, ')', "）"),    "中文标点 ) → ）");
    CHECK(one_is(SF_PUNCT_CN, '^', "……"),   "中文标点 ^ → ……");
    CHECK(one_is(SF_PUNCT_CN, '_', "——"),   "中文标点 _ → ——");
}

static void test_multi(void)
{
    puts("\n== 多候选：弹候选窗 ==");
    const char *c = sf_punct_lookup(SF_PUNCT_CN, '[', NULL);
    CHECK(c && sf_punct_count(c) == 4, "中文标点 [ 有 4 个候选");
    CHECK(nth_is(SF_PUNCT_CN, '[', 0, "「"), "  [ 首选 = 「");
    CHECK(nth_is(SF_PUNCT_CN, '[', 1, "【"), "  [ 次选 = 【");
    CHECK(nth_is(SF_PUNCT_CN, '[', 2, "〔"), "  [ 第三 = 〔");
    CHECK(nth_is(SF_PUNCT_CN, '[', 3, "［"), "  [ 第四 = ［");

    CHECK(nth_is(SF_PUNCT_CN, ']', 0, "」"), "  ] 首选 = 」");
    CHECK(nth_is(SF_PUNCT_CN, '>', 0, "》"), "  > 首选 = 》");
    CHECK(nth_is(SF_PUNCT_CN, '<', 1, "〈"), "  < 次选 = 〈");

    c = sf_punct_lookup(SF_PUNCT_CN, '$', NULL);
    CHECK(c && sf_punct_count(c) == 7, "$ 有 7 个候选（￥ $ € £ ¥ ¢ ¤）");
    CHECK(nth_is(SF_PUNCT_CN, '$', 0, "￥"), "  $ 首选 = ￥");
    CHECK(nth_is(SF_PUNCT_CN, '$', 3, "£"), "  $ 第四 = £");

    c = sf_punct_lookup(SF_PUNCT_CN, '*', NULL);
    CHECK(c && sf_punct_count(c) == 7, "* 有 7 个候选");
    CHECK(nth_is(SF_PUNCT_CN, '*', 4, "×"), "  * 第五 = ×");

    c = sf_punct_lookup(SF_PUNCT_CN, '/', NULL);
    CHECK(c && sf_punct_count(c) == 4, "中文标点 / 有 4 个候选（、 / ／ ÷）");
    CHECK(nth_is(SF_PUNCT_CN, '/', 0, "、"), "  / 首选 = 、");
}

static void test_pair(void)
{
    puts("\n== 成对引号：左右交替 ==");
    int pair = 0;
    const char *c = sf_punct_lookup(SF_PUNCT_CN, '"', &pair);
    CHECK(c && pair == 1, "双引号带 pair 标记");
    CHECK(sf_punct_count(c) == 2, "双引号 2 段");
    size_t len = 0;
    const char *l = sf_punct_pair(c, 0, &len);
    CHECK(len == 3 && memcmp(l, "“", 3) == 0, "  第 0 次 = 左引号 “");
    const char *r = sf_punct_pair(c, 1, &len);
    CHECK(len == 3 && memcmp(r, "”", 3) == 0, "  第 1 次 = 右引号 ”");
    const char *l2 = sf_punct_pair(c, 2, &len);
    CHECK(l2 == l, "  第 2 次又回到左引号");

    pair = 0;
    c = sf_punct_lookup(SF_PUNCT_CN, '\'', &pair);
    CHECK(c && pair == 1, "单引号带 pair 标记");
    const char *sl = sf_punct_pair(c, 0, &len);
    CHECK(len == 3 && memcmp(sl, "‘", 3) == 0, "  第 0 次 = ‘");
    const char *sr = sf_punct_pair(c, 1, &len);
    CHECK(len == 3 && memcmp(sr, "’", 3) == 0, "  第 1 次 = ’");
}

static void test_ascii(void)
{
    puts("\n== 英文标点：全部原样 ==");
    CHECK(one_is(SF_PUNCT_EN, ',', ","), "英文标点 , → ,");
    CHECK(one_is(SF_PUNCT_EN, '.', "."), "英文标点 . → .");
    CHECK(one_is(SF_PUNCT_EN, '?', "?"), "英文标点 ? → ?");
    CHECK(one_is(SF_PUNCT_EN, '[', "["), "英文标点 [ → [");
    CHECK(one_is(SF_PUNCT_EN, '^', "^"), "英文标点 ^ → ^");
    CHECK(one_is(SF_PUNCT_EN, '$', "$"), "英文标点 $ → $");
    int pair = 1;
    sf_punct_lookup(SF_PUNCT_EN, '"', &pair);
    CHECK(pair == 0, "英文标点下引号不成对");
}

static void test_full(void)
{
    puts("\n== 全角 ==");
    CHECK(one_is(SF_PUNCT_FULL, '~', "～"), "全角 ~ → ～");
    CHECK(one_is(SF_PUNCT_FULL, '-', "－"), "全角 - → －");
    CHECK(one_is(SF_PUNCT_FULL, '+', "＋"), "全角 + → ＋");
    CHECK(one_is(SF_PUNCT_FULL, '=', "＝"), "全角 = → ＝");
    CHECK(one_is(SF_PUNCT_FULL, '`', "｀"), "全角 ` → ｀");
    CHECK(one_is(SF_PUNCT_FULL, '&', "＆"), "全角 & → ＆");
    CHECK(nth_is(SF_PUNCT_FULL, '/', 0, "／"), "全角 / 首选 = ／（与中文标点的「、」不同）");
    CHECK(nth_is(SF_PUNCT_FULL, '@', 1, "☯"), "全角 @ 次选 = ☯");
    CHECK(nth_is(SF_PUNCT_FULL, '#', 1, "⌘"), "全角 # 次选 = ⌘");
    CHECK(nth_is(SF_PUNCT_FULL, '\\', 0, "、"), "全角 \\ 首选 = 、");
    CHECK(one_is(SF_PUNCT_FULL, ' ', "　"), "全角 空格 → 全角空格（半角模式下空格不在表里）");
}

static void test_edge(void)
{
    puts("\n== 边界 ==");
    CHECK(sf_punct_lookup(SF_PUNCT_CN, 'a', NULL) == NULL, "字母 a 不在表里（走编码）");
    CHECK(sf_punct_lookup(SF_PUNCT_CN, 'Z', NULL) == NULL, "大写 Z 不在表里");
    CHECK(sf_punct_lookup(SF_PUNCT_CN, ' ', NULL) == NULL, "空格不在表里（空格是上屏键）");
    CHECK(sf_punct_lookup(SF_PUNCT_CN, ';', NULL) != NULL, "分号在表里（虽然实际被 speller 抢）");
    CHECK(sf_punct_lookup(SF_PUNCT_EN, ' ', NULL) == NULL, "英文标点：空格不处理");
    CHECK(sf_punct_count(NULL) == 0, "count(NULL) = 0");
    CHECK(sf_punct_nth(NULL, 0, NULL) == NULL, "nth(NULL) = NULL");
    const char *c = sf_punct_lookup(SF_PUNCT_CN, ',', NULL);
    size_t len = 99;
    CHECK(sf_punct_nth(c, 5, &len) == NULL && len == 0, "越界取段返回 NULL 且长度清零");
}

static void dump(void)
{
    const SFPunctStyle styles[] = { SF_PUNCT_CN, SF_PUNCT_EN, SF_PUNCT_FULL };
    const char *keys =
        ",.<>/?;:'\"\\|`~!@#%$^&*()-_+=[ ]{}" " ";
    for (int si = 0; si < 3; si++) {
        printf("\n########## %s ##########\n", sf_punct_style_name(styles[si]));
        for (const char *k = keys; *k; k++) {
            if (*k == ' ') continue;
            int pair = 0;
            const char *c = sf_punct_lookup(styles[si], (unsigned char)*k, &pair);
            if (!c) continue;
            printf("  %-3c → ", *k);
            int n = sf_punct_count(c);
            for (int i = 0; i < n; i++) {
                size_t len = 0;
                const char *s = sf_punct_nth(c, i, &len);
                printf("%.*s%s", (int)len, s, i + 1 < n ? " | " : "");
            }
            if (pair) printf("   [成对]");
            printf("\n");
        }
    }
}

int main(int argc, char **argv)
{
    if (argc > 1 && strcmp(argv[1], "--dump") == 0) { dump(); return 0; }

    puts("===== 标点模块单测 =====");
    test_single();
    test_multi();
    test_pair();
    test_ascii();
    test_full();
    test_edge();
    printf("\n===== %d 通过 / %d 失败 =====\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
