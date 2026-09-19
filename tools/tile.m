/*
 * tile.m —— 把候选图标按「真机尺寸」摆一起，用最近邻放大看清楚。
 *
 * 输入法图标在菜单栏里就是 22x16 pt；2x 屏上是 44x32 个物理像素。
 * 把它渲染成 44x32 再按最近邻放大 6 倍，得到的就是**眼睛实际看到的像素网格**，
 * 比看放大的矢量图更能判断「这个字到底认不认得出」。
 *
 * 统一按「模板渲染 · 浅色模式」出图（系统真实的画法）：
 *   pixel = tint * alpha + 背景 * (1 - alpha)
 *
 * 用法： tile 输出.png  候选1.pdf:名字  候选2.pdf:名字 ...
 */
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>
#import <ImageIO/ImageIO.h>
#import <stdio.h>

#define ZOOM   6
#define PAD    24
#define LABEL  56
#define GAP    40

static double TINT[3]  = { 0.10, 0.10, 0.12 };   /* 浅色模式菜单栏的前景色 */
static double BG[3]    = { 0.93, 0.93, 0.94 };

typedef struct { unsigned char *px; size_t w, h; } RGBA;

static RGBA render_pdf(NSString *path, size_t w, size_t h)
{
    RGBA out = { calloc(h * w * 4, 1), w, h };
    CGPDFDocumentRef doc = CGPDFDocumentCreateWithURL(
        (__bridge CFURLRef)[NSURL fileURLWithPath:path]);
    if (!doc) return out;
    CGPDFPageRef page = CGPDFDocumentGetPage(doc, 1);
    CGRect box = CGPDFPageGetBoxRect(page, kCGPDFMediaBox);
    CGContextRef ctx = CGBitmapContextCreate(out.px, w, h, 8, w * 4,
                                             CGColorSpaceCreateDeviceRGB(),
                                             kCGImageAlphaPremultipliedLast |
                                             kCGBitmapByteOrder32Big);
    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    CGContextSetShouldAntialias(ctx, true);
    double sc = (double)w / box.size.width;
    CGContextScaleCTM(ctx, sc, sc);
    CGContextDrawPDFPage(ctx, page);
    CGContextRelease(ctx);
    CGPDFDocumentRelease(doc);
    /* 实测：位图内存第 0 行就是图像顶部，不用翻转 */
    return out;
}

static void draw_text(CGContextRef ctx, NSString *s, CGPoint at, double size, double r, double g, double b)
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
        if (argc < 3) { fprintf(stderr, "用法: tile 输出.png 候选.pdf:名字 ...\n"); return 2; }
        NSString *out = @(argv[1]);
        int n = argc - 2;

        size_t cellW = 22 * 2 * ZOOM, cellH = 16 * 2 * ZOOM;      /* 按 2x 屏的物理像素放大 */
        size_t W = PAD * 2 + n * cellW + (n - 1) * GAP;
        size_t H = PAD * 2 + cellH + LABEL;

        size_t bpr = W * 4;
        unsigned char *buf = calloc(H, bpr);
        /* 画布行 0 = 顶部，直接按行写 */
        for (size_t i = 0; i < W * H; i++) {
            buf[i*4+0] = 250; buf[i*4+1] = 250; buf[i*4+2] = 251; buf[i*4+3] = 255;
        }

        for (int i = 0; i < n; i++) {
            NSString *spec = @(argv[2 + i]);
            NSRange colon = [spec rangeOfString:@":"];
            NSString *path = colon.location == NSNotFound ? spec : [spec substringToIndex:colon.location];
            NSString *name = colon.location == NSNotFound ? spec : [spec substringFromIndex:colon.location + 1];

            RGBA src = render_pdf(path, 22 * 2, 16 * 2);
            size_t cx = PAD + i * (cellW + GAP);

            /* 底色块 + 模板图着色，然后最近邻放大 */
            for (size_t y = 0; y < cellH; y++) {
                for (size_t x = 0; x < cellW; x++) {
                    size_t sx = x / ZOOM, sy = y / ZOOM;
                    double a = src.px[(sy * src.w + sx) * 4 + 3] / 255.0;
                    unsigned char *d = buf + ((PAD + y) * W + (cx + x)) * 4;
                    for (int c = 0; c < 3; c++)
                        d[c] = (unsigned char)(TINT[c] * a * 255 + BG[c] * (1 - a) + 0.5);
                    d[3] = 255;
                }
            }
            free(src.px);

            /* 名字 */
            CGContextRef ctx = CGBitmapContextCreate(buf, W, H, 8, bpr,
                                                     CGColorSpaceCreateDeviceRGB(),
                                                     kCGImageAlphaPremultipliedLast |
                                                     kCGBitmapByteOrder32Big);
            draw_text(ctx, name, CGPointMake(cx, H - PAD - cellH - 34), 22, .15, .15, .2);
            CGContextRelease(ctx);
        }

        CGDataProviderRef dp = CGDataProviderCreateWithData(NULL, buf, W * H * 4, NULL);
        CGImageRef img = CGImageCreate(W, H, 8, 32, bpr, CGColorSpaceCreateDeviceRGB(),
                                       kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big,
                                       dp, NULL, false, kCGRenderingIntentDefault);
        CGImageDestinationRef d = CGImageDestinationCreateWithURL(
            (__bridge CFURLRef)[NSURL fileURLWithPath:out], CFSTR("public.png"), 1, NULL);
        CGImageDestinationAddImage(d, img, NULL);
        CGImageDestinationFinalize(d);
        printf("输出 %s (%zux%zu)，每个方块 = 22x16 pt 在 2x 屏上的真实像素，放大 %d 倍\n",
               out.UTF8String, W, H, ZOOM);
    }
    return 0;
}
