/* freq.c —— 重码记忆的存储层。格式与取舍见 freq.h 头注释。
 *
 * 数据结构：动态数组 + 按 code 排序，二分查找。规模预期是几百到几千条
 * （码表里重码编码一共 4,317 个，用户实际常用的远少于此），不需要哈希表。
 */
#include "freq.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

/* 多少天没用就忘掉。防的是「十天前的一次误选永久置顶」——
 * 单值记忆没有次数概念来纠错，只能靠时间衰减。 */
#define SF_FREQ_TTL_DAYS 30

typedef struct {
    char    *code;
    char    *text;
    int64_t  used;        /* 最后使用时间戳（秒）。手写文件里省略时用 0 = 永远不过期。 */
} SFFreqItem;

struct SFFreq {
    SFFreqItem *items;
    size_t      n, cap;
    char       *path;     /* 加载时的路径，flush 没给路径时用它 */
    int         dirty;    /* put/trim 之后置位，flush 后清零 */
};

static char *xstrdup(const char *s)
{
    size_t len = strlen(s);
    char *p = (char *)malloc(len + 1);
    if (p) memcpy(p, s, len + 1);
    return p;
}

static int cmp_item(const void *a, const void *b)
{
    const SFFreqItem *x = (const SFFreqItem *)a, *y = (const SFFreqItem *)b;
    return strcmp(x->code, y->code);
}

/* 第一个 code >= target 的下标。命中时 items[i].code == target。 */
static size_t lower_bound(const SFFreq *f, const char *target)
{
    size_t lo = 0, hi = f->n;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        if (strcmp(f->items[mid].code, target) < 0) lo = mid + 1;
        else                                        hi = mid;
    }
    return lo;
}

SFFreq *sf_freq_load(const char *path)
{
    if (!path) return NULL;

    FILE *fh = fopen(path, "rb");
    if (!fh) return NULL;                        /* 没这个文件 = 没有记忆，不是错误 */

    SFFreq *f = (SFFreq *)calloc(1, sizeof *f);
    if (!f) { fclose(fh); return NULL; }
    f->path = xstrdup(path);

    /* 过期判断的基准。手动测试时可以用环境变量拨到过去/未来。 */
    int64_t now = (int64_t)time(NULL);
    const char *clock = getenv("SIMPLEFLY_FAKE_NOW");
    if (clock && *clock) {
        int64_t v = strtoll(clock, NULL, 10);
        if (v > 0) now = v;
    }

    char line[4096];
    while (fgets(line, sizeof line, fh)) {
        char *nl = strchr(line, '\n');
        if (nl) *nl = '\0';

        /* 前导空白与注释 */
        char *s = line;
        while (*s == ' ' || *s == '\t') s++;
        if (!*s || *s == '#') continue;

        /* 格式：code <TAB> text [ <TAB> ts ]
         * 制表符是分隔符 —— 编码是 [a-z;']，词条里出现 TAB 的可能性为零，
         * 用 TAB 而不是空格是为了让带空格的词条（理论上不该有）也不至于解析错。 */
        char *t1 = strchr(s, '\t');
        if (!t1) continue;
        *t1 = '\0';
        char *text = t1 + 1;
        char *t2 = strchr(text, '\t');
        int64_t used = 0;
        if (t2) {
            *t2 = '\0';
            used = strtoll(t2 + 1, NULL, 10);
        }
        if (!*s || !*text) continue;

        /* 过期就跳过：读入时过滤，比每次 get 时判断便宜，也顺便让文件自然收缩。 */
        if (used > 0 && now - used > (int64_t)SF_FREQ_TTL_DAYS * 86400)
            continue;

        /* 追加（排到最后统一 sort，文件乱序也能读） */
        if (f->n == f->cap) {
            size_t cap = f->cap ? f->cap * 2 : 32;
            SFFreqItem *ni = (SFFreqItem *)realloc(f->items, cap * sizeof *ni);
            if (!ni) break;
            f->items = ni;
            f->cap   = cap;
        }
        f->items[f->n].code = xstrdup(s);
        f->items[f->n].text = xstrdup(text);
        f->items[f->n].used = used;
        if (!f->items[f->n].code || !f->items[f->n].text) break;
        f->n++;
    }
    fclose(fh);

    if (f->n == 0) { sf_freq_free(f); return NULL; }
    qsort(f->items, f->n, sizeof *f->items, cmp_item);
    return f;
}

SFFreq *sf_freq_new(const char *path)
{
    if (!path || !*path) return NULL;
    SFFreq *f = (SFFreq *)calloc(1, sizeof *f);
    if (!f) return NULL;
    f->path = xstrdup(path);
    if (!f->path) { free(f); return NULL; }
    return f;
}

void sf_freq_free(SFFreq *f)
{
    if (!f) return;
    for (size_t i = 0; i < f->n; i++) {
        free(f->items[i].code);
        free(f->items[i].text);
    }
    free(f->items);
    free(f->path);
    free(f);
}

size_t sf_freq_count(const SFFreq *f) { return f ? f->n : 0; }

const char *sf_freq_get(const SFFreq *f, const char *code)
{
    if (!f || !code) return NULL;
    size_t i = lower_bound(f, code);
    if (i < f->n && strcmp(f->items[i].code, code) == 0)
        return f->items[i].text;
    return NULL;
}

void sf_freq_put(SFFreq *f, const char *code, const char *text, int64_t now)
{
    if (!f || !code || !text || !*code || !*text) return;

    size_t i = lower_bound(f, code);
    if (i < f->n && strcmp(f->items[i].code, code) == 0) {
        /* 已有：覆盖词条 + 时间戳。原地覆盖比「删了再插」省一次排序。 */
        char *nt = xstrdup(text);
        if (!nt) return;
        free(f->items[i].text);
        f->items[i].text = nt;
        f->items[i].used = now;
        f->dirty = 1;
        return;
    }

    /* 新插入：挪出位置（memmove 保证有序，不用再 qsort） */
    if (f->n == f->cap) {
        size_t cap = f->cap ? f->cap * 2 : 32;
        SFFreqItem *ni = (SFFreqItem *)realloc(f->items, cap * sizeof *ni);
        if (!ni) return;
        f->items = ni;
        f->cap   = cap;
    }
    memmove(f->items + i + 1, f->items + i, (f->n - i) * sizeof *f->items);
    f->items[i].code = xstrdup(code);
    f->items[i].text = xstrdup(text);
    f->items[i].used = now;
    if (!f->items[i].code || !f->items[i].text) {
        /* 分配失败：回滚这次插入，别留下半条 */
        free(f->items[i].code);
        free(f->items[i].text);
        memmove(f->items + i, f->items + i + 1, (f->n - i) * sizeof *f->items);
        return;
    }
    f->n++;
    f->dirty = 1;
}

/* trim 用的键比较：used 升序，同分按 code 字典序。
 * qsort 比较器拿不到上下文，用文件静态指针把 f 递过去 ——
 * 输入法的事件处理在主线程串行，没有并发问题。 */
static const SFFreq *g_trim_ctx;

static int cmp_trim_key(const void *a, const void *b)
{
    const struct { int64_t used; size_t idx; } *x = a, *y = b;
    if (x->used != y->used) return x->used < y->used ? -1 : 1;
    return strcmp(g_trim_ctx->items[x->idx].code, g_trim_ctx->items[y->idx].code);
}

void sf_freq_trim(SFFreq *f, size_t limit)
{
    if (!f || f->n <= limit) return;

    /* 按 used 从旧到新淘汰；used 相同（含 0）时按 code 字典序，保证结果确定。 */
    struct Key { int64_t used; size_t idx; };
    struct Key *keys = (struct Key *)malloc(f->n * sizeof *keys);
    if (!keys) return;
    for (size_t i = 0; i < f->n; i++) { keys[i].used = f->items[i].used; keys[i].idx = i; }

    g_trim_ctx = f;
    qsort(keys, f->n, sizeof *keys, cmp_trim_key);

    /* 删掉 used 最旧的 (n - limit) 条，再把幸存者压缩到数组前部 */
    for (size_t k = 0; k < f->n - limit; k++) {
        size_t idx = keys[k].idx;
        free(f->items[idx].code);
        free(f->items[idx].text);
        f->items[idx].code = NULL;
        f->items[idx].text = NULL;
    }
    size_t out = 0;
    for (size_t i = 0; i < f->n; i++)
        if (f->items[i].code) f->items[out++] = f->items[i];
    f->n = out;
    /* 删完仍按 code 有序（幸存者相对顺序没变），不用重新 qsort */
    f->dirty = 1;
    free(keys);
}

int sf_freq_flush(SFFreq *f, const char *path)
{
    if (!f) return 0;
    const char *p = path ? path : f->path;
    if (!p) return 0;

    FILE *fh = fopen(p, "wb");
    if (!fh) return -1;

    fputs("# SimpleFly 重码记忆（自动生成，可手改；删一行 = 忘一条）\n", fh);
    fputs("# 格式：编码<TAB>词条<TAB>最后使用时间戳\n", fh);
    fputs("# 超过 30 天没用的条目会在下次加载时被清掉\n", fh);
    for (size_t i = 0; i < f->n; i++)
        fprintf(fh, "%s\t%s\t%lld\n", f->items[i].code, f->items[i].text,
                (long long)f->items[i].used);
    fclose(fh);
    f->dirty = 0;
    return 0;
}

int sf_freq_purge(const char *path)
{
    if (!path) return -1;
    struct stat st;
    if (stat(path, &st) != 0) return 0;          /* 本来就没有，算成功 */
    return remove(path) == 0 ? 0 : -1;
}
