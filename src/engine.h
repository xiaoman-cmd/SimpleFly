/* SimpleFly 输入引擎 —— 纯 C，无 UI 依赖，可脱离 InputMethodKit 单独跑测试。
 *
 * 设计取向（对应评估文档 §11「确定性优先」）：
 *   - 码表是确定性的：编码 -> 候选，不做整句解码、不做语言模型。
 *   - 查询 = 前缀匹配，精确匹配排在前，补全候选排在后。
 *   - 码长 4 且命中精确匹配时，前一候选可直接上屏（音形「四键上屏」）。
 */
#ifndef SF_ENGINE_H
#define SF_ENGINE_H

#include <stddef.h>

#define SF_CODE_CAP   8   /* 编码最长 4，留余量 */
#define SF_MAX_CANDS  9   /* 一页候选数，对应数字键 1-9 */

/* 「查编码」一次能列出多少候选。
 * 为什么不是 9：码表里同音字是**各带形码**的（好=hc，但号=hck、浩=hcd、豪=hcw），
 * 所以「精确匹配 hc」只剩 1 个字，查编码必须走**前缀匹配**才能列出同音的一整族，
 * 而这一族动辄几十个（hao 42 个、yi 199 个）。调用方的 SFHit 数组要按这个数开。 */
#define SF_PREFIX_MAX 256

typedef struct SFEngine SFEngine;

typedef struct {
    const char *text;   /* 词条（UTF-8），指向引擎内部，无需释放 */
    int         exact;  /* 1 = 精确匹配（编码 == 输入），0 = 前缀补全 */
} SFHit;

/* 从 TSV 码表加载（每行 `编码<TAB>词条`，文件内顺序即优先级）。
 * 失败返回 NULL，错误信息用 sf_engine_last_error() 取。 */
SFEngine *sf_engine_load(const char *path);

void        sf_engine_free(SFEngine *e);
size_t      sf_engine_size(const SFEngine *e);      /* 总条目数 */
size_t      sf_engine_code_count(const SFEngine *e);/* 不同编码数 */
const char *sf_engine_last_error(void);

/* 输入 code，把候选写进 hits，返回实际个数（<= max）。
 * code 的合法字符集与官方 schema 的 speller.alphabet 一致：[a-z;']，其余字符一律返回 0。
 * include_completion=0 时只返回精确匹配；=1 时在精确匹配之后追加前缀补全候选。
 * （官方 flypy.schema.yaml 里 translator.enable_completion 为 false，即默认关补全。） */
int sf_engine_lookup(const SFEngine *e, const char *code, SFHit *hits,
                     int max, int include_completion);

/* 前缀反查（「查编码」用）：列出**所有编码以 code 开头**的词条，精确匹配排最前。
 * 与 sf_engine_lookup 的两点区别：
 *   1. max 不受 SF_MAX_CANDS 夹取，上限是 SF_PREFIX_MAX（候选窗要一次列出一族同音字）；
 *   2. singles_only 控制收什么：
 *        0 = 单字 + 词语都要；
 *        1 = 只要「单个汉字」（查编码最常用，避免被「好吧 / 毫不」挤下去）；
 *        2 = 只要「词语」（多字词条）。
 *      调用方通常先以 1 收单字、再以 2 收词语，单字排前、词语排后。
 * 返回值 <= max；hits 里的指针指向引擎内部，调用方不要释放。 */
int sf_engine_lookup_prefix(const SFEngine *e, const char *code, SFHit *hits,
                            int max, int singles_only);

/* 是否满足「四键上屏」条件：码长 4，且命中恰好一个精确匹配。
 * 对应官方 flypy.schema.yaml 的 speller.auto_select_pattern: ^;.$|^\w{4}$；
 * 这里额外要求「精确匹配唯一」，有重码时把选择权留给用户。 */
int sf_engine_should_autocommit(const char *code, const SFHit *hits, int n);

/* ---- 反查：词条 -> 编码（「查编码」功能用） ----
 *
 * 码表里同一个词条往往有多个编码（一简 b、二简 bj、三简 bjf、音形全码 bjfy），
 * sf_engine_code_for_text 返回**最长**的那条，也就是「音形全码」——用户问
 * 「这个字怎么打」时要的是它。返回 NULL 表示码表里没有这个词条。
 *
 * sf_engine_codes_for_text 返回全部编码（短的在前），写入 out，返回个数。
 * 返回的指针都指向引擎内部存储，调用方不要释放。 */
const char *sf_engine_code_for_text(const SFEngine *e, const char *text);
int         sf_engine_codes_for_text(const SFEngine *e, const char *text,
                                     const char **out, int max);

#endif /* SF_ENGINE_H */
