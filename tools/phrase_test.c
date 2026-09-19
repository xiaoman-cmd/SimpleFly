/* phrase_test.c —— 自定义快捷输入表单测（纯 C，不需要码表）
 *
 * 自己造一个临时文件来测，覆盖：两种分隔符、注释与空行、多条目同码、
 * 前缀查询（打 abc 时中途的 fm 不能判空码）、热重载判断、非法行跳过。
 */
#include "phrase.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <utime.h>

static int g_pass = 0;
static int g_fail = 0;

static void check(int ok, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    if (ok) { g_pass++; printf("  ✓ "); }
    else    { g_fail++; printf("  ✗ "); }
    vprintf(fmt, ap);
    va_end(ap);
    printf("\n");
}

static char g_path[512];

static const char *WriteFile(const char *content)
{
    FILE *fh = fopen(g_path, "wb");
    if (!fh) { perror("临时文件"); exit(2); }
    fwrite(content, 1, strlen(content), fh);
    fclose(fh);
    return g_path;
}

static void test_basic(void)
{
    puts("\n== 解析与精确查询 ==");
    WriteFile("# 注释行\n"
              "\n"
              "abc = 测试短语\n"
              "dz\t我的常用地址\n"
              "   sj   =   13900000000   \n"     /* 前后空白 */
              "YX = you@example.com\n"          /* 大写编码 */
              "没有分隔符的行\n"
              "  = 没有编码\n"
              "x=   \n");                        /* 空的词条 */

    SFPhrases *p = sf_phrase_load(g_path);
    check(p != NULL, "加载成功");
    if (!p) return;

    check(sf_phrase_count(p) == 4, "只收下 4 条合法条目（得到 %zu）", sf_phrase_count(p));

    const char *out[8];
    int n;

    n = sf_phrase_lookup(p, "abc", out, 8);
    check(n == 1 && strcmp(out[0], "测试短语") == 0, "abc → 测试短语（得到 %d 条）", n);

    n = sf_phrase_lookup(p, "dz", out, 8);
    check(n == 1 && strcmp(out[0], "我的常用地址") == 0, "dz → 制表符分隔也认");

    n = sf_phrase_lookup(p, "sj", out, 8);
    check(n == 1 && strcmp(out[0], "13900000000") == 0, "sj → 编码/词条两侧空白被去掉");

    n = sf_phrase_lookup(p, "yx", out, 8);
    check(n == 1 && strcmp(out[0], "you@example.com") == 0, "YX 大写编码归一成小写");

    n = sf_phrase_lookup(p, "nope", out, 8);
    check(n == 0, "查不到的编码返回 0");

    sf_phrase_free(p);
}

static void test_code_charset(void)
{
    /* 合法编码 = speller 字符集 [a-z;'] + 数字。
     * ; 和 ' 容易被漏掉：它们是 speller.alphabet 的正经码位（; 开头的 24 个快符、
     * ' 做韵母分隔符），漏了的表现很隐蔽 —— 那一行被静默跳过，不报错。 */
    puts("\n== 编码字符集 ==");
    WriteFile(";a = 自定义快符\naof' = 带撇号的码\nb1 = 含数字\n"
              "a#b = 井号\nab c = 含空格\nab-c = 连字符\n");

    SFPhrases *p = sf_phrase_load(g_path);
    check(p != NULL, "加载成功");
    if (!p) return;

    check(sf_phrase_count(p) == 3, "只收下 3 条合法编码（得到 %zu）", sf_phrase_count(p));

    const char *out[8];
    check(sf_phrase_lookup(p, ";a", out, 8) == 1, "; 开头的快符码可用（能覆盖官方快符）");
    check(sf_phrase_lookup(p, "aof'", out, 8) == 1, "带撇号的码可用");
    check(sf_phrase_lookup(p, "b1", out, 8) == 1, "含数字的码可用");
    check(sf_phrase_lookup(p, "a#b", out, 8) == 0, "井号码被拒");
    check(sf_phrase_lookup(p, "ab-c", out, 8) == 0, "连字符码被拒");

    sf_phrase_free(p);
}

static void test_multi_and_limit(void)
{
    puts("\n== 同码多条 与 数量上限 ==");
    WriteFile("aa = 第一条\naa = 第二条\naa = 第三条\nbb = 别的\n");

    SFPhrases *p = sf_phrase_load(g_path);
    check(p != NULL, "加载成功");
    if (!p) return;
    check(sf_phrase_count(p) == 4, "共 4 条（%zu）", sf_phrase_count(p));

    const char *out[8];
    int n = sf_phrase_lookup(p, "aa", out, 8);
    check(n == 3, "aa 有 3 条（得到 %d）", n);
    check(n == 3 && strcmp(out[0], "第一条") == 0 && strcmp(out[2], "第三条") == 0,
          "同码保持文件顺序");

    n = sf_phrase_lookup(p, "aa", out, 2);
    check(n == 2, "上限 max=2 时只给 2 条（得到 %d）", n);

    sf_phrase_free(p);
}

static void test_prefix(void)
{
    puts("\n== 前缀查询（防「打着打着被判空码」）==");
    WriteFile("abc = 测试短语\nzzz = 无关\n");

    SFPhrases *p = sf_phrase_load(g_path);
    if (!p) { check(0, "加载失败"); return; }

    check(sf_phrase_has_prefix(p, "a")   == 1, "a 是 abc 的前缀");
    check(sf_phrase_has_prefix(p, "ab")  == 1, "ab 是 abc 的前缀");
    check(sf_phrase_has_prefix(p, "abc") == 1, "abc 自己也算");
    check(sf_phrase_has_prefix(p, "abcx")== 0, "abcx 不是任何编码的前缀");
    check(sf_phrase_has_prefix(p, "g")   == 0, "g 不是");
    check(sf_phrase_has_prefix(p, "zz")  == 1, "zz 是 zzz 的前缀");

    sf_phrase_free(p);
}

static void test_stale(void)
{
    puts("\n== 热重载判断 ==");
    WriteFile("aa = 旧内容\n");
    SFPhrases *p = sf_phrase_load(g_path);
    if (!p) { check(0, "加载失败"); return; }

    check(sf_phrase_stale(p, g_path) == 0, "刚加载完不算过期");

    /* 改动文件并把 mtime 推到未来，确保秒级精度也能区分 */
    WriteFile("aa = 新内容\n");
    struct stat st;
    stat(g_path, &st);
    struct utimbuf ut = { st.st_atime, st.st_mtime + 5 };
    utime(g_path, &ut);

    check(sf_phrase_stale(p, g_path) == 1, "文件改过后应当过期");

    /* 文件被删 → 也该重载（重载成「没有自定义短语」）*/
    unlink(g_path);
    check(sf_phrase_stale(p, g_path) == 1, "文件被删也应当过期");

    sf_phrase_free(p);
}

static void test_missing_file(void)
{
    puts("\n== 文件不存在 ==");
    SFPhrases *p = sf_phrase_load("/tmp/肯定不存在的_simplefly_短语文件");
    check(p == NULL, "不存在的文件返回 NULL（不是错误，就是没有自定义短语）");
    check(sf_phrase_count(NULL) == 0, "NULL 上查数量得到 0");

    const char *out[4];
    check(sf_phrase_lookup(NULL, "aa", out, 4) == 0, "NULL 上查询返回 0");
    check(sf_phrase_has_prefix(NULL, "a") == 0, "NULL 上前缀查询返回 0");
    sf_phrase_free(NULL);   /* 不应崩 */
    check(1, "sf_phrase_free(NULL) 安全");
}

static void test_sample(void)
{
    puts("\n== 示例文件 ==");
    unlink(g_path);
    check(sf_phrase_write_sample(g_path) == 1, "写出示例文件");
    SFPhrases *p = sf_phrase_load(g_path);
    check(p != NULL, "示例文件能被正确解析");
    if (p) {
        const char *out[4];
        int n = sf_phrase_lookup(p, "abc", out, 4);
        check(n == 1 && strcmp(out[0], "测试短语") == 0, "示例里的 abc = 测试短语 可用");
        sf_phrase_free(p);
    }
    /* 已存在时不覆盖 */
    check(sf_phrase_write_sample(g_path) == 1, "文件已存在时直接返回，不覆盖");
    unlink(g_path);
}

int main(void)
{
    snprintf(g_path, sizeof g_path, "/tmp/sf_phrase_test_%d.txt", (int)getpid());

    puts("===== 自定义快捷输入表 单测 =====");
    test_basic();
    test_code_charset();
    test_multi_and_limit();
    test_prefix();
    test_stale();
    test_missing_file();
    test_sample();

    printf("\n===== %d 通过 / %d 失败 =====\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
