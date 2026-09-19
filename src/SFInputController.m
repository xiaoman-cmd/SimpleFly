#import "SFInputController.h"
#import "SFCandidatePanel.h"
#import "SFCandidateTheme.h"

#include "engine.h"
#include "punctuation.h"
#include "phrase.h"
#include "pinyin.h"
#include "freq.h"
#include "s2t.h"
#include <time.h>

/* IMKTextInput 协议的声明头（IMKInputSession.h）没有随 Command Line Tools 的 SDK 发布，
 * 这里只按需声明用到的方法。取光标位置就靠 attributesForCharacterIndex:lineHeightRectangle:。
 * 调用前一律用 respondsToSelector: 兜底，取不到就退回鼠标位置。 */
@protocol SFTextInputClient <NSObject>
- (void)insertText:(id)string replacementRange:(NSRange)replacementRange;
- (NSDictionary *)attributesForCharacterIndex:(NSUInteger)index lineHeightRectangle:(NSRect *)lineRect;
@end

/* ------------------------------------------------------------------ *
 * 事件接收方式的选择（决定了本文件为什么长这样）
 *
 * IMKInputController.h 的原文：
 *   "there are three ways to receive events here. An input method should
 *    choose one of those ways and implement the appropriate methods"
 *     1. inputText:client:  + didCommandBySelector:client:   ← 键位绑定
 *     2. inputText:key:modifiers:client:                    ← 只要文本数据
 *     3. handleEvent:client:                                ← 直接收 NSEvent
 *
 * 三条路互斥，只能选一条。这里选第 3 条，理由有两个：
 *   - 第 1 条永远收不到「单敲 Shift」——修饰键不产生 keyDown，系统只会给出
 *     flagsChanged，而 flagsChanged 只走 handleEvent:。中英一键切换必须要它。
 *   - 第 3 条能拿到完整的 modifierFlags 与 keyCode，模式开关键的判断更直接。
 *
 * 代价：recognizedEvents 不再等于默认的 NSKeyDownMask，IMK 那套「鼠标点在组合区外
 * 自动 commitComposition:」的默认处理就失效了，必须自己实现 mouseDownOnCharacterIndex:。
 * ------------------------------------------------------------------ */

#pragma mark - 码表加载

static NSString *SFAppSupportDir(void)
{
    NSArray<NSString *> *dirs =
        NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString *base = dirs.firstObject ?: [@"~/Library/Application Support" stringByExpandingTildeInPath];
    return [base stringByAppendingPathComponent:@"SimpleFly"];
}

/* 用户覆盖用的码表。与 SFPhrasePath / SFS2TPath 同构：支持环境变量指到别处，
 * 这样缺码表的分支也能离线测（把它指到一个不存在的路径即可）。 */
static NSString *SFUserDictPath(void)
{
    const char *env = getenv("SIMPLEFLY_DICT_FILE");
    if (env && *env) return [NSString stringWithUTF8String:env];
    return [SFAppSupportDir() stringByAppendingPathComponent:@"simplefly.dict"];
}

/* 自定义快捷输入表：abc = 测试短语 那一份。
 * 支持用环境变量指到别处 —— 离线单测靠它把短语表放到临时目录，
 * 免得跑一次测试就把用户自己配的短语覆盖掉。 */
static NSString *SFPhrasePath(void)
{
    const char *env = getenv("SIMPLEFLY_PHRASE_FILE");
    if (env && *env) return [NSString stringWithUTF8String:env];
    return [SFAppSupportDir() stringByAppendingPathComponent:@"phrase.txt"];
}

/* 重码记忆文件（freq.txt）：编码 → 上次选中的词条。
 * 同样支持环境变量指到别处 —— 离线单测靠它把记忆文件放进临时目录。 */
static NSString *SFFreqPath(void)
{
    const char *env = getenv("SIMPLEFLY_FREQ_FILE");
    if (env && *env) return [NSString stringWithUTF8String:env];
    return [SFAppSupportDir() stringByAppendingPathComponent:@"freq.txt"];
}

/* 打错日志文件（mislog.tsv）：「时间戳 \t 被废弃的编码 \t 最终上屏的词」。
 * 同样支持环境变量指到别处 —— 离线单测靠它把日志放进临时目录。 */
static NSString *SFMislogPath(void)
{
    const char *env = getenv("SIMPLEFLY_MISLOG_FILE");
    if (env && *env) return [NSString stringWithUTF8String:env];
    return [SFAppSupportDir() stringByAppendingPathComponent:@"mislog.tsv"];
}

/* 简→繁单字映射表（resources/s2t.tsv，tools/gen_s2t.py 从 OpenCC 生成）。
 * 顺序：环境变量（离线单测）→ bundle 资源 → 可执行文件旁边（测试二进制无 Resources）。 */
static NSString *SFS2TPath(void)
{
    const char *env = getenv("SIMPLEFLY_S2T_FILE");
    if (env && *env) return [NSString stringWithUTF8String:env];
    NSString *p = [[NSBundle mainBundle] pathForResource:@"s2t" ofType:@"tsv"];
    if (p.length) return p;
    NSString *exe = [[NSBundle mainBundle] executablePath];
    if (exe.length == 0) return @"";
    return [[exe stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"s2t.tsv"];
}

/* 繁→简单字映射表（resources/t2s.tsv，tools/gen_t2s.py 从 OpenCC TSCharacters.txt 生成）。
 * 与 SFS2TPath 同构：环境变量（离线单测）→ bundle 资源 → 可执行文件旁边。 */
static NSString *SFT2SPath(void)
{
    const char *env = getenv("SIMPLEFLY_T2S_FILE");
    if (env && *env) return [NSString stringWithUTF8String:env];
    NSString *p = [[NSBundle mainBundle] pathForResource:@"t2s" ofType:@"tsv"];
    if (p.length) return p;
    NSString *exe = [[NSBundle mainBundle] executablePath];
    if (exe.length == 0) return @"";
    return [[exe stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"t2s.tsv"];
}

/* 进程级单例：优先用用户覆盖的码表，其次用 app bundle 里自带的那份。
 * 在 main() 里主动调一次，让加载结果立刻出现在日志里，而不是等第一次按键。 */
SFEngine *SFSharedEngine(void)
{
    static SFEngine *engine;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        /* 环境变量显式指定码表时**不回退**：既然指名要这份，找不到就该报出来。
         * 否则把它指到一个不存在的路径会静默用回 bundle 里那份，
         * 「缺码表」这条分支永远测不到（离线单测正是靠这个变量模拟缺表的）。 */
        const char *env = getenv("SIMPLEFLY_DICT_FILE");
        NSString *path = SFUserDictPath();
        if (!(env && *env) && ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            path = [[NSBundle mainBundle] pathForResource:@"simplefly" ofType:@"dict"];
        }
        if (path.length == 0) {
            NSLog(@"[SimpleFly] 找不到码表（既不在 ~/Library/Application Support/SimpleFly/，也不在 bundle 里）");
            return;
        }
        engine = sf_engine_load(path.fileSystemRepresentation);
        if (engine) {
            NSLog(@"[SimpleFly] 码表就绪：%zu 条 / %zu 个编码  ← %@",
                  sf_engine_size(engine), sf_engine_code_count(engine), path);
        } else {
            NSLog(@"[SimpleFly] 码表加载失败 ← %@：%s", path, sf_engine_last_error());
        }
    });
    return engine;
}

/* 官方 schema 的 speller.alphabet = "abcdefghijklmnopqrstuvwxyz;'" */
static BOOL SFIsCodeChar(unichar c)
{
    return (c >= 'a' && c <= 'z') || c == ';' || c == '\'';
}

/* 候选来自哪里。数字键 / 空格 / 方向键的语义对三者一致，用同一个枚举区分来源。 */
typedef NS_ENUM(NSInteger, SFPickMode) {
    SFPickNone   = 0,
    SFPickCode   = 1,   /* 正在组字，候选来自码表（可能还混着自定义短语） */
    SFPickPunct  = 2,   /* 按了一个有多个候选的标点键（如 [ → 「【〔［） */
    SFPickSearch = 3,   /* 查编码模式：候选来自「拼音/双拼 → 码表」，每条带音形码附注 */
};

#pragma mark - 控制器

@implementation SimpleFlyInputController {
    NSMutableString *_code;                 /* 当前编码缓冲（查编码模式下是拼音） */
    NSArray<SFCandidate *> *_cands;         /* 当前候选（码表 / 标点 / 查编码） */
    NSUInteger _sel;                        /* 候选窗里高亮第几项（方向键移动的就是它） */
    SFPickMode _mode;
    NSDictionary<NSNumber *, NSNumber *> *_pairState;  /* 成对引号交替计数，按 key 分别记 */
    BOOL _composing;                        /* 输入框里当前是否挂着内嵌编码 */

    BOOL _asciiMode;                        /* 英文模式（Shift 切换） */
    BOOL _punctAscii;                       /* ascii_punct：标点用英文的（Ctrl+. 切换） */
    BOOL _fullShape;                        /* full_shape：全角（Shift+空格 切换） */
    BOOL _shiftDown;                        /* Shift 当前是否按下 */
    BOOL _shiftCombo;                       /* Shift 按下期间是否又按了别的键 */

    BOOL _reverseMode;                      /* 「查编码」模式开关（Ctrl+/ 切换） */
    SFPhrases *_phraseBook;                 /* 自定义快捷输入表。惰性加载 + 按 mtime 热重载 */
    SFFreq *_freq;                          /* 重码记忆：编码 → 上次选中的词条（freq.c） */

    SFCandidatePanel *_panel;
    BOOL _autoCommit4;
    BOOL _completion;
    BOOL _inlinePreedit;
    BOOL _reverseAutoExit;                  /* 查到一个字就自动退出查编码模式 */
    CGFloat _panelDX;
    CGFloat _panelDY;
    BOOL _panelFlipY;                       /* IMK 返回的 rect 原点方向未定，见 candidateTopLeftWithClient: */
    BOOL _debugPanelRect;                   /* 打 raw rect + 鼠标位置，用于一次性确定原点方向 */
    BOOL _freqMemory;                       /* 重码记忆开关（FreqMemory，默认开） */
    BOOL _logMisses;                        /* 打错日志开关（LogMisses，默认关，见 §3.2 建议） */
    BOOL _outputTrad;                       /* 输出模式：YES=上屏转繁体，NO=简体（Ctrl+Shift+T 切换） */
    NSString *_missCandidate;               /* 本次 commit 以来最长的 ≥2 码尝试（打错日志用） */
    NSString *_pendingMiss;                 /* 被废弃、等下一次上屏来配对的码 */
    NSUInteger _maxCands;
    NSString *_themeName;                   /* 当前主题名，对应 NSUserDefaults 的 Theme */
    NSTimeInterval _dictWarnAt;             /* 上次弹「缺码表」提示的时间（节流用） */
}

- (id)initWithServer:(IMKServer *)server delegate:(id)delegate client:(id)inputClient
{
    if ((self = [super initWithServer:server delegate:delegate client:inputClient])) {
        [self setupState];
    }
    return self;
}

/* 状态初始化单独拆出来，不写在 initWithServer: 里。
 * 原因：IMKInputController 的 initWithServer:delegate:client: 会校验 client 是不是
 * 真实的输入会话代理（传个普通对象进去直接抛 NSInvalidArgumentException），
 * 于是离线单测没法走那条路 —— 它 alloc 之后直接调这个方法。
 * 本方法只碰自己的 ivar，不依赖 IMK 的任何内部状态。 */
- (void)setupState
{
    _code      = [NSMutableString string];
    _cands     = @[];
    _sel       = 0;
    _pairState = @{};
    _panel     = [[SFCandidatePanel alloc] init];

    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d registerDefaults:@{ @"AutoCommit4":      @YES,
                           @"EnableCompletion": @YES,
                           @"MaxCandidates":    @(SF_MAX_CANDS),
                           /* metro 主题的 inline_preedit: true —— 编码显示在输入框里，
                            * 候选窗只放候选。关掉它就退回「编码画在候选窗左侧」。 */
                           @"InlinePreedit":    @YES,
                           @"PunctAscii":       @NO,
                           @"FullShape":        @NO,
                           /* 想每次开机就落在英文模式就把它设 YES；默认每次从中文开始，
                            * 免得「怎么打不出汉字」这种困惑。 */
                           @"InitialAsciiMode": @NO,
                           /* 查编码模式默认「常驻」：进入后一直保持拼音输入，可以连续打拼音出字，
                            * 每个候选后面都标音形码；上屏后不退出，按 Esc / 再按一次 Ctrl+/ 才退。
                            * 想要「查一个字就退回小鹤」就把 ReverseModeAutoExit 设 YES。 */
                           @"ReverseModeAutoExit": @NO,
                           /* 候选窗配色主题。内置 metro（浅，默认）/ dark（深）/ paper（暖白）。
                            * 改它可以不重启输入法 —— 按一下 Ctrl+; 循环切换，或
                            *   defaults write com.simplefly.inputmethod.SimpleFly Theme dark
                            * 直接指定（要生效得先注销重登，让输入法进程重启）。 */
                           @"Theme":            @"metro",
                           @"PanelOffsetX":     @0.0,
                           @"PanelOffsetY":     @0.0,
                           /* 候选窗定位诊断用（真机验收项，见 README §8）：
                            *   DebugPanelRect YES → 每次定位都 NSLog 出 IMK 原始 rect / 鼠标位置 / 最终点。
                            *   PanelFlipY     YES → 把 rect 的 y 在屏幕上做一次镜像再当「原点在左下」用。
                            * 两者一起开，一次就能定下原点方向，之后把 DebugPanelRect 关掉即可。
                            * 注意 PanelOffsetX/Y 只能救固定距离的错；原点方向反了是和光标高度成正比的错，
                            * 偏移量调不出来，必须用 PanelFlipY。 */
                           @"PanelFlipY":       @NO,
                           @"DebugPanelRect":   @NO,
                           /* 重码记忆（0.5.3）：记住「这个编码上次选了谁」，下次重排到第一位。
                            * 单值、可复现、可手改（freq.txt 一行一条）、30 天没用自动忘，
                            * 与官方 enable_user_dict: false 的设计取向不冲突 —— 见 freq.h。 */
                           @"FreqMemory":       @YES,
                           /* 打错日志：记「打了又废弃的编码 → 最终上屏了什么」，跑一周后
                            * 用 tools/suggest_phrases.py 生成贴合自己的短语建议。
                            * 默认关 —— 虽然只落本地，但把「你打过的字」记成明文必须显式开。 */
                           @"LogMisses":        @NO,
                           /* 输出模式（0.5.6）：YES = 所有上屏文字转繁体（单字映射）。
                            * 给「想直接打繁体」的场景 —— 不用打完再 Ctrl+Shift+F 全选转换。 */
                           @"OutputTrad":       @NO }];

    _autoCommit4     = [d boolForKey:@"AutoCommit4"];
    _completion      = [d boolForKey:@"EnableCompletion"];
    _inlinePreedit   = [d boolForKey:@"InlinePreedit"];
    _punctAscii      = [d boolForKey:@"PunctAscii"];
    _fullShape       = [d boolForKey:@"FullShape"];
    _asciiMode       = [d boolForKey:@"InitialAsciiMode"];
    _reverseAutoExit = [d boolForKey:@"ReverseModeAutoExit"];
    _panelDX         = [d doubleForKey:@"PanelOffsetX"];
    _panelDY         = [d doubleForKey:@"PanelOffsetY"];
    _panelFlipY      = [d boolForKey:@"PanelFlipY"];
    _debugPanelRect  = [d boolForKey:@"DebugPanelRect"];
    _freqMemory      = [d boolForKey:@"FreqMemory"];
    _logMisses       = [d boolForKey:@"LogMisses"];
    _outputTrad      = [d boolForKey:@"OutputTrad"];

    /* 主题名可能是用户手写的（defaults write），不在内置列表里就退回 metro，
     * 免得面板拿到无配色对象而崩在绘制里。 */
    NSString *themeName = [d stringForKey:@"Theme"];
    if (![[SFCandidateTheme allThemeNames] containsObject:themeName]) themeName = @"metro";
    _themeName   = themeName;
    _panel.theme = [SFCandidateTheme themeNamed:_themeName];

    NSInteger m = [d integerForKey:@"MaxCandidates"];
    _maxCands   = (m >= 1 && m <= SF_MAX_CANDS) ? (NSUInteger)m : (NSUInteger)SF_MAX_CANDS;
}

#pragma mark 事件接收方式

/* 默认实现只返回 NSKeyDownMask。必须显式加上 FlagsChanged，否则收不到 Shift 的按下/抬起；
 * 加了 LeftMouseDown 是为了自己补上「点在组合区外就结束组字」这件事（见文件头注释）。 */
- (NSUInteger)recognizedEvents:(id)sender
{
    (void)sender;
    return NSEventMaskKeyDown | NSEventMaskFlagsChanged | NSEventMaskLeftMouseDown;
}

/* IMK 通过 updateComposition 取这个串发给客户端（内部就是 setMarkedText:）。
 * 返回空串即「清掉内嵌编码」。 */
- (id)composedString:(id)sender
{
    (void)sender;
    return _code ?: @"";
}

- (BOOL)handleEvent:(NSEvent *)event client:(id)sender
{
    switch (event.type) {
        case NSEventTypeFlagsChanged:
            [self handleFlagsChanged:event client:sender];
            return NO;                 /* 修饰键本身不该被吞掉 */
        case NSEventTypeKeyDown:
            return [self handleKeyDown:event client:sender];
        default:
            return NO;
    }
}

/* 单敲 Shift 切中/英：Shift 不含其它键 → 切换；Shift+字母/Shift+空格 → 只是组合键，不切。
 * 判断放在「抬起」那一刻做，因为按下时还不知道后面会不会跟别的键。
 * 这里把 client 一路传下去，模式浮层才能贴在插入点而不是鼠标位置。 */
- (void)handleFlagsChanged:(NSEvent *)event client:(id)sender
{
    NSEventModifierFlags f = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    BOOL shift = (f & NSEventModifierFlagShift) != 0;

    if (shift && !_shiftDown) {
        _shiftDown  = YES;
        _shiftCombo = NO;
    } else if (!shift && _shiftDown) {
        _shiftDown = NO;
        /* 查编码模式下不切中英 —— 它的字母本来就要被输入法拦下来去查拼音，
         * 切到「英文」会让输入法不再拦键，模式看着就坏了。 */
        if (!_shiftCombo && !_reverseMode) [self toggleAsciiMode:sender];
    }
}

#pragma mark 客户端交互

- (void)commitText:(NSString *)text client:(id)sender
{
    /* 输出模式（0.5.6）：开了「输出：繁体」就让所有上屏文字过一遍简→繁映射。
     * 放在 commitText 是因为它是唯一上屏出口 —— 候选、短语、英文回退全走这里，
     * 一处转换全场景生效；映射是单字查表，纯汉字以外的内容原样直通，开销可忽略。 */
    if (_outputTrad && text.length > 0) {
        NSString *trad = [self convertedString:text withTable:[self s2tTable]];
        if (trad) text = trad;
    }
    [self logPendingMissWithCommit:text];     /* 打错日志：废弃码 ←→ 最终上屏词 配对 */
    _missCandidate = nil;
    if (text.length > 0) {
        [(id<SFTextInputClient>)sender insertText:text
                               replacementRange:NSMakeRange(NSNotFound, NSNotFound)];
    }
    /* 上屏后不用再动 marked text：insertText 已经把输入框里的内嵌编码替换掉了。 */
    [_code setString:@""];
    _composing = NO;
    _cands     = @[];
    _sel       = 0;
    _mode      = SFPickNone;
    [_panel hide];
}

/* 丢弃当前状态（Esc / 切模式 / 点击别处）。与 commitText: 的区别是「什么都没输出」，
 * 所以得主动把输入框里的内嵌编码抹掉。刻意不叫 cancelComposition: —— 那是 IMK 自己的方法名。 */
- (void)discardComposition:(id)sender
{
    (void)sender;
    BOOL hadUI = (_code.length > 0) || _cands.count > 0;
    [_code setString:@""];
    _cands = @[];
    _sel   = 0;
    _mode  = SFPickNone;
    if (_composing) {
        _composing = NO;
        [self updateComposition];       /* composedString 返回空串 → 清掉内嵌编码 */
    }
    if (hadUI) [_panel hide];
}

/* 候选窗定位：面板左下角 = 插入点那一行的下沿再往下 2pt；拿不到 rect 就退回鼠标位置。
 *
 * ⚠️ 原点方向是个真机未验证项。IMK 的 attributesForCharacterIndex:lineHeightRectangle:
 * 到底返回「原点在屏幕左下」还是「原点在左上」的 rect，不同客户端/系统版本上说法不一，
 * 而下面这条 NSMinY - 2 的锚点算法**只在左下原点下成立**。方向反了的表现是
 * 「光标越靠屏幕下方，候选窗偏得越离谱」—— 误差和光标高度成正比，用 PanelOffsetY 是调不出来的。
 *
 * 所以给了两个诊断开关（都是 NSUserDefaults，改完要注销重登才生效）：
 *   defaults write com.simplefly.inputmethod.SimpleFly DebugPanelRect -bool YES
 *   defaults write com.simplefly.inputmethod.SimpleFly PanelFlipY     -bool YES
 * 开 DebugPanelRect 打一次字，用 `log stream --predicate 'process == "SimpleFly"'` 看日志，
 * 拿 raw rect 的 y 和鼠标 y 对一下就知道方向了；方向反了就开 PanelFlipY（镜像是自反的，
 * 不用管是从哪边翻到哪边）。定下来之后关掉 DebugPanelRect 即可。
 *
 * 返回的 p 是**面板的左下角** —— SFCandidatePanel 定位时会再减去面板高度。 */
/* 取 rect 所在的那一块屏。多屏 / 分屏下不能固定用 mainScreen —— 副屏的坐标系和主屏不是一套，
 * 用错屏翻转 y 会把窗口甩到另一块屏上。找不到（rect 是空的）才退回主屏。 */
static NSScreen *SFScreenForRect(NSRect r)
{
    NSArray<NSScreen *> *screens = [NSScreen screens];
    if (screens.count == 0) return nil;
    if (r.size.width > 0 || r.size.height > 0) {
        NSPoint c = NSMakePoint(NSMidX(r), NSMidY(r));
        for (NSScreen *s in screens)
            if (NSPointInRect(c, s.frame)) return s;
    }
    return [NSScreen mainScreen] ?: screens.firstObject;
}

- (NSPoint)candidateTopLeftWithClient:(id)sender
{
    NSPoint p;
    NSRect raw = NSZeroRect;
    id<SFTextInputClient> client = (id<SFTextInputClient>)sender;
    if ([client respondsToSelector:@selector(attributesForCharacterIndex:lineHeightRectangle:)]) {
        [client attributesForCharacterIndex:0 lineHeightRectangle:&raw];
    }

    NSRect lineRect = raw;
    if (_panelFlipY && lineRect.size.height > 0) {
        /* y 在这块屏上做一次镜像：newMinY = screenMaxY - oldMaxY。
         * 这个操作是**自反**的（翻两次回到原样），所以一个开关就能覆盖「左下↔左上」两个方向，
         * 不用先判断当前是哪一边。写成减 NSMaxY（而不是只减 origin.y）才能保住高度。 */
        NSRect sf = SFScreenForRect(lineRect).frame;
        lineRect.origin.y = NSMaxY(sf) - NSMaxY(lineRect);
    }

    if (lineRect.size.height > 0)
        p = NSMakePoint(NSMinX(lineRect), NSMinY(lineRect) - 2.0);
    else {
        NSPoint mouse = [NSEvent mouseLocation];
        p = NSMakePoint(mouse.x + 6.0, mouse.y - 6.0);
    }

    NSPoint out = NSMakePoint(p.x + _panelDX, p.y + _panelDY);
    if (_debugPanelRect) {
        NSPoint  mouse = [NSEvent mouseLocation];
        NSRect   sf    = SFScreenForRect(raw).frame;
        /* 判据：raw 的 y 若「光标越靠下越大」→ 左下原点（现行假设成立）；
         * 若「光标越靠下 y 越大得离谱/接近屏幕高」→ 左上原点，开 PanelFlipY。
         * 拿鼠标 y 做参照最快：两者同向且接近，说明原点方向一致。 */
        NSLog(@"[SimpleFly] 定位 raw=%@ flip=%d → line=%@ → 面板左下=%@ | 鼠标=%@ 屏=%@",
              NSStringFromRect(raw), (int)_panelFlipY, NSStringFromRect(lineRect),
              NSStringFromPoint(out), NSStringFromPoint(mouse), NSStringFromRect(sf));
    }
    return out;
}

#pragma mark 候选构建

/* 自定义快捷输入表（abc = 测试短语 那份）。
 *
 * 惰性加载 + 按 mtime 热重载，放在这里而不是启动时，是为了「改完文件不用重启输入法」：
 * 每次组字开头检查一次文件时间，代价只是一次 stat。 */
- (SFPhrases *)phraseBook
{
    NSString *path  = SFPhrasePath();
    const char *p   = path.fileSystemRepresentation;

    if (sf_phrase_stale(_phraseBook, p)) {
        if (_phraseBook) { sf_phrase_free(_phraseBook); _phraseBook = NULL; }
        _phraseBook = sf_phrase_load(p);
        NSLog(@"[SimpleFly] 自定义短语：%zu 条 ← %@", sf_phrase_count(_phraseBook), path);
    }
    return _phraseBook;
}

/* 重码记忆。惰性加载：文件不存在时先不创建（ sf_freq_load 返回 NULL），
 * 等第一次真的选中重码才建空对象 —— 不打字就永远不落盘。
 * 不做 mtime 热重载：这文件只由本进程写，用户手改后重启输入法即可（罕见路径）。 */
- (SFFreq *)freqBook
{
    if (!_freq) {
        NSString *path = SFFreqPath();
        _freq = sf_freq_load(path.fileSystemRepresentation);
        if (!_freq) _freq = sf_freq_new(path.fileSystemRepresentation);
        if (_freq && sf_freq_count(_freq) > 0)
            NSLog(@"[SimpleFly] 重码记忆：%zu 条 ← %@", sf_freq_count(_freq), path);
    }
    return _freq;
}

/* 简→繁映射表。进程内加载一次 —— 换表要 killall SimpleFly（跟码表一个待遇）。 */
- (SFS2T *)s2tTable
{
    static SFS2T *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = SFS2TPath();
        table = sf_s2t_load(path.fileSystemRepresentation);
        if (table)
            NSLog(@"[SimpleFly] 简→繁映射：%zu 对 ← %@", sf_s2t_count(table), path);
        else
            NSLog(@"[SimpleFly] 简→繁映射表缺失（%@）", path);
    });
    return table;
}

/* 繁→简映射表（0.5.6，双向简繁）。加载策略与 s2tTable 相同。 */
- (SFS2T *)t2sTable
{
    static SFS2T *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = SFT2SPath();
        table = sf_s2t_load(path.fileSystemRepresentation);
        if (table)
            NSLog(@"[SimpleFly] 繁→简映射：%zu 对 ← %@", sf_s2t_count(table), path);
        else
            NSLog(@"[SimpleFly] 繁→简映射表缺失（%@）", path);
    });
    return table;
}

/* 用指定映射表转换整个字符串。表缺失或无变化返回 nil —— 调用方借此区分
 * 「没表（要报错）」和「没差异（静默/提示均可）」。缓冲策略沿用 0.5.4：
 * 繁体码位可能多一字节，按 4x 预留，报告需要更多时重试一次。 */
- (NSString *)convertedString:(NSString *)text withTable:(SFS2T *)t
{
    if (!t || text.length == 0) return nil;
    const char *src = text.UTF8String;
    size_t cap = text.length * 4 + 8;
    char *buf = (char *)malloc(cap);
    if (!buf) return nil;
    size_t need = sf_s2t_convert(t, src, buf, cap);
    if (need > cap) {
        char *nb = (char *)realloc(buf, need);
        if (!nb) { free(buf); return nil; }
        buf = nb;
        sf_s2t_convert(t, src, buf, need);
    }
    NSString *conv = [NSString stringWithUTF8String:buf];
    free(buf);
    if (conv.length == 0 || [conv isEqualToString:text]) return nil;
    return conv;
}

/* 普通组字的候选 = 自定义短语（排最前）+ 码表。
 * hits/hitCount 回传给调用方做「四键上屏」判断；phraseCount 用来判断列表里有没有混进短语。 */
- (NSArray<SFCandidate *> *)codeCandidates:(SFHit *)hits
                                  hitCount:(int *)outCount
                               phraseCount:(int *)outPhrase
{
    NSMutableArray<SFCandidate *> *list = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];

    const char *ph[SF_MAX_CANDS];
    int pn = sf_phrase_lookup([self phraseBook], _code.UTF8String, ph, (int)_maxCands);
    for (int i = 0; i < pn; i++) {
        NSString *t = [NSString stringWithUTF8String:ph[i]];
        if (!t || [seen containsObject:t]) continue;
        [seen addObject:t];
        [list addObject:[SFCandidate text:t note:nil]];
    }
    if (outPhrase) *outPhrase = (int)list.count;

    int n = sf_engine_lookup(SFSharedEngine(), _code.UTF8String, hits,
                             (int)_maxCands, _completion ? 1 : 0);
    if (outCount) *outCount = n;
    for (int i = 0; i < n; i++) {
        NSString *t = [NSString stringWithUTF8String:hits[i].text];
        if (!t || [seen containsObject:t]) continue;
        [seen addObject:t];
        [list addObject:[SFCandidate text:t note:nil]];
    }
    return list;
}

/* 候选后面那条附注：该字的完整音形码，并在音码（2 位）与形码之间插一个中点，
 * 一眼能看出「前两位是音、后面是形」——这正是「编码拆分」要传达的东西。
 * 多字词条没有这种 2+2 结构（词组编码是按字取码拼的），原样显示。 */
- (NSString *)noteForText:(NSString *)text
{
    const char *c = sf_engine_code_for_text(SFSharedEngine(), text.UTF8String);
    if (!c) return nil;
    NSString *code = [NSString stringWithUTF8String:c];
    if (text.length == 1 && code.length > 2)
        return [NSString stringWithFormat:@"%@·%@",
                [code substringToIndex:2], [code substringFromIndex:2]];
    return code;
}

/* 选中文字 → 查编码（Ctrl+Shift+/，0.5.3）。解决「想打这个字但不会拆」的另一半：
 * Ctrl+/ 是「拿拼音查编码」，这里是「拿现成的字查编码」—— 看到字（比如聊天里
 * 别人发的）直接选中反查。结果走 HUD 显示，查完就走，不进组字状态、不碰输入框。
 * 反查地基与 Ctrl+/ 同一套：sf_engine_code_for_text。 */
- (void)lookupSelection:(id)sender
{
    NSString *text = nil;
    /* 两个 respondsToSelector 都要查：不是所有 client 都实现了完整选择接口
     * （比如我们自己的离线测试假客户端、某些非标准文本视图）。 */
    if ([sender respondsToSelector:@selector(selectedRange)] &&
        [sender respondsToSelector:@selector(attributedSubstringFromRange:)]) {
        NSRange range = [(id)sender selectedRange];
        if (range.location != NSNotFound && range.length > 0 && range.length <= 32) {
            NSAttributedString *sub = [(id)sender attributedSubstringFromRange:range];
            text = sub.string;
        }
    }
    /* 首尾空白清一下 —— 双击选词常带出空格，别让它把查词搞挂 */
    if (text) {
        text = [text stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    if (text.length == 0) {
        [self showHUD:@"先选中一个字或词，再按 Ctrl+Shift+/"
               accent:YES seconds:2.0 client:sender];
        return;
    }
    if (text.length > 6) {
        /* 码表最长 4 码，能反查的词条就几个字长；选了一段落的场景直接拦下 */
        [self showHUD:@"选中的内容太长，只支持单个字或词"
               accent:YES seconds:2.0 client:sender];
        return;
    }
    const char *code = sf_engine_code_for_text(SFSharedEngine(), text.UTF8String);
    if (!code || !*code) {
        [self showHUD:[NSString stringWithFormat:@"「%@」不在码表里", text]
               accent:YES seconds:2.0 client:sender];
        return;
    }
    NSString *note = [self noteForText:text];   /* 复用：单字加中点分隔音形 */
    [self showHUD:[NSString stringWithFormat:@"%@  %@", text, note]
           accent:NO seconds:2.5 client:sender];
}

/* 选中文字 → 简繁互转（Ctrl+Shift+F，0.5.6 起双向）。
 * 最简版边界（§3.3）：**单字映射**，一简对多繁/一繁对多简各取 OpenCC 第一个变体 ——
 * 「干/乾/幹」这类歧义没有上下文无解，正确预期是「能读懂、不保证地道」。
 * 方向判定：先试简→繁，有差异就是简体文本；否则试繁→简；两边都无差异（纯
 * ASCII / 简繁同形 / 没有汉字）就不动，免得把选区白白重写一遍。 */
- (void)convertSelectionToTrad:(id)sender
{
    NSString *text = nil;
    NSRange range = NSMakeRange(NSNotFound, 0);
    if ([sender respondsToSelector:@selector(selectedRange)] &&
        [sender respondsToSelector:@selector(attributedSubstringFromRange:)]) {
        range = [(id)sender selectedRange];
        if (range.location != NSNotFound && range.length > 0 && range.length <= 20000) {
            NSAttributedString *sub = [(id)sender attributedSubstringFromRange:range];
            text = sub.string;
        }
    }
    if (text.length == 0) {
        [self showHUD:@"先选中要转换的文字" accent:YES seconds:2.0 client:sender];
        return;
    }
    if (![self s2tTable] && ![self t2sTable]) {
        [self showHUD:@"简繁映射表缺失" accent:YES seconds:2.0 client:sender];
        return;
    }

    NSString *conv = [self convertedString:text withTable:[self s2tTable]];
    NSString *what = @"已转繁体";
    if (!conv) {
        conv = [self convertedString:text withTable:[self t2sTable]];
        what = @"已转简体";
    }
    if (!conv) {
        [self showHUD:@"未发现简繁差异" accent:NO seconds:1.5 client:sender];
        return;
    }

    [(id<SFTextInputClient>)sender insertText:conv replacementRange:range];
    [self showHUD:[NSString stringWithFormat:@"%@（单字映射，多形取常用）", what]
           accent:NO seconds:1.5 client:sender];
}

/* 输出模式切换：简体 / 繁体（Ctrl+Shift+T，0.5.6）。
 * 开了之后所有上屏文字过一遍简→繁映射（commitText 是唯一出口，见那里）。
 * 与 Ctrl+Shift+F 的分工：F 是「对已有文字原地转」，T 是「以后打的都转」。 */
- (void)toggleOutputTrad:(id)sender
{
    _outputTrad = !_outputTrad;
    [[NSUserDefaults standardUserDefaults] setBool:_outputTrad forKey:@"OutputTrad"];
    [self showHUD:(_outputTrad ? @"输出：繁体" : @"输出：简体")
           accent:_outputTrad client:sender];
}

#pragma mark WebDAV 同步（0.5.8，手动）

/* 把 phrase.txt（自定义短语）+ freq.txt（重码记忆）同步到任意 WebDAV 网盘。
 * 刻意只做**手动**两键（Ctrl+Shift+U 上传 / Ctrl+Shift+D 恢复），不做自动同步：
 *   - 输入法进程里挂网络任务，阻塞或失败都会打断打字本身；
 *   - 短语/记忆是单机小文件，没有多端并发写，「上传/恢复」二选一足够，
 *     自动双向合并带来的冲突处理远超它的收益。
 * mislog.tsv 不同步 —— 那是打错日志，落本地才有隐私边界。
 *
 * 配置三件套 url/user/pass，缺一不可。主入口是状态栏菜单「网盘配置…」
 *（编辑 ~/Library/Application Support/SimpleFly/webdav.conf，模板自带坚果云三步引导）；
 * 旧的 defaults 三键（WebDAVURL/WebDAVUser/WebDAVPass，域
 * com.simplefly.inputmethod.SimpleFly）继续兼容 —— conf 文件对应键优先。
 * 密码明文存本机 —— 只存本机、只往配置的网盘传这两个文件。 */

/* 配置文件（webdav.conf）：状态栏菜单「网盘配置…」点开就能编辑的那份。
 * 放 Application Support 而不是 defaults —— 普通用户看得见、找得到、改得动，
 * 不用学 defaults write。测试用环境变量指到临时目录。 */
static NSString *SFWebDAVConfPath(void)
{
    const char *env = getenv("SIMPLEFLY_WEBDAV_CONF_FILE");
    if (env && *env) return [NSString stringWithUTF8String:env];
    return [SFAppSupportDir() stringByAppendingPathComponent:@"webdav.conf"];
}

/* 首次点「网盘配置…」时生成的模板。整份都是注释 —— 用户去掉 # 填值，
 * 解析器遇到全注释 = 未配置，行为和没建过文件完全一致。 */
static NSString *SFWebDAVConfTemplate(void)
{
    return
    @"# ============================================================\n"
    @"#  SimpleFly · WebDAV 网盘同步配置\n"
    @"#  改完保存即可，不用重启输入法 —— 下一次「同步到网盘」自动读取。\n"
    @"#  同步内容：phrase.txt（自定义短语）+ freq.txt（重码记忆）\n"
    @"# ============================================================\n"
    @"#\n"
    @"# 用法：把下面「url / user / pass」三行行首的 # 去掉，右边填上你的值。\n"
    @"# 三行都填了才算配置完成。\n"
    @"#\n"
    @"# ── 以坚果云为例，三步 ──\n"
    @"#\n"
    @"# 第 1 步：建同步文件夹\n"
    @"#   浏览器打开 www.jianguoyun.com 登录 → 我的坚果云 → 新建文件夹 →\n"
    @"#   命名 SimpleFly（名字随意，但必须是英文，不能带空格和中文）\n"
    @"#\n"
    @"# 第 2 步：生成应用密码（不是登录密码！）\n"
    @"#   右上角账户名 → 账户信息 → 安全选项 → 第三方应用管理 → 添加应用 →\n"
    @"#   输入名称（如 xiaoman）→ 生成一串随机密码，复制下来。\n"
    @"#   这个密码只显示这一次，关掉就找不回了（忘了就删掉重新生成一个）。\n"
    @"#\n"
    @"# 第 3 步：去掉下面三行行首的 # 并填值\n"
    @"#\n"
    @"# url = https://dav.jianguoyun.com/dav/SimpleFly\n"
    @"#       （坚果云固定格式：https://dav.jianguoyun.com/dav/ 加第 1 步的文件夹名）\n"
    @"# user = 你的坚果云登录邮箱\n"
    @"# pass = 第 2 步生成的应用密码\n"
    @"#\n"
    @"# ── 其他网盘 ──\n"
    @"#   任何支持 WebDAV 的网盘都行（群晖/绿联 NAS、InfiniCloud、Box 等），\n"
    @"#   把 url 换成对应 WebDAV 地址即可；user / pass 用网盘给的 WebDAV 凭据。\n"
    @"#\n"
    @"# ── 出问题了？──\n"
    @"#   401 认证失败   → pass 填成登录密码了，换成应用密码\n"
    @"#   404/409 目录不存在 → url 里的文件夹在网盘里不存在，或写在了根目录（/dav 结尾）\n"
    @"#   同步了但没内容 → 先在网页版确认文件夹里出现了 phrase.txt / freq.txt\n";
}

/* 同步哪些文件（相对 ~/Library/Application Support/SimpleFly/）。 */
static NSArray<NSString *> *SFWebDAVFiles(void)
{
    return @[@"phrase.txt", @"freq.txt"];
}

/* 解析 webdav.conf：`key = value`，# 开头是注释，key 大小写不敏感。
 * 返回 url/user/pass 三个键的子集（没配置的键不出现）；文件不存在/全注释返回空。 */
- (NSDictionary<NSString *, NSString *> *)webdavConfFile
{
    NSString *s = [NSString stringWithContentsOfFile:SFWebDAVConfPath()
                                            encoding:NSUTF8StringEncoding
                                               error:NULL];
    if (!s.length) return @{};
    NSMutableDictionary<NSString *, NSString *> *d = [NSMutableDictionary dictionary];
    NSCharacterSet *ws = [NSCharacterSet whitespaceCharacterSet];
    for (NSString *raw in [s componentsSeparatedByCharactersInSet:
                               [NSCharacterSet newlineCharacterSet]]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:ws];
        if (line.length == 0 || [line hasPrefix:@"#"]) continue;
        NSRange eq = [line rangeOfString:@"="];
        if (eq.location == NSNotFound || eq.location == 0) continue;
        NSString *k = [[line substringToIndex:eq.location]
                          stringByTrimmingCharactersInSet:ws].lowercaseString;
        NSString *v = [[line substringFromIndex:eq.location + 1]
                          stringByTrimmingCharactersInSet:ws];
        if (k.length && v.length) d[k] = v;
    }
    return d;
}

/* 三件套配置，缺一返回 nil（调用方给引导 HUD，别让用户对着「上传失败」猜）。
 * 来源优先级：webdav.conf（「网盘配置…」编辑的那份）→ 旧 defaults 三键（兼容）。
 * 每次同步时读一遍 —— 只在按菜单/快捷键时发生，代价可忽略，换来「改完即生效」。 */
- (NSDictionary<NSString *, NSString *> *)webdavConfig
{
    NSDictionary<NSString *, NSString *> *f = [self webdavConfFile];
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *url  = f[@"url"]  ?: [d stringForKey:@"WebDAVURL"];
    NSString *user = f[@"user"] ?: [d stringForKey:@"WebDAVUser"];
    NSString *pass = f[@"pass"] ?: [d stringForKey:@"WebDAVPass"];
    if (url.length && user.length && pass.length)
        return @{ @"url": url, @"user": user, @"pass": pass };
    return nil;
}

/* Basic Auth 头。文件名全是 ASCII（phrase.txt/freq.txt），不需要逐段编码。 */
- (void)sf_setAuth:(NSDictionary<NSString *, NSString *> *)cfg on:(NSMutableURLRequest *)req
{
    NSData *cred = [[NSString stringWithFormat:@"%@:%@", cfg[@"user"], cfg[@"pass"]]
                        dataUsingEncoding:NSUTF8StringEncoding];
    [req setValue:[NSString stringWithFormat:@"Basic %@",
                   [cred base64EncodedStringWithOptions:0]]
        forHTTPHeaderField:@"Authorization"];
}

/* 状态码 → 人话。坚果云的「父目录缺失」不止 409 一种（403/404/405 同因），统一归一类。 */
static NSString *SFWebDAVErrorText(NSInteger status, NSError *err)
{
    if (err) return err.localizedDescription ?: @"网络错误";
    switch (status) {
        case 401: return @"认证失败（WebDAVPass 要填应用密码，不是登录密码）";
        case 403: case 404: case 405: case 409:
            return @"目录不存在（先在网盘建好 WebDAVURL 里的英文文件夹，且不能挂在根上）";
        default:
            return [NSString stringWithFormat:@"HTTP %ld", (long)status];
    }
}

/* 上传同步（Ctrl+Shift+U）。freq 是写后置缓存，先 flush 保证传出去的是最新数据。 */
- (void)webdavSyncUp:(id)sender
{
    NSDictionary<NSString *, NSString *> *cfg = [self webdavConfig];
    if (!cfg) { [self showWebDAVSetupHUD:sender]; return; }
    if (_freq) sf_freq_flush(_freq, SFFreqPath().fileSystemRepresentation);

    [self showHUD:@"WebDAV 同步中…" accent:NO client:sender];
    NSString *dir = SFAppSupportDir();
    dispatch_group_t group = dispatch_group_create();
    __block NSMutableArray<NSString *> *errors = [NSMutableArray array];
    __block NSInteger uploaded = 0;

    for (NSString *name in SFWebDAVFiles()) {
        NSString *path = [dir stringByAppendingPathComponent:name];
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) continue;  /* 没用过的文件不传 */
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
            [NSURL URLWithString:[NSString stringWithFormat:@"%@/%@", cfg[@"url"], name]]];
        req.HTTPMethod  = @"PUT";
        req.HTTPBody    = [NSData dataWithContentsOfFile:path];
        [self sf_setAuth:cfg on:req];
        dispatch_group_enter(group);
        [[[NSURLSession sharedSession] dataTaskWithRequest:req
            completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
                (void)data;   /* 上传只看状态码 */
                NSInteger status = [(NSHTTPURLResponse *)resp statusCode];
                if (err || status < 200 || status >= 300)
                    [errors addObject:[NSString stringWithFormat:@"%@：%@",
                                       name, SFWebDAVErrorText(status, err)]];
                else
                    uploaded++;
                dispatch_group_leave(group);
            }] resume];
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        if (errors.count == 0)
            [self showHUD:[NSString stringWithFormat:@"已同步 %lu 个文件", (unsigned long)uploaded]
                   accent:NO seconds:2.0 client:sender];
        else
            [self showHUD:[NSString stringWithFormat:@"同步失败：%@",
                           [errors componentsJoinedByString:@"；"]]
                   accent:YES seconds:4.0 client:sender];
    });
}

/* 下载恢复（Ctrl+Shift+D）。两步走保住「要么不动，要么完整」：
 * ① 全部拉到临时文件，任何一个失败就整体放弃（HUD 报原因），本地原样；
 * ② 都成功才替换：原文件先备份成 .bak（手改过短语的用户保得住现场），
 *    freq 缓存置空按需重载，phrase 靠 mtime 热重载自动生效。 */
- (void)webdavSyncDown:(id)sender
{
    NSDictionary<NSString *, NSString *> *cfg = [self webdavConfig];
    if (!cfg) { [self showWebDAVSetupHUD:sender]; return; }

    [self showHUD:@"WebDAV 恢复中…" accent:NO client:sender];
    NSString *dir  = SFAppSupportDir();
    NSString *tmp  = [NSTemporaryDirectory() stringByAppendingPathComponent:@"SimpleFlyRestore"];
    [[NSFileManager defaultManager] createDirectoryAtPath:tmp
                              withIntermediateDirectories:YES attributes:nil error:NULL];
    dispatch_group_t group = dispatch_group_create();
    __block NSMutableArray<NSString *> *errors = [NSMutableArray array];
    __block NSInteger fetched = 0;

    for (NSString *name in SFWebDAVFiles()) {
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
            [NSURL URLWithString:[NSString stringWithFormat:@"%@/%@", cfg[@"url"], name]]];
        req.HTTPMethod = @"GET";
        req.timeoutInterval = 15.0;
        [self sf_setAuth:cfg on:req];
        dispatch_group_enter(group);
        [[[NSURLSession sharedSession] dataTaskWithRequest:req
            completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
                NSInteger status = [(NSHTTPURLResponse *)resp statusCode];
                if (err || status < 200 || status >= 300 || data.length == 0) {
                    if (status == 404)
                        [errors addObject:[NSString stringWithFormat:@"%@：云端没有这个文件", name]];
                    else
                        [errors addObject:[NSString stringWithFormat:@"%@：%@",
                                           name, SFWebDAVErrorText(status, err)]];
                } else {
                    [data writeToFile:[tmp stringByAppendingPathComponent:name] atomically:YES];
                    fetched++;
                }
                dispatch_group_leave(group);
            }] resume];
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        if (errors.count > 0) {
            [self showHUD:[NSString stringWithFormat:@"恢复失败（本地未动）：%@",
                           [errors componentsJoinedByString:@"；"]]
                   accent:YES seconds:4.0 client:sender];
            return;
        }
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *name in SFWebDAVFiles()) {
            NSString *dst = [dir stringByAppendingPathComponent:name];
            if ([fm fileExistsAtPath:dst]) {
                NSString *bak = [dst stringByAppendingString:@".bak"];
                [fm removeItemAtPath:bak error:NULL];          /* 上次的备份让位，保留最新一份 */
                [fm copyItemAtPath:dst toPath:bak error:NULL];
            }
            [fm removeItemAtPath:dst error:NULL];
            [fm moveItemAtPath:[tmp stringByAppendingPathComponent:name]
                        toPath:dst error:NULL];
        }
        [fm removeItemAtPath:tmp error:NULL];
        if (_freq) { sf_freq_free(_freq); _freq = NULL; }   /* 下次用时按新文件重载 */
        [self showHUD:[NSString stringWithFormat:@"已恢复 %lu 个文件（原件备份为 .bak）",
                       (unsigned long)fetched]
               accent:NO seconds:2.5 client:sender];
    });
}

/* 未配置时的引导 HUD：主推「网盘配置…」菜单（点开就是配置文件，照注释填），
 * defaults 三键留给会用命令行的用户。 */
- (void)showWebDAVSetupHUD:(id)sender
{
    [self showHUD:@"未配置网盘：点输入法菜单「网盘配置…」，按文件里的注释填 url/user/pass 三项"
           accent:YES seconds:4.0 client:sender];
}

/* 「网盘配置…」：没有配置文件就先按模板生成，再用文本编辑打开。
 * 测试（conf 路径被环境变量指走）时只生成不开编辑器 —— 测试机不该弹 TextEdit。 */
- (void)openWebDAVConfig:(id)sender
{
    NSString *path = SFWebDAVConfPath();
    BOOL created = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        created = [SFWebDAVConfTemplate() writeToFile:path
                                             atomically:YES
                                               encoding:NSUTF8StringEncoding
                                                  error:NULL];
        if (!created) {
            [self showHUD:@"生成配置文件失败（目录不可写？）" accent:YES seconds:2.5 client:sender];
            return;
        }
        NSLog(@"[SimpleFly] WebDAV 配置模板已生成 ← %@", path);
    }
    if (getenv("SIMPLEFLY_WEBDAV_CONF_FILE")) {
        [self showHUD:[NSString stringWithFormat:@"配置文件已就绪：%@", path]
               accent:NO seconds:2.5 client:sender];
        return;
    }
    [[NSWorkspace sharedWorkspace] openFile:path withApplication:@"TextEdit"];
    [self showHUD:@"已打开 webdav.conf：去掉 # 填 url/user/pass 三项，保存后即可同步"
           accent:NO seconds:3.0 client:sender];
}

/* 状态栏菜单（点菜单栏输入法名字弹出的那个）—— 手动同步的主入口，对普通用户
 * 比记快捷键友好；快捷键保留给顺手党，菜单项上同时标出等价键。
 * IMK 约定：menu 返回 autoreleased 菜单；菜单项 action 经 doCommandBySelector:
 * 回来时参数是 infoDictionary（含 kIMKCommandClientName），不是 client 本身 ——
 * 所以每个菜单动作都要从字典里取 client 再调真正的实现。 */
- (NSMenu *)menu
{
    NSMenu *m = [[NSMenu alloc] initWithTitle:@"SimpleFly"];

    NSMenuItem *up = [[NSMenuItem alloc] initWithTitle:@"同步到网盘（短语·重码记忆）"
                                                action:@selector(menuWebDAVSyncUp:)
                                         keyEquivalent:@"u"];
    up.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagShift;
    up.target = self;
    [m addItem:up];

    NSMenuItem *down = [[NSMenuItem alloc] initWithTitle:@"从网盘恢复…"
                                                  action:@selector(menuWebDAVSyncDown:)
                                           keyEquivalent:@"d"];
    down.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagShift;
    down.target = self;
    [m addItem:down];

    /* 网盘配置：点开生成 + 编辑 webdav.conf —— 普通用户的主配置入口，
     * 不用碰 defaults 命令行。放最后，前两项是高频动作。 */
    NSMenuItem *conf = [[NSMenuItem alloc] initWithTitle:@"网盘配置…"
                                                  action:@selector(menuWebDAVConfig:)
                                           keyEquivalent:@""];
    conf.target = self;
    [m addItem:conf];

    /* ARC 下非 init/copy 族方法返回新造对象会自动按 +0 约定 autorelease，
     * 直接 return 即可，不需要也不允许显式 autorelease。 */
    return m;
}

- (void)menuWebDAVSyncUp:(id)sender
{
    id client = [sender isKindOfClass:[NSDictionary class]]
                ? ((NSDictionary *)sender)[kIMKCommandClientName] : sender;
    [self webdavSyncUp:client ?: sender];
}

- (void)menuWebDAVSyncDown:(id)sender
{
    id client = [sender isKindOfClass:[NSDictionary class]]
                ? ((NSDictionary *)sender)[kIMKCommandClientName] : sender;
    [self webdavSyncDown:client ?: sender];
}

- (void)menuWebDAVConfig:(id)sender
{
    id client = [sender isKindOfClass:[NSDictionary class]]
                ? ((NSDictionary *)sender)[kIMKCommandClientName] : sender;
    [self openWebDAVConfig:client ?: sender];
}


/* 查编码模式的候选 —— 0.4.1 修「拼音打进去候选窗只有一两个字」的 bug（前缀匹配），
 * 0.4.2 修「精确匹配 hc 只回得来『好』一个字」（同音字各带形码，必须前缀收全部），
 * 0.4.4 再加「词语」：同一前缀下先收单字（singles_only=1）再收词语（singles_only=2），
 * 单字排前、词语排后，用 seen 去重（「好」既在单字也在「好啊」里时不重复）。 */
- (void)appendReverseCandidatesForCode:(NSString *)code
                                    to:(NSMutableArray<SFCandidate *> *)list
                                  seen:(NSMutableSet<NSString *> *)seen
                          singlesOnly:(int)singlesOnly
{
    if (code.length == 0) return;

    SFHit hits[SF_PREFIX_MAX];
    int n = sf_engine_lookup_prefix(SFSharedEngine(), code.UTF8String, hits, SF_PREFIX_MAX, singlesOnly);
    for (int i = 0; i < n; i++) {
        NSString *t = [NSString stringWithUTF8String:hits[i].text];
        if (!t || [seen containsObject:t]) continue;
        [seen addObject:t];
        [list addObject:[SFCandidate text:t note:[self noteForText:t]]];
    }
}

/* 三条路都走、合并去重（「全拼 + 双拼都接受」）：
 *   1. 输入能解析成拼音音节 → 换小鹤双拼码按前缀查（hao → hc → 好/号/浩/豪/… + 好啊/好吧）；
 *   2. 输入是多音节拼音 → 每个音节转双拼码拼起来（nihao → nihc → 你好）；
 *   3. 输入原样当双拼码前缀查（想直接敲 hc、hck 也认）。
 * 单字与词语各走两遍：单字排前、词语排后。中途状态（"h"、"ha"）解析不成音节，
 * 只有第 3 条路，但那正是「越打越窄」的正常过程。 */
- (NSArray<SFCandidate *> *)reverseCandidates
{
    NSMutableArray<SFCandidate *> *list = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];

    char dbl[3] = {0};
    BOOL hasDbl = (sf_pinyin_to_double(_code.UTF8String, dbl) == 2);

    char mult[32] = {0};
    int multLen = sf_pinyin_to_double_multi(_code.UTF8String, mult, sizeof mult);

    if (hasDbl) {
        NSString *cs = [NSString stringWithUTF8String:dbl];
        [self appendReverseCandidatesForCode:cs to:list seen:seen singlesOnly:1];
        [self appendReverseCandidatesForCode:cs to:list seen:seen singlesOnly:2];
    }
    if (multLen > 0 && (!hasDbl || strcmp(mult, dbl) != 0)) {
        NSString *cs = [NSString stringWithUTF8String:mult];
        [self appendReverseCandidatesForCode:cs to:list seen:seen singlesOnly:1];
        [self appendReverseCandidatesForCode:cs to:list seen:seen singlesOnly:2];
    }

    /* 原样当双拼码前缀查（想直接敲 hc、hck 也认） */
    [self appendReverseCandidatesForCode:_code to:list seen:seen singlesOnly:1];
    [self appendReverseCandidatesForCode:_code to:list seen:seen singlesOnly:2];

    return list;
}

/* 把当前 _cands 画出来。移动高亮时也走这里，保证只有一个出口。 */
- (void)showPanelWithClient:(id)sender
{
    if (_cands.count == 0) { [_panel hide]; return; }
    [_panel showCandidates:_cands
                      code:(_inlinePreedit ? @"" : _code)
                  selected:_sel
                 atTopLeft:[self candidateTopLeftWithClient:sender]];
}

/* 移动候选高亮。两端回绕：一页最多 9 个候选，按一次反方向就能跳到另一头，比夹边省事。 */
- (void)moveSelection:(NSInteger)delta client:(id)sender
{
    NSUInteger n = _cands.count;
    if (n == 0) return;

    NSInteger s = (NSInteger)_sel + delta;
    s %= (NSInteger)n;
    if (s < 0) s += (NSInteger)n;
    _sel = (NSUInteger)s;

    [self showPanelWithClient:sender];
}

#pragma mark 打错日志

/* 用户把一段组字**整段打断**（Esc / Tab / ForwardDelete / 退格退到空）。
 * 这里只记候选（本次上屏以来最长的码），真正落盘等下一次 commitText 配对 ——
 * 「废弃的码 + 最终上屏了什么」凑成一条才有分析价值。 */
- (void)noteMissSevered
{
    if (!_logMisses) return;
    NSString *code = _missCandidate ?: ((_code.length >= 2) ? _code : nil);
    if (code.length >= 2) _pendingMiss = code;
    _missCandidate = nil;
}

/* 上屏了 text：若有待配对的废弃码，追加一行日志。text 太长（>12 字）说明
 * 后面接的不是「想打的词」，落盘时词列留空，只参与频次统计。 */
- (void)logPendingMissWithCommit:(NSString *)text
{
    if (!_logMisses || !_pendingMiss) return;
    NSString *word = text;
    if (word.length > 12) word = @"";
    NSCharacterSet *bad = [NSCharacterSet newlineCharacterSet];
    NSString *code = [[_pendingMiss componentsSeparatedByCharactersInSet:bad]
                        componentsJoinedByString:@""];
    word = [[word componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@""];
    word = [word stringByReplacingOccurrencesOfString:@"\t" withString:@""];
    FILE *fh = fopen(SFMislogPath().fileSystemRepresentation, "a");
    if (fh) {
        fprintf(fh, "%lld\t%s\t%s\n", (long long)time(NULL),
                code.UTF8String ?: "", word.UTF8String ?: "");
        fclose(fh);
    }
    _pendingMiss = nil;
}

/* 上屏第 idx 个候选。查编码模式下落盘与否按 ReverseModeAutoExit 决定。 */
- (void)commitCandidateAtIndex:(NSUInteger)idx client:(id)sender
{
    if (idx >= _cands.count) { [self discardComposition:sender]; return; }

    NSString *text = _cands[idx].text;
    BOOL wasSearch = (_mode == SFPickSearch);
    /* 重码记忆：先抓状态再上屏 —— commitText 会把 _code/_cands/_mode 全部清掉。 */
    NSString *code       = [_code copy];
    NSUInteger candCount = _cands.count;
    BOOL wasCode         = (_mode == SFPickCode);
    [self commitText:text client:sender];

    /* 记录「这个编码这次选了谁」。与重排同边界：码长 >= 3、有重码。
     * 选字是低频事件（远低于按键频率），这里同步 flush 一次几 KB 的写，
     * 换「崩了也不丢记忆」，比 debounce 状态机划算。 */
    if (wasCode && _freqMemory && candCount > 1 && code.length >= 3) {
        SFFreq *f = [self freqBook];
        sf_freq_put(f, code.UTF8String, text.UTF8String, (int64_t)time(NULL));
        sf_freq_trim(f, SF_FREQ_MAX_ITEMS);
        sf_freq_flush(f, SFFreqPath().fileSystemRepresentation);
    }

    if (wasSearch && _reverseAutoExit) {
        _reverseMode = NO;                       /* 旧行为：查一个字就退回小鹤 */
    } else if (wasSearch) {
        /* 常驻拼音模式：上屏后把这个字的音形码显示在 HUD 一小会儿，
         * 「打出来之后直接看到编码」就是这里要的效果（用户不知道怎么拆字时用来记码）。 */
        NSString *codeNote = [self noteForText:text];
        if (codeNote.length)
            [self showHUD:[NSString stringWithFormat:@"%@  %@", text, codeNote]
                   accent:NO seconds:1.8 client:sender];
    }
}

- (void)refreshWithClient:(id)sender
{
    if (_code.length == 0) { [self discardComposition:sender]; return; }

    /* 内嵌编码：把当前编码同步进输入框（metro 的 inline_preedit: true） */
    _composing = YES;
    [self updateComposition];

    if (_reverseMode) {
        NSArray<SFCandidate *> *list = [self reverseCandidates];
        _cands = list;
        _sel   = 0;
        if (list.count == 0) { _mode = SFPickNone; [_panel hide]; return; }
        _mode = SFPickSearch;
        [self showPanelWithClient:sender];
        return;
    }

    SFHit hits[SF_MAX_CANDS];
    int n = 0, pn = 0;
    NSArray<SFCandidate *> *list = [self codeCandidates:hits hitCount:&n phraseCount:&pn];
    if (list.count == 0) {
        _cands = @[]; _sel = 0; _mode = SFPickNone;
        [_panel hide];
        return;
    }
    if (list.count > _maxCands) list = [list subarrayWithRange:NSMakeRange(0, _maxCands)];
    _cands = list;
    _sel   = 0;

    /* 四键上屏：只在精确匹配唯一时触发，有重码就把选择权留给用户。
     * 混进了自定义短语也不自动上屏 —— 那是用户自己绑的内容，让他按空格确认。 */
    if (_autoCommit4 && pn == 0 && n > 0 &&
        sf_engine_should_autocommit(_code.UTF8String, hits, n)) {
        [self commitText:list.firstObject.text client:sender];
        return;
    }

    /* 重码记忆：上次这个编码选了谁，就把它重排到第一位 —— 「直接空格 = 上次选的」。
     * 边界（刻意收窄，见 freq.h 的设计说明）：
     *   - 只在重码时排（单候选没有可排的）；
     *   - 码长 >= 3 才排 —— 2 码的二简组是练码手感的一部分，不让历史记录干扰；
     *   - 混了自定义短语不排 —— 短语本来就在最前面，那是用户自己定的优先级；
     *   - 排在 autocommit 判断**之后**：唯一精确匹配的 4 码直接上屏，不受重排影响。
     * 只动顺序、不动 _sel：高亮仍从第 0 项开始，重排的收益就建立在这一点上。 */
    if (_freqMemory && pn == 0 && list.count > 1 && _code.length >= 3) {
        const char *remembered = sf_freq_get([self freqBook], _code.UTF8String);
        if (remembered) {
            NSString *want = [NSString stringWithUTF8String:remembered];
            NSUInteger at = [list indexOfObjectPassingTest:
                ^BOOL(SFCandidate *c, NSUInteger i, BOOL *stop) {
                    (void)i; (void)stop;
                    return [c.text isEqualToString:want];
                }];
            if (at != NSNotFound && at > 0) {
                NSMutableArray<SFCandidate *> *m = [list mutableCopy];
                SFCandidate *c = m[at];
                [m removeObjectAtIndex:at];
                [m insertObject:c atIndex:0];
                list = m;
                _cands = m;      /* 别忘了写回 —— 只改局部变量面板永远看不到（踩过） */
            }
        }
    }

    _mode = SFPickCode;
    [self showPanelWithClient:sender];

    /* 打错日志：记住「本次上屏以来最长的 ≥2 码尝试」。只在这时更新 ——
     * 退格改错字（hcd→hc→hck）不算废弃，只有整段被打断才配对落盘。 */
    if (_logMisses && _code.length >= 2) _missCandidate = [_code copy];
}

#pragma mark 标点

- (SFPunctStyle)punctStyle
{
    if (_fullShape)  return SF_PUNCT_FULL;
    if (_punctAscii) return SF_PUNCT_EN;
    return SF_PUNCT_CN;
}

- (NSArray<NSString *> *)punctCandidatesForKey:(unichar)ch
{
    int pair = 0;
    const char *cands = sf_punct_lookup([self punctStyle], (unsigned char)ch, &pair);
    if (!cands) return nil;

    int n = sf_punct_count(cands);
    if (n <= 0) return nil;

    NSMutableArray<NSString *> *out = [NSMutableArray arrayWithCapacity:(NSUInteger)n];
    for (int i = 0; i < n; i++) {
        size_t len = 0;
        const char *s = sf_punct_nth(cands, i, &len);
        if (!s) continue;
        [out addObject:[[NSString alloc] initWithBytes:s length:len encoding:NSUTF8StringEncoding]];
    }
    return out.count ? out : nil;
}

/* 按下一个标点键。表里没有这个键 → 返回 NO，调用方原样送出。
 *   单候选（, → ，）        → 直接上屏
 *   成对引号（' → ‘’）      → 左右交替，状态记在 _pairState
 *   多候选（[ → 「【〔［）   → 进候选窗，用数字键选 */
- (BOOL)handlePunctuation:(unichar)ch client:(id)sender
{
    int pair = 0;
    const char *raw = sf_punct_lookup([self punctStyle], (unsigned char)ch, &pair);
    if (!raw) return NO;

    NSArray<NSString *> *list = [self punctCandidatesForKey:ch];
    if (list.count == 0) return NO;

    [self discardComposition:sender];    /* 标点独立输出，先把编码组合结束掉（无组合时是空操作） */

    if (pair) {
        NSUInteger k = (NSUInteger)[_pairState[@(ch)] integerValue];
        [self commitText:list[k % list.count] client:sender];
        NSMutableDictionary *next = [_pairState mutableCopy];
        next[@(ch)] = @(k + 1);
        _pairState = next;
        return YES;
    }

    if (list.count == 1) {
        [self commitText:list.firstObject client:sender];
        return YES;
    }

    NSMutableArray<SFCandidate *> *items = [NSMutableArray arrayWithCapacity:list.count];
    for (NSString *s in list) [items addObject:[SFCandidate text:s note:nil]];
    _cands = items;
    _sel   = 0;
    _mode  = SFPickPunct;
    [self showPanelWithClient:sender];
    return YES;
}

#pragma mark 模式切换

- (void)showHUD:(NSString *)text accent:(BOOL)accent seconds:(NSTimeInterval)secs client:(id)sender
{
    [_panel showHUD:text accent:accent seconds:secs atTopLeft:[self candidateTopLeftWithClient:sender]];
}

- (void)showHUD:(NSString *)text accent:(BOOL)accent client:(id)sender
{
    [_panel showHUD:text accent:accent atTopLeft:[self candidateTopLeftWithClient:sender]];
}

- (void)toggleAsciiMode:(id)sender
{
    /* 切英文前，把已打出的字母原样上屏（对齐 Rime ascii_composer 的行为）：
     * 打了一半想临时切英文，不用先 Esc 再重敲。没有组合时才走丢弃（空操作）。
     * 切回中文那一次 _code 必为空（英文模式不拦键），不受影响。 */
    if (_code.length > 0) [self commitText:[_code copy] client:sender];
    else                  [self discardComposition:sender];
    _asciiMode = !_asciiMode;
    [self showHUD:(_asciiMode ? @"英文" : @"中文") accent:_asciiMode client:sender];
}

- (void)togglePunctAscii:(id)sender
{
    _punctAscii = !_punctAscii;
    [[NSUserDefaults standardUserDefaults] setBool:_punctAscii forKey:@"PunctAscii"];
    [self showHUD:(_punctAscii ? @"英文标点" : @"中文标点") accent:_punctAscii client:sender];
}

- (void)toggleFullShape:(id)sender
{
    _fullShape = !_fullShape;
    [[NSUserDefaults standardUserDefaults] setBool:_fullShape forKey:@"FullShape"];
    [self showHUD:(_fullShape ? @"全角" : @"半角") accent:_fullShape client:sender];
}

/* 查编码模式：输入拼音（或双拼码）→ 候选窗列出同音字，每个字后面标出它的音形码。
 * 场景是「遇到不会打的字，知道读音不知道码」。 */
- (void)toggleReverseMode:(id)sender
{
    [self discardComposition:sender];
    _reverseMode = !_reverseMode;
    /* 英文模式是「一个键都不拦」，与「要拦字母来查编码」直接冲突，
     * 所以进查编码模式时顺手把英文模式关掉，省得按了 Ctrl+/ 却打不出东西。 */
    if (_reverseMode) _asciiMode = NO;
    [self showHUD:(_reverseMode ? @"查编码：输入拼音" : @"查编码：关")
           accent:_reverseMode client:sender];
}

/* 主题切换：在内置主题里循环（metro → dark → paper → …），并写回 NSUserDefaults 记住。
 *
 * 刻意不清空组字状态 —— 换主题只是换外观，不该打断正在打的字：
 *   正在组字（候选窗开着）→ 重绘候选窗，立刻看到新配色；
 *   没在组字            → 用 HUD 报一下当前主题名。
 * 分号在组字里是「次选」，但那条路要求不带 Ctrl，与本键位不冲突。 */
- (void)toggleTheme:(id)sender
{
    NSArray<NSString *> *names = [SFCandidateTheme allThemeNames];
    NSUInteger i = [names indexOfObject:_themeName];
    if (i == NSNotFound) i = 0;
    i = (i + 1) % names.count;

    _themeName = names[i];
    [[NSUserDefaults standardUserDefaults] setObject:_themeName forKey:@"Theme"];
    _panel.theme = [SFCandidateTheme themeNamed:_themeName];

    if (_cands.count > 0) [self showPanelWithClient:sender];     /* 立刻看到新配色 */
    else [self showHUD:[NSString stringWithFormat:@"主题：%@", _themeName]
                accent:NO client:sender];
}

#pragma mark 按键

- (BOOL)handleKeyDown:(NSEvent *)event client:(id)sender
{
    if (_shiftDown) _shiftCombo = YES;   /* Shift 期间按了别的键 → 不算「单敲 Shift」 */

    /* 码表缺失守卫。本仓库不含码表（版权归小鹤官方，见 NOTICE），clone 之后必须自己
     * 放一份才能打汉字。缺表时按键一点反应都没有，而 NSLog 用户根本看不到 ——
     * 最容易被误判成「装坏了」，所以这里弹一条可见提示，指名放到哪个目录。
     * 返回 NO 不吞键：字母照常上屏，至少还能当英文键盘用，不会看起来像卡死。
     * 节流 20 秒，免得连续打字时 HUD 一直闪。 */
    if (!SFSharedEngine()) {
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        if (now - _dictWarnAt > 20.0) {
            _dictWarnAt = now;
            [self showHUD:@"未找到码表 simplefly.dict（获取方法见 README）"
                   accent:YES seconds:5.0 client:sender];
        }
        return NO;
    }

    NSEventModifierFlags f = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    BOOL cmd   = (f & NSEventModifierFlagCommand) != 0;
    BOOL opt   = (f & NSEventModifierFlagOption)  != 0;
    BOOL ctrl  = (f & NSEventModifierFlagControl) != 0;
    BOOL shift = (f & NSEventModifierFlagShift)   != 0;
    unsigned short kc = event.keyCode;

    /* ---- 1. 四个组合开关。放在最前面，免得被下面的 Cmd/Ctrl 直通规则截走 ---- */
    if (shift && !cmd && !opt && !ctrl && kc == kVK_Space) {
        [self toggleFullShape:sender];
        return YES;
    }
    if (ctrl && !cmd && !opt && kc == kVK_ANSI_Period) {
        [self togglePunctAscii:sender];
        return YES;
    }
    if (ctrl && !cmd && !opt && kc == kVK_ANSI_Slash) {
        if (shift) {
            [self lookupSelection:sender];   /* Ctrl+Shift+/：查选中文字的编码 */
        } else {
            [self toggleReverseMode:sender];
        }
        return YES;
    }
    if (ctrl && shift && !cmd && !opt && kc == kVK_ANSI_F) {
        [self convertSelectionToTrad:sender];   /* Ctrl+Shift+F：选中文字简繁互转（双向） */
        return YES;
    }
    if (ctrl && shift && !cmd && !opt && kc == kVK_ANSI_T) {
        [self toggleOutputTrad:sender];   /* Ctrl+Shift+T：输出模式 简/繁 切换 */
        return YES;
    }
    if (ctrl && shift && !cmd && !opt && kc == kVK_ANSI_U) {
        [self webdavSyncUp:sender];       /* Ctrl+Shift+U：短语+重码记忆 上传同步 */
        return YES;
    }
    if (ctrl && shift && !cmd && !opt && kc == kVK_ANSI_D) {
        [self webdavSyncDown:sender];     /* Ctrl+Shift+D：从云端下载恢复 */
        return YES;
    }
    if (ctrl && !cmd && !opt && kc == kVK_ANSI_Semicolon) {
        if (shift) {
            /* Ctrl+Shift+; 清空重码记忆：删文件 + 丢缓存，HUD 确认。
             * 放在这里是因为它和切主题同键位 —— 主题是 Ctrl+;，加 Shift 是清记忆，
             * 手感上「记忆也是一种外观偏好」，一组键位收一起不用再占一个组合。 */
            NSString *path = SFFreqPath();
            sf_freq_purge(path.fileSystemRepresentation);
            if (_freq) { sf_freq_free(_freq); _freq = NULL; }
            [self showHUD:@"重码记忆已清空" accent:NO seconds:1.5 client:sender];
        } else {
            [self toggleTheme:sender];
        }
        return YES;
    }

    /* ---- 2. Cmd / Opt / Ctrl 组合一律交还应用（复制粘贴、切输入法、终端 Ctrl 序列…） ---- */
    if (cmd || opt || ctrl) {
        [self discardComposition:sender];
        return NO;
    }

    /* ---- 3. 英文模式：一个键都不拦 ----
     * 全部 return NO 交给应用，连标点也不管 —— 这才是「英文模式」该有的样子，
     * 顺带避免吞掉应用的单键快捷键。 */
    if (_asciiMode) {
        [self discardComposition:sender];
        return NO;
    }

    /* ---- 4. 功能键 ---- */
    switch (kc) {
        case kVK_Delete:                                  /* Backspace */
            if (_code.length == 1) [self noteMissSevered];   /* 退到空 = 整段放弃 */
            if (_code.length > 0) {
                [_code deleteCharactersInRange:NSMakeRange(_code.length - 1, 1)];
                [self refreshWithClient:sender];
                return YES;
            }
            if (_mode == SFPickPunct) {                   /* 标点候选态下退格 = 放弃选择 */
                [self discardComposition:sender];
                return YES;
            }
            return NO;

        case kVK_ForwardDelete:
            if (_code.length == 0 && _mode == SFPickNone) return NO;
            [self noteMissSevered];
            [self discardComposition:sender];
            return YES;

        case kVK_Escape:
            /* 查编码模式下、缓冲已空时，Esc 用来退出这个模式（有缓冲时先清缓冲） */
            if (_reverseMode && _code.length == 0 && _mode == SFPickNone) {
                [self toggleReverseMode:sender];
                return YES;
            }
            if (_code.length == 0 && _mode == SFPickNone) return NO;
            [self noteMissSevered];                       /* Esc = 打了又放弃 */
            [self discardComposition:sender];
            return YES;

        case kVK_Tab:
            /* 官方 key_binder 里 Tab 在组字状态下等价于 Escape；清掉缓冲后照常送给应用 */
            if (_code.length == 0 && _mode == SFPickNone) return NO;
            [self noteMissSevered];
            [self discardComposition:sender];
            return NO;

        case kVK_Return:
        case kVK_ANSI_KeypadEnter:
            if (_code.length == 0 && _mode == SFPickNone) return NO;
            if (_cands.count > 0) [self commitCandidateAtIndex:_sel client:sender];
            else                  [self discardComposition:sender];
            return YES;

        /* 方向键选候选。有候选时四个键都移动高亮（↑ ← 往前、↓ → 往后，两端回绕，
         * 这样一页 9 个候选按一次反方向就能跳到末尾）；没有候选时保持老行为 ——
         * 不在组字状态直接放行，让应用去移动文本光标。 */
        case kVK_LeftArrow:  case kVK_UpArrow:
        case kVK_RightArrow: case kVK_DownArrow:
            if (_cands.count == 0) {
                if (_code.length == 0 && _mode == SFPickNone) return NO;
                [self discardComposition:sender];
                return NO;
            }
            [self moveSelection:((kc == kVK_LeftArrow || kc == kVK_UpArrow) ? -1 : +1)
                         client:sender];
            return YES;

        case kVK_Home:       case kVK_End:
        case kVK_PageUp:     case kVK_PageDown:
            if (_code.length == 0 && _mode == SFPickNone) return NO;
            [self discardComposition:sender];
            return NO;

        case kVK_Space:
            if (_cands.count > 0 && _mode != SFPickNone) {
                [self commitCandidateAtIndex:_sel client:sender];      /* 空格上屏高亮项 */
                return YES;
            }
            if (_code.length > 0) {                                   /* 有编码但无候选：丢掉别卡住 */
                [self discardComposition:sender];
                return YES;
            }
            break;    /* 无编码 → 走下面的字符流程（全角模式下会变成全角空格） */

        default:
            break;
    }

    /* ---- 5. 文本字符 ---- */
    NSString *chars = event.characters;
    if (chars.length == 0) {
        if (_code.length > 0 || _mode != SFPickNone) [self discardComposition:sender];
        return NO;
    }

    unichar ch = [chars characterAtIndex:0];
    /* 控制字符与功能键区（NSFunctionKeyRange 起于 0xF700）不归输入法管 */
    if (ch < 0x20 || ch == 0x7F || ch >= 0xF700) {
        if (_code.length > 0 || _mode != SFPickNone) [self discardComposition:sender];
        return NO;
    }

    /* 数字键选词：码表 / 标点 / 查编码三种候选共用同一套。
     * 编号是**本页内**的序号（候选窗画的也是它），所以要先按高亮推出当前页起点 ——
     * 普通组字最多 9 条、只有一页，pageStart 恒为 0，行为与以前完全一致；
     * 查编码一页 27 个，翻到第 2 页时按 1 选的是本页第 1 个，不是全局第 1 个。 */
    if (ch >= '1' && ch <= '9' && _mode != SFPickNone) {
        NSUInteger pageStart = [SFCandidatePanel pageRangeForSelected:_sel
                                                               count:_cands.count].location;
        NSUInteger idx = pageStart + (NSUInteger)(ch - '1');
        if (idx < _cands.count) {
            [self commitCandidateAtIndex:idx client:sender];
            return YES;
        }
        [self discardComposition:sender];
        return NO;
    }

    /* 分号次选 —— 对应官方 key_binder 的 {accept: semicolon, send: 2, when: has_menu}。
     * 分号同时是编码首字符（音形用），所以仅当「已在组字且缓冲不以 ; 开头」时才当次选。 */
    if (ch == ';' && _cands.count > 1 && _code.length > 0 && ![_code hasPrefix:@";"]) {
        [self commitCandidateAtIndex:1 client:sender];
        return YES;
    }

    /* 大写字母（Shift+字母）：Rime 的 ascii_composer 直接输出原字符，不进编码缓冲。
     * 顺带避免 Shift+A 被 lowercased 成 a 而丢掉大小写。 */
    if (ch >= 'A' && ch <= 'Z') {
        if (_code.length > 0 || _mode != SFPickNone) [self discardComposition:sender];
        [self commitText:chars client:sender];
        return YES;
    }

    /* 编码字符：[a-z;'] */
    if ([chars isEqualToString:[chars lowercaseString]]) {
        BOOL allCode = (chars.length > 0);
        for (NSUInteger i = 0; i < chars.length && allCode; i++)
            if (!SFIsCodeChar([chars characterAtIndex:i])) allCode = NO;
        if (allCode) return [self appendCode:chars client:sender];
    }

    /* 逗号/句号顶屏 —— 对应官方 {accept: Release+period/comma, send: period, when: composing}：
     * 先把当前高亮那个候选顶上去，再把标点本身打出去。
     * 顶的是「高亮项」而不是死板的第一个 —— 用户按过方向键选中的就是他想上屏的那个。 */
    if ((ch == ',' || ch == '.') && _mode == SFPickCode) {
        if (_cands.count > 0) [self commitCandidateAtIndex:_sel client:sender];
        else                  [self discardComposition:sender];
        if (![self handlePunctuation:ch client:sender]) [self commitText:chars client:sender];
        return YES;
    }

    /* 标点表 */
    if ([self handlePunctuation:ch client:sender]) return YES;

    /* 兜底：先结束组字，再把字符原样送出 */
    if (_code.length > 0 || _mode != SFPickNone) [self discardComposition:sender];
    [self commitText:chars client:sender];
    return YES;
}

/* 追加一个编码字符并刷新。返回 YES 表示这个键已被输入法消费。 */
- (BOOL)appendCode:(NSString *)chars client:(id)sender
{
    NSString *prev = [_code copy];
    BOOL wasEmpty  = (_code.length == 0);
    [_code appendString:chars];

    /* 查编码模式：输入的是拼音，中途状态（"ha"）在码表里当然查不到，
     * 但那是正常过程，不能判空码 —— 这里只要缓冲没长得离谱就一直收。 */
    if (_reverseMode) {
        if (_code.length <= 12) {
            [self refreshWithClient:sender];
            return YES;
        }
        [_code setString:prev];
        NSBeep();
        return YES;
    }

    SFHit probe[SF_MAX_CANDS];
    int n = sf_engine_lookup(SFSharedEngine(), _code.UTF8String, probe,
                             (int)_maxCands, _completion ? 1 : 0);
    if (n > 0) {
        [self refreshWithClient:sender];
        return YES;
    }

    /* 自定义短语的前缀同样算「还没打完」。
     * 没有这一条，用户绑了 abc=测试短语 之后敲到 fm 会因为码表里什么都没有、
     * 被判成空码回退并 beep —— 于是永远打不出 abc。 */
    if (sf_phrase_has_prefix([self phraseBook], _code.UTF8String)) {
        [self refreshWithClient:sender];
        return YES;
    }

    /* 空码：回退这一键，不吞按键也不乱改缓冲。
     * 唯一的例外是「缓冲区本来是空的 + 单字符 + 标点表里有映射」——
     * 码表里没有任何以 ' 开头的编码（单引号只做韵母分隔符），
     * 所以空缓冲下敲 ' 是「想要中文引号」，不是「想打编码」。 */
    [_code setString:prev];
    if (wasEmpty && chars.length == 1 &&
        [self handlePunctuation:[chars characterAtIndex:0] client:sender]) {
        return YES;
    }
    NSBeep();
    return YES;
}

#pragma mark 鼠标

/* 自己实现默认的鼠标行为：有活动组合时点击文本 → 结束组合（IMK 的默认处理在
 * recognizedEvents 不是 NSKeyDownMask 时会失效）。返回 NO 表示点击照常交给应用。 */
- (BOOL)mouseDownOnCharacterIndex:(NSUInteger)index
                       coordinate:(NSPoint)point
                     withModifier:(NSUInteger)flags
                 continueTracking:(BOOL *)keepTracking
                           client:(id)sender
{
    (void)index; (void)point; (void)flags;
    if (keepTracking) *keepTracking = NO;
    [self discardComposition:sender];
    return NO;
}

#pragma mark 生命周期

- (void)commitComposition:(id)sender
{
    /* 客户端要求立刻结束组合。这里只有一个未成词的编码，没有可上屏的内容。 */
    [self discardComposition:sender];
}

- (void)activateServer:(id)sender
{
    [super activateServer:sender];
    [self discardComposition:sender];
}

- (void)deactivateServer:(id)sender
{
    [self discardComposition:sender];
    [super deactivateServer:sender];
}

- (void)hidePalettes
{
    [_panel hide];
    [super hidePalettes];
}

- (void)inputControllerWillClose
{
    [_panel hide];
    _cands = @[];
    [_code setString:@""];
    /* 自定义短语表是 C 结构、归 ARC 不管，得自己收 */
    if (_phraseBook) { sf_phrase_free(_phraseBook); _phraseBook = NULL; }
    /* 重码记忆同理。每次上屏时已同步 flush 过，这里大概率没有脏数据，
     * flush 一次是无害兜底（比如用户手改了文件但本进程还没写回的场景不存在 ——
     * 本进程不重读，这里只防 trim/put 之后没走到 flush 的路径）。 */
    if (_freq) {
        sf_freq_flush(_freq, SFFreqPath().fileSystemRepresentation);
        sf_freq_free(_freq);
        _freq = NULL;
    }
}

@end
