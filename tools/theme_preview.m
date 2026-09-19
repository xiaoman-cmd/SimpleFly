/* theme_preview.m —— 把内置主题各渲染一张候选窗，拼成一张 PNG。
 *
 * 为什么需要它：输入法要注销重登才重启进程，改个配色就重登一次太折腾。
 * 这里把 SFCandidateView（定义在 SFCandidatePanel.m 里的私有类）拉到离屏窗口里
 * 渲染一遍，直接出图，配色对不对一眼可见。
 *
 * 用法：
 *   build/theme_preview [输出.png]      默认 simplefly/docs/主题预览.png
 *
 * 编译见 build.sh 的 --preview 目标。
 */
#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>

#import "SFCandidatePanel.h"
#import "SFCandidateTheme.h"

/* SFCandidateView 是 SFCandidatePanel.m 里的私有类，这里只声明要用到的两个成员，
 * 其余一律走 KVC（setValue:forKey:），免得为出图去改产品代码的可见性。 */
@interface NSView (SFPreviewAccess)
- (NSSize)desiredSize;
@end

static NSImage *RenderTheme(SFCandidateTheme *theme,
                           NSArray<SFCandidate *> *cands,
                           NSString *code)
{
    Class V = NSClassFromString(@"SFCandidateView");
    if (!V) { fprintf(stderr, "拿不到 SFCandidateView（SFCandidatePanel.m 没链进来？）\n"); return nil; }

    NSView *v = [[V alloc] initWithFrame:NSMakeRect(0, 0, 400, 120)];
    [v setValue:theme      forKey:@"theme"];
    [v setValue:cands      forKey:@"candidates"];
    [v setValue:code       forKey:@"code"];
    [v setValue:@1         forKey:@"selectedIndex"];   /* 高亮第 2 项，能看到高亮块配色 */
    [v setValue:@""        forKey:@"hud"];

    NSSize s = [v desiredSize];
    NSRect r = NSMakeRect(0, 0, ceil(s.width), ceil(s.height));
    v.frame = r;

    /* 离屏渲染：挂到一个不显示的窗口上再抓，比直接调 drawRect: 稳（走完整显示链路） */
    NSWindow *w = [[NSWindow alloc] initWithContentRect:r
                                              styleMask:NSWindowStyleMaskBorderless
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    w.contentView = v;
    [v setNeedsDisplay:YES];
    [w display];

    NSBitmapImageRep *rep = [v bitmapImageRepForCachingDisplayInRect:r];
    if (!rep) { fprintf(stderr, "离屏渲染失败\n"); return nil; }
    [v cacheDisplayInRect:r toBitmapImageRep:rep];

    NSImage *img = [[NSImage alloc] initWithSize:r.size];
    [img addRepresentation:rep];
    return img;
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        [NSApplication sharedApplication];

        NSString *out = (argc > 1) ? [NSString stringWithUTF8String:argv[1]]
                                   : @"../docs/主题预览.png";
        NSString *outPath = out.stringByStandardizingPath;

        /* 造一组候选：模拟「查编码」模式（每条带音形码附注，能看出 note 的配色） */
        NSArray<NSString *> *words = @[ @"好", @"号", @"浩", @"豪", @"毫", @"耗", @"皓", @"昊", @"灏" ];
        NSArray<NSString *> *notes = @[ @"hc·nz", @"hc·kb", @"hc·js", @"hc·wk", @"hc·yb",
                                        @"hc·qb", @"hc·rb", @"hc·rt", @"hc·js" ];
        NSMutableArray<SFCandidate *> *cands = [NSMutableArray array];
        for (NSUInteger i = 0; i < words.count; i++)
            [cands addObject:[SFCandidate text:words[i] note:(i < notes.count ? notes[i] : nil)]];

        NSArray<NSString *> *names = [SFCandidateTheme allThemeNames];

        /* 先各渲染一张，量出总尺寸再拼 */
        NSMutableArray<NSImage *> *imgs = [NSMutableArray array];
        CGFloat maxW = 0, totalH = 0;
        const CGFloat kLabelW = 96.0;
        const CGFloat kGap    = 18.0;
        const CGFloat kPad    = 24.0;

        for (NSString *n in names) {
            NSImage *img = RenderTheme([SFCandidateTheme themeNamed:n], cands, @"hc");
            if (!img) return 1;
            [imgs addObject:img];
            maxW   = MAX(maxW, img.size.width);
            totalH += img.size.height + kGap;
        }

        NSSize canvas = NSMakeSize(kPad * 2 + kLabelW + maxW, kPad * 2 + totalH - kGap);
        NSImage *sheet = [[NSImage alloc] initWithSize:canvas];

        [sheet lockFocus];
        [[NSColor colorWithSRGBRed:0.93 green:0.93 blue:0.94 alpha:1.0] setFill];
        NSRectFill(NSMakeRect(0, 0, canvas.width, canvas.height));

        CGFloat y = canvas.height - kPad;
        NSUInteger idx = 0;
        for (NSImage *img in imgs) {
            y -= img.size.height;

            /* 左侧标注主题名 */
            NSString *label = names[idx];
            NSDictionary *attrs = @{ NSFontAttributeName: [NSFont systemFontOfSize:13
                                                                          weight:NSFontWeightMedium],
                                     NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:0.25
                                                                                        green:0.25
                                                                                         blue:0.26
                                                                                        alpha:1.0] };
            [label drawAtPoint:NSMakePoint(kPad, y + 4) withAttributes:attrs];

            [img drawAtPoint:NSMakePoint(kPad + kLabelW, y)
                    fromRect:NSMakeRect(0, 0, img.size.width, img.size.height)
                   operation:NSCompositingOperationSourceOver
                    fraction:1.0];

            y -= kGap;
            idx++;
        }
        [sheet unlockFocus];

        NSData *png = nil;
        CGImageRef cg = [sheet CGImageForProposedRect:NULL context:nil hints:nil];
        if (cg) {
            NSBitmapImageRep *r = [[NSBitmapImageRep alloc] initWithCGImage:cg];
            png = [r representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        }
        if (!png) { fprintf(stderr, "导出 PNG 失败\n"); return 1; }

        [[NSFileManager defaultManager] createDirectoryAtPath:outPath.stringByDeletingLastPathComponent
                                  withIntermediateDirectories:YES attributes:nil error:NULL];
        BOOL ok = [png writeToFile:outPath atomically:YES];
        printf("%s\n", ok ? outPath.UTF8String : "写文件失败");
        return ok ? 0 : 1;
    }
}
