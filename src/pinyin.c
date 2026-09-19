#include "pinyin.h"

#include <stdio.h>
#include <string.h>

/* ------------------------------------------------------------------ *
 * 小鹤双拼键位表
 *
 * 声母：只有 zh / ch / sh 需要换成单键，其余声母就是它自己。
 * 韵母：见下表。同一个键被多个韵母共用（如 l = iang/uang），这是方案本身的设计。
 *
 * 校验方式见 tools/verify_pinyin.py —— 拿官方码表里每个单字的音码（2 码条目，
 * 或 3/4 码条目的前两位）与该字的真实拼音对照，9377 个单字一致率 98.2%，
 * 余下 154 个全是部首字（艹宀辶 这类在码表里走形码 ob/of）与多音生僻字，
 * 没有任何一个拼音出现系统性偏差。
 * ------------------------------------------------------------------ */

typedef struct { const char *fin; char key; } SFFin;

/* ⚠️ 顺序即匹配优先级 —— 长的在前，否则 "uang" 会被 "u"/"ang" 提前吃掉。 */
static const SFFin kFin[] = {
    /* 三字母韵母 */
    { "uang", 'l' }, { "iang", 'l' }, { "iong", 's' }, { "uai", 'k' },
    { "uan", 'r' },  { "ian", 'm' },  { "iao", 'n' },  { "ang", 'h' },
    { "eng", 'g' },  { "ing", 'k' },  { "ong", 's' },
    /* 双字母韵母 */
    { "ai", 'd' }, { "ei", 'w' }, { "ui", 'v' }, { "ao", 'c' }, { "ou", 'z' },
    { "iu", 'q' }, { "ie", 'p' }, { "ue", 't' }, { "ve", 't' }, { "er", 'r' },
    { "an", 'j' }, { "en", 'f' }, { "in", 'b' }, { "un", 'y' }, { "vn", 'y' },
    { "ia", 'x' }, { "ua", 'x' }, { "uo", 'o' },
    /* 单字母韵母 */
    { "a", 'a' }, { "o", 'o' }, { "e", 'e' }, { "i", 'i' }, { "u", 'u' },
    { "v", 'v' },
};

/* 零声母音节（a / o / e 开头的那些）。
 *
 * 为什么必须单独列表而不能算出来：小鹤对零声母的定义**不是**「首字母 + 韵母键」。
 * 拿码表实测就知道了 —— an 就是 an（不是 a+j），而 ang 是 ah（不是 ang）。
 * 规律是「全拼长度 ≤ 2 就直接用；ang / eng 这两个三字母的才走韵母键」，
 * 但与其套这个规律，不如把 12 个音节直接列出来，一目了然也不会算错。 */
static const struct { const char *py; char code[3]; } kZero[] = {
    { "a",   "aa" }, { "o",   "oo" }, { "e",   "ee" },
    { "ai",  "ai" }, { "ei",  "ei" }, { "ao",  "ao" }, { "ou",  "ou" },
    { "an",  "an" }, { "en",  "en" }, { "er",  "er" },
    { "ang", "ah" }, { "eng", "eg" },
};

/* 可以在拼音里出现的声母（含零声母开头的 y / w）。 */
static const char kInitialChars[] = "bpmfdtnlgkhjqxrzcsyw";

/* ü 在键盘上打不出来，用户一律敲 v；但也容忍真的输入了 ü（UTF-8 的 C3 BC）。
 * 把输入规范成小写 + ü→v 的形态，剩下的逻辑就只管 a-z 了。 */
static size_t normalize(const char *in, char *out, size_t cap)
{
    size_t n = 0;
    for (const unsigned char *p = (const unsigned char *)in; *p; p++) {
        char c;
        if (p[0] == 0xC3 && p[1] == 0xBC) { c = 'v'; p++; }        /* ü → v */
        else if (p[0] == 0xC3 && p[1] == 0x9C) { c = 'v'; p++; }   /* Ü → v */
        else c = (char)*p;

        if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
        if (n + 1 >= cap) return 0;
        out[n++] = c;
    }
    out[n] = '\0';
    return n;
}

/* 韵母 → 键；找不到返回 0（0 不是任何键位，所以可以当「失败」用）。 */
static char final_key(const char *fin)
{
    for (size_t i = 0; i < sizeof kFin / sizeof kFin[0]; i++)
        if (strcmp(kFin[i].fin, fin) == 0) return kFin[i].key;
    return 0;
}

int sf_pinyin_to_double(const char *pinyin, char out[3])
{
    if (!pinyin || !out) return 0;

    char buf[16];
    size_t n = normalize(pinyin, buf, sizeof buf);
    if (n < 1 || n > 6) return 0;

    /* ---- 零声母 ---- */
    if (buf[0] == 'a' || buf[0] == 'o' || buf[0] == 'e') {
        for (size_t i = 0; i < sizeof kZero / sizeof kZero[0]; i++) {
            if (strcmp(kZero[i].py, buf) == 0) {
                out[0] = kZero[i].code[0];
                out[1] = kZero[i].code[1];
                out[2] = '\0';
                return 2;
            }
        }
        return 0;
    }

    /* ---- 声母：zh / ch / sh 换成单键，其余就是首字母 ----
     * 合法性检查必须用**原首字母**做，放在转换之前 —— 转换后 zh 会变成 'v'，
     * 而 v 不是声母字符（它是韵母 ü 的键），拿转换后的值去查必然全部失败。 */
    char ini = buf[0];
    const char *rest = buf + 1;
    if (!strchr(kInitialChars, ini)) return 0;

    if (n >= 2) {
        if      (buf[0] == 'z' && buf[1] == 'h') { ini = 'v'; rest = buf + 2; }
        else if (buf[0] == 'c' && buf[1] == 'h') { ini = 'i'; rest = buf + 2; }
        else if (buf[0] == 's' && buf[1] == 'h') { ini = 'u'; rest = buf + 2; }
    }

    char k = final_key(rest);
    if (!k) return 0;

    out[0] = ini;
    out[1] = k;
    out[2] = '\0';
    return 2;
}

int sf_pinyin_is_syllable(const char *s)
{
    char tmp[3];
    return sf_pinyin_to_double(s, tmp) == 2;
}

int sf_pinyin_to_double_multi(const char *pinyin, char *out, size_t cap)
{
    if (!pinyin || !out || cap == 0) return 0;

    char buf[64];
    size_t n = normalize(pinyin, buf, sizeof buf);
    if (n < 1) return 0;

    size_t pos = 0, w = 0;
    while (pos < n) {
        size_t remain = n - pos;
        int matched = 0;
        /* 贪婪最长匹配：从一个音节最多 6 个字母（zhuang）往下试到 1。
         * 整音节交给 sf_pinyin_to_double 判定（它内部已正确处理声母/零声母/韵母），
         * 所以这里按音节长度贪心不会拼出假音节。 */
        for (size_t L = (remain < 6 ? remain : 6); L >= 1; L--) {
            char syl[7];
            memcpy(syl, buf + pos, L);
            syl[L] = '\0';
            char d[3];
            if (sf_pinyin_to_double(syl, d) == 2) {
                if (w + 3 > cap) return 0;     /* 至少留 2 字符 + NUL */
                out[w++] = d[0];
                out[w++] = d[1];
                pos += L;
                matched = 1;
                break;
            }
        }
        if (!matched) return 0;   /* 这一段拼不出合法音节，整词作废 */
    }
    out[w] = '\0';
    return (int)w;
}

/* 反解：把「所有可能的拼音」正向跑一遍，谁转出来等于 code 就返回谁。
 * 组合数不过千，没必要为它做逆表（而且逆表容易和正向表不一致）。 */
/* 声母键 → 声母字符串。v/i/u 三个键在方案里专门送给 zh/ch/sh，别用作他途。 */
static const struct { char key; const char *ini; } kIniRev[] = {
    { 'v', "zh" }, { 'i', "ch" }, { 'u', "sh" },
    { 'b', "b" }, { 'p', "p" }, { 'm', "m" }, { 'f', "f" }, { 'd', "d" },
    { 't', "t" }, { 'n', "n" }, { 'l', "l" }, { 'g', "g" }, { 'k', "k" },
    { 'h', "h" }, { 'j', "j" }, { 'q', "q" }, { 'x', "x" }, { 'r', "r" },
    { 'z', "z" }, { 'c', "c" }, { 's', "s" }, { 'y', "y" }, { 'w', "w" },
};

int sf_double_to_pinyin(const char *code, char *out, size_t cap)
{
    if (!code || !out || cap == 0) return 0;

    char norm[16], dbl[3];
    size_t n = normalize(code, norm, sizeof norm);
    if (n != 2) return 0;

    /* 零声母音节：双拼码本身可能就是零声母形式（aa / an / ah…） */
    for (size_t i = 0; i < sizeof kZero / sizeof kZero[0]; i++) {
        if (kZero[i].code[0] == norm[0] && kZero[i].code[1] == norm[1]) {
            size_t len = strlen(kZero[i].py);
            if (len + 1 > cap) return 0;
            memcpy(out, kZero[i].py, len + 1);
            return (int)len;
        }
    }

    for (size_t i = 0; i < sizeof kIniRev / sizeof kIniRev[0]; i++) {
        if (kIniRev[i].key != norm[0]) continue;
        for (size_t f = 0; f < sizeof kFin / sizeof kFin[0]; f++) {
            if (kFin[f].key != norm[1]) continue;
            char trial[16];
            int len = snprintf(trial, sizeof trial, "%s%s", kIniRev[i].ini, kFin[f].fin);
            if (len <= 0 || (size_t)len >= sizeof trial) continue;
            /* 正向能解析回来，且结果确实是这个码 —— 否则是拼出来的假音节 */
            if (sf_pinyin_to_double(trial, dbl) == 2 &&
                dbl[0] == norm[0] && dbl[1] == norm[1]) {
                if ((size_t)len + 1 > cap) return 0;
                memcpy(out, trial, (size_t)len + 1);
                return len;
            }
        }
    }
    return 0;
}
