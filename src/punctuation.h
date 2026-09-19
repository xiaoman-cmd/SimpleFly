/* punctuation.h —— 标点符号映射（数据源：Rime 官方 punctuation.yaml）
 *
 * Rime 的 punctuator 有三套表，由两个开关选择：
 *   full_shape 关 + ascii_punct 关  →  half_shape（中文标点，默认）
 *   full_shape 关 + ascii_punct 开  →  ascii_style（英文标点，原样输出）
 *   full_shape 开                    →  full_shape（全角）
 * 对应官方 flypy.schema.yaml 的 switches: full_shape / ascii_punct。
 *
 * 语义与 Rime 一致：
 *   候选只有一个  → 直接上屏（例如 "," → "，"）
 *   候选有多个    → 弹候选窗让用户选（例如 "[" → 「【〔［）
 *   带 pair 标记  → 成对引号，左右交替输出（‘’ / “”），状态由调用方维护
 *
 * 纯 C，无 UI 依赖，可脱离 InputMethodKit 单测。
 */
#ifndef SF_PUNCTUATION_H
#define SF_PUNCTUATION_H

#include <stddef.h>

/* 候选分隔符（ASCII Unit Separator），与码表 TSV 的 \t 区分开 */
#define SF_PUNCT_SEP '\x1f'

typedef enum {
    SF_PUNCT_CN   = 0,   /* 中文标点（Rime half_shape）—— 默认 */
    SF_PUNCT_EN   = 1,   /* 英文标点（Rime ascii_style）—— 全部原样 */
    SF_PUNCT_FULL = 2,   /* 全角（Rime full_shape） */
} SFPunctStyle;

/* 查询某个 ASCII 键在当前风格下的候选串。
 * 返回 NULL 表示「表里没有这个键」，调用方应原样输出该字符。
 * *pair（可传 NULL）返回非 0 表示这是成对引号，需要左右交替。 */
const char *sf_punct_lookup(SFPunctStyle style, unsigned char key, int *pair);

/* 候选个数（段数）。cands 为 NULL 返回 0。 */
int sf_punct_count(const char *cands);

/* 取第 n 段（0 开始）的起始指针，*len 返回该段字节数。返回 NULL 表示越界。 */
const char *sf_punct_nth(const char *cands, int n, size_t *len);

/* 成对引号的第 n 次输出（n 从 0 开始）：0→左，1→右，2→左 …… */
const char *sf_punct_pair(const char *cands, int n, size_t *len);

/* 便于日志与调试 */
const char *sf_punct_style_name(SFPunctStyle style);

#endif /* SF_PUNCTUATION_H */
