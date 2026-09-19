/*
 * preview_sheet.m —— 把候选图标按「四种渲染方式」画成一张对比表。
 *
 * 为什么要模拟「模板渲染」：
 *   输入法在菜单栏 / 输入源列表里的图标是**模板图** —— 系统只看 alpha 通道，
 *   颜色由系统自己涂成单色（浅色模式黑、深色模式白）。
 *   直接看 PDF 的彩色渲染会严重误判：靛蓝底 + 不透明白字看着挺好，
 *   一到菜单栏就变成一整块纯黑方块。
 *
 *   做法：pixel(输出) = tint * alpha + 背景 * (1 - alpha)
 *   这就是模板图的定义。
 *
 * 上一版用 CGContextClipToMask 做过，结果遮罩被画偏（底面下沉、顶部被切），
 * 说明没吃透它的缩放置换规则；现在改成**自己算每一个像素**，
 * 不依赖任何平台魔法，结果可复现、可核对。
 *
 * 编译：
 *   clang -fobjc-arc -O2 -Wall -isysroot "$(xcrun --show-sdk-path)" \
 *         -framework Foundation -framework CoreGraphics -framework CoreText -framework ImageIO \
 *         tools/preview_sheet.m -o build/preview_sheet
 *
 * 用法： preview_sheet 输出.png  候选1.pdf:名字  候选2.pdf:名字 ...
 */
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>
#import <ImageIO/ImageIO.h>
#import <stdio.h>

/* 整张表按 2x 出图，读起来清楚 */
#define SC 2
#define CELL_W (240 * SC)
#define CELL_H (176 * SC)
#define GAP_X  (28  * SC)
#define GAP_Y  (46  * SC)
#define LBL_W  (250 * SC)
#define HEAD_H (92  * SC)
#define MARGIN (26  * SC)

/* 菜单栏实际尺寸：22x16 pt，2x 屏上就是 44x32 px */
#define REAL_W (22 * SC)
#define REAL_H (16 * SC)

typedef struct { unsigned char *px; size_t w, h; } RGBA;

static RGBA rgba_new(size_t w, size_t h) { RGBA b = { calloc(h * w * 4, 1), w, h }; return b; }
static void rgba_free(RGBA b) { free(b.px); }

static void rgba_fill(RGBA b, double r, double g, double bl)
{
    for (size_t i = 0; i < b.w * b.h; i++) {
        b.px[i*4+0] = (unsigned char)(r  * 255);
        b.px[i*4+1] = (unsigned char)(g  * 255);
        b.px[i*4+2] = (unsigned char)(bl * 255);
        b.px[i*4+3] = 255;
    }
}

/* 把 PDF 渲染成 RGBA，统一约定：行 0 = 图像顶部 */
static RGBA render_pdf(NSString *path, size_t w, size_t h)
{
    RGBA out = rgba_new(w, h);
    CGPDFDocumentRef doc = CGPDFDocumentCreateWithURL(
        (__bridge CFURLRef)[NSURL fileURLWithPath:path]);
    if (!doc) { fprintf(stderr, "打不开 %s\n", path.UTF8String); return out; }
    CGPDFPageRef page = CGPDFDocumentGetPage(doc, 1);
    CGRect box = CGPDFPageGetBoxRect(page, kCGPDFMediaBox);

    unsigned char *buf = calloc(h * w * 4, 1);
    CGContextRef ctx = CGBitmapContextCreate(buf, w, h, 8, w * 4,
                                             CGColorSpaceCreateDeviceRGB(),
                                             kCGImageAlphaPremultipliedLast |
                                             kCGBitmapByteOrder32Big);
    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    CGContextSetShouldAntialias(ctx, true);
    double sc = (double)w / box.size.width;
    CGContextScaleCTM(ctx, sc, sc);
    CGContextDrawPDFPage(ctx, page);

    /* 不翻转。实测（见 tools/preview_sheet.m 头部说明）：CGBitmapContext 的内存第 0 行
     * 本来就是图像的**顶部**（CG 用户坐标 y=0 在底部，对应内存最后一行），
     * 直接原样拷即可；多翻一次反而上下颠倒 —— 第一版就栽在这。 */
    memcpy(out.px, buf, (size_t)w * h * 4);
    free(buf);
    CGContextRelease(ctx);
    CGPDFDocumentRelease(doc);
    return out;
}

/* 把 src（premultiplied RGBA）合成到 dst 的 (x0,y0)。
 * tint 为 NULL 走「彩色原样」，否则按模板图规则涂成单色。 */
static void blit(RGBA dst, RGBA src, size_t x0, size_t y0, const double *tint)
{
    for (size_t y = 0; y < src.h; y++) {
        if (y0 + y >= dst.h) break;
        for (size_t x = 0; x < src.w; x++) {
            if (x0 + x >= dst.w) break;
            unsigned char *s = src.px + (y * src.w + x) * 4;
            unsigned char *d = dst.px + ((y0 + y) * dst.w + (x0 + x)) * 4;
            double a = s[3] / 255.0;
            if (tint) {
                for (int c = 0; c < 3; c++)
                    d[c] = (unsigned char)(tint[c] * a * 255 + d[c] * (1 - a) + 0.5);
            } else {
                for (int c = 0; c < 3; c++)      /* 源已 premultiplied，直接叠底 */
                    d[c] = (unsigned char)(s[c] + d[c] * (1 - a) + 0.5);
            }
            d[3] = 255;
        }
    }
}

/* RGBA（行 0 = 顶部）→ CGImage。CGImageCreate 也把第 0 行当顶部，方向天然一致 */
static CGImageRef rgba_to_image(RGBA b)
{
    CGDataProviderRef dp = CGDataProviderCreateWithData(NULL, b.px, b.w * b.h * 4, NULL);
    CGImageRef img = CGImageCreate(b.w, b.h, 8, 32, b.w * 4,
                                   CGColorSpaceCreateDeviceRGB(),
                                   kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big,
                                   dp, NULL, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(dp);
    return img;
}

static void draw_text(CGContextRef ctx, NSString *s, CGPoint at, double size,
                      double r, double g, double b)
{
    CGColorRef col = CGColorCreateGenericRGB(r, g, b, 1.0);
    CTFontRef f = CTFontCreateWithName(CFSTR("PingFangSC-Regular"), size, NULL);
    NSDictionary *attr = @{ (__bridge id)kCTFontAttributeName: (__bridge id)f,
                            (__bridge id)kCTForegroundColorAttributeName: (__bridge id)col };
    NSAttributedString *as = [[NSAttributedString alloc] initWithString:s attributes:attr];
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)as);
    CGContextSetTextPosition(ctx, at.x, at.y);
    CTLineDraw(line, ctx);
    CFRelease(line); CFRelease(f); CGColorRelease(col);
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        if (argc < 3) { fprintf(stderr, "用法: preview_sheet 输出.png 候选.pdf:名字 ...\n"); return 2; }
        NSString *out = @(argv[1]);
        int n = argc - 2, cols = 4;

        size_t W = MARGIN * 2 + LBL_W + cols * CELL_W + (cols - 1) * GAP_X;
        size_t H = HEAD_H + n * (CELL_H + GAP_Y) + MARGIN;

        RGBA sheet = rgba_new(W, H);
        rgba_fill(sheet, 0.97, 0.97, 0.98);

        const char *names[] = { "① 彩色渲染（PDF 原样）",
                                "② 模板渲染 · 浅色模式",
                                "③ 模板渲染 · 深色模式",
                                "④ 实际大小 · 浅色模式" };
        double bgs[4][3]   = { {1,1,1}, {0.93,0.93,0.94}, {0.16,0.16,0.18}, {0.93,0.93,0.94} };
        double tints[4][3] = { {0,0,0}, {0.10,0.10,0.12}, {0.96,0.96,0.97}, {0.10,0.10,0.12} };
        int isTemplate[4]  = { 0, 1, 1, 1 };

        for (int i = 0; i < n; i++) {
            NSString *spec = @(argv[2 + i]);
            NSRange colon = [spec rangeOfString:@":"];
            NSString *path = colon.location == NSNotFound ? spec : [spec substringToIndex:colon.location];

            RGBA big  = render_pdf(path, CELL_W, CELL_H);
            RGBA real = render_pdf(path, REAL_W, REAL_H);
            size_t rowY = HEAD_H + i * (CELL_H + GAP_Y);

            for (int c = 0; c < cols; c++) {
                size_t cellX = MARGIN + LBL_W + c * (CELL_W + GAP_X);
                RGBA cell = rgba_new(CELL_W, CELL_H);
                rgba_fill(cell, bgs[c][0], bgs[c][1], bgs[c][2]);

                if (c == 3) blit(cell, real, (CELL_W - REAL_W) / 2, (CELL_H - REAL_H) / 2, tints[c]);
                else        blit(cell, big, 0, 0, isTemplate[c] ? tints[c] : NULL);

                for (size_t x = 0; x < CELL_W; x++)          /* 细边框 */
                    for (int e = 0; e < 2; e++) {
                        unsigned char *p = cell.px + ((e ? CELL_H-1-e : e) * CELL_W + x) * 4;
                        p[0]=p[1]=p[2]=150; p[3]=255;
                    }
                for (size_t y = 0; y < CELL_H; y++)
                    for (int e = 0; e < 2; e++) {
                        unsigned char *p = cell.px + (y * CELL_W + (e ? CELL_W-1-e : e)) * 4;
                        p[0]=p[1]=p[2]=150; p[3]=255;
                    }

                /* sheet 与 cell 都是「行 0 = 顶部」，顺序直拷 */
                for (size_t y = 0; y < CELL_H; y++)
                    memcpy(sheet.px + ((rowY + y) * W + cellX) * 4,
                           cell.px + y * CELL_W * 4, CELL_W * 4);
                rgba_free(cell);
            }
            rgba_free(big);
            rgba_free(real);
        }

        /* 文字最后画，压在底色之上。
         * 坐标换算：sheet 用「行 0 = 顶部」，而 CG 用户坐标 y=0 在底部，
         * 两者关系是 内存行 = H-1-y，反解出 y = H - 行号。 */
        CGContextRef ctx = CGBitmapContextCreate(sheet.px, W, H, 8, W * 4,
                                                 CGColorSpaceCreateDeviceRGB(),
                                                 kCGImageAlphaPremultipliedLast |
                                                 kCGBitmapByteOrder32Big);
        CGContextSetShouldSmoothFonts(ctx, false);

        draw_text(ctx, @"输入法图标渲染对比（22×16 pt）",
                  CGPointMake(MARGIN, H - 40 * SC), 19 * SC, .08, .08, .12);  /* 行 40S 处 */
        for (int c = 0; c < cols; c++) {
            size_t cellX = MARGIN + LBL_W + c * (CELL_W + GAP_X);
            draw_text(ctx, @(names[c]), CGPointMake(cellX, H - 100 * SC), 15 * SC, .25, .25, .3);
        }
        for (int i = 0; i < n; i++) {
            NSString *spec = @(argv[2 + i]);
            NSRange colon = [spec rangeOfString:@":"];
            NSString *name = colon.location == NSNotFound ? spec : [spec substringFromIndex:colon.location + 1];
            size_t rowY = HEAD_H + i * (CELL_H + GAP_Y);
            /* 想要文字落在「行 rowY + CELL_H/2」附近 → y = H - 行号 */
            draw_text(ctx, name,
                      CGPointMake(MARGIN, H - (double)(rowY + CELL_H / 2 - 6 * SC)),
                      15 * SC, .12, .12, .16);
        }
        CGContextRelease(ctx);

        CGImageRef img = rgba_to_image(sheet);
        CGImageDestinationRef d = CGImageDestinationCreateWithURL(
            (__bridge CFURLRef)[NSURL fileURLWithPath:out], CFSTR("public.png"), 1, NULL);
        CGImageDestinationAddImage(d, img, NULL);
        CGImageDestinationFinalize(d);
        printf("输出 %s (%zux%zu)\n", out.UTF8String, W, H);
        CGImageRelease(img);
        rgba_free(sheet);
    }
    return 0;
}
