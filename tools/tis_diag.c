/*
 * tis_diag.c —— 输入法「装了但系统设置里看不到」的深度诊断。
 *
 * 比 inputsource_list.c 多问四件事：
 *   1. enableCapable —— 这个源到底「能不能被启用」（=0 就是永远加不进去）
 *   2. bundleURL / iconURL —— 系统实际认的 bundle 路径与图标是否存在实物
 *   3. localizedName / languages —— 系统设置里显示成什么、归到哪个语言分类
 *   4. --select —— 直接试着把它切成当前输入法（TIS 层最决定性的验证）
 *
 * 编译：clang -O2 -isysroot "$(xcrun --show-sdk-path)" \
 *              tools/tis_diag.c -o /tmp/tisdiag -framework Carbon
 * 用法：/tmp/tisdiag simplefly          # 只想看某个 bundle
 *       /tmp/tisdiag simplefly --select # 顺带尝试选中它的输入模式
 */

#include <Carbon/Carbon.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <dirent.h>

/* CLT 的 SDK 里缺这几个常量声明，自己补（名字以 HIToolbox 实际导出为准） */
extern const CFStringRef kTISPropertyInputSourceIsEnableCapable;
extern const CFStringRef kTISPropertyInputSourceIsASCIICapable;
extern const CFStringRef kTISPropertyInputSourceIsInvisible;
extern const CFStringRef kTISPropertyInputSourceIsFromSystem;
extern const CFStringRef kTISPropertyLocalizedName;
extern const CFStringRef kTISPropertyIconImageURL;
extern const CFStringRef kTISPropertyIconRef;
extern const CFStringRef kTISPropertyInputSourceLanguages;
extern const CFStringRef kTISPropertyIntendedLanguage;

extern OSStatus TISSelectInputSource(TISInputSourceRef inputSource);

static void cstr(CFStringRef s, char *buf, size_t n)
{
    buf[0] = '\0';
    if (s) CFStringGetCString(s, buf, (CFIndex)n, kCFStringEncodingUTF8);
}

static int flag(TISInputSourceRef s, CFStringRef key)
{
    CFTypeRef v = TISGetInputSourceProperty(s, key);
    if (!v) return -9;                                        /* 属性本身不存在 */
    if (CFGetTypeID(v) != CFBooleanGetTypeID()) return -8;     /* 类型不是 bool */
    return CFBooleanGetValue(v) ? 1 : 0;
}

static void print_url(TISInputSourceRef s, CFStringRef key, const char *label)
{
    CFTypeRef v = TISGetInputSourceProperty(s, key);
    if (!v || CFGetTypeID(v) != CFURLGetTypeID()) {
        printf("  %-16s = (无)\n", label);
        return;
    }
    char p[1024];
    CFURLRef u = (CFURLRef)v;
    if (CFURLCopyFileSystemPath(u, kCFURLPOSIXPathStyle)) {
        CFStringRef ps = CFURLCopyFileSystemPath(u, kCFURLPOSIXPathStyle);
        cstr(ps, p, sizeof p);

        /* TIS 给的图标 URL 往往是**相对路径**（"Contents/Resources/x.pdf"），
         * 直接拿它 access() 判断永远返回「否」，看着像图标丢了 —— 纯属误报。
         * 这里按 kTISPropertyBundleID 去两个输入法目录里找出那个 .app，拼成绝对路径再判。
         *
         * 本来想用 kTISPropertyBundleURL，但 HIToolbox 根本没导出这个符号，会链接失败；
         * 也不想依赖 LaunchServices（NSBundle bundleWithIdentifier:），就自己扫目录。 */
        char abs[3072] = "";
        if (p[0] != '/') {
            char bid[256] = "";
            cstr(TISGetInputSourceProperty(s, kTISPropertyBundleID), bid, sizeof bid);
            const char *home = getenv("HOME");
            char roots[2][2048];
            int nroots = 0;
            if (home) snprintf(roots[nroots++], sizeof roots[0], "%s/Library/Input Methods", home);
            snprintf(roots[nroots++], sizeof roots[0], "/Library/Input Methods");

            for (int r = 0; r < nroots && !abs[0]; r++) {
                DIR *dp = opendir(roots[r]);
                if (!dp) continue;
                struct dirent *e;
                while (!abs[0] && (e = readdir(dp))) {
                    size_t n = strlen(e->d_name);
                    if (n < 4 || strcmp(e->d_name + n - 4, ".app") != 0) continue;
                    char plist[3072];
                    snprintf(plist, sizeof plist, "%s/%s/Contents/Info.plist", roots[r], e->d_name);
                    CFURLRef pu = CFURLCreateFromFileSystemRepresentation(
                        NULL, (const UInt8 *)plist, (CFIndex)strlen(plist), false);
                    CFReadStreamRef rs = pu ? CFReadStreamCreateWithFile(NULL, pu) : NULL;
                    CFPropertyListRef pl = NULL;
                    if (rs && CFReadStreamOpen(rs))
                        pl = CFPropertyListCreateWithStream(NULL, rs, 0,
                                                            kCFPropertyListImmutable, NULL, NULL);
                    if (rs) { if (pl) CFReadStreamClose(rs); CFRelease(rs); }
                    if (pu) CFRelease(pu);
                    if (pl) {
                        if (CFGetTypeID(pl) == CFDictionaryGetTypeID() && bid[0]) {
                            char gb[256] = "";
                            cstr(CFDictionaryGetValue(pl, CFSTR("CFBundleIdentifier")),
                                 gb, sizeof gb);
                            if (strcmp(gb, bid) == 0)
                                snprintf(abs, sizeof abs, "%s/%s/%s", roots[r], e->d_name, p);
                        }
                        CFRelease(pl);
                    }
                }
                closedir(dp);
            }
        }
        if (abs[0]) {
            printf("  %-16s = %s  [完整=%s, 存在=%s]\n", label, p, abs,
                   access(abs, F_OK) == 0 ? "是" : "否");
        } else {
            printf("  %-16s = %s  [存在=%s]\n", label, p,
                   access(p, F_OK) == 0 ? "是" : "否");
        }
        CFRelease(ps);
    } else {
        cstr(CFURLGetString(u), p, sizeof p);
        printf("  %-16s = %s\n", label, p);
    }
}

static void dump(TISInputSourceRef s)
{
    char id[256], bid[256], type[160], cat[128], nm[256];
    cstr(TISGetInputSourceProperty(s, kTISPropertyInputSourceID), id, sizeof id);
    cstr(TISGetInputSourceProperty(s, kTISPropertyBundleID), bid, sizeof bid);
    cstr(TISGetInputSourceProperty(s, kTISPropertyInputSourceType), type, sizeof type);
    cstr(TISGetInputSourceProperty(s, kTISPropertyInputSourceCategory), cat, sizeof cat);
    cstr(TISGetInputSourceProperty(s, kTISPropertyLocalizedName), nm, sizeof nm);

    printf("  id             = %s\n", id);
    printf("  bundle         = %s\n", bid);
    printf("  type           = %s\n", type);
    printf("  category       = %s\n", cat);
    printf("  localizedName  = %s\n", nm[0] ? nm : "(空 —— 系统设置里会没名字!)");
    printf("  enabled=%d  enableCapable=%d  selectCapable=%d  selected=%d  asciiCapable=%d\n",
           flag(s, kTISPropertyInputSourceIsEnabled),
           flag(s, kTISPropertyInputSourceIsEnableCapable),
           flag(s, kTISPropertyInputSourceIsSelectCapable),
           flag(s, kTISPropertyInputSourceIsSelected),
           flag(s, kTISPropertyInputSourceIsASCIICapable));
    printf("  invisible=%d  fromSystem=%d   ← invisible=1 时系统设置里看不到它\n",
           flag(s, kTISPropertyInputSourceIsInvisible),
           flag(s, kTISPropertyInputSourceIsFromSystem));

    CFTypeRef langs = TISGetInputSourceProperty(s, kTISPropertyInputSourceLanguages);
    if (langs && CFGetTypeID(langs) == CFArrayGetTypeID()) {
        printf("  languages      =");
        for (CFIndex i = 0; i < CFArrayGetCount((CFArrayRef)langs); i++) {
            char l[64];
            cstr((CFStringRef)CFArrayGetValueAtIndex((CFArrayRef)langs, i), l, sizeof l);
            printf(" %s", l);
        }
        printf("\n");
    } else {
        printf("  languages      = (无)   ← 系统设置可能因此不把它归到任何语言分类\n");
    }

    char il[64];
    cstr(TISGetInputSourceProperty(s, kTISPropertyIntendedLanguage), il, sizeof il);
    printf("  intendedLang   = %s\n", il[0] ? il : "(无)");

    print_url(s, kTISPropertyIconImageURL, "iconURL");
    CFTypeRef iref = TISGetInputSourceProperty(s, kTISPropertyIconRef);
    printf("  iconRef        = %s\n", iref ? "非空（有图标）" : "空");
    printf("\n");
}

int main(int argc, char **argv)
{
    const char *filter = NULL;
    int do_select = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--select") == 0) do_select = 1;
        else filter = argv[i];
    }

    CFArrayRef list = TISCreateInputSourceList(NULL, true);
    if (!list) { fprintf(stderr, "TISCreateInputSourceList 返回 NULL\n"); return 1; }

    CFIndex n = CFArrayGetCount(list);
    printf("共 %ld 个输入源（含未安装/未启用）\n\n", (long)n);

    int hit = 0;
    for (CFIndex i = 0; i < n; i++) {
        TISInputSourceRef s = (TISInputSourceRef)CFArrayGetValueAtIndex(list, i);
        char id[256], bid[256];
        cstr(TISGetInputSourceProperty(s, kTISPropertyInputSourceID), id, sizeof id);
        cstr(TISGetInputSourceProperty(s, kTISPropertyBundleID), bid, sizeof bid);
        if (filter && !strstr(id, filter) && !strstr(bid, filter)) continue;
        hit++;
        dump(s);
    }
    if (hit == 0) printf("  （没有匹配「%s」的输入源）\n", filter ? filter : "");
    CFRelease(list);

    if (do_select && filter) {
        printf("===== 尝试 TISSelectInputSource =====\n");
        CFArrayRef l2 = TISCreateInputSourceList(NULL, true);
        for (CFIndex i = 0; i < CFArrayGetCount(l2); i++) {
            TISInputSourceRef s = (TISInputSourceRef)CFArrayGetValueAtIndex(l2, i);
            char id[256], bid[256], type[160];
            cstr(TISGetInputSourceProperty(s, kTISPropertyInputSourceID), id, sizeof id);
            cstr(TISGetInputSourceProperty(s, kTISPropertyBundleID), bid, sizeof bid);
            cstr(TISGetInputSourceProperty(s, kTISPropertyInputSourceType), type, sizeof type);
            if (!strstr(id, filter) && !strstr(bid, filter)) continue;
            if (!strstr(type, "KeyboardInputMode")) continue;      /* 只有模式级能选 */
            OSStatus st = TISSelectInputSource(s);
            printf("  TISSelectInputSource(%s) -> %d %s\n", id, (int)st,
                   st == noErr ? "(成功)" : "(失败)");
            char cur[256];
            cstr(TISGetInputSourceProperty(s, kTISPropertyInputSourceID), cur, sizeof cur);
            printf("  selected 现在 = %d\n",
                   flag(s, kTISPropertyInputSourceIsSelected));
        }
        CFRelease(l2);
    }
    return 0;
}
