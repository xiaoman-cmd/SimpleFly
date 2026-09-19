/*
 * inputsource_list.c —— 列出 Text Input Source 服务当前认识的输入源。
 *
 * 用途：输入法装了却不出现在「系统设置 › 键盘 › 输入法」里时，用它判定
 *       到底是「TIS 根本没认这个 bundle」（列表里查不到）还是
 *       「TIS 认了但没被启用 / 不可见」（列表里查得到）。
 *
 * 编译：clang -O2 -isysroot "$(xcrun --show-sdk-path)" \
 *              tools/inputsource_list.c -o /tmp/inputsource_list -framework Carbon
 * 运行：/tmp/inputsource_list            # 只列已启用的
 *       /tmp/inputsource_list --all      # 连所有已安装（含未启用）一起列
 *       /tmp/inputsource_list im.rime    # 只列 id 里含该子串的
 */

#include <Carbon/Carbon.h>
#include <stdio.h>
#include <string.h>

static void cstr(CFStringRef s, char *buf, size_t n)
{
    buf[0] = '\0';
    if (s) CFStringGetCString(s, buf, (CFIndex)n, kCFStringEncodingUTF8);
}

static int flag(CFTypeRef v)
{
    return (v && CFGetTypeID(v) == CFBooleanGetTypeID()) ? (CFBooleanGetValue(v) ? 1 : 0) : -1;
}

int main(int argc, char **argv)
{
    int all = 0;
    const char *filter = NULL;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--all") == 0) all = 1;
        else filter = argv[i];
    }

    CFArrayRef list = TISCreateInputSourceList(NULL, all);
    if (!list) { fprintf(stderr, "TISCreateInputSourceList 返回 NULL\n"); return 1; }

    CFIndex n = CFArrayGetCount(list);
    printf("includeAllInstalled=%d  共 %ld 个输入源\n\n", all, (long)n);

    int shown = 0, hit = 0;
    for (CFIndex i = 0; i < n; i++) {
        TISInputSourceRef src = (TISInputSourceRef)CFArrayGetValueAtIndex(list, i);
        char id[256], bid[256], cat[128], type[128];
        cstr(TISGetInputSourceProperty(src, kTISPropertyInputSourceID), id, sizeof id);
        cstr(TISGetInputSourceProperty(src, kTISPropertyBundleID), bid, sizeof bid);
        cstr(TISGetInputSourceProperty(src, kTISPropertyInputSourceCategory), cat, sizeof cat);
        cstr(TISGetInputSourceProperty(src, kTISPropertyInputSourceType), type, sizeof type);

        if (filter && !strstr(id, filter) && !strstr(bid, filter)) continue;
        hit++;

        if (!filter && shown < 40) {
            /* 只打印输入法类，键盘布局太多会淹掉输出 */
            if (strstr(type, "TISTypeKeyboardInputMethodModeEnabled") == NULL &&
                strstr(type, "TISTypeKeyboardInputMethodWithoutModes") == NULL &&
                strstr(type, "TISTypeKeyboardInputMode") == NULL) continue;
        }
        shown++;

        printf("  id       = %s\n", id);
        printf("  bundle   = %s\n", bid[0] ? bid : "(无)");
        printf("  category = %s\n", cat);
        printf("  type     = %s\n", type);
        printf("  enabled=%d  selectable=%d  selected=%d\n",
               flag(TISGetInputSourceProperty(src, kTISPropertyInputSourceIsEnabled)),
               flag(TISGetInputSourceProperty(src, kTISPropertyInputSourceIsSelectCapable)),
               flag(TISGetInputSourceProperty(src, kTISPropertyInputSourceIsSelected)));
        printf("\n");
    }
    if (hit == 0) printf("  （没有匹配「%s」的输入源）\n", filter ? filter : "");
    CFRelease(list);
    return 0;
}
