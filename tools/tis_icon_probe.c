/*
 * tis_icon_probe.c —— 看系统 TISCopyIconForInputSource 对 SimpleFly 模式到底吐回什么位图。
 * 编译：clang -O2 tools/tis_icon_probe.c -o build/tis_icon_probe -framework Carbon
 */
#include <Carbon/Carbon.h>
#include <stdio.h>
#include <string.h>

/* CLT SDK 未声明，按 HIToolbox 实际导出自行 extern */
extern CGImageRef TISCopyIconForInputSource(TISInputSourceRef inputSource, Boolean isTemplate);
extern bool CGImageIsMaskTemplate(CGImageRef image);

static void cstr(CFStringRef s, char *buf, size_t n)
{
    buf[0] = '\0';
    if (s) CFStringGetCString(s, buf, (CFIndex)n, kCFStringEncodingUTF8);
}

int main(int argc, char **argv)
{
    const char *want = (argc > 1) ? argv[1] : "com.simplefly.inputmethod.SimpleFly.Hans";

    CFArrayRef list = TISCreateInputSourceList(NULL, true);
    if (!list) { fprintf(stderr, "TISCreateInputSourceList NULL\n"); return 1; }

    for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
        TISInputSourceRef s = (TISInputSourceRef)CFArrayGetValueAtIndex(list, i);
        char id[256];
        cstr(TISGetInputSourceProperty(s, kTISPropertyInputSourceID), id, sizeof id);
        if (strcmp(id, want) != 0) continue;

        printf("input source: %s\n", id);

        CGImageRef img = TISCopyIconForInputSource(s, true);   /* template 版 */
        CGImageRef img2 = TISCopyIconForInputSource(s, false); /* 原色版 */
        if (img) {
            printf("  copyIcon(template) = %ld x %ld px, alpha-only=%d\n",
                   (long)CGImageGetWidth(img), (long)CGImageGetHeight(img),
                   CGImageIsMaskTemplate(img));
            CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
            CGContextRef ctx = CGBitmapContextCreate(NULL,
                    CGImageGetWidth(img), CGImageGetHeight(img), 8, 0, cs,
                    kCGImageAlphaPremultipliedLast);
            CGRect r = CGRectMake(0, 0, CGImageGetWidth(img), CGImageGetHeight(img));
            CGContextSetRGBFillColor(ctx, 1, 1, 1, 1);
            CGContextFillRect(ctx, r);
            CGContextDrawImage(ctx, r, img);
            CGImageRef out = CGBitmapContextCreateImage(ctx);
            CFURLRef u = CFURLCreateWithFileSystemPath(NULL,
                    CFSTR("/tmp/tis_icon_template.png"), kCFURLPOSIXPathStyle, false);
            CGImageDestinationRef d = CGImageDestinationCreateWithURL(u, CFSTR("public.png"), 1, NULL);
            CGImageDestinationAddImage(d, out, NULL);
            CGImageDestinationFinalize(d);
            printf("  saved /tmp/tis_icon_template.png\n");
            CFRelease(d); CFRelease(u); CFRelease(out); CFRelease(ctx); CFRelease(cs);
            CFRelease(img);
        } else {
            printf("  copyIcon(template) = NULL\n");
        }
        if (img2) {
            printf("  copyIcon(original) = %ld x %ld px, alpha-only=%d\n",
                   (long)CGImageGetWidth(img2), (long)CGImageGetHeight(img2),
                   CGImageIsMaskTemplate(img2));
            CFRelease(img2);
        } else {
            printf("  copyIcon(original) = NULL\n");
        }
    }
    CFRelease(list);
    return 0;
}
