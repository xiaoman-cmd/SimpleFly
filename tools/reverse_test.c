/* reverse_test.c —— 引擎反查（词条 -> 编码）单测
 *
 * 「查编码」功能的地基：给定一个汉字，告诉用户它的完整音形码。
 * 需要真实码表，用法：./reverse_test resources/simplefly.dict
 */
#include "engine.h"

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

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

static void eq_code(const SFEngine *e, const char *text, const char *want)
{
    const char *got = sf_engine_code_for_text(e, text);
    check(got && strcmp(got, want) == 0, "%-4s → %-6s（期望 %s）",
          text, got ? got : "NULL", want);
}

int main(int argc, char **argv)
{
    if (argc < 2) { fprintf(stderr, "用法: %s <码表>\n", argv[0]); return 2; }

    SFEngine *e = sf_engine_load(argv[1]);
    if (!e) { fprintf(stderr, "码表加载失败：%s\n", sf_engine_last_error()); return 2; }

    printf("===== 引擎反查（词条 → 编码）单测 =====\n");
    printf("码表：%zu 条 / %zu 个编码\n", sf_engine_size(e), sf_engine_code_count(e));

    puts("\n== 取「最完整」的编码（音形全码优先）==");
    /* 这几个字的全部条目都可以用 awk -F'\\t' '$2==\"好\"' 码表 复核 */
    eq_code(e, "好", "hcnz");     /* 码表里另有 hc */
    eq_code(e, "双", "ulyy");     /* 另有 ul */
    eq_code(e, "小", "xnld");     /* 另有 x（一简）、oxx */
    eq_code(e, "安", "anbn");     /* 另有 an */
    eq_code(e, "快", "kkxg");     /* 另有 kk */
    eq_code(e, "吃", "iikq");     /* 另有 ii */
    eq_code(e, "师", "uilj");     /* 另有 uil */

    puts("\n== 同长度时结果必须确定（不能每次不一样）==");
    /* 「会」在码表里有 hv/hvr/hvrs 与 kkr/kkrs —— 两个 4 码。取字典序小的 hvrs。 */
    {
        const char *a = sf_engine_code_for_text(e, "会");
        const char *b = sf_engine_code_for_text(e, "会");
        check(a && b && strcmp(a, b) == 0, "同一词条连续两次反查结果一致（%s）", a ? a : "NULL");
        eq_code(e, "会", "hvrs");
    }

    puts("\n== 词条不存在 ==");
    check(sf_engine_code_for_text(e, "龘龘龘") == NULL, "码表里没有的词条返回 NULL");
    check(sf_engine_code_for_text(e, "") == NULL, "空串返回 NULL");
    check(sf_engine_code_for_text(e, NULL) == NULL, "NULL 返回 NULL");

    puts("\n== 全部编码 sf_engine_codes_for_text ==");
    {
        const char *out[16];
        int n = sf_engine_codes_for_text(e, "好", out, 16);
        check(n == 2, "「好」有 2 个编码（得到 %d）", n);
        if (n == 2)
            check(strcmp(out[0], "hc") == 0 && strcmp(out[1], "hcnz") == 0,
                  "短的在前：%s, %s", out[0], out[1]);

        n = sf_engine_codes_for_text(e, "小", out, 16);
        check(n == 3, "「小」有 3 个编码（得到 %d）", n);
        if (n == 3)
            check(strcmp(out[0], "x") == 0 && strcmp(out[1], "oxx") == 0 &&
                  strcmp(out[2], "xnld") == 0,
                  "按长度升序：%s, %s, %s", out[0], out[1], out[2]);

        n = sf_engine_codes_for_text(e, "好", out, 1);
        check(n == 1 && strcmp(out[0], "hc") == 0, "上限 1 时只给最短的 hc");
    }

    puts("\n== 覆盖率抽样：码表里每个单字都应当能反查到至少一个编码 ==");
    {
        /* 随便挑一批常用字，全都要能反查出来 */
        static const char *words[] = {
            "我", "你", "他", "的", "是", "在", "有", "和", "人", "这",
            "中", "大", "为", "上", "个", "国", "到", "说", "们", "年",
            "凤", "满", "成", "鹤", "粤", "拼", "输", "入", "法", "码",
        };
        int miss = 0;
        for (size_t i = 0; i < sizeof words / sizeof words[0]; i++)
            if (!sf_engine_code_for_text(e, words[i])) {
                printf("    ! %s 反查不到\n", words[i]);
                miss++;
            }
        check(miss == 0, "%zu 个常用字全部反查成功", sizeof words / sizeof words[0]);
    }

    sf_engine_free(e);
    printf("\n===== %d 通过 / %d 失败 =====\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
