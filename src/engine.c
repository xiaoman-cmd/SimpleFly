#include "engine.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    char     code[SF_CODE_CAP];
    uint32_t text_off;
} SFRecord;

/* 反查索引条目：按词条排序，用来回答「这个字怎么打」。
 * text 直接指向 texts 池内部（加载后不再变动，所以指针稳定）。 */
typedef struct {
    const char *text;
    uint32_t    rec;
} SFRev;

struct SFEngine {
    SFRecord *recs;
    uint32_t  n;
    uint32_t  n_codes;
    char     *texts;
    size_t    texts_len;
    SFRev    *rev;      /* 按 text 排序的反查索引 */
};

static char g_err[256];

const char *sf_engine_last_error(void) { return g_err; }
size_t sf_engine_size(const SFEngine *e)       { return e ? e->n : 0; }
size_t sf_engine_code_count(const SFEngine *e) { return e ? e->n_codes : 0; }

static void set_err(const char *msg, const char *detail)
{
    if (detail)
        snprintf(g_err, sizeof g_err, "%s: %s", msg, detail);
    else
        snprintf(g_err, sizeof g_err, "%s", msg);
}

/* 码表字符集与官方 flypy.schema.yaml 的 speller.alphabet 一致：
 *   "abcdefghijklmnopqrstuvwxyz;'"   —— 撇号是合法码位（finals）
 */
static int code_char_ok(unsigned char c)
{
    return c == ';' || c == '\'' || (c >= 'a' && c <= 'z');
}

/* 第一个 code >= target 的下标（code 均为 ASCII，strcmp 的序即字典序）。 */
static uint32_t first_ge(const SFEngine *e, const char *target)
{
    uint32_t lo = 0, hi = e->n;
    while (lo < hi) {
        uint32_t mid = lo + (hi - lo) / 2;
        if (strcmp(e->recs[mid].code, target) < 0)
            lo = mid + 1;
        else
            hi = mid;
    }
    return lo;
}

/* 反查索引的比较函数。同词条时保持任意序 —— 取哪条由调用方按「编码更长者优先」挑。 */
static int cmp_rev(const void *a, const void *b)
{
    return strcmp(((const SFRev *)a)->text, ((const SFRev *)b)->text);
}

SFEngine *sf_engine_load(const char *path)
{
    g_err[0] = '\0';

    FILE *fh = fopen(path, "rb");
    if (!fh) { set_err("打不开码表", path); return NULL; }

    if (fseek(fh, 0, SEEK_END) != 0) { fclose(fh); set_err("读码表失败", path); return NULL; }
    long fsize = ftell(fh);
    if (fsize <= 0) { fclose(fh); set_err("码表为空", path); return NULL; }
    rewind(fh);

    char *buf = (char *)malloc((size_t)fsize + 1);
    if (!buf) { fclose(fh); set_err("内存不足", NULL); return NULL; }
    size_t got = fread(buf, 1, (size_t)fsize, fh);
    fclose(fh);
    buf[got] = '\0';

    /* 去掉可能的 BOM */
    size_t start = 0;
    if (got >= 3 && (unsigned char)buf[0] == 0xEF &&
        (unsigned char)buf[1] == 0xBB && (unsigned char)buf[2] == 0xBF)
        start = 3;

    /* 上界：行数 */
    size_t max_lines = 1;
    for (size_t i = start; i < got; i++)
        if (buf[i] == '\n') max_lines++;

    SFEngine *e = (SFEngine *)calloc(1, sizeof *e);
    if (!e) { free(buf); set_err("内存不足", NULL); return NULL; }

    e->recs = (SFRecord *)calloc(max_lines, sizeof *e->recs);
    e->texts = (char *)malloc(got + 1);
    if (!e->recs || !e->texts) {
        free(buf); sf_engine_free(e); set_err("内存不足", NULL); return NULL;
    }

    size_t text_pos = 0;
    size_t skipped = 0;
    char *p = buf + start;
    char *buf_end = buf + got;

    while (p < buf_end) {
        char *nl = memchr(p, '\n', (size_t)(buf_end - p));
        char *line_end = nl ? nl : buf_end;

        /* 去行尾 \r */
        char *end = line_end;
        while (end > p && (end[-1] == '\r' || end[-1] == ' ')) end--;
        *end = '\0';

        if (*p && *p != '#') {
            char *tab = strchr(p, '\t');
            if (tab) {
                *tab = '\0';
                const char *text = tab + 1;
                size_t clen = strlen(p);

                int ok = (clen >= 1 && clen < SF_CODE_CAP && text[0] != '\0');
                for (size_t k = 0; ok && k < clen; k++)
                    if (!code_char_ok((unsigned char)p[k])) ok = 0;

                if (ok) {
                    SFRecord *r = &e->recs[e->n];
                    memcpy(r->code, p, clen + 1);
                    r->text_off = (uint32_t)text_pos;
                    size_t tlen = strlen(text);
                    memcpy(e->texts + text_pos, text, tlen + 1);
                    text_pos += tlen + 1;
                    e->n++;
                } else {
                    skipped++;
                }
            }
        }
        if (!nl) break;
        p = nl + 1;
    }

    free(buf);
    e->texts_len = text_pos;

    if (e->n == 0) { sf_engine_free(e); set_err("码表里没有可用条目", path); return NULL; }

    /* 码表必须已按编码排好序（生成脚本保证），否则二分查找不成立 —— 直接报错而不是静默出错 */
    for (uint32_t i = 1; i < e->n; i++) {
        if (strcmp(e->recs[i - 1].code, e->recs[i].code) > 0) {
            sf_engine_free(e);
            set_err("码表未按编码排序，请重新用 tools/build_dict.py 生成", path);
            return NULL;
        }
    }

    e->n_codes = 1;
    for (uint32_t i = 1; i < e->n; i++)
        if (strcmp(e->recs[i - 1].code, e->recs[i].code) != 0) e->n_codes++;

    /* 反查索引：把「词条 -> 第几条记录」按词条排序，供 sf_engine_code_for_text 二分。
     * 76k 条排序一次约 20 ms，只在加载时做，之后每次反查是 O(log n + 同词条数)。 */
    e->rev = (SFRev *)calloc(e->n, sizeof *e->rev);
    if (e->rev) {
        for (uint32_t i = 0; i < e->n; i++) {
            e->rev[i].text = e->texts + e->recs[i].text_off;
            e->rev[i].rec  = i;
        }
        qsort(e->rev, e->n, sizeof *e->rev, cmp_rev);
    }

    if (skipped)
        fprintf(stderr, "[simplefly] 跳过 %zu 条非法编码\n", skipped);

    return e;
}

void sf_engine_free(SFEngine *e)
{
    if (!e) return;
    free(e->recs);
    free(e->texts);
    free(e->rev);
    free(e);
}

int sf_engine_lookup(const SFEngine *e, const char *code, SFHit *hits,
                     int max, int include_completion)
{
    if (!e || !code || !*code || !hits || max <= 0) return 0;
    if (max > SF_MAX_CANDS) max = SF_MAX_CANDS;

    size_t n = strlen(code);
    if (n == 0 || n >= SF_CODE_CAP) return 0;
    for (size_t k = 0; k < n; k++)
        if (!code_char_ok((unsigned char)code[k])) return 0;

    uint32_t begin = first_ge(e, code);

    /* 前缀区间右端：末位字符 +1 作为「前缀后继」 */
    char next[SF_CODE_CAP];
    memcpy(next, code, n + 1);
    unsigned char last = (unsigned char)next[n - 1];
    next[n - 1] = (char)(last + 1);   /* 字母表最大字符是 'z'(0x7A)，+1 仍在 char 范围内 */
    uint32_t end = first_ge(e, next);

    int cnt = 0;
    uint32_t i = begin;

    /* 先按「精确 -> 补全」的顺序收集到一个窗口里，再去重。
     * 去重对应官方 schema 的 filters.uniquifier —— 同一个词条可能由多个编码命中
     * （例如「阿爸」既有三码 aab 也有全码 aaba），不去重会出现重复候选。 */
    enum { WIN = 256 };
    const char *raw[WIN];
    int raw_exact[WIN];
    int raw_n = 0;

    for (; i < end && raw_n < WIN; i++) {
        if (strlen(e->recs[i].code) != n) break;   /* 精确匹配排在前 */
        raw[raw_n]   = e->texts + e->recs[i].text_off;
        raw_exact[raw_n] = 1;
        raw_n++;
    }
    if (include_completion) {
        for (; i < end && raw_n < WIN; i++) {
            raw[raw_n]   = e->texts + e->recs[i].text_off;
            raw_exact[raw_n] = 0;
            raw_n++;
        }
    }

    for (int k = 0; k < raw_n && cnt < max; k++) {
        int dup = 0;
        for (int j = 0; j < cnt; j++)
            if (strcmp(hits[j].text, raw[k]) == 0) { dup = 1; break; }
        if (dup) continue;
        hits[cnt].text  = raw[k];
        hits[cnt].exact = raw_exact[k];
        cnt++;
    }
    return cnt;
}

/* UTF-8 正文字符个数。只用来判断「是不是单个汉字」——
 * 一个字的 UTF-8 里只有一个非续接字节（0b10xxxxxx 之外）。 */
static int utf8_char_count(const char *s)
{
    int n = 0;
    for (const unsigned char *p = (const unsigned char *)s; *p; p++)
        if ((*p & 0xC0) != 0x80) n++;
    return n;
}

int sf_engine_lookup_prefix(const SFEngine *e, const char *code, SFHit *hits,
                            int max, int singles_only)
{
    if (!e || !code || !*code || !hits || max <= 0) return 0;
    if (max > SF_PREFIX_MAX) max = SF_PREFIX_MAX;

    size_t n = strlen(code);
    if (n == 0 || n >= SF_CODE_CAP) return 0;
    for (size_t k = 0; k < n; k++)
        if (!code_char_ok((unsigned char)code[k])) return 0;

    uint32_t begin = first_ge(e, code);

    char next[SF_CODE_CAP];
    memcpy(next, code, n + 1);
    next[n - 1] = (char)((unsigned char)next[n - 1] + 1);
    uint32_t end = first_ge(e, next);

    /* 两遍扫同一个区间：第一遍只收「码长恰好等于输入」的精确匹配，第二遍收更长的。
     * 这样不用先攒一个大窗口（同音一族可能有上千条词条），而且凑够 max 就能提前退出。 */
    int cnt = 0;
    for (int pass = 0; pass < 2 && cnt < max; pass++) {
        for (uint32_t i = begin; i < end && cnt < max; i++) {
            int is_exact = (strlen(e->recs[i].code) == n);
            if (pass == 0) { if (!is_exact) break; }     /* 精确段是连续的一段，断了就没有了 */
            else           { if (is_exact) continue; }   /* 第一遍已经收过 */
            int cc = utf8_char_count(e->texts + e->recs[i].text_off);
            if (singles_only == 1 && cc != 1) continue;   /* 只要单字 */
            if (singles_only == 2 && cc == 1) continue;   /* 只要词语（多字词条） */

            const char *text = e->texts + e->recs[i].text_off;
            int dup = 0;
            for (int j = 0; j < cnt; j++)
                if (strcmp(hits[j].text, text) == 0) { dup = 1; break; }
            if (dup) continue;

            hits[cnt].text  = text;
            hits[cnt].exact = is_exact;
            cnt++;
        }
    }
    return cnt;
}

/* 官方 flypy.schema.yaml：auto_select_pattern: ^;.$|^\w{4}$
 * 是**两半**：四码词自动上屏（^\w{4}$）+ 快符自动上屏（^;.$）。这里两半都实现。
 * 码表里以 ; 开头的编码实测恰好 26 条，全是「; + 单字母」，正好落在 ^;.$ 上。
 *
 * 注意 ^;.$ 只匹配码长 2 —— 单敲 ; （码长 1）在码表里有 2 个候选（：/ ；），
 * 必须继续留给用户选，别把 n==1 也放进来。 */
int sf_engine_should_autocommit(const char *code, const SFHit *hits, int n){
    if (!code || !hits || n <= 0) return 0;

    size_t len = strlen(code);
    if (!(len == 4 || (len == 2 && code[0] == ';' && code_char_ok((unsigned char)code[1]))))
        return 0;

    int exact = 0;
    for (int i = 0; i < n; i++)
        if (hits[i].exact) exact++;

    /* 只在精确匹配唯一时上屏：有重码时把选择权留给用户。 */
    return exact == 1 ? 1 : 0;
}

/* ------------------------------------------------------------------ *
 * 反查：词条 -> 编码
 * ------------------------------------------------------------------ */

/* 反查索引里第一个 text >= target 的位置。返回 NULL 表示没有比它大的。 */
static const SFRev *rev_lower_bound(const SFEngine *e, const char *text)
{
    if (!e->rev || e->n == 0) return NULL;
    uint32_t lo = 0, hi = e->n;
    while (lo < hi) {
        uint32_t mid = lo + (hi - lo) / 2;
        if (strcmp(e->rev[mid].text, text) < 0) lo = mid + 1;
        else                                    hi = mid;
    }
    return (lo < e->n) ? &e->rev[lo] : NULL;
}

const char *sf_engine_code_for_text(const SFEngine *e, const char *text)
{
    if (!e || !text || !*text) return NULL;
    const SFRev *p = rev_lower_bound(e, text);
    if (!p || strcmp(p->text, text) != 0) return NULL;

    /* 同词条可能有好几条：一简(b) / 二简(bj) / 三简(bjf) / 音形全码(bjfy)。
     * 用户问「这个字怎么打」，要的是最完整的那条，所以取编码最长的；
     * 长度相同（如「会」既有 hvrs 也有 kkrs）时取字典序小的，让结果**确定**，
     * 否则 qsort 不稳定会让同一个字每次返回不同的码，测试也没法断言。 */
    const char *best = NULL;
    for (uint32_t i = (uint32_t)(p - e->rev); i < e->n; i++) {
        if (strcmp(e->rev[i].text, text) != 0) break;
        const char *code = e->recs[e->rev[i].rec].code;
        if (!best) { best = code; continue; }
        size_t l1 = strlen(code), l2 = strlen(best);
        if (l1 > l2 || (l1 == l2 && strcmp(code, best) < 0)) best = code;
    }
    return best;
}

int sf_engine_codes_for_text(const SFEngine *e, const char *text,
                             const char **out, int max)
{
    if (!e || !text || !out || max <= 0) return 0;
    const SFRev *p = rev_lower_bound(e, text);
    if (!p || strcmp(p->text, text) != 0) return 0;

    /* 先把同一词条的所有编码收全，再去重 + 排序 + 截断。
     * 不能边收边截断：rev 里同词条的先后由 qsort 决定、并不稳定，
     * 提前 break 有可能先收到 hcnz 就把 hc 挤掉了（第一版就是这么错的）。 */
    enum { CAP = 64 };
    const char *tmp[CAP];
    int cnt = 0;

    for (uint32_t i = (uint32_t)(p - e->rev); i < e->n && cnt < CAP; i++) {
        if (strcmp(e->rev[i].text, text) != 0) break;
        const char *code = e->recs[e->rev[i].rec].code;

        int dup = 0;
        for (int j = 0; j < cnt; j++)
            if (strcmp(tmp[j], code) == 0) { dup = 1; break; }
        if (!dup) tmp[cnt++] = code;
    }

    /* 插入排序：长度升序，同长度按字典序（与 sf_engine_code_for_text 取最大值的规则对称） */
    for (int i = 1; i < cnt; i++) {
        const char *key = tmp[i];
        size_t kl = strlen(key);
        int j = i - 1;
        while (j >= 0) {
            size_t jl = strlen(tmp[j]);
            if (jl < kl || (jl == kl && strcmp(tmp[j], key) <= 0)) break;
            tmp[j + 1] = tmp[j];
            j--;
        }
        tmp[j + 1] = key;
    }

    int n = (cnt < max) ? cnt : max;
    for (int i = 0; i < n; i++) out[i] = tmp[i];
    return n;
}
