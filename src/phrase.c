#include "phrase.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

typedef struct {
    char *code;
    char *text;
} SFPhrase;

struct SFPhrases {
    SFPhrase *items;
    size_t    n;
    size_t    cap;
    time_t    mtime;
};

/* ------------------------------------------------------------------ */

static char *xstrdup(const char *s)
{
    size_t n = strlen(s);
    char *p = (char *)malloc(n + 1);
    if (p) memcpy(p, s, n + 1);
    return p;
}

/* 去掉首尾空白（空格 / 制表 / CR / LF）。返回的是 s 内部指针。 */
static char *trim(char *s)
{
    while (*s == ' ' || *s == '\t' || *s == '\r' || *s == '\n') s++;
    char *end = s + strlen(s);
    while (end > s && (end[-1] == ' ' || end[-1] == '\t' || end[-1] == '\r' || end[-1] == '\n'))
        *--end = '\0';
    return s;
}

/* 编码字符集：小写字母与数字。用户敲不出别的，所以别的直接判非法。 */
/* 合法编码 = speller 字符集 [a-z;'] + 数字（数字不进码表，但短语表允许用户自己乱绑）。
 * ⚠️ 别把 ; 和 ' 漏掉：它们是 speller.alphabet 的正经码位，; 开头的「快符」也是用户会想
 * 覆盖的东西（;a=自己常用的符号）。漏了的表现很隐蔽 —— 那一行被静默跳过，不报错。
 * 另外：数字允许，是因为注释里承诺了「编码也可以用数字」。 */
static int code_ok(const char *code)
{
    if (!*code) return 0;
    for (const char *p = code; *p; p++) {
        int c = (unsigned char)*p;
        if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
              c == ';' || c == '\'')) return 0;
    }
    return 1;
}

/* 按编码排序，二分之一查找才成立。编码是 ASCII，strcmp 的序即字典序。 */
static int cmp_phrase(const void *a, const void *b)
{
    const SFPhrase *x = (const SFPhrase *)a, *y = (const SFPhrase *)b;
    return strcmp(x->code, y->code);
}

/* 第一个 code >= target 的下标 */
static size_t first_ge(const SFPhrases *p, const char *target)
{
    size_t lo = 0, hi = p->n;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        if (strcmp(p->items[mid].code, target) < 0) lo = mid + 1;
        else                                        hi = mid;
    }
    return lo;
}

static int add(SFPhrases *p, char *code, char *text)
{
    if (p->n == p->cap) {
        size_t cap = p->cap ? p->cap * 2 : 16;
        SFPhrase *ni = (SFPhrase *)realloc(p->items, cap * sizeof *ni);
        if (!ni) return 0;
        p->items = ni;
        p->cap   = cap;
    }
    p->items[p->n].code = xstrdup(code);
    p->items[p->n].text = xstrdup(text);
    if (!p->items[p->n].code || !p->items[p->n].text) return 0;
    p->n++;
    return 1;
}

SFPhrases *sf_phrase_load(const char *path)
{
    if (!path) return NULL;

    struct stat st;
    if (stat(path, &st) != 0) return NULL;      /* 没这个文件就是没有自定义短语 */

    FILE *fh = fopen(path, "rb");
    if (!fh) return NULL;

    SFPhrases *p = (SFPhrases *)calloc(1, sizeof *p);
    if (!p) { fclose(fh); return NULL; }
    p->mtime = st.st_mtime;

    char line[4096];
    while (fgets(line, sizeof line, fh)) {
        /* 只取第一行内容；超长行会被截断，截断处的剩余部分当下一行处理会很乱，
         * 所以直接放弃这一行剩下的字节。 */
        size_t len = strlen(line);
        int truncated = (len == sizeof line - 1 && line[len - 1] != '\n');
        if (truncated) {
            int c;
            while ((c = fgetc(fh)) != EOF && c != '\n') { }
        }

        char *s = trim(line);
        if (!*s || *s == '#') continue;

        /* 分隔符：制表符优先，其次等号。等号取第一个，词条里可以有等号。 */
        char *sep = strchr(s, '\t');
        if (!sep) sep = strchr(s, '=');
        if (!sep) continue;

        *sep = '\0';
        char *code = trim(s);
        char *text = trim(sep + 1);

        for (char *q = code; *q; q++)
            if (*q >= 'A' && *q <= 'Z') *q = (char)(*q - 'A' + 'a');

        if (!code_ok(code) || !*text) continue;
        if (!add(p, code, text)) break;
    }
    fclose(fh);

    if (p->n == 0) { sf_phrase_free(p); return NULL; }

    qsort(p->items, p->n, sizeof *p->items, cmp_phrase);
    return p;
}

void sf_phrase_free(SFPhrases *p)
{
    if (!p) return;
    for (size_t i = 0; i < p->n; i++) {
        free(p->items[i].code);
        free(p->items[i].text);
    }
    free(p->items);
    free(p);
}

size_t sf_phrase_count(const SFPhrases *p) { return p ? p->n : 0; }

int sf_phrase_lookup(const SFPhrases *p, const char *code, const char **out, int max)
{
    if (!p || !code || !out || max <= 0) return 0;

    size_t i = first_ge(p, code);
    int cnt = 0;
    for (; i < p->n && cnt < max; i++) {
        if (strcmp(p->items[i].code, code) != 0) break;
        out[cnt++] = p->items[i].text;
    }
    return cnt;
}

int sf_phrase_has_prefix(const SFPhrases *p, const char *code)
{
    if (!p || !code || !*code) return 0;

    size_t n = strlen(code);
    size_t i = first_ge(p, code);
    if (i >= p->n) return 0;

    /* >= code 的第一条，只要它的前 n 个字符就是 code，说明存在这个前缀。 */
    return strncmp(p->items[i].code, code, n) == 0;
}

int sf_phrase_stale(const SFPhrases *p, const char *path)
{
    if (!path) return 0;
    struct stat st;
    if (stat(path, &st) != 0) return p && p->n > 0;      /* 文件被删了 → 该重载成空 */
    if (!p) return 1;                                     /* 之前没有，现在有了 → 该加载 */
    return st.st_mtime != p->mtime;
}

static const char kSample[] =
    "# SimpleFly 自定义快捷输入\n"
    "#\n"
    "# 一行一条，格式：  编码 = 内容\n"
    "# 分隔符用 = 或制表符都行；# 开头是注释。\n"
    "#\n"
    "# 行为：敲完编码后，这条内容出现在候选窗**第一位**，空格或数字键 1 上屏。\n"
    "# 编码可以比 4 码长，也可以用数字。改完这个文件立即生效，不用重启输入法。\n"
    "\n"
    "# --- 下面是示例，删掉或改成自己的 ---\n"
    "abc = 测试短语\n"
    "dz  = 我的常用地址\n"
    "yx  = you@example.com\n"
    "sj  = 13900000000\n";

int sf_phrase_write_sample(const char *path)
{
    if (!path) return 0;

    struct stat st;
    if (stat(path, &st) == 0) return 1;      /* 已经有了，不动它 */

    FILE *fh = fopen(path, "wb");
    if (!fh) return 0;
    size_t n = strlen(kSample);
    int ok = (fwrite(kSample, 1, n, fh) == n);
    fclose(fh);
    return ok;
}
