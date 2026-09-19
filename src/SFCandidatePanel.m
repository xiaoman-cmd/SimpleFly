#import "SFCandidatePanel.h"
#import "SFCandidateTheme.h"
#include <math.h>

/* ==================================================================== *
 * 配色不再写死：颜色全部来自 SFCandidateTheme（见 SFCandidateTheme.{h,m}）。
 * 这里只保留「度量」（间距 / 圆角 / 字号）和字体选择；颜色随主题切换。
 *
 * 主题色值的原始依据（metro 主题）仍记录在 SFCandidateTheme.m 的注释里：
 *   Rime 的 preset_color_schemes/metro，色值是 24 位 **BGR**（0xBBGGRR），
 *   例如 hilited_candidate_back_color: 0xe89f00 实际是 #009FE8（青蓝，非橙色）。
 *
 * 想加主题：往 SFCandidateTheme.m 的 kThemes 表加一行 10 个色值即可，
 * 名字会自动出现在 allThemeNames，切换（Ctrl+;）也会带上它。
 * ==================================================================== */

/* squirrel.yaml 的 style.font_face 默认是 'Avenir'，metro 没有覆盖它，所以鼠须管用的是 Avenir。
 * Avenir 没有中文字形，中文由系统自动回退到 PingFang —— 中文候选的观感于是与鼠须管一致。
 * 取不到 Avenir 就退回系统字体。 */
static NSFont *SFMetroFont(CGFloat point)
{
    return [NSFont fontWithName:@"Avenir" size:point] ?: [NSFont systemFontOfSize:point];
}

static const CGFloat kPadX    = 8.0;    /* metro border_width  */
static const CGFloat kPadY    = 8.0;    /* metro border_height */
static const CGFloat kRadius  = 6.0;    /* metro corner_radius */
static const CGFloat kCodeGap = 8.0;    /* squirrel.yaml style.spacing：编码与候选之间 */
static const NSUInteger kSFGridCols = 9;  /* 每行几个候选（对应数字键 1-9） */
static const CGFloat kRowGap    = 2.0;    /* 行间距 */
static const CGFloat kHeaderGap = 6.0;    /* 页眉和第一行之间 */
static const CGFloat kHUDPadX = 12.0;
static const CGFloat kHUDPadY = 6.0;
static const NSTimeInterval kHUDSeconds = 1.0;

#pragma mark - 候选

@implementation SFCandidate
+ (instancetype)text:(NSString *)text note:(NSString *)note
{
    SFCandidate *c = [[SFCandidate alloc] init];
    c.text = text;
    c.note = note;
    return c;
}
- (NSString *)description { return self.note ? [NSString stringWithFormat:@"%@(%@)", self.text, self.note]
                                                : self.text; }
@end

#pragma mark - 绘制视图

@interface SFCandidateView : NSView
@property (nonatomic, copy) NSString *code;
@property (nonatomic, copy) NSArray<SFCandidate *> *candidates;
@property (nonatomic, assign) NSUInteger selectedIndex;   /* 方向键移动的就是它 */
@property (nonatomic, copy) NSString *hud;      /* 非空时只画模式提示 */
@property (nonatomic, assign) BOOL hudAccent;
@property (nonatomic, strong) SFCandidateTheme *theme;     /* 当前配色主题 */
- (NSSize)desiredSize;
@end

@implementation SFCandidateView

- (instancetype)initWithFrame:(NSRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        _theme = [SFCandidateTheme themeNamed:@"metro"];   /* 兜底默认，panel 会覆盖 */
    }
    return self;
}

- (BOOL)isFlipped { return YES; }   /* y 向下增长，排版更直观 */

- (NSDictionary *)candAttrs      { return @{ NSFontAttributeName: SFMetroFont(18),
                                             NSForegroundColorAttributeName: self.theme.candText }; }
- (NSDictionary *)labelAttrs     { return @{ NSFontAttributeName: SFMetroFont(14),
                                             NSForegroundColorAttributeName: self.theme.label }; }
- (NSDictionary *)selCandAttrs   { return @{ NSFontAttributeName: SFMetroFont(18),
                                             NSForegroundColorAttributeName: self.theme.selText }; }
- (NSDictionary *)selLabelAttrs  { return @{ NSFontAttributeName: SFMetroFont(14),
                                             NSForegroundColorAttributeName: self.theme.selLabel }; }
- (NSDictionary *)codeAttrs      { return @{ NSFontAttributeName: SFMetroFont(16),
                                             NSForegroundColorAttributeName: self.theme.codeText }; }
- (NSDictionary *)noteAttrs      { return @{ NSFontAttributeName: SFMetroFont(13),
                                             NSForegroundColorAttributeName: self.theme.note }; }
- (NSDictionary *)selNoteAttrs   { return @{ NSFontAttributeName: SFMetroFont(13),
                                             NSForegroundColorAttributeName: self.theme.selNote }; }
- (NSDictionary *)hudAttrs       { return @{ NSFontAttributeName: SFMetroFont(14),
                                             NSForegroundColorAttributeName:
                                                 (self.hudAccent ? self.theme.selBack : self.theme.codeText) }; }

/* metro 的 candidate_format 是 "%c\u2005%@\u2005"，即
 *   编号 + 1/6em 空格 + 词条 + 1/6em 空格
 * 所以候选之间不另加间距（两个 1/6em 就是自然间隔），高亮块也因此紧贴文字。
 * widget 宽度与 drawRect 共用这一个算式，避免两处算不一致。 */
/* 网格排版：把「当前页」的候选排成若干行，每行最多 kSFGridCols 个。
 *
 * 为什么要网格：metro 原本是**单行**排布，一页只看得到 9 个。查编码要列出同音的
 * 一整族字（hao 42 个、yi 199 个），单行排不下，于是改成 3 行 × 9 列 = 27 个一页。
 * 普通组字仍然最多 9 条，永远只有一页，观感不变。
 *
 * 每行的高度统一（取候选字号的行高），不等高会让网格看着歪。
 * items 里的 x 在这里一次算好，绘制时不再重复累加。 */
- (NSArray<NSArray<NSDictionary *> *> *)layoutRowsWithPageStart:(NSUInteger *)outStart
                                                          total:(NSUInteger *)outTotal
{
    NSArray<SFCandidate *> *all = self.candidates;
    NSUInteger total = all.count;
    NSRange page = [SFCandidatePanel pageRangeForSelected:self.selectedIndex count:total];
    if (outStart) *outStart = page.location;
    if (outTotal) *outTotal = total;
    if (page.length == 0) return @[];

    NSMutableArray<NSArray<NSDictionary *> *> *rows = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *cur  = [NSMutableArray array];

    NSDictionary *labelAttrs = self.labelAttrs;
    NSDictionary *textAttrs  = self.candAttrs;
    CGFloat thin = [@"\u2005" sizeWithAttributes:textAttrs].width;
    CGFloat x = kPadX;

    for (NSUInteger i = page.location; i < NSMaxRange(page); i++) {
        SFCandidate *c  = all[i];
        /* 编号是**本页内**的序号（1..27），不是全局序号 ——
         * 这样数字键 1-9 在任何一页都对应本页第一行的九个，语义一致。 */
        NSString *label = [NSString stringWithFormat:@"%lu", (unsigned long)(i - page.location + 1)];
        NSSize sl = [label sizeWithAttributes:labelAttrs];
        NSSize st = [c.text sizeWithAttributes:textAttrs];
        CGFloat w = sl.width + thin + st.width + thin;

        CGFloat nw = 0;
        if (c.note.length > 0) {
            nw = [c.note sizeWithAttributes:self.noteAttrs].width;
            w += thin + nw;
        }

        [cur addObject:@{ @"x": @(x), @"w": @(w),
                          @"labelw": @(sl.width), @"thin": @(thin), @"notew": @(nw),
                          @"label": label, @"text": c.text, @"note": c.note ?: @"",
                          @"index": @(i) }];
        x += w;

        if (cur.count == kSFGridCols) { [rows addObject:cur]; cur = [NSMutableArray array]; x = kPadX; }
    }
    if (cur.count) [rows addObject:cur];
    return rows;
}

- (CGFloat)rowHeight   { return ceil([@"汉" sizeWithAttributes:self.candAttrs].height); }
- (CGFloat)headerHeight{ return ceil([@"h"  sizeWithAttributes:self.codeAttrs].height); }

/* 页眉只在「有编码要显示」或「多于一项页」时出现。
 * 普通组字两个条件都不满足 → 不占高度，和以前的单行观感一致。 */
- (BOOL)showsHeaderWithTotal:(NSUInteger)total
{
    return self.code.length > 0 || [SFCandidatePanel pageCountFor:total] > 1;
}

- (NSString *)pageTextWithTotal:(NSUInteger)total
{
    NSUInteger pages = [SFCandidatePanel pageCountFor:total];
    if (pages <= 1) return @"";
    NSUInteger page  = self.selectedIndex / [SFCandidatePanel pageSize];
    return [NSString stringWithFormat:@"%lu/%lu", (unsigned long)(page + 1), (unsigned long)pages];
}

- (NSSize)desiredSize
{
    if (self.hud.length > 0) {
        NSSize s = [self.hud sizeWithAttributes:self.hudAttrs];
        return NSMakeSize(ceil(s.width) + kHUDPadX * 2, ceil(s.height) + kHUDPadY * 2);
    }

    NSUInteger start = 0, total = 0;
    NSArray<NSArray<NSDictionary *> *> *rows = [self layoutRowsWithPageStart:&start total:&total];
    if (rows.count == 0) return NSMakeSize(1, 1);

    CGFloat contentW = 0;
    for (NSArray<NSDictionary *> *row in rows) {
        NSDictionary *last = row.lastObject;
        contentW = MAX(contentW, [last[@"x"] doubleValue] + [last[@"w"] doubleValue]);
    }
    CGFloat w = MAX(contentW + kPadX, 40);

    CGFloat header = 0;
    if ([self showsHeaderWithTotal:total]) {
        CGFloat cw = self.code.length > 0 ? [self.code sizeWithAttributes:self.codeAttrs].width : 0;
        CGFloat iw = [[self pageTextWithTotal:total] sizeWithAttributes:self.noteAttrs].width;
        w = MAX(w, kPadX + cw + kCodeGap + iw + kPadX);
        header = [self headerHeight] + kHeaderGap;
    }

    CGFloat h = header + rows.count * [self rowHeight]
              + (rows.count - 1) * kRowGap + kPadY * 2;
    return NSMakeSize(w, h);
}

- (void)drawBackground
{
    NSBezierPath *bg =
        [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5)
                                        xRadius:kRadius yRadius:kRadius];
    [self.theme.back setFill];
    [bg fill];
    [self.theme.hairline setStroke];
    bg.lineWidth = 1.0;
    [bg stroke];
}

- (void)drawRect:(NSRect)dirtyRect
{
    [self drawBackground];

    /* 模式提示：一行居中文字，复用同一块面板 */
    if (self.hud.length > 0) {
        NSDictionary *attrs = self.hudAttrs;
        NSSize s = [self.hud sizeWithAttributes:attrs];
        [self.hud drawAtPoint:NSMakePoint((self.bounds.size.width  - s.width)  / 2.0,
                                          (self.bounds.size.height - s.height) / 2.0)
               withAttributes:attrs];
        return;
    }

    NSUInteger start = 0, total = 0;
    NSArray<NSArray<NSDictionary *> *> *rows = [self layoutRowsWithPageStart:&start total:&total];
    if (rows.count == 0) return;

    CGFloat y = kPadY;

    /* 页眉：左边是当前编码，右边是页码（多于一页时才画）。
     * 编码以前是挤在第一行里、跟着候选一起排的；改网格后单独占一行才对齐。 */
    if ([self showsHeaderWithTotal:total]) {
        if (self.code.length > 0)
            [self.code drawAtPoint:NSMakePoint(kPadX, y) withAttributes:self.codeAttrs];

        NSString *pt = [self pageTextWithTotal:total];
        if (pt.length > 0) {
            NSDictionary *a = self.noteAttrs;
            NSSize s = [pt sizeWithAttributes:a];
            [pt drawAtPoint:NSMakePoint(MAX(kPadX, self.bounds.size.width - kPadX - s.width), y + 2)
             withAttributes:a];
        }
        y += [self headerHeight] + kHeaderGap;
    }

    CGFloat rowH = [self rowHeight];

    for (NSArray<NSDictionary *> *row in rows) {
        for (NSDictionary *item in row) {
            CGFloat x = [item[@"x"] doubleValue];
            BOOL selected = ([item[@"index"] unsignedIntegerValue] == self.selectedIndex);

            if (selected) {
                NSRect pill = NSMakeRect(x, y - 2, [item[@"w"] doubleValue], rowH + 4);
                NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:pill xRadius:4 yRadius:4];
                [self.theme.selBack setFill];
                [path fill];
            }

            NSDictionary *labelAttrs = selected ? self.selLabelAttrs : self.labelAttrs;
            NSDictionary *textAttrs  = selected ? self.selCandAttrs  : self.candAttrs;
            CGFloat thin = [item[@"thin"] doubleValue];
            CGFloat labelw = [item[@"labelw"] doubleValue];
            CGFloat notew  = [item[@"notew"] doubleValue];

            [item[@"label"] drawAtPoint:NSMakePoint(x, y) withAttributes:labelAttrs];
            [item[@"text"]  drawAtPoint:NSMakePoint(x + labelw + thin, y) withAttributes:textAttrs];

            if (notew > 0) {
                /* 附注字号小一号，同一条基线压不住，往下挪一点才看着是齐的。
                 * x 直接由「块右边界 - 末尾 thin - 附注宽」反推，不用另存词条宽度。 */
                CGFloat nx = x + [item[@"w"] doubleValue] - thin - notew;
                [item[@"note"] drawAtPoint:NSMakePoint(nx, y + 3)
                            withAttributes:(selected ? self.selNoteAttrs : self.noteAttrs)];
            }
        }
        y += rowH + kRowGap;
    }
}

@end

#pragma mark - 面板

@implementation SFCandidatePanel {
    NSPanel *_panel;
    SFCandidateView *_view;
    NSTimer *_hideTimer;
}

#pragma mark 分页（纯计算，单测直接调）

+ (NSUInteger)pageSize { return kSFGridCols * 3; }   /* 9 列 × 3 行 */

+ (NSUInteger)pageCountFor:(NSUInteger)count
{
    NSUInteger ps = [self pageSize];
    if (count == 0 || ps == 0) return 0;
    return (count + ps - 1) / ps;
}

+ (NSRange)pageRangeForSelected:(NSUInteger)selected count:(NSUInteger)count
{
    NSUInteger ps = [self pageSize];
    if (count == 0 || ps == 0) return NSMakeRange(0, 0);
    if (selected >= count) selected = count - 1;      /* 越界一律夹回，调用方不必自己重置 */
    NSUInteger start = (selected / ps) * ps;
    return NSMakeRange(start, MIN(ps, count - start));
}

- (instancetype)init
{
    if ((self = [super init])) {
        _theme = [SFCandidateTheme themeNamed:@"metro"];
        _view = [[SFCandidateView alloc] initWithFrame:NSMakeRect(0, 0, 10, 10)];
        _view.theme = _theme;

        _panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 10, 10)
                                            styleMask:(NSWindowStyleMaskBorderless |
                                                       NSWindowStyleMaskNonactivatingPanel)
                                              backing:NSBackingStoreBuffered
                                                defer:NO];
        _panel.opaque = NO;
        _panel.backgroundColor = [NSColor clearColor];
        _panel.hasShadow = YES;
        _panel.level = NSPopUpMenuWindowLevel;
        _panel.ignoresMouseEvents = YES;
        _panel.collectionBehavior = (NSWindowCollectionBehaviorCanJoinAllSpaces |
                                     NSWindowCollectionBehaviorTransient |
                                     NSWindowCollectionBehaviorIgnoresCycle);
        _panel.contentView = _view;
    }
    return self;
}

- (void)dealloc { [_hideTimer invalidate]; }

- (NSScreen *)screenContaining:(NSPoint)point
{
    for (NSScreen *screen in [NSScreen screens])
        if (NSPointInRect(point, screen.frame)) return screen;
    return [NSScreen mainScreen];
}

- (void)presentAtTopLeft:(NSPoint)topLeft
{
    NSSize size = [_view desiredSize];
    [_panel setContentSize:size];
    _view.frame = NSMakeRect(0, 0, size.width, size.height);

    NSRect visible = [self screenContaining:topLeft].visibleFrame;
    NSPoint p = topLeft;
    if (p.x + size.width > NSMaxX(visible)) p.x = NSMaxX(visible) - size.width;
    if (p.x < NSMinX(visible))             p.x = NSMinX(visible);
    if (p.y - size.height < NSMinY(visible)) p.y = NSMinY(visible) + size.height;  /* 底下放不下就翻到上方 */

    [_panel setFrameOrigin:NSMakePoint(p.x, p.y - size.height)];
    [_panel orderFrontRegardless];
    [_view setNeedsDisplay:YES];
}

- (void)cancelHideTimer
{
    [_hideTimer invalidate];
    _hideTimer = nil;
}

- (void)showCandidates:(NSArray<SFCandidate *> *)candidates
                  code:(NSString *)code
              selected:(NSUInteger)selected
             atTopLeft:(NSPoint)topLeft
{
    if (candidates.count == 0) { [self hide]; return; }

    [self cancelHideTimer];
    _view.theme = _theme;
    _view.hud = nil;
    _view.hudAccent = NO;
    _view.code = code ?: @"";
    _view.candidates = candidates;
    /* 越界一律夹回合法范围 —— 调用方在「候选变少」时不必自己记得重置 */
    _view.selectedIndex = MIN(selected, candidates.count - 1);

    [self presentAtTopLeft:topLeft];
}

- (void)showHUD:(NSString *)text accent:(BOOL)accent seconds:(NSTimeInterval)secs
       atTopLeft:(NSPoint)topLeft
{
    if (text.length == 0) return;
    [self cancelHideTimer];

    _view.theme = _theme;
    _view.hud = text;
    _view.hudAccent = accent;
    _view.code = @"";
    _view.candidates = @[];
    _view.selectedIndex = 0;

    [self presentAtTopLeft:topLeft];

    _hideTimer = [NSTimer scheduledTimerWithTimeInterval:secs
                                                  target:self
                                                selector:@selector(hideTimerFired:)
                                                userInfo:nil
                                                 repeats:NO];
}

- (void)showHUD:(NSString *)text accent:(BOOL)accent atTopLeft:(NSPoint)topLeft
{
    [self showHUD:text accent:accent seconds:kHUDSeconds atTopLeft:topLeft];
}

- (void)hideTimerFired:(NSTimer *)timer
{
    (void)timer;
    _hideTimer = nil;
    [self hide];
}

- (void)hide
{
    [self cancelHideTimer];
    if (_panel.isVisible) [_panel orderOut:nil];
}

- (BOOL)isVisible { return _panel.isVisible; }

@end
