/* freq_test.c —— 重码记忆单测（纯 C，不需要码表）
 *
 * 覆盖：加载/手改文件、TTL 过期、get/put、trim 淘汰顺序、flush 往返、purge。
 * 用 SIMPLEFLY_FAKE_NOW 环境变量把「现在」拨到固定值，TTL 用例才不会随时间漂。
 */
#include "freq.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int g_pass = 0, g_fail = 0;

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

#define NOW 1751700000   /* 2025-07-05 左右。⚠️ 只能配合 SIMPLEFLY_FAKE_NOW 用：
                          * 不设 FAKE_NOW 时，这个「固定值」相对真实时间会越来越旧，
                          * 30 天后 TTL 用例就会假失败。所有用到 NOW 的用例都必须
                          * 先 setenv("SIMPLEFLY_FAKE_NOW") 把被测进程的时钟拨过来。 */

static void SetFakeNow(void)   /* C89 风格的 setUp */
{
    char buf[32];
    snprintf(buf, sizeof buf, "%d", NOW);
    setenv("SIMPLEFLY_FAKE_NOW", buf, 1);
}

static void test_load(void)
{
    puts("\n== 加载与查询 ==");
    SetFakeNow();
    WriteFile("# 注释\n"
              "hc\t好\t1751700000\n"          /* 刚刚用过 */
              "abc\t测试短语\n"                 /* 手写、无时间戳 → used=0，不过期 */
              "xx\t旧词\t1\n"                 /* 1970 年 → 已过期，应被过滤 */
              "\n"
              "没有分隔符\n");

    SFFreq *f = sf_freq_load(g_path);
    check(f != NULL, "加载成功");
    if (!f) return;
    check(sf_freq_count(f) == 2, "过期与非法行被过滤，剩 2 条（得到 %zu）", sf_freq_count(f));
    check(sf_freq_get(f, "hc") && strcmp(sf_freq_get(f, "hc"), "好") == 0,
          "hc → 好");
    check(sf_freq_get(f, "abc") && strcmp(sf_freq_get(f, "abc"), "测试短语") == 0,
          "手写无时间戳的条目能查到（不过期）");
    check(sf_freq_get(f, "xx") == NULL, "过期条目查不到");
    check(sf_freq_get(f, "nope") == NULL, "没记过的编码返回 NULL");
    sf_freq_free(f);
}

static void test_ttl(void)
{
    puts("\n== TTL：30 天没用就忘 ==");

    /* 现在 = NOW；31 天前用的 → 过期；29 天前 → 留下 */
    WriteFile("old\t旧\tNOW-31d\nnew\t新\tNOW-29d\n");
    char buf[256];
    snprintf(buf, sizeof buf, "old\t旧\t%lld\nnew\t新\t%lld\n",
             (long long)(NOW - 31LL * 86400), (long long)(NOW - 29LL * 86400));
    WriteFile(buf);

    char nowstr[32];
    snprintf(nowstr, sizeof nowstr, "%d", NOW);
    setenv("SIMPLEFLY_FAKE_NOW", nowstr, 1);

    SFFreq *f = sf_freq_load(g_path);
    check(f != NULL && sf_freq_count(f) == 1, "31 天前的过期、29 天前的留下（得到 %zu）",
          f ? sf_freq_count(f) : 0);
    check(f && sf_freq_get(f, "new") != NULL, "留下的是 29 天前那条");
    sf_freq_free(f);
    /* 注意：不要 unsetenv —— main() 已统一拨钟，后面用例都依赖假时钟。
     * 拆了它，NOW（2025-07）相对真实时间就超 30 天，TTL 会把 flush 往返
     * 的条目全过滤掉，测试随时间假失败（踩过一次）。 */
}

static void test_put_get(void)
{
    puts("\n== put / 覆盖 / flush 往返 ==");
    WriteFile("# 空\n");

    SFFreq *f = sf_freq_load(g_path);
    check(f == NULL, "全注释的文件 → NULL（没有记忆，不算错误）");

    /* NULL 也能当「空记忆」用：put 会开新对象？—— 设计上不会，调用方自己判。
     * 这里按真实用法走：文件不存在 → NULL → 直接 put 一个新对象从 load 造不出来，
     * 所以控制器那边是「NULL 时惰性创建」。验证 put 在已有对象上的行为。 */
    WriteFile("aa\t第一\n");
    f = sf_freq_load(g_path);
    check(f != NULL, "有一条的文件能加载");
    if (!f) return;

    sf_freq_put(f, "bb", "第二", NOW);
    check(sf_freq_count(f) == 2, "put 新增一条（%zu）", sf_freq_count(f));
    check(sf_freq_get(f, "bb") && strcmp(sf_freq_get(f, "bb"), "第二") == 0, "能查到");

    sf_freq_put(f, "aa", "覆盖", NOW);
    check(sf_freq_get(f, "aa") && strcmp(sf_freq_get(f, "aa"), "覆盖") == 0,
          "同码再 put = 覆盖，不新增（共 %zu 条）", sf_freq_count(f));

    check(sf_freq_flush(f, NULL) == 0, "flush 写回");
    sf_freq_free(f);

    /* 重新加载验证往返 */
    SFFreq *f2 = sf_freq_load(g_path);
    check(f2 != NULL && sf_freq_get(f2, "aa") && strcmp(sf_freq_get(f2, "aa"), "覆盖") == 0,
          "flush 后重新加载，覆盖仍在");
    sf_freq_free(f2);
}

static void test_trim(void)
{
    puts("\n== trim：淘汰最久没用的 ==");
    /* 时间戳必须相对 NOW 造：写死 100/300 这种 1970 年的值，
     * 加载时就被 TTL 过滤成 0 条，根本到不了 trim（踩过一次）。 */
    char buf[256];
    snprintf(buf, sizeof buf,
             "a\tA\t%lld\nb\tB\t%lld\nc\tC\t%lld\nd\tD\t%lld\n",
             (long long)(NOW - 50), (long long)(NOW - 300),
             (long long)(NOW - 200), (long long)(NOW - 500));
    WriteFile(buf);
    SFFreq *f = sf_freq_load(g_path);
    check(f != NULL && sf_freq_count(f) == 4, "4 条加载（%zu）", f ? sf_freq_count(f) : 0);
    if (!f) return;

    sf_freq_trim(f, 2);
    check(sf_freq_count(f) == 2, "trim 到 2 条（%zu）", sf_freq_count(f));
    check(sf_freq_get(f, "a") != NULL, "最新的 a 留下");
    check(sf_freq_get(f, "c") != NULL, "次新的 c 留下");
    check(sf_freq_get(f, "b") == NULL, "较旧的 b 被淘汰");
    check(sf_freq_get(f, "d") == NULL, "最旧的 d 被淘汰");

    sf_freq_trim(f, 10);
    check(sf_freq_count(f) == 2, "limit 大于现有数时不误删");
    sf_freq_free(f);
}

static void test_purge(void)
{
    puts("\n== purge ==");
    WriteFile("aa\t第一\n");
    check(sf_freq_purge(g_path) == 0, "purge 删掉文件");
    check(sf_freq_load(g_path) == NULL, "purge 后加载 = 没有记忆");
    check(sf_freq_purge(g_path) == 0, "文件不存在时 purge 也算成功");
}

int main(void)
{
    snprintf(g_path, sizeof g_path, "/tmp/sf_freq_test_%d.txt", (int)getpid());
    unlink(g_path);

    /* 整个测试进程的「现在」都拨到 NOW：测试里写的固定时间戳（2025-07）
     * 相对真实时间会越来越旧，不拨钟 TTL 过滤会随时间假失败。 */
    SetFakeNow();

    puts("===== 重码记忆 单测 =====");
    test_load();
    test_ttl();
    test_put_get();
    test_trim();
    test_purge();

    unlink(g_path);
    printf("\n===== %d 通过 / %d 失败 =====\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
