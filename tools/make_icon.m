/*
 * make_icon.m —— 生成输入法图标。
 *
 * 两个产出：
 *   1. resources/SimpleFly.pdf   22x16 pt 矢量 PDF —— 输入法在**菜单栏 / 输入源列表**里的图标
 *   2. resources/SimpleFly.icns  应用图标（16→1024）—— Finder / 系统设置里那个方块，
 *      **同时也是「系统设置 → 键盘 → 输入法」列表在拿不到模式图标时的兜底**
 *
 * ============================ 为什么必须「挖空」 ============================
 *
 * 这是 0.3.1 修掉的那个「图标是一整块黑方块」的 bug 的根因；
 * 0.4.0 又在**应用图标**上栽了同一个跟头（见下面「应用图标也要挖空」）。
 *
 * 输入法在菜单栏里的图标是**模板图**：系统只看 alpha 通道，颜色由系统自己涂成单色
 * （浅色模式黑、深色模式白）。所以：
 *
 *     不透明底 + 不透明字   →  整块 alpha 都是 255  →  涂成一个纯黑方块，字没了
 *     不透明底 + 挖空的字   →  底 255、字 0        →  黑底透出背景色的字 ✔
 *
 * 「黑底挖出白字」正是系统输入法的画法 —— macOS 日本语输入法菜单栏那个「あ」
 * 就是「黒字に白抜き」（黑底白挖空）。鼠须管的 rime.pdf 也一样：
 * 实测它的字形区域 alpha=15、底色区域 alpha=255，就是个挖空。
 *
 * 实现上就是把「圆角矩形」和「字形轮廓」放进**同一条路径**，用 even-odd 规则填充。
 * even-odd 只看穿越次数，所以字形自己的封闭部件（比如「鸟」里那几个口）也能正确翻回来。
 *
 * --------------------- 应用图标也要挖空（0.4.1 修的） ---------------------
 *
 * 曾经以为「应用图标只在 Finder 里**彩色**渲染，所以要实心白字」，于是 build_icns()
 * 里把 knockout 硬编码成 NO。**这是错的**：实测「系统设置 → 键盘 → 输入法」的
 * 输入源列表会把 `.icns` 当**模板图**渲染 ——
 *
 *   现象：「小鹤音形」那一行显示成一个 26x26 px 的纯灰实心方块，字完全不见；
 *         同期鼠须管显示正常（16x16 的底板 + 白色挖空字，实测）。
 *   量出来的事实：那一块内部像素**恒为 (108,108,108)**，方差为零 —— 即 alpha 恒 1。
 *   尺寸也对得上应用图标：16 pt 槽位 x 内容占比 0.804 ≈ 12.9 pt ≈ 26 px（2x 屏）。
 *
 * 对照物：鼠须管的 RimeIcon.icns 实测**完全不透明像素 46.5% / 完全透明 47.8%**，
 * 中心像素 alpha=0 —— 它就是挖空的。也就是说「应用图标要实心」这个前提从来不存在。
 *
 * 代价：Finder 里那个方块的字形会透出窗口背景色（浅色背景下看起来正常，
 * 深色背景下对比度差）。本输入法是 LSUIElement 代理程序、没有 Dock 图标，
 * 除了「输入法」列表几乎看不到它，所以按鼠须管的做法处理。
 *
 * 不挖空（--solid）只在确认有颜色渲染的场合才好看，留着做对照用。
 *
 * ============================ 为什么是 22x16 pt ============================
 *
 * Apple 的输入法图标按「PDF 页面尺寸」当逻辑尺寸用，**不按像素**。
 * 128x128、72dpi 的 TIFF 会被理解成 128 pt 见方，在菜单栏里就是「图标太大」。
 * 22x16 是照**系统「简体拼音」的「拼」**定的（@2x 屏实测 44×31 px）。
 * （更正：以前这里写「鼠须管的 rime.pdf 页面正是 22x16 pt」—— 实测 rime.pdf 的页面是
 *   **16x16 pt**，它的菜单栏徽标也只有 32×31 px。见 docs/开发笔记.md「菜单栏图标」。）
 *
 * 为什么把汉字转成轮廓路径而不是画文字：PDF 画文字会把整个中文字体嵌进去
 * （PingFang 动辄十几 MB）；走 CTFontCreatePathForGlyph 拿轮廓再填充，
 * PDF 里只有几段贝塞尔曲线，几 KB，且仍是纯矢量。
 *
 * 编译：
 *   clang -fobjc-arc -O2 -Wall -isysroot "$(xcrun --show-sdk-path)" \
 *         -framework Foundation -framework CoreGraphics -framework CoreText -framework ImageIO \
 *         tools/make_icon.m -o build/make_icon
 *
 * 用法：
 *   make_icon -o resources/SimpleFly.pdf --icns resources/SimpleFly.icns   # 两个图标一起出
 *   make_icon -t 鹤 --pad 1.2 --hex 3C3489                                 # 调字/留白/底色
 *   make_icon --solid                                                     # 旧的不挖空画法（对照用）
 *   make_icon --style glyph                                               # 不要底板，只画字形
 *   make_icon --font Heiti\ SC                                            # 指定字体
 */

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>
#import <ImageIO/ImageIO.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>

static void die(NSString *m)
{
    fprintf(stderr, "错误：%s\n", m.UTF8String);
    exit(1);
}

/* 依次尝试候选字体，返回第一个能给出该字字形的 */
static CTFontRef pick_font(UniChar ch, CGGlyph *out_glyph, char *used, size_t used_n)
{
    const char *cands[] = {
        "PingFangSC-Semibold",
        "PingFangSC-Medium",
        "PingFangSC-Regular",
        "Heiti SC",
        "STHeitiSC-Medium",
        "Songti SC",
        NULL
    };
    for (int i = 0; cands[i]; i++) {
        CTFontRef f = CTFontCreateWithName((__bridge CFStringRef)@(cands[i]), 100.0, NULL);
        if (!f) continue;
        CGGlyph g = 0;
        if (CTFontGetGlyphsForCharacters(f, &ch, &g, 1) && g != 0) {
            *out_glyph = g;
            snprintf(used, used_n, "%s", cands[i]);
            return f;
        }
        CFRelease(f);
    }
    return NULL;
}

/* 取字形的轮廓，并按「撑满 + 居中」映射到 target 矩形里。
 * 以墨迹边界框（而不是 em 方框）为准，所以小字号的视觉大小是稳的。 */
static CGPathRef fitted_glyph(CTFontRef font, CGGlyph glyph, CGRect target,
                              CGRect *inkOut, double *scaleOut)
{
    CGPathRef gp = CTFontCreatePathForGlyph(font, glyph, NULL);
    if (!gp) return NULL;
    CGRect gb = CGPathGetPathBoundingBox(gp);
    if (gb.size.width <= 0 || gb.size.height <= 0) { CGPathRelease(gp); return NULL; }
    if (inkOut)   *inkOut = gb;

    double s = target.size.height / gb.size.height;
    if (gb.size.width * s > target.size.width) s = target.size.width / gb.size.width;
    if (scaleOut) *scaleOut = s;

    double tx = target.origin.x + (target.size.width  - gb.size.width  * s) / 2 - gb.origin.x * s;
    double ty = target.origin.y + (target.size.height - gb.size.height * s) / 2 - gb.origin.y * s;
    CGAffineTransform t = CGAffineTransformMake(s, 0, 0, s, tx, ty);
    CGPathRef placed = CGPathCreateCopyByTransformingPath(gp, &t);
    CGPathRelease(gp);
    return placed;
}

/* 画「底板 + 字形」。
 * knockout=YES 时两者合成一条路径用 even-odd 填 —— 这就是模板图能正确显示的关键。
 * knockout=NO  分两次填：先实心底板，再把字形盖上去。 */
static void draw_plate_and_glyph(CGContextRef ctx, CGRect canvas, double radius,
                                 CGPathRef glyphInCanvas, CGPathRef plateShape,
                                 double r, double g, double b, BOOL knockout, BOOL noBG)
{
    if (noBG) {                       /* 只画字形，不要底板 */
        CGContextAddPath(ctx, glyphInCanvas);
        CGContextSetRGBFillColor(ctx, r, g, b, 1.0);
        CGContextFillPath(ctx);
        return;
    }

    /* plateShape 传进来时是「借用的」，所以要 retain 一份好统一释放 */
    CGPathRef plate = plateShape
        ? CGPathRetain(plateShape)
        : CGPathCreateWithRoundedRect(canvas, radius, radius, NULL);

    if (knockout) {
        CGMutablePathRef both = CGPathCreateMutable();
        CGPathAddPath(both, NULL, plate);
        CGPathAddPath(both, NULL, glyphInCanvas);
        CGContextAddPath(ctx, both);
        CGContextSetRGBFillColor(ctx, r, g, b, 1.0);
        CGContextEOFillPath(ctx);     /* ← 关键：even-odd，字形位置变成洞 */
        CGPathRelease(both);
    } else {
        CGContextAddPath(ctx, plate);
        CGContextSetRGBFillColor(ctx, r, g, b, 1.0);
        CGContextFillPath(ctx);

        CGContextAddPath(ctx, glyphInCanvas);
        CGContextSetRGBFillColor(ctx, 1.0, 1.0, 1.0, 1.0);
        CGContextFillPath(ctx);
    }
    CGPathRelease(plate);
}

struct IconOpts {
    const char *text;
    double W, H, pad, radius;
    double cr, cg, cb;
    BOOL noBG;
    BOOL knockout;
    const char *forceFont;
};

/* 22x16 pt 的输入法图标 PDF */
static void build_pdf(NSString *outPath, struct IconOpts o)
{
    NSString *text = @(o.text);
    if (text.length == 0) die(@"-t 不能为空");
    UniChar ch = (UniChar)[text characterAtIndex:0];

    char fname[64] = "";
    CGGlyph glyph = 0;
    CTFontRef font = NULL;
    if (o.forceFont) {
        font = CTFontCreateWithName((__bridge CFStringRef)@(o.forceFont), 100.0, NULL);
        if (font && (!CTFontGetGlyphsForCharacters(font, &ch, &glyph, 1) || glyph == 0)) {
            CFRelease(font); font = NULL;
        } else if (font) {
            snprintf(fname, sizeof fname, "%s", o.forceFont);
        }
    }
    if (!font) font = pick_font(ch, &glyph, fname, sizeof fname);
    if (!font) die([NSString stringWithFormat:@"候选字体里都没有「%@」的字形", text]);

    CGRect box = CGRectMake(0, 0, o.W, o.H);
    CGRect inner = CGRectMake(o.pad, o.pad, o.W - 2 * o.pad, o.H - 2 * o.pad);

    CGRect ink = CGRectZero; double s = 0;
    CGPathRef glyphPath = fitted_glyph(font, glyph, inner, &ink, &s);
    if (!glyphPath) die(@"取字形轮廓失败（该字可能没有轮廓，如空格）");

    NSString *dir = [outPath stringByDeletingLastPathComponent];
    if (dir.length) [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                             withIntermediateDirectories:YES
                                                              attributes:nil
                                                                   error:NULL];
    CFURLRef url = (__bridge CFURLRef)[NSURL fileURLWithPath:outPath];
    CGContextRef ctx = CGPDFContextCreateWithURL(url, &box, NULL);
    if (!ctx) die([NSString stringWithFormat:@"无法创建 PDF：%@", outPath]);

    CGPDFContextBeginPage(ctx, NULL);
    draw_plate_and_glyph(ctx, box, o.radius, glyphPath, NULL,
                         o.cr, o.cg, o.cb, o.knockout, o.noBG);
    CGPDFContextEndPage(ctx);
    CGPDFContextClose(ctx);
    CGContextRelease(ctx);

    NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:outPath error:NULL];
    printf("字形      = %s（字体 %s）\n", o.text, fname);
    printf("墨迹边界  = %.2f x %.2f (原始)  →  缩放 %.3f\n", ink.size.width, ink.size.height, s);
    printf("画布      = %.1f x %.1f pt  留白 %.1f  圆角 %.1f\n", o.W, o.H, o.pad, o.radius);
    printf("画法      = %s\n", o.noBG ? "无底板" : (o.knockout ? "底板 + 字形挖空（模板图安全）"
                                                                  : "底板 + 不透明字形（仅彩色场合）"));
    printf("PDF       = %s (%llu bytes)\n", outPath.UTF8String,
           (unsigned long long)[attr fileSize]);

    CGPathRelease(glyphPath);
    CFRelease(font);
}

/* ---- 应用图标：macOS 风格圆角方块，导出 .icns ---- */
static const struct { int px; const char *name; } ICNS_SIZES[] = {
    {  16, "icon_16x16.png"     }, {  32, "icon_16x16@2x.png" },
    {  32, "icon_32x32.png"     }, {  64, "icon_32x32@2x.png" },
    { 128, "icon_128x128.png"   }, { 256, "icon_128x128@2x.png" },
    { 256, "icon_256x256.png"   }, { 512, "icon_256x256@2x.png" },
    { 512, "icon_512x512.png"   }, {1024, "icon_512x512@2x.png" },
};

static void build_icns(NSString *outPath, struct IconOpts o)
{
    NSString *text = @(o.text);
    UniChar ch = (UniChar)[text characterAtIndex:0];

    char fname[64] = "";
    CGGlyph glyph = 0;
    CTFontRef font = o.forceFont
        ? CTFontCreateWithName((__bridge CFStringRef)@(o.forceFont), 100.0, NULL)
        : pick_font(ch, &glyph, fname, sizeof fname);
    if (!font) die(@"应用图标：取不到字体");
    if (o.forceFont) CTFontGetGlyphsForCharacters(font, &ch, &glyph, 1);
    if (glyph == 0) die(@"应用图标：取不到字形");

    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
                     [NSString stringWithFormat:@"sf_icon_%d.iconset", getpid()]];
    [[NSFileManager defaultManager] removeItemAtPath:tmp error:NULL];
    [[NSFileManager defaultManager] createDirectoryAtPath:tmp
                              withIntermediateDirectories:YES attributes:nil error:NULL];

    /* macOS 应用图标的常规网格：1024 画布里内容 824、四边各留 100，圆角半径约 185 */
    for (size_t i = 0; i < sizeof ICNS_SIZES / sizeof ICNS_SIZES[0]; i++) {
        int S = ICNS_SIZES[i].px;
        double k = S / 1024.0;
        double inset  = 100.0 * k;
        double radius = 185.0 * k;
        CGRect plateR = CGRectMake(inset, inset, S - 2 * inset, S - 2 * inset);

        CGContextRef ctx = CGBitmapContextCreate(NULL, S, S, 8, S * 4,
                                                 CGColorSpaceCreateDeviceRGB(),
                                                 kCGImageAlphaPremultipliedLast |
                                                 kCGBitmapByteOrder32Big);
        if (!ctx) die(@"应用图标：位图上下文创建失败");
        CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);

        /* 底盘留一点内缩，让字形不贴边 */
        CGRect inner = CGRectInset(plateR, plateR.size.width * 0.20,
                                            plateR.size.height * 0.20);
        CGRect ink = CGRectZero; double sc = 0;
        CGPathRef gp = fitted_glyph(font, glyph, inner, &ink, &sc);
        if (!gp) die(@"应用图标：轮廓失败");

        CGPathRef plateShape = CGPathCreateWithRoundedRect(plateR, radius, radius, NULL);
        /* 必须跟菜单栏图标一样**挖空**（follow o.knockout）：
         * 「系统设置 → 键盘 → 输入法」的列表会把应用图标当**模板图**渲染（只看 alpha），
         * 不挖空的话整个方块 alpha 恒为 1 → 被涂成一整块纯色，字完全看不见。
         * （0.3.1~0.4.0 就是这么栽的：以为应用图标只在 Finder 里彩色渲染，硬编码了不挖空。）
         * 参照物：鼠须管的 RimeIcon.icns 也是挖空的（字形处 alpha=0）。
         * `--solid` 可退回实心，仅用于对照。 */
        draw_plate_and_glyph(ctx, plateR, radius, gp, plateShape,
                             o.cr, o.cg, o.cb, o.knockout, NO);
        CGPathRelease(plateShape);
        CGPathRelease(gp);

        CGImageRef img = CGBitmapContextCreateImage(ctx);
        NSString *png = [tmp stringByAppendingPathComponent:@(ICNS_SIZES[i].name)];
        CGImageDestinationRef d = CGImageDestinationCreateWithURL(
            (__bridge CFURLRef)[NSURL fileURLWithPath:png], CFSTR("public.png"), 1, NULL);
        CGImageDestinationAddImage(d, img, NULL);
        if (!CGImageDestinationFinalize(d)) die([NSString stringWithFormat:@"写 PNG 失败：%@", png]);
        CFRelease(d); CGImageRelease(img); CGContextRelease(ctx);
    }

    NSString *dir = [outPath stringByDeletingLastPathComponent];
    if (dir.length) [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                             withIntermediateDirectories:YES
                                                              attributes:nil error:NULL];
    [[NSFileManager defaultManager] removeItemAtPath:outPath error:NULL];
    NSTask *t = [[NSTask alloc] init];
    t.executableURL = [NSURL fileURLWithPath:@"/usr/bin/iconutil"];
    t.arguments = @[ @"-c", @"icns", tmp, @"-o", outPath ];
    NSError *err = nil;
    if (![t launchAndReturnError:&err]) { die([NSString stringWithFormat:@"iconutil 起不来：%@", err]); }
    [t waitUntilExit];
    if (t.terminationStatus != 0) die(@"iconutil 转换失败");
    [[NSFileManager defaultManager] removeItemAtPath:tmp error:NULL];

    NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:outPath error:NULL];
    printf("ICNS      = %s (%llu bytes, 16→1024)\n", outPath.UTF8String,
           (unsigned long long)[attr fileSize]);
    CFRelease(font);
}

/* ---- 模式图标 TIFF：严格照 Apple 自家输入法的规格 ----
 *
 * 为什么在 22x16 的 PDF 之外还要一个 TIFF：
 *   macOS 26 实测，「系统设置 › 键盘 › 输入法」的列表对 PDF 模式图标不认
 *   （iconURL 正确、文件存在也照旧），回退到应用图标的 16x16 表示 → 26x26 小方块。
 *   而同一列表里简体拼音的「拼」徽标显示正常 —— 解剖
 *   /System/Library/Input Methods/SCIM.app/.../pinyin.tiff 得到的规格是：
 *
 *     双帧 TIFF：frame0 = 16x16 @72dpi，frame1 = 32x32（= 2x）；
 *     黑墨 + alpha（模板图）；整幅圆角方形底板 + 挖空字形（连底板带字满幅、
 *     只留极小内边距）；菜单栏与设置列表共用这一个文件。
 *
 *   所以这里按同样规格出 SimpleFly.tiff，三个 tsInputMode*IconFileKey 全指向它。
 */
static void build_tiff(NSString *outPath, struct IconOpts o)
{
    NSString *text = @(o.text);
    UniChar ch = (UniChar)[text characterAtIndex:0];

    char fname[64] = "";
    CGGlyph glyph = 0;
    CTFontRef font = o.forceFont
        ? CTFontCreateWithName((__bridge CFStringRef)@(o.forceFont), 100.0, NULL)
        : pick_font(ch, &glyph, fname, sizeof fname);
    if (!font) die(@"模式图标 TIFF：取不到字体");
    if (o.forceFont) CTFontGetGlyphsForCharacters(font, &ch, &glyph, 1);
    if (glyph == 0) die(@"模式图标 TIFF：取不到字形");

        /* pinyin.tiff 实测：底板**满幅**（角上靠圆角收边，不留 inset —— 留 0.5px
         * 内缩会让整行像素只盖一半，alpha 恒 128，模板渲染成半透明灰边） */
        struct { int px; double dpi; } frames[] = { { 16, 72.0 }, { 32, 144.0 } };

    CGImageRef imgs[2] = { NULL, NULL };
    for (int i = 0; i < 2; i++) {
        int S = frames[i].px;
        double k = S / 16.0;                       /* 16pt 逻辑尺寸的倍率 */
        double radius = 3.4 * k;                   /* 圆角（跟 22x16 版的 3.6 视觉一致） */
        CGRect canvas = CGRectMake(0, 0, S, S);
        CGRect plateR = canvas;

        CGContextRef ctx = CGBitmapContextCreate(NULL, S, S, 8, S * 4,
                                                 CGColorSpaceCreateDeviceRGB(),
                                                 kCGImageAlphaPremultipliedLast |
                                                 kCGBitmapByteOrder32Big);
        if (!ctx) die(@"模式图标 TIFF：位图上下文创建失败");
        CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);

        /* 字形在底板内留 ~1.2pt 视觉边距（拼的字面约占底板 85%） */
        CGRect inner = CGRectInset(plateR, 1.2 * k, 1.2 * k);
        CGRect ink = CGRectZero; double sc = 0;
        CGPathRef gp = fitted_glyph(font, glyph, inner, &ink, &sc);
        if (!gp) { CGContextRelease(ctx); die(@"模式图标 TIFF：轮廓失败"); }

        /* 模板图：颜色无所谓，统一画黑；底板 + 字形 even-odd 挖空 */
        CGPathRef plateShape = CGPathCreateWithRoundedRect(plateR, radius, radius, NULL);
        draw_plate_and_glyph(ctx, plateR, radius, gp, plateShape,
                             0.0, 0.0, 0.0, YES, NO);
        CGPathRelease(plateShape);
        CGPathRelease(gp);

        imgs[i] = CGBitmapContextCreateImage(ctx);
        CGContextRelease(ctx);
    }

    NSString *dir = [outPath stringByDeletingLastPathComponent];
    if (dir.length) [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                             withIntermediateDirectories:YES
                                                              attributes:nil error:NULL];
    CFURLRef url = (__bridge CFURLRef)[NSURL fileURLWithPath:outPath];
    CGImageDestinationRef d = CGImageDestinationCreateWithURL(url, CFSTR("public.tiff"), 2, NULL);
    if (!d) die([NSString stringWithFormat:@"无法创建 TIFF：%@", outPath]);
    for (int i = 0; i < 2; i++) {
        NSDictionary *props = @{
            (__bridge NSString *)kCGImagePropertyDPIWidth  : @(frames[i].dpi),
            (__bridge NSString *)kCGImagePropertyDPIHeight : @(frames[i].dpi),
        };
        CGImageDestinationAddImage(d, imgs[i], (__bridge CFDictionaryRef)props);
        CGImageRelease(imgs[i]);
    }
    if (!CGImageDestinationFinalize(d)) die(@"写 TIFF 失败");
    CFRelease(d);
    CFRelease(font);

    NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:outPath error:NULL];
    printf("TIFF      = %s (%llu bytes, 16x16@72dpi + 32x32@144dpi)\n", outPath.UTF8String,
           (unsigned long long)[attr fileSize]);
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        struct IconOpts o = {
            .text = "飞", .W = 22.0, .H = 16.0, .pad = 1.0, .radius = 3.6,
            .cr = 0x3C / 255.0, .cg = 0x34 / 255.0, .cb = 0x89 / 255.0,   /* 靛蓝 */
            .noBG = NO, .knockout = YES, .forceFont = NULL,
        };
        NSString *outPath  = @"resources/SimpleFly.pdf";
        NSString *icnsPath = nil;
        NSString *tiffPath = nil;

        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "-o") && i + 1 < argc)        outPath  = @(argv[++i]);
            else if (!strcmp(argv[i], "--icns") && i + 1 < argc) icnsPath = @(argv[++i]);
            else if (!strcmp(argv[i], "--tiff") && i + 1 < argc) tiffPath = @(argv[++i]);
            else if (!strcmp(argv[i], "-t") && i + 1 < argc)   o.text   = argv[++i];
            else if (!strcmp(argv[i], "--font") && i + 1 < argc) o.forceFont = argv[++i];
            else if (!strcmp(argv[i], "--w") && i + 1 < argc)  o.W      = atof(argv[++i]);
            else if (!strcmp(argv[i], "--h") && i + 1 < argc)  o.H      = atof(argv[++i]);
            else if (!strcmp(argv[i], "--pad") && i + 1 < argc) o.pad   = atof(argv[++i]);
            else if (!strcmp(argv[i], "--radius") && i + 1 < argc) o.radius = atof(argv[++i]);
            else if (!strcmp(argv[i], "--no-bg"))              o.noBG   = YES;
            else if (!strcmp(argv[i], "--style") && i + 1 < argc) {
                const char *s = argv[++i];
                if      (!strcmp(s, "glyph")) o.noBG = YES;
                else if (!strcmp(s, "plate")) o.noBG = NO;
                else    die(@"--style 只认 plate / glyph");
            }
            else if (!strcmp(argv[i], "--solid"))              o.knockout = NO;
            else if (!strcmp(argv[i], "--knockout"))           o.knockout = YES;
            else if (!strcmp(argv[i], "--hex") && i + 1 < argc) {
                unsigned int v = 0;
                if (sscanf(argv[++i], "%x", &v) != 1) die(@"--hex 需要 6 位十六进制，如 3C3489");
                o.cr = ((v >> 16) & 0xFF) / 255.0;
                o.cg = ((v >> 8)  & 0xFF) / 255.0;
                o.cb = ( v        & 0xFF) / 255.0;
            } else {
                fprintf(stderr,
                    "用法: make_icon [-o 输出.pdf] [--icns 输出.icns] [--tiff 输出.tiff] [-t 汉字] [--font 字体名]\n"
                    "                 [--hex RRGGBB] [--style plate|glyph] [--solid|--knockout]\n"
                    "                 [--w 宽pt] [--h 高pt] [--pad 留白pt] [--radius 圆角pt]\n"
                    "\n"
                    "  默认 = 圆角底板 + 字形挖空（输入法菜单栏是模板图渲染，必须挖空，见文件头）\n"
                    "  --solid  不挖空（字形白色实心），只在彩色渲染的场合好看\n"
                    "  --style glyph  不要底板，只画字形\n");
                return 2;
            }
        }

        build_pdf(outPath, o);
        if (icnsPath) build_icns(icnsPath, o);
        if (tiffPath) build_tiff(tiffPath, o);
    }
    return 0;
}
