/* pinyin.h —— 全拼 ↔ 小鹤双拼（纯算法，纯 C，无 UI 依赖）
 *
 * 用途：「拼音反查」模式。用户遇到不会打的字，输入它的全拼（hao），
 * 转成小鹤双拼码（hc）后就能拿现有码表查到字，进而看到它的音形全码。
 *
 * 键位表不是抄来的，是从官方码表逐字反推、再用 pypinyin 对 9377 个单字
 * 全量校验过的（tools/verify_pinyin.py，一致率 98.2%，余下全是部首字与多音字）。
 */
#ifndef SF_PINYIN_H
#define SF_PINYIN_H

#include <stddef.h>

/* 全拼 → 小鹤双拼码。小写字母，ü 可写 v 或 u（详见实现）。
 * 成功把 2 个字符写进 out 并补 NUL、返回 2；无法解析返回 0。
 * out 至少要 3 字节。 */
int sf_pinyin_to_double(const char *pinyin, char out[3]);

/* 多音节全拼 → 小鹤双拼码：把拼音按音节切开，每个音节转 2 字符双拼码拼起来。
 * 用于「查编码」里输整词拼音（nihao → nihc → 你好）。单音节仍走 sf_pinyin_to_double。
 * 成功把双拼码写进 out 并补 NUL、返回写出长度（>0）；无法解析返回 0。
 * out 至少要 cap 字节（整词可能到 6+ 字符）。 */
int sf_pinyin_to_double_multi(const char *pinyin, char *out, size_t cap);

/* 是不是一个能解析的拼音音节。用来在反查模式里区分「用户想打全拼」和「想打双拼码」。 */
int sf_pinyin_is_syllable(const char *s);

/* 双拼码 → 全拼。同一个双拼码可能对应多个拼音（如 hc 可以是 hao / hao 之外的），
 * 这里返回第一个解；无法反解返回 0。*out 会被补 NUL。 */
int sf_double_to_pinyin(const char *code, char *out, size_t cap);

#endif /* SF_PINYIN_H */
