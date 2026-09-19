/* 引擎测试夹具 —— 不依赖 InputMethodKit，可直接在命令行跑。
 *
 *   ./engine_test <码表> --selftest          跑断言
 *   ./engine_test <码表> <编码> [编码...]     打印候选
 *   ./engine_test <码表> --bench             查表性能
 */
#include "../src/engine.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static int g_fail = 0;

#define CHECK(cond, ...)                                                    \
    do {                                                                    \
        if (cond) {                                                         \
            printf("  \033[32mok\033[0m   " __VA_ARGS__);                   \
            printf("\n");                                                   \
        } else {                                                            \
            g_fail++;                                                       \
            printf("  \033[31mFAIL\033[0m " __VA_ARGS__);                   \
            printf("\n");                                                   \
        }                                                                   \
    } while (0)

static void show(const SFEngine *e, const char *code, int completion)
{
    SFHit hits[SF_MAX_CANDS];
    int n = sf_engine_lookup(e, code, hits, SF_MAX_CANDS, completion);
    printf("%-6s -> %d 个候选", code, n);
    if (n == 0) { printf("\n"); return; }
    printf("   自动上屏=%d\n", sf_engine_should_autocommit(code, hits, n));
    for (int i = 0; i < n; i++)
        printf("       %d. %s%s\n", i + 1, hits[i].text, hits[i].exact ? "" : "  (补全)");
}

static void selftest(const SFEngine *e)
{
    SFHit hits[SF_MAX_CANDS];
    int n;

    puts("== 一简 / 二简（音码，双拼可用）==");
    n = sf_engine_lookup(e, "a", hits, SF_MAX_CANDS, 0);
    CHECK(n > 0 && strcmp(hits[0].text, "啊") == 0, "\"a\" 首选应为「啊」，实得 %s", n ? hits[0].text : "(空)");

    n = sf_engine_lookup(e, "aa", hits, SF_MAX_CANDS, 0);
    CHECK(n > 0 && strcmp(hits[0].text, "阿") == 0, "\"aa\" 首选应为「阿」，实得 %s", n ? hits[0].text : "(空)");

    puts("== 音形全码 = 4 码 = 精确匹配 ==");
    n = sf_engine_lookup(e, "aaba", hits, SF_MAX_CANDS, 1);
    CHECK(n > 0 && hits[0].exact, "\"aaba\" 应有精确匹配");
    CHECK(sf_engine_lookup(e, "aab", hits, SF_MAX_CANDS, 0) > 0, "\"aab\" 应有精确匹配（三码填空）");

    puts("== 四键上屏规则（构造用例，不依赖具体数据）==");
    {
        SFHit uniq[]   = { { "啊", 1 } };
        SFHit dup[]    = { { "啊", 1 }, { "阿", 1 } };
        SFHit compl[]  = { { "啊", 1 }, { "阿", 0 } };
        SFHit three[]  = { { "阿爸", 0 }, { "阿爸", 0 } };

        CHECK(sf_engine_should_autocommit("aaba", uniq, 1) == 1,  "唯一精确匹配 -> 上屏");
        CHECK(sf_engine_should_autocommit("aaba", compl, 2) == 1, "精确唯一 + 补全 -> 上屏");
        CHECK(sf_engine_should_autocommit("aaba", dup, 2) == 0,   "4 码重码 -> 不上屏，留给用户选");
        CHECK(sf_engine_should_autocommit("aab", three, 2) == 0,  "三码 -> 不上屏");
        CHECK(sf_engine_should_autocommit("aa", uniq, 1) == 0,    "二简 -> 不上屏");
    }

    puts("== ;x 快符上屏规则（官方 ^;.$，用构造用例保证不依赖码表）==");
    {
        SFHit uniq[] = { { "！", 1 } };
        SFHit dup[]  = { { "：", 1 }, { "；", 1 } };

        CHECK(sf_engine_should_autocommit(";a", uniq, 1) == 1,  "两码快符 -> 上屏");
        CHECK(sf_engine_should_autocommit(";a", dup, 2) == 0,   "两码快符有重码 -> 不上屏");
        CHECK(sf_engine_should_autocommit(";", dup, 2) == 0,    "单敲 ; 有 2 候选 -> 必须留给用户选");
        CHECK(sf_engine_should_autocommit(";ab", uniq, 1) == 0, "三码 ; 开头 -> 落不进 ^;.$，不上屏");
        CHECK(sf_engine_should_autocommit(";1", uniq, 1) == 0,  "; 后非码表字符 -> 不上屏");

        /* 真数据：码表里 ;+单字母 恰好 24 条且每条唯一，应当全部可自动上屏 */
        int ok = 0, total = 0;
        for (char c = 'a'; c <= 'z'; c++) {
            char code[3] = { ';', c, 0 };
            int n = sf_engine_lookup(e, code, hits, SF_MAX_CANDS, 0);
            if (n == 0) continue;
            total++;
            if (sf_engine_should_autocommit(code, hits, n) == 1) ok++;
        }
        CHECK(total > 0 && ok == total,
              "码表里 %d 个 ;x 快符应全部可自动上屏，实得 %d", total, ok);
    }

    puts("== 前缀补全 ==");
    int with_c = sf_engine_lookup(e, "aab", hits, SF_MAX_CANDS, 1);
    int no_c   = sf_engine_lookup(e, "aab", hits, SF_MAX_CANDS, 0);
    CHECK(with_c >= no_c, "开启补全时候选数不应少于关闭时（%d vs %d）", with_c, no_c);

    puts("== 空码 / 非法输入 ==");
    {
        /* 不假定具体数据：在 4 码空间里找一个确实为空的编码 */
        char absent[5] = { 0 };
        int found = 0;
        for (char a = 'q'; a <= 'z' && !found; a++)
            for (char b = 'q'; b <= 'z' && !found; b++)
                for (char c = 'q'; c <= 'z' && !found; c++)
                    for (char d = 'q'; d <= 'z' && !found; d++) {
                        char t[5] = { a, b, c, d, 0 };
                        if (sf_engine_lookup(e, t, hits, SF_MAX_CANDS, 1) == 0) {
                            memcpy(absent, t, 5); found = 1;
                        }
                    }
        CHECK(found, "应能找到一个空码（用于验证空码路径）");
        if (found) {
            int r = sf_engine_lookup(e, absent, hits, SF_MAX_CANDS, 1);
            CHECK(r == 0, "空码 \"%s\" 应返回 0 个候选，实得 %d", absent, r);
        }
    }
    CHECK(sf_engine_lookup(e, "", hits, SF_MAX_CANDS, 1) == 0, "空输入应返回 0");
    CHECK(sf_engine_lookup(e, "a1", hits, SF_MAX_CANDS, 1) == 0, "含非法字符应返回 0");
    CHECK(sf_engine_lookup(e, "aB", hits, SF_MAX_CANDS, 1) == 0, "大写字母应返回 0（前端负责转小写）");

    puts("== 撇号码位（官方 alphabet 含 '）==");
    n = sf_engine_lookup(e, "aof'", hits, SF_MAX_CANDS, 1);
    CHECK(n > 0, "\"aof'\" 应有候选（生僻字全码避让位），实得 %d", n);

    puts("== 候选去重（对应官方 filters.uniquifier）==");
    {
        int bad = 0;
        const char *probe[] = { "a", "aa", "ab", "x", "d", "n", "j", "z", "s" };
        for (int t = 0; t < 9; t++) {
            n = sf_engine_lookup(e, probe[t], hits, SF_MAX_CANDS, 1);
            for (int i = 0; i < n && !bad; i++)
                for (int j = i + 1; j < n; j++)
                    if (strcmp(hits[i].text, hits[j].text) == 0) {
                        printf("       \"%s\" 中「%s」重复\n", probe[t], hits[i].text);
                        bad = 1;
                    }
        }
        CHECK(!bad, "候选列表内不应出现重复词条");
    }

    puts("== 候选上限 ==");
    n = sf_engine_lookup(e, "a", hits, 3, 1);
    CHECK(n <= 3, "max 参数应被遵守，实得 %d", n);

    printf("\n结果：%s（失败 %d 项）\n", g_fail ? "\033[31m不通过\033[0m" : "\033[32m全部通过\033[0m", g_fail);
}

static void bench(const SFEngine *e)
{
    static const char *codes[] = { "a", "aa", "aab", "aaba", "keyi", "xhgw", "de", "wo", "n", "zzzz" };
    SFHit hits[SF_MAX_CANDS];
    const int rounds = 200000;
    clock_t t0 = clock();
    volatile int sink = 0;
    for (int i = 0; i < rounds; i++)
        sink += sf_engine_lookup(e, codes[i % 10], hits, SF_MAX_CANDS, 1);
    double ms = (double)(clock() - t0) * 1000.0 / CLOCKS_PER_SEC;
    printf("%d 次查表耗时 %.1f ms，平均 %.1f µs/次（checksum %d）\n",
           rounds, ms, ms * 1000.0 / rounds, sink);
}

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr, "用法: %s <码表> --selftest | <编码...> | --bench\n", argv[0]);
        return 2;
    }

    SFEngine *e = sf_engine_load(argv[1]);
    if (!e) {
        fprintf(stderr, "加载失败: %s\n", sf_engine_last_error());
        return 1;
    }
    printf("码表 %s：%zu 条 / %zu 个编码\n\n", argv[1], sf_engine_size(e), sf_engine_code_count(e));

    if (strcmp(argv[2], "--selftest") == 0)      selftest(e);
    else if (strcmp(argv[2], "--bench") == 0)    bench(e);
    else for (int i = 2; i < argc; i++)          show(e, argv[i], 1);

    sf_engine_free(e);
    return g_fail ? 1 : 0;
}
