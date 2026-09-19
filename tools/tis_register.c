/*
 * tis_register.c —— 向 Text Input Source 服务直接注册一个输入法 bundle，并验证它是否被接受。
 *
 * 为什么需要它：第三方输入法正常要「注销重登」才会被 TIS 扫描到。
 * 但 TIS 导出了 TISRegisterInputSource()（安装器用的 API），可以在**不注销**的情况下
 * 当场问系统「这个 bundle 你收不收」—— 于是改 Info.plist 就有了快速的验证回路，
 * 不用每改一次就让用户注销一次。
 *
 * 注：CLT 的 SDK 里没有 TextInputSources.h，所以这里自己声明用到的两个函数。
 *
 * 编译：clang -O2 -isysroot "$(xcrun --show-sdk-path)" tools/tis_register.c \
 *              -o /tmp/tisreg -framework Carbon
 * 用法：/tmp/tisreg "/Users/me/Library/Input Methods/SimpleFly.app"            # 只注册 + 验证
 *       /tmp/tisreg "/Users/me/Library/Input Methods/SimpleFly.app" --enable   # 顺带启用
 */

#include <Carbon/Carbon.h>
#include <stdio.h>
#include <string.h>

extern OSStatus TISRegisterInputSource(CFURLRef inputSourceURL);
extern OSStatus TISEnableInputSource(TISInputSourceRef inputSource);

static void cstr(CFStringRef s, char *buf, size_t n)
{
    buf[0] = '\0';
    if (s) CFStringGetCString(s, buf, (CFIndex)n, kCFStringEncodingUTF8);
}

static int flag(CFTypeRef v)
{
    return (v && CFGetTypeID(v) == CFBooleanGetTypeID()) ? (CFBooleanGetValue(v) ? 1 : 0) : -1;
}

/* 在 TIS 当前列表里找 bundle id 对应的输入源；want_mode=1 找 mode 级，0 找输入法本体 */
static TISInputSourceRef find_source(CFStringRef bundleID, int want_mode, int *count_out)
{
    TISInputSourceRef found = NULL;
    int count = 0;
    CFArrayRef list = TISCreateInputSourceList(NULL, true);
    if (!list) return NULL;

    for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
        TISInputSourceRef s = (TISInputSourceRef)CFArrayGetValueAtIndex(list, i);
        CFStringRef bid = TISGetInputSourceProperty(s, kTISPropertyBundleID);
        if (!bid || !CFEqual(bid, bundleID)) continue;
        count++;
        CFStringRef type = TISGetInputSourceProperty(s, kTISPropertyInputSourceType);
        char t[128];
        cstr(type, t, sizeof t);
        /* 本体是 TISTypeKeyboardInputMethodModeEnabled / ...WithoutModes；
           模式级是 TISTypeKeyboardInputMode。按 "KeyboardInputMode" 区分才准。 */
        int is_mode = (strstr(t, "KeyboardInputMode") != NULL);
        if (want_mode ? is_mode : !is_mode) found = s;
    }
    CFRelease(list);
    if (count_out) *count_out = count;
    return found;
}

int main(int argc, char **argv)
{
    const char *path = NULL;
    int do_enable = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--enable") == 0) do_enable = 1;
        else path = argv[i];
    }
    if (!path) { fprintf(stderr, "用法: tis_register <bundle 路径> [--enable]\n"); return 2; }

    CFStringRef pstr = CFStringCreateWithCString(NULL, path, kCFStringEncodingUTF8);
    CFURLRef url = CFURLCreateWithFileSystemPath(NULL, pstr, kCFURLPOSIXPathStyle, true);
    CFStringRef bundleID = CFBundleGetIdentifier(CFBundleCreate(NULL, url));

    char bidbuf[256];
    cstr(bundleID, bidbuf, sizeof bidbuf);
    printf("bundle      = %s\n", path);
    printf("bundle id   = %s\n\n", bidbuf);

    printf("--- 注册前 ---\n");
    int before = 0;
    find_source(bundleID, 0, &before);
    printf("  TIS 里属于该 bundle 的输入源数 = %d\n\n", before);

    OSStatus st = TISRegisterInputSource(url);
    printf("--- TISRegisterInputSource() -> %d ---\n", (int)st);
    if (st != noErr) {
        printf("  注册被拒。常见原因：\n");
        printf("   · CFBundleIdentifier 不是 <厂商>.inputmethod.<产品> 形式\n");
        printf("   · 缺少 ComponentInputModeDict / tsInputModeListKey\n");
        printf("   · 图标文件在 bundle 里不存在\n");
        return 1;
    }

    int after = 0;
    TISInputSourceRef src = find_source(bundleID, 0, &after);
    printf("--- 注册后 ---\n");
    printf("  TIS 里属于该 bundle 的输入源数 = %d\n", after);
    if (!src) {
        printf("  ✗ 注册返回成功，但列表里仍然查不到 —— plist 仍不完整\n");
        return 1;
    }
    printf("  ✓ 已被 TIS 接受，enabled=%d selectable=%d\n",
           flag(TISGetInputSourceProperty(src, kTISPropertyInputSourceIsEnabled)),
           flag(TISGetInputSourceProperty(src, kTISPropertyInputSourceIsSelectCapable)));

    /* 把该 bundle 下所有输入源列出来 */
    CFArrayRef list = TISCreateInputSourceList(NULL, true);
    for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
        TISInputSourceRef s = (TISInputSourceRef)CFArrayGetValueAtIndex(list, i);
        CFStringRef bid = TISGetInputSourceProperty(s, kTISPropertyBundleID);
        if (!bid || !CFEqual(bid, bundleID)) continue;
        char id[256], t[128];
        cstr(TISGetInputSourceProperty(s, kTISPropertyInputSourceID), id, sizeof id);
        cstr(TISGetInputSourceProperty(s, kTISPropertyInputSourceType), t, sizeof t);
        printf("    %-46s %-40s enabled=%d\n", id, t,
               flag(TISGetInputSourceProperty(s, kTISPropertyInputSourceIsEnabled)));
    }
    CFRelease(list);

    if (do_enable) {
        /* 本体和各个模式都要启用：只启用模式时，本体的 enabled 仍为 0 */
        CFArrayRef all = TISCreateInputSourceList(NULL, true);
        int n_ok = 0, n_try = 0;
        for (CFIndex i = 0; i < CFArrayGetCount(all); i++) {
            TISInputSourceRef s = (TISInputSourceRef)CFArrayGetValueAtIndex(all, i);
            CFStringRef bid = TISGetInputSourceProperty(s, kTISPropertyBundleID);
            if (!bid || !CFEqual(bid, bundleID)) continue;
            n_try++;
            OSStatus es = TISEnableInputSource(s);
            char id[256];
            cstr(TISGetInputSourceProperty(s, kTISPropertyInputSourceID), id, sizeof id);
            printf("  TISEnableInputSource(%s) -> %d\n", id, (int)es);
            if (es == noErr) n_ok++;
        }
        CFRelease(all);
        printf("  启用 %d/%d\n", n_ok, n_try);
    }
    return 0;
}
