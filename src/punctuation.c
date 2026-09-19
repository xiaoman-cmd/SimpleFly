#include "punctuation.h"
#include <string.h>

/* ------------------------------------------------------------------ *
 * 数据表：逐条对应 Rime 官方 punctuation.yaml。
 * cn  = half_shape 段（中文标点，默认生效的那套）
 * full= full_shape 段（全角）
 * ascii_style 段全部是原样输出，所以不建表，在 lookup 里直接返回单字符。
 *
 * 多候选用 \x1f 连接，顺序即 Rime 里的候选顺序（第一个是首选）。
 * ------------------------------------------------------------------ */

#define PAIR 0x01

typedef struct {
    unsigned char key;
    const char *cn;
    const char *full;
    unsigned char flags;
} SFPunctEntry;

static const SFPunctEntry kEntries[] = {
    { ',',  "，",                              "，",                             0 },
    { '.',  "。",                              "。",                             0 },
    { '<',  "《\x1f〈\x1f«\x1f‹",               "《\x1f〈\x1f«\x1f‹",              0 },
    { '>',  "》\x1f〉\x1f»\x1f›",               "》\x1f〉\x1f»\x1f›",              0 },
    { '/',  "、\x1f/\x1f／\x1f÷",               "／\x1f÷",                        0 },
    { '?',  "？",                              "？",                             0 },
    { ';',  "；",                              "；",                             0 },
    { ':',  "：",                              "：",                             0 },
    { '\'', "‘\x1f’",                          "‘\x1f’",                         PAIR },
    { '"',  "“\x1f”",                          "“\x1f”",                         PAIR },
    { '\\', "、\x1f\\\x1f＼",                   "、\x1f＼",                       0 },
    { '|',  "·\x1f|\x1f｜\x1f§\x1f¦",           "·\x1f｜\x1f§\x1f¦",              0 },
    { '`',  "`",                               "｀",                             0 },
    { '~',  "~\x1f～",                          "～",                             0 },
    { '!',  "！",                              "！",                             0 },
    { '@',  "@",                               "＠\x1f☯",                        0 },
    { '#',  "#",                               "＃\x1f⌘",                        0 },
    { '%',  "%\x1f％\x1f°\x1f℃",                "％\x1f°\x1f℃",                   0 },
    { '$',  "￥\x1f$\x1f€\x1f£\x1f¥\x1f¢\x1f¤",  "￥\x1f$\x1f€\x1f£\x1f¥\x1f¢\x1f¤", 0 },
    { '^',  "……",                              "……",                             0 },
    { '&',  "&",                               "＆",                             0 },
    { '*',  "*\x1f＊\x1f·\x1f・\x1f×\x1f※\x1f❂", "＊\x1f·\x1f・\x1f×\x1f※\x1f❂",    0 },
    { '(',  "（",                              "（",                             0 },
    { ')',  "）",                              "）",                             0 },
    { '-',  "-",                               "－",                             0 },
    { '_',  "——",                              "——",                             0 },
    { '+',  "+",                               "＋",                             0 },
    { '=',  "=",                               "＝",                             0 },
    { '[',  "「\x1f【\x1f〔\x1f［",               "「\x1f【\x1f〔\x1f［",              0 },
    { ']',  "」\x1f】\x1f〕\x1f］",               "」\x1f】\x1f〕\x1f］",              0 },
    { '{',  "『\x1f〖\x1f｛",                     "『\x1f〖\x1f｛",                    0 },
    { '}',  "』\x1f〗\x1f｝",                     "』\x1f〗\x1f｝",                    0 },
    /* 空格只在全角模式下接管：半角/中文模式下空格是「上屏首选」，绝不能落到表里。
     * cn 故意留 NULL —— sf_punct_lookup 返回 NULL，调用方按「表里没有」处理，正好放行。 */
    { ' ',  NULL,                              "　",                             0 },
};

static const size_t kEntryCount = sizeof(kEntries) / sizeof(kEntries[0]);

const char *sf_punct_lookup(SFPunctStyle style, unsigned char key, int *pair)
{
    if (pair) *pair = 0;

    /* ascii_style：整段都是原样输出，等价于「查得到、只有一个候选就是它自己」。
     * 排除空格（0x20）—— 空格是上屏键，由控制器专门处理，标点表不接管。 */
    if (style == SF_PUNCT_EN) {
        static char ascii_buf[2];
        if (key <= 0x20 || key >= 0x7f) return NULL;
        ascii_buf[0] = (char)key;
        ascii_buf[1] = '\0';
        return ascii_buf;
    }

    for (size_t i = 0; i < kEntryCount; i++) {
        if (kEntries[i].key != key) continue;
        if (pair && (kEntries[i].flags & PAIR)) *pair = 1;
        return (style == SF_PUNCT_FULL) ? kEntries[i].full : kEntries[i].cn;
    }
    return NULL;
}

int sf_punct_count(const char *cands)
{
    if (!cands || !*cands) return 0;
    int n = 1;
    for (const char *p = cands; *p; p++)
        if (*p == SF_PUNCT_SEP) n++;
    return n;
}

/* 定位第 n 段的起始位置 */
static const char *seg_start(const char *cands, int n)
{
    const char *p = cands;
    while (n-- > 0) {
        p = strchr(p, SF_PUNCT_SEP);
        if (!p) return NULL;
        p++;
    }
    return p;
}

const char *sf_punct_nth(const char *cands, int n, size_t *len)
{
    if (!cands || n < 0 || n >= sf_punct_count(cands)) {
        if (len) *len = 0;
        return NULL;
    }
    const char *p = seg_start(cands, n);
    if (!p) { if (len) *len = 0; return NULL; }
    const char *sep = strchr(p, SF_PUNCT_SEP);
    if (len) *len = sep ? (size_t)(sep - p) : strlen(p);
    return p;
}

const char *sf_punct_pair(const char *cands, int n, size_t *len)
{
    return sf_punct_nth(cands, n & 1, len);   /* 成对引号固定两段，按奇偶交替 */
}

const char *sf_punct_style_name(SFPunctStyle style)
{
    switch (style) {
        case SF_PUNCT_CN:   return "中文标点";
        case SF_PUNCT_EN:   return "英文标点";
        case SF_PUNCT_FULL: return "全角";
    }
    return "?";
}
