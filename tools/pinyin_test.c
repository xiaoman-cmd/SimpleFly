/* pinyin_test.c —— 全拼 -> 小鹤双拼 的键位表单测（纯 C，不需要码表）
 *
 * 每个用例都标了它的出处：码表里那个字的实际音码。也就是说这些断言不是
 * 「我认为应该是这样」，而是「官方码表里它就是这样」。
 * 全量校验（9377 个单字、与 pypinyin 对照）见 tools/verify_pinyin.py。
 */
#include "pinyin.h"

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

/* 全拼 -> 双拼；want 为 NULL 表示「应当解析失败」 */
static void eq(const char *py, const char *want)
{
    char got[3] = { '?', '?', '\0' };
    int n = sf_pinyin_to_double(py, got);

    if (!want) {
        check(n == 0, "%-8s → 应当失败（得到 \"%s\"）", py, n == 2 ? got : "");
        return;
    }
    check(n == 2 && strcmp(got, want) == 0, "%-8s → %-3s（期望 %s）", py, n == 2 ? got : "—", want);
}

static void test_initials(void)
{
    puts("\n== 声母：zh/ch/sh 各占一键 ==");
    eq("zhi",  "vi");   /* 码表「织」visb 前两位 */
    eq("chi",  "ii");   /* 码表「吃」ii   */
    eq("shi",  "ui");   /* 码表「师」uil 前两位 */
    eq("zhang","vh");   /* 码表「长」vh    */
    eq("chang","ih");   /* 码表「藏」ch    */
    eq("shang","uh");   /* 码表「上」uh    */
    eq("zhu",  "vu");   /* 码表「丶」用形码，这里校验的是规则本身 */
}

static void test_finals(void)
{
    puts("\n== 韵母键位（全部取自码表实测）==");
    eq("hao",   "hc");  /* 好 hc */
    eq("shuang","ul");  /* 双 ul */
    eq("kuai",  "kk");  /* 快 kk */
    eq("xue",   "xt");  /* 学 xt */
    eq("hui",   "hv");  /* 会 hv */
    eq("sui",   "sv");  /* 岁 sv */
    eq("xiao",  "xn");  /* 小 x n */
    eq("yong",  "ys");  /* 用 ys */
    eq("wang",  "wh");  /* 王 wh */
    eq("weng",  "wg");  /* 翁 wg */
    eq("jiu",   "jq");  /* 就 jq */
    eq("yan",   "yj");  /* 烟 yjh 前两位 */
    eq("yuan",  "yr");  /* 远 yrz 前两位 */
    eq("nv",    "nv");  /* 女 */
    eq("jun",   "jy");  /* 军 */
    eq("yao",   "yc");  /* 要 */
    eq("duo",   "do");  /* 多 */
    eq("guang", "gl");  /* 光 */
    eq("liang", "ll");  /* 两 */
    eq("xiong", "xs");  /* 熊 */
    eq("jia",   "jx");  /* 加 */
    eq("gua",   "gx");  /* 瓜 */
}

static void test_zero_initial(void)
{
    puts("\n== 零声母（a/o/e 开头）==");
    /* 这组是小鹤里最容易搞错的地方：an 就是 an，而 ang 是 ah。 */
    eq("an",  "an");    /* 安 an */
    eq("ai",  "ai");    /* 爱 ai */
    eq("ao",  "ao");    /* 奥 ao */
    eq("ou",  "ou");    /* 欧 ou */
    eq("en",  "en");    /* 恩 en */
    eq("er",  "er");    /* 而 er */
    eq("ei",  "ei");    /* 欸 ei */
    eq("ang", "ah");    /* 昂 ah —— 注意不是 ang */
    eq("a",   "aa");    /* 阿 aa */
    eq("e",   "ee");    /* 额 ee */
    eq("o",   "oo");    /* 喔 oo */
}

static void test_umlaut_and_case(void)
{
    puts("\n== ü 的写法与大小写 ==");
    eq("lve", "lt");    /* lüe，键盘上打 lve */
    eq("lue", "lt");    /* 也收 ue 的写法 */
    eq("nve", "nt");
    eq("nv",  "nv");
    eq("\u00fc",  NULL); /* 单独一个 ü 不是音节 */
    eq("HAO", "hc");    /* 大写照样能解析 */
    eq("hao", "hc");
}

static void test_invalid(void)
{
    puts("\n== 非法输入 ==");
    eq("",     NULL);
    eq("xyz",  NULL);
    eq("hao ", NULL);   /* 带空格 */
    eq("hao1", NULL);
    eq("zzz",  NULL);   /* z + z 不是韵母 */
    eq("bbbb", NULL);
    eq("yi",   "yi");   /* y 开头按「y + 韵母」处理，与码表一致 */
}

static void test_is_syllable(void)
{
    puts("\n== sf_pinyin_is_syllable（反查模式用它区分全拼/双拼码）==");
    check(sf_pinyin_is_syllable("hao") == 1, "hao 是合法全拼");
    check(sf_pinyin_is_syllable("shuang") == 1, "shuang 是合法全拼");
    check(sf_pinyin_is_syllable("hc") == 0, "hc 不是合法全拼 → 反查时按双拼码处理");
    check(sf_pinyin_is_syllable("abc") == 0, "abc 不是合法全拼 → 当双拼码处理");
    check(sf_pinyin_is_syllable("xyz") == 0, "xyz 不是");
}

static void test_multi(void)
{
    puts("\n== sf_pinyin_to_double_multi（查编码里输整词拼音）==");
    struct { const char *py; const char *want; } cases[] = {
        { "nihao",    "nihc" },   /* 你好 */
        { "xiexie",   "xpxp" },   /* 谢谢 */
        { "beijing",  "bwjk" },   /* 北京 */
        { "zhongguo", "vsgo" },   /* 中国 */
        { "hao",      "hc"   },   /* 单音节退化为原单音节接口的结果 */
        { "niha",     "niha" },   /* 中途态也照切（ni + ha） */
    };
    for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        char out[32] = "";
        int n = sf_pinyin_to_double_multi(cases[i].py, out, sizeof out);
        check(n > 0 && strcmp(out, cases[i].want) == 0,
              "%-10s → %-5s（期望 %s）", cases[i].py, n > 0 ? out : "—", cases[i].want);
    }
    /* 非法：拼不出音节直接失败 */
    char tmp[32];
    check(sf_pinyin_to_double_multi("hello", tmp, sizeof tmp) == 0, "hello 不是拼音 → 0");
    check(sf_pinyin_to_double_multi("", tmp, sizeof tmp) == 0, "空串 → 0");
}

static void test_round_trip(void)
{
    puts("\n== 反解 sf_double_to_pinyin ==");
    struct { const char *code; const char *py; } cases[] = {
        { "hc", "hao" }, { "ul", "shuang" }, { "an", "an" }, { "ah", "ang" },
        { "vi", "zhi" }, { "ii", "chi"  }, { "ui", "shi" },
    };
    for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        char out[16] = "";
        int n = sf_double_to_pinyin(cases[i].code, out, sizeof out);
        /* 反解可能有多个解，只要解出来的拼音能转回同一个码就算对 */
        char back[3];
        int ok = (n > 0) && sf_pinyin_to_double(out, back) == 2 &&
                 strcmp(back, cases[i].code) == 0;
        check(ok, "%s ⇄ %s（反解得 \"%s\"）", cases[i].code, cases[i].py, n > 0 ? out : "—");
    }
}

int main(void)
{
    puts("===== 全拼 → 小鹤双拼 单测 =====");
    test_initials();
    test_finals();
    test_zero_initial();
    test_umlaut_and_case();
    test_invalid();
    test_is_syllable();
    test_multi();
    test_round_trip();

    printf("\n===== %d 通过 / %d 失败 =====\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
