/* s2t.c —— 简→繁单字转换。数据结构与取舍见 s2t.h。
 *
 * 实现：表加载时把 UTF-8 解成 UTF-32 码位数组（已排序），转换时逐码点二分查找。
 * UTF-8 的解码/编码只用到 3 字节以内的分支（CJK 全在 BMP 内），刻意不写通用
 * 4 字节分支 —— 表里只有 BMP 码位，遇到 4 字节序列直通。
 */
#include "s2t.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    uint32_t from;   /* 简体码位 */
    uint32_t to;     /* 繁体码位 */
} Pair;

struct SFS2T {
    Pair  *pairs;
    size_t n;
};

/* ---- UTF-8 ↔ 码位（只处理 BMP 内的序列，4 字节直通） ---- */

/* 解一个码点，返回消耗的字节数；非法返回 0。
 * 完整支持 1–4 字节：OpenCC 表里有 1,169 条 CJK 扩展区（BMP 外）的映射，
 * 只认 BMP 会丢掉三成表。非法序列当孤立字节直通（返回 1、*cp 收 0）。 */
static size_t utf8_decode(const char *s, size_t len, uint32_t *cp)
{
    const unsigned char *p = (const unsigned char *)s;
    if (len == 0 || !p[0]) return 0;
    if (p[0] < 0x80) { *cp = p[0]; return 1; }
    if ((p[0] & 0xE0) == 0xC0 && len >= 2) {
        *cp = ((uint32_t)(p[0] & 0x1F) << 6) | (p[1] & 0x3F);
        return 2;
    }
    if ((p[0] & 0xF0) == 0xE0 && len >= 3) {
        *cp = ((uint32_t)(p[0] & 0x0F) << 12) |
              ((uint32_t)(p[1] & 0x3F) << 6) | (p[2] & 0x3F);
        return 3;
    }
    if ((p[0] & 0xF8) == 0xF0 && len >= 4) {
        *cp = ((uint32_t)(p[0] & 0x07) << 18) |
              ((uint32_t)(p[1] & 0x3F) << 12) |
              ((uint32_t)(p[2] & 0x3F) << 6) | (p[3] & 0x3F);
        return 4;
    }
    *cp = 0;
    return 1;
}

static size_t utf8_encode(uint32_t cp, char *out)
{
    if (cp < 0x80) { out[0] = (char)cp; return 1; }
    if (cp < 0x800) {
        out[0] = (char)(0xC0 | (cp >> 6));
        out[1] = (char)(0x80 | (cp & 0x3F));
        return 2;
    }
    if (cp < 0x10000) {
        out[0] = (char)(0xE0 | (cp >> 12));
        out[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
        out[2] = (char)(0x80 | (cp & 0x3F));
        return 3;
    }
    out[0] = (char)(0xF0 | (cp >> 18));
    out[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
    out[2] = (char)(0x80 | ((cp >> 6) & 0x3F));
    out[3] = (char)(0x80 | (cp & 0x3F));
    return 4;
}

/* ---- 表 ---- */

SFS2T *sf_s2t_load(const char *path)
{
    if (!path) return NULL;
    FILE *fh = fopen(path, "rb");
    if (!fh) return NULL;

    SFS2T *t = (SFS2T *)calloc(1, sizeof *t);
    if (!t) { fclose(fh); return NULL; }

    size_t cap = 0;
    char line[64];
    while (fgets(line, sizeof line, fh)) {
        char *nl = strchr(line, '\n');
        if (nl) *nl = '\0';
        if (!line[0] || line[0] == '#') continue;
        char *tab = strchr(line, '\t');
        if (!tab) continue;
        *tab = '\0';
        const char *trad = tab + 1;

        uint32_t from = 0, to = 0;
        uint32_t cp;
        size_t used = utf8_decode(line, tab - line, &cp);
        if (used && cp) from = cp;
        used = utf8_decode(trad, strlen(trad), &cp);
        if (used && cp) to = cp;
        if (!from || !to) continue;

        if (t->n == cap) {
            cap = cap ? cap * 2 : 512;
            Pair *np = (Pair *)realloc(t->pairs, cap * sizeof *np);
            if (!np) break;
            t->pairs = np;
        }
        t->pairs[t->n].from = from;
        t->pairs[t->n].to   = to;
        t->n++;
    }
    fclose(fh);

    if (t->n == 0) { sf_s2t_free(t); return NULL; }
    return t;
}

void sf_s2t_free(SFS2T *t)
{
    if (!t) return;
    free(t->pairs);
    free(t);
}

size_t sf_s2t_count(const SFS2T *t) { return t ? t->n : 0; }

/* 查映射；没有返回 0 */
static uint32_t lookup(const SFS2T *t, uint32_t cp)
{
    size_t lo = 0, hi = t->n;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        if (t->pairs[mid].from < cp) lo = mid + 1;
        else                         hi = mid;
    }
    if (lo < t->n && t->pairs[lo].from == cp) return t->pairs[lo].to;
    return 0;
}

size_t sf_s2t_convert(const SFS2T *t, const char *in, char *out, size_t outcap)
{
    if (!t || !in || !out || in == out) return 0;   /* 原地转换会写坏，拒绝 */

    size_t need = 1;                 /* 留给 NUL */
    const char *p = in;
    size_t left = strlen(in);
    size_t w = 0;
    int truncated = 0;

    while (left > 0) {
        uint32_t cp = 0;
        size_t used = utf8_decode(p, left, &cp);
        if (used == 0) break;
        p += used; left -= used;

        uint32_t mapped = cp ? lookup(t, cp) : 0;
        if (!mapped) mapped = cp;    /* 无映射 / 非法字节 → 直通 */

        char buf[4];
        size_t len = utf8_encode(mapped, buf);
        need += len;
        if (w + len < outcap) { memcpy(out + w, buf, len); w += len; }
        else truncated = 1;
    }
    if (w < outcap) out[w] = '\0';
    return truncated ? need : w + 1;
}
