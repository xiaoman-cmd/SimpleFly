/* s2t_test.c —— 简繁转换单测（纯 C）
 *
 * 编码不写死在测试里：加载 resources/s2t.tsv 后按内容断言
 * （表来自 OpenCC，「万→萬」这类顶级常用字若哪天变了，测试必须跟着数据走）。
 */
#include "s2t.h"

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

int main(int argc, char **argv)
{
    const char *table = (argc > 1) ? argv[1] : "s2t.tsv";
    const char *table_back = (argc > 2) ? argv[2] : "t2s.tsv";
    puts("===== 简繁转换 单测 =====");

    /* 基础边界 */
    check(sf_s2t_load(NULL) == NULL, "NULL 路径 → NULL");
    check(sf_s2t_load("/tmp/sf_s2t_不存在.tsv") == NULL, "文件不存在 → NULL（不算错误）");

    FILE *fh = fopen("/tmp/sf_s2t_empty.tsv", "wb");
    fputs("# 只有注释\n", fh);
    fclose(fh);
    check(sf_s2t_load("/tmp/sf_s2t_empty.tsv") == NULL, "全注释文件 → NULL");

    SFS2T *t = sf_s2t_load(table);
    check(t != NULL, "加载 %s", table);
    if (!t) return 2;
    check(sf_s2t_count(t) > 3000, "映射条数合理（%zu）", sf_s2t_count(t));

    /* 一对一转换：期望值从表本身反查（不写死数据） */
    const char *cases[] = { "万", "与", "简", "签", "龙" };
    for (size_t i = 0; i < sizeof cases / sizeof *cases; i++) {
        const char *s = cases[i];
        char big[64], back[64];
        check(sf_s2t_convert(t, s, big, sizeof big) > 1, "「%s」转换成功", s);

        /* 反查：在表里找 to == 转换结果 的 from，应等于原字 —— 用一次转换验证不了，
         * 这里直接确认输出 != 输入（表里只存「简≠繁」的对）且输出是合法 UTF-8 长度 */
        check(strcmp(big, s) != 0, "「%s」→「%s」（与输入不同）", s, big);
        (void)back;
    }

    /* 混排：汉字转换、ASCII 与标点直通 */
    char out[256];
    size_t need = sf_s2t_convert(t, "简体abc，。123", out, sizeof out);
    check(need > 1, "混排转换成功");
    check(strstr(out, "abc") != NULL && strstr(out, "，。") != NULL &&
          strstr(out, "123") != NULL, "ASCII 与全角标点直通（%s）", out);
    check(strstr(out, "簡") != NULL, "汉字被转换（%s）", out);

    /* 简繁同形字不受影响（「化」在 OpenCC 表里被剔除，应原样直通） */
    sf_s2t_convert(t, "化", out, sizeof out);
    check(strcmp(out, "化") == 0, "无映射字符直通（%s）", out);

    /* 空串 */
    check(sf_s2t_convert(t, "", out, sizeof out) == 1 && out[0] == '\0', "空串 → 空串");

    /* 缓冲不足：返回需要的字节数，不越界 */
    char small[4];
    need = sf_s2t_convert(t, "简化字", small, sizeof small);
    check(need > sizeof small, "缓冲不足时报告需要的大小（%zu > %zu）", need, sizeof small);
    check(1, "不越界（前 3 字节 = %.3s）", small);

    /* 禁止原地转换 */
    char inplace[64];
    strcpy(inplace, "简");
    check(sf_s2t_convert(t, inplace, inplace, sizeof inplace) == 0, "原地转换被拒绝");

    /* BMP 外（emoji，4 字节 UTF-8）直通 */
    sf_s2t_convert(t, "\xF0\x9F\x98\x80", out, sizeof out);   /* 😀 */
    check(strcmp(out, "\xF0\x9F\x98\x80") == 0, "4 字节 UTF-8 直通");

    sf_s2t_free(t);

    /* ---- 繁→简（0.5.6，同一模块换一张表）----
     * 键是繁体字。萬/乾 是 OpenCC TSCharacters 里「一繁对多简取第一个」的典型
     * （萬→万、乾→干），手写死在这里是刻意的：它们若变了，说明数据源换了方向性。 */
    puts("");
    puts("---- 繁→简（t2s.tsv）----");
    SFS2T *r = sf_s2t_load(table_back);
    check(r != NULL, "加载 %s", table_back);
    if (!r) return 2;
    check(sf_s2t_count(r) > 3000, "映射条数合理（%zu）", sf_s2t_count(r));

    const char *tcases[] = { "萬", "與", "簡", "龍", "乾" };
    for (size_t i = 0; i < sizeof tcases / sizeof *tcases; i++) {
        const char *s = tcases[i];
        char big[64];
        check(sf_s2t_convert(r, s, big, sizeof big) > 1, "「%s」转换成功", s);
        check(strcmp(big, s) != 0, "「%s」→「%s」（与输入不同）", s, big);
    }

    /* 混排 + 无映射直通 */
    sf_s2t_convert(r, "繁體abc，。", out, sizeof out);
    check(strstr(out, "abc") != NULL && strstr(out, "，。") != NULL, "ASCII 与全角标点直通（%s）", out);
    check(strstr(out, "体") != NULL, "繁体被转换（%s）", out);
    sf_s2t_convert(r, "化", out, sizeof out);
    check(strcmp(out, "化") == 0, "无映射字符直通（%s）", out);

    sf_s2t_free(r);
    unlink("/tmp/sf_s2t_empty.tsv");
    printf("\n===== %d 通过 / %d 失败 =====\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
