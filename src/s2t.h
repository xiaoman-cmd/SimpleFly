/* s2t.h —— 简→繁单字转换（纯 C，无 UI 依赖，可单测）
 *
 * §3.3「最简版」的实现边界（刻意收窄，别在这里加功能）：
 *   - **单字级映射**：一个源码位 → 一个目标码位。一简对多繁/一繁对多简取 OpenCC
 *     STCharacters/TSCharacters.txt 的第一个变体（tools/gen_s2t.py / gen_t2s.py
 *     生成 resources/s2t.tsv 与 t2s.tsv —— 模块本身不关心方向，表给什么转什么）。
 *   - **不做**词组转换、不做一简对多繁消歧（干/乾/幹 无上下文无解）、
 *     不做繁→简反向。最小版的正确预期是「能读懂、不保证地道」。
 *
 * 接口全部 UTF-8 进出。未映射的字符原样直通（含 ASCII、标点、生僻字）。
 */
#ifndef SF_S2T_H
#define SF_S2T_H

#include <stddef.h>

/* 加载映射表（TSV：简<TAB>繁，# 注释，须已按码位排序 —— gen_s2t.py 保证）。
 * 文件不存在 / 为空 → 返回 NULL（转换功能等于没有，不算错误）。 */
typedef struct SFS2T SFS2T;
SFS2T *sf_s2t_load(const char *path);
void   sf_s2t_free(SFS2T *t);
size_t sf_s2t_count(const SFS2T *t);

/* 转换。out 至少 outcap 字节；返回需要的字节数（含 NUL）——
 * 大于 outcap 表示被截断，调用方应重试。in == out 允许（原地）？不允许：
 * 繁体普遍比简体多一字节，原地会写坏，实现里会直接返回 0 拒绝。 */
size_t sf_s2t_convert(const SFS2T *t, const char *in, char *out, size_t outcap);

#endif /* SF_S2T_H */
