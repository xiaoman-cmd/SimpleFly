/* controller_test.m —— 控制器按键路由的离线单测
 *
 * 为什么需要它：真机上验证输入法只能靠「手动打字看效果」，一旦某条分支写错，
 * 表现是「某个键没反应」这种极难定位的现象。这里把 SimpleFlyInputController
 * 装上一个假客户端，直接喂合成的 NSEvent，断言「最终上屏了什么」。
 *
 * 关键手法有两个：
 *   1. 用一个子类把 -updateComposition 覆盖成空操作。IMKInputController 的
 *      这个方法会去碰 InputMethodKit 内部（要和真实输入法会话通信），覆盖掉就
 *      完全不依赖 IMK 运行时，普通命令行程序也能跑。
 *   2. 事件用 +[NSEvent keyEventWithType:...] 自己造，characters / keyCode /
 *      modifierFlags 全部由我们指定，所以不需要真实键盘。
 *
 * 编译与运行见 ./build.sh 的 test 目标，或：
 *   clang -fobjc-arc -O2 -Wall -Wextra -isysroot "$(xcrun --show-sdk-path)" \
 *         -framework Cocoa -framework InputMethodKit -I src \
 *         src/ *.m  src/ *.c  tools/controller_test.m -o build/controller_test
 *   cp resources/simplefly.dict build/     # 测试二进制要从自己旁边读码表
 *   ./build/controller_test
 */
#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>

#import "SFInputController.h"
#import "SFCandidatePanel.h"
#import "SFCandidateTheme.h"
#include "engine.h"
#include "punctuation.h"
#include "s2t.h"

/* 非正式协议（NSObject (IMKServerInput)）里的方法没有类接口声明，补一下免得编译器告警 */
@interface SimpleFlyInputController (SFTestOnly)
- (BOOL)handleEvent:(NSEvent *)event client:(id)sender;
- (id)composedString:(id)sender;
- (void)setupState;      /* 定义在 .m 里，initWithServer: 之后会调它 */
- (NSMenu *)menu;        /* 状态栏菜单（IMK informal，覆盖实现） */
- (NSDictionary<NSString *, NSString *> *)webdavConfig;   /* 合并 conf + defaults */
- (void)openWebDAVConfig:(id)sender;                      /* 「网盘配置」实现 */
- (void)openUserConfig:(id)sender;                        /* 「用户配置」实现 */
- (void)openUserManual:(id)sender;                        /* 「用户手册」实现 */
@end

#pragma mark - 断言

static int g_pass = 0;
static int g_fail = 0;

/* printf 不认 %@，打印对象统一走这个 */
static const char *CStr(id x)
{
    NSString *s = [x description];
    return s ? s.UTF8String : "(nil)";
}

#define CHECK(cond, fmt, ...) do {                                          \
    if (cond) { g_pass++; printf("  \xe2\x9c\x93 " fmt "\n", ##__VA_ARGS__); } \
    else      { g_fail++; printf("  \xe2\x9c\x97 " fmt "\n", ##__VA_ARGS__); } \
} while (0)

#pragma mark - 假客户端

@interface FakeClient : NSObject
@property (nonatomic, strong) NSMutableString *output;
@property (nonatomic, assign) NSRect caretRect;
@property (nonatomic, assign) NSUInteger caretQueries;
/* 「选中文字」模拟（Ctrl+Shift+/ 用）：置空 range = 没有选区 */
@property (nonatomic, assign) NSRange selection;
@property (nonatomic, copy) NSString *selectionText;
@end

@implementation FakeClient

- (instancetype)init
{
    if ((self = [super init])) {
        _output = [NSMutableString string];
        _selection = NSMakeRange(NSNotFound, 0);    /* 默认没有选区 */
    }
    return self;
}

/* 与真 client 相同语义：没有选区/越界时返回 nil */
- (NSAttributedString *)attributedSubstringFromRange:(NSRange)range
{
    if (!_selectionText || range.location == NSNotFound ||
        NSMaxRange(range) > _selectionText.length)
        return nil;
    return [[NSAttributedString alloc]
            initWithString:[_selectionText substringWithRange:range]];
}

- (NSRange)selectedRange
{
    return _selection;
}

/* 控制器只会用这两个方法 */
- (void)insertText:(id)string replacementRange:(NSRange)replacementRange
{
    /* 范围有效且在已输出文本内 → 原位替换（简繁转换走这条路）；否则追加 */
    if (replacementRange.location != (NSUInteger)NSNotFound &&
        NSMaxRange(replacementRange) <= _output.length) {
        [_output replaceCharactersInRange:replacementRange withString:string];
    } else {
        [_output appendString:string];
    }
}

- (NSDictionary *)attributesForCharacterIndex:(NSUInteger)index lineHeightRectangle:(NSRect *)lineRect
{
    (void)index;
    _caretQueries++;
    if (lineRect) *lineRect = _caretRect;
    return @{};
}

@end

#pragma mark - 被测试的控制器

/* 覆盖 updateComposition：记录「告诉 IMK 的当前编码」但不碰 IMK 内部。
 * 这样整条链路（handleEvent → 状态机 → 上屏）都能在命令行里真跑。 */
@interface TestController : SimpleFlyInputController
@property (nonatomic, copy)   NSString *lastComposed;
@property (nonatomic, assign) NSUInteger compositionUpdates;
@end

@implementation TestController

- (void)updateComposition
{
    self.compositionUpdates++;
    self.lastComposed = [self composedString:nil];
}

@end

#pragma mark - 造事件

static TestController *gCtl;
static FakeClient *gClient;

static NSEvent *KeyEvent(unichar ch, unsigned short keyCode, NSEventModifierFlags mods)
{
    NSString *s = ch ? [NSString stringWithFormat:@"%C", ch] : @"";
    return [NSEvent keyEventWithType:NSEventTypeKeyDown
                            location:NSZeroPoint
                       modifierFlags:mods
                           timestamp:0
                        windowNumber:0
                             context:nil
                          characters:s
         charactersIgnoringModifiers:s
                           isARepeat:NO
                             keyCode:keyCode];
}

static NSEvent *FlagsEvent(NSEventModifierFlags mods)
{
    return [NSEvent keyEventWithType:NSEventTypeFlagsChanged
                            location:NSZeroPoint
                       modifierFlags:mods
                           timestamp:0
                        windowNumber:0
                             context:nil
                          characters:@""
         charactersIgnoringModifiers:@""
                           isARepeat:NO
                             keyCode:0];
}

/* US 布局下字符 → 虚拟键码，测试里只覆盖用得到的这些 */
static unsigned short KeyCodeForChar(unichar ch)
{
    static const unsigned short letterCodes[26] = {
        kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F,
        kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L,
        kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R,
        kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X,
        kVK_ANSI_Y, kVK_ANSI_Z
    };
    static const unsigned short digitCodes[10] = {
        kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
        kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9
    };
    if (ch >= 'a' && ch <= 'z') return letterCodes[ch - 'a'];
    if (ch >= 'A' && ch <= 'Z') return letterCodes[ch - 'A'];
    if (ch >= '0' && ch <= '9') return digitCodes[ch - '0'];
    switch (ch) {
        case ' ':  return kVK_Space;
        case ',':  return kVK_ANSI_Comma;
        case '.':  return kVK_ANSI_Period;
        case ';':  return kVK_ANSI_Semicolon;
        case '\'': return kVK_ANSI_Quote;
        case '"':  return kVK_ANSI_Quote;
        case '/':  return kVK_ANSI_Slash;
        case '[':  return kVK_ANSI_LeftBracket;
        case ']':  return kVK_ANSI_RightBracket;
        case '-':  return kVK_ANSI_Minus;
        case '=':  return kVK_ANSI_Equal;
        default:   return 0;
    }
}

/* 敲一个可见字符 */
static BOOL Type(unichar ch, NSEventModifierFlags mods)
{
    return [gCtl handleEvent:KeyEvent(ch, KeyCodeForChar(ch), mods) client:gClient];
}

/* 敲一个功能键（没有可见字符） */
static BOOL TypeKey(unsigned short keyCode, NSEventModifierFlags mods)
{
    return [gCtl handleEvent:KeyEvent(0, keyCode, mods) client:gClient];
}

static void TypeString(const char *s)
{
    for (const char *p = s; *p; p++) Type((unichar)*p, 0);
}

/* 单敲 Shift：按下再抬起，中间不按别的键 */
static void ShiftTap(void)
{
    [gCtl handleEvent:FlagsEvent(NSEventModifierFlagShift) client:gClient];
    [gCtl handleEvent:FlagsEvent(0) client:gClient];
}

#pragma mark - 状态读取（直接读 ivar，避免为测试改产品代码）

static BOOL BoolIvar(id obj, const char *name)
{
    Ivar iv = class_getInstanceVariable([obj class], name);
    if (!iv) { printf("  ! 找不到 ivar %s\n", name); return NO; }
    return *(BOOL *)((char *)(__bridge void *)obj + ivar_getOffset(iv));
}

static int IntIvar(id obj, const char *name)
{
    Ivar iv = class_getInstanceVariable([obj class], name);
    if (!iv) { printf("  ! 找不到 ivar %s\n", name); return 0; }
    return *(int *)((char *)(__bridge void *)obj + ivar_getOffset(iv));
}

static id ObjIvar(id obj, const char *name)
{
    Ivar iv = class_getInstanceVariable([obj class], name);
    if (!iv) { printf("  ! 找不到 ivar %s\n", name); return nil; }
    return object_getIvar(obj, iv);      /* ARC 下不能自己把 char* 转成 __strong id* */
}

#pragma mark - 期望值直接问引擎

/* 找一个真实的编码，而不是把测试写死在对码表的假设上。
 * 曾经写死过 "hao" —— 码表里根本没有这个编码（小鹤双拼里 ao 映射到 c，好 = hc）。
 * 只取长度 2~3 的：长度 4 会触发四键上屏，不适合用来测「组字/选词」。
 * include_completion=0 表示只认精确匹配，保证返回的编码至少 minCands 个真候选。 */
static NSString *FindCode(NSUInteger minCands)
{
    const char *L = "abcdefghijklmnopqrstuvwxyz";
    SFHit hits[SF_MAX_CANDS];
    for (int len = 2; len <= 3; len++) {
        int idx[4] = {0};
        char buf[8] = {0};
        while (1) {
            for (int i = 0; i < len; i++) buf[i] = L[idx[i]];
            int n = sf_engine_lookup(SFSharedEngine(), buf, hits, (int)minCands, 0);
            if (n >= (int)minCands) return [NSString stringWithUTF8String:buf];
            int p = len - 1;
            while (p >= 0 && ++idx[p] == 26) { idx[p] = 0; p--; }
            if (p < 0) break;
        }
    }
    return nil;
}

static NSString *Cand(const char *code, int idx)
{
    SFHit hits[SF_MAX_CANDS];
    int n = sf_engine_lookup(SFSharedEngine(), code, hits, SF_MAX_CANDS, 1);
    if (idx >= n) return nil;
    return [NSString stringWithUTF8String:hits[idx].text];
}

#pragma mark - 新功能的辅助

/* 当前候选（SFCandidate 数组） */
static NSArray *Cands(void) { return (NSArray *)ObjIvar(gCtl, "_cands"); }

static NSUInteger CandsCount(void) { return [Cands() count]; }

/* 从当前候选里挑出词条是 text 的那条，用来检查它的附注（音形码） */
static SFCandidate *CandidateNamed(NSString *text)
{
    for (SFCandidate *c in Cands())
        if ([c.text isEqualToString:text]) return c;
    return nil;
}

/* 找一个「码表会判空」的编码：首字符码表里有候选，但两字符、三字符都没有。
 * 自定义短语的前缀保护就靠它验证 —— 没有保护的话，敲完第一个字符之后
 * 第二个字符会被判空码回退，三字符的短语永远打不出来。 */
static NSString *FindGapCode(void)
{
    const char *L = "abcdefghijklmnopqrstuvwxyz";
    SFHit hits[SF_MAX_CANDS];
    for (int a = 0; a < 26; a++) {
        char one[2] = { L[a], '\0' };
        if (sf_engine_lookup(SFSharedEngine(), one, hits, 1, 0) <= 0) continue;
        for (int b = 0; b < 26; b++) {
            char two[3] = { L[a], L[b], '\0' };
            if (sf_engine_lookup(SFSharedEngine(), two, hits, 1, 0) > 0) continue;
            char three[4] = { L[a], L[b], 'q', '\0' };
            if (sf_engine_lookup(SFSharedEngine(), three, hits, 1, 0) > 0) continue;
            return [NSString stringWithUTF8String:three];
        }
    }
    return nil;
}

/* 自定义短语表的位置，由 main 传给进程；测试绝不碰用户真实配置 */
static const char *gPhrasePath = NULL;

/* 重码记忆文件的位置，由 main 传给进程；提前声明，前面的用例也可能要清它 */
static const char *gFreqPath = NULL;

/* 打错日志文件的位置，由 main 传给进程 */
static const char *gMislogPath = NULL;

static void WritePhraseFile(NSString *content)
{
    if (!gPhrasePath) return;
    [content writeToFile:[NSString stringWithUTF8String:gPhrasePath]
              atomically:YES
                encoding:NSUTF8StringEncoding
                   error:NULL];
}

#pragma mark - 用例

/* -client 的测试替身。
 *
 * 真机上 IMKInputController 的 -client 返回当前输入会话的客户端；测试里那块内部字段
 * 没有初始化（见 Fresh 的注释），菜单命令的 client 兜底一旦问它就会摸到野指针、
 * 当场段错误。把它的实现换成返回 gClient —— 语义与真机一致。
 * gClient 每轮 Fresh 都新建，所以这里只在被调用时取值，不做缓存。 */
static id SFTestClientGetter(id self, SEL _cmd) { return gClient; }

static void Fresh(void)
{
    gClient = [[FakeClient alloc] init];
    gClient.caretRect = NSMakeRect(200, 400, 8, 20);
    /* 不走 initWithServer:delegate:client: —— IMKInputController 那一步会校验 client
     * 必须是真实的输入会话代理，塞个假对象进去直接抛异常。alloc + setupState 等价，
     * 只是跳过了 IMK 自己的那点内部初始化，而本测试根本不碰 IMK 内部。
     * 代价就是 -client 不可用，所以要先把它的实现换掉（幂等，只做一次）。 */
    static BOOL clientPatched = NO;
    if (!clientPatched) {
        Method m = class_getInstanceMethod([TestController class], @selector(client));
        if (m) method_setImplementation(m, (IMP)SFTestClientGetter);
        clientPatched = YES;
    }
    gCtl = [[TestController alloc] init];
    [gCtl setupState];
}

static void test_composition(void)
{
    puts("\n== 组字：内嵌编码 + 空格上屏 ==");
    NSString *code = FindCode(1);
    CHECK(code.length > 0, "码表里找到可测编码（%s）", CStr(code));
    if (code.length == 0) return;

    Fresh();
    NSString *head = [code substringToIndex:1];
    Type([code characterAtIndex:0], 0);
    CHECK([ObjIvar(gCtl, "_code") isEqualToString:head], "敲首个字符后缓冲 = %s", CStr(head));
    CHECK([gCtl.lastComposed isEqualToString:head], "内嵌编码同步给输入框 = %s", CStr(head));
    CHECK(gCtl.compositionUpdates >= 1, "改编码会刷新一次 composition（%lu 次）",
          (unsigned long)gCtl.compositionUpdates);
    CHECK(gClient.output.length == 0, "组字途中不上屏");

    TypeString(code.UTF8String + 1);
    CHECK([ObjIvar(gCtl, "_code") isEqualToString:code], "完整编码进入缓冲 = %s", CStr(code));
    NSString *want = Cand(code.UTF8String, 0);
    CHECK(want.length > 0, "码表里 %s 有候选（%s）", code.UTF8String, CStr(want));

    BOOL handled = Type(' ', 0);
    CHECK(handled, "空格被输入法消费");
    CHECK([gClient.output isEqualToString:want], "空格上屏首选：%s", CStr(gClient.output));
    CHECK([ObjIvar(gCtl, "_code") length] == 0, "上屏后缓冲清空");
    /* 上屏刻意不再调 updateComposition —— insertText 会把输入框里的内嵌编码顶掉，
     * 这是 IMK/TIM 的标准语义（所有输入法都依赖它）。所以这里断言的是 composedString
     * 已经为空，而不是 lastComposed 被刷新过。 */
    CHECK([(NSString *)[gCtl composedString:nil] length] == 0, "上屏后 composedString 为空");
}

static void test_select(void)
{
    puts("\n== 选词：数字键 / 分号次选 / 回车 ==");
    NSString *code = FindCode(2);
    CHECK(code.length > 0, "码表里找到至少 2 个候选的编码（%s）", CStr(code));
    if (code.length == 0) return;

    NSString *second = Cand(code.UTF8String, 1);
    CHECK(second.length > 0, "%s 至少两个候选", code.UTF8String);

    Fresh();
    TypeString(code.UTF8String);
    Type('2', 0);
    CHECK([gClient.output isEqualToString:second], "数字键 2 = 第 2 候选：%s", CStr(gClient.output));

    Fresh();
    TypeString(code.UTF8String);
    Type(';', 0);
    CHECK([gClient.output isEqualToString:second], "分号 = 次选：%s", CStr(gClient.output));

    /* 单敲 ; 的候选菜单（：/；+ 补全带出的快符，不止 2 个）：; 是次选（0.6.2 补：
     * 缓冲恰为 ";" 时放行，";;" 不是合法编码、与快符 ;x 无冲突；
     * 此前被 hasPrefix:@";" 挡住落到编码路径）。 */
    Fresh();
    Type(';', 0);
    NSUInteger semiN = CandsCount();
    CHECK(semiN >= 2, "单敲 ; 至少 2 个候选（%lu）", (unsigned long)semiN);
    if (semiN >= 2) {
        NSString *semiSecond = ((SFCandidate *)Cands()[1]).text;
        Type(';', 0);
        CHECK([gClient.output isEqualToString:semiSecond],
              "单敲 ; 再按 ; = 第 2 候选：%s", CStr(gClient.output));
        CHECK(BoolIvar(gCtl, "_composing") == NO, "上屏后组词态结束");
    }

    Fresh();
    TypeString(code.UTF8String);
    BOOL handled = TypeKey(kVK_Return, 0);
    CHECK(handled && [gClient.output isEqualToString:Cand(code.UTF8String, 0)],
          "回车上屏首选：%s", CStr(gClient.output));
}

static void test_backspace_escape(void)
{
    puts("\n== 退格 / Esc ==");
    Fresh();
    Type('h', 0);
    Type('a', 0);
    TypeKey(kVK_Delete, 0);
    CHECK([ObjIvar(gCtl, "_code") isEqualToString:@"h"], "退格删一个字符 → h");
    CHECK([gCtl.lastComposed isEqualToString:@"h"], "退格后内嵌编码跟着变");

    Fresh();
    Type('h', 0);
    BOOL handled = TypeKey(kVK_Escape, 0);
    CHECK(handled && [ObjIvar(gCtl, "_code") length] == 0, "Esc 清空缓冲");
    CHECK(gCtl.lastComposed.length == 0, "Esc 后内嵌编码抹掉");

    Fresh();
    CHECK(TypeKey(kVK_Delete, 0) == NO, "空缓冲下退格交还应用");
    CHECK(TypeKey(kVK_Escape, 0) == NO, "空缓冲下 Esc 交还应用");
}

static void test_autocommit(void)
{
    puts("\n== 四键上屏 ==");
    /* 找一个「码长 4 且精确匹配唯一」的编码，直接用引擎的判定函数找 */
    const char *letters = "abcdefghijklmnopqrstuvwxyz";
    char code[8] = {0};
    BOOL found = NO;
    for (int a = 0; a < 26 && !found; a++)
    for (int b = 0; b < 26 && !found; b++)
    for (int c = 0; c < 26 && !found; c++)
    for (int d = 0; d < 26 && !found; d++) {
        code[0] = letters[a]; code[1] = letters[b];
        code[2] = letters[c]; code[3] = letters[d];
        SFHit hits[SF_MAX_CANDS];
        int n = sf_engine_lookup(SFSharedEngine(), code, hits, SF_MAX_CANDS, 1);
        if (n == 1 && sf_engine_should_autocommit(code, hits, n)) found = YES;
    }
    CHECK(found, "码表里存在可四键上屏的编码（%s）", code);
    if (found) {
        Fresh();
        TypeString(code);
        CHECK([gClient.output isEqualToString:Cand(code, 0)],
              "四键 %s 自动上屏：%s", code, CStr(gClient.output));
        CHECK([ObjIvar(gCtl, "_code") length] == 0, "四键上屏后缓冲清空");
    }
}

static void test_quick_symbol(void)
{
    /* 官方 auto_select_pattern 的 ^;.$ 那一半：快符打满两码就上屏，不用再按空格。
     * 码表里 ; 开头共 26 行 = 24 个「;+单字母」快符 + 「;」单敲（：/；两个候选）。 */
    puts("\n== ;x 快符上屏（官方 ^;.$）==");

    Fresh();
    TypeString(";a");
    CHECK([gClient.output isEqualToString:Cand(";a", 0)],
          ";a 两码自动上屏（无需空格）：%s", CStr(gClient.output));
    CHECK([ObjIvar(gCtl, "_code") length] == 0, "快符上屏后缓冲清空");

    Fresh();
    TypeString(";x");
    CHECK([gClient.output isEqualToString:Cand(";x", 0)],
          ";x 两码自动上屏：%s", CStr(gClient.output));

    /* 单敲 ; 不能上屏 —— 码表里它就有 2 个候选（：/；），必须留给用户选。
     * 候选数写 >= 2 而不是 == 2：开了补全时 ; 前缀还会带出 ;a/;c… 那一串快符。 */
    Fresh();
    CHECK(Type(';', 0), "; 被消费");
    CHECK(gClient.output.length == 0, "单敲 ; 不自动上屏（有重码要选）");
    CHECK(CandsCount() >= 2, "单敲 ; 至少给 2 个候选，实得 %d", CandsCount());
    Type(' ', 0);
    CHECK([gClient.output isEqualToString:Cand(";", 0)],
          "空格上屏第一个：%s", CStr(gClient.output));

    /* 三个字符：前两码已经把快符顶上去了，第三个字符应当另起一段组字，
     * 而不是拼成 ;aa 去查表（;aa 落不进 ^;.$，本来也不该自动上屏）。 */
    Fresh();
    TypeString(";aa");
    CHECK([gClient.output isEqualToString:Cand(";a", 0)],
          ";aa = 快符上屏 + 新的 a 组字：%s", CStr(gClient.output));
    CHECK([ObjIvar(gCtl, "_code") isEqualToString:@"a"],
          "缓冲里剩下新起的 a，实得 %s", CStr(ObjIvar(gCtl, "_code")));
}

static void test_punctuation_single(void)
{
    puts("\n== 标点：单候选直接上屏 ==");
    Fresh();
    CHECK(Type(',', 0), "逗号被消费");
    CHECK([gClient.output isEqualToString:@"，"], "空缓冲下 , → ，：%s", CStr(gClient.output));
    CHECK(Type('.', 0), "句号被消费");
    CHECK([gClient.output isEqualToString:@"，。"], ". → 。：%s", CStr(gClient.output));
    CHECK(Type('?', 0), "问号被消费");
    CHECK([gClient.output isEqualToString:@"，。？"], "? → ？：%s", CStr(gClient.output));

    Fresh();
    Type('[', 0);
    CHECK(gClient.output.length == 0, "[ 有多个候选，不直接上屏");
    CHECK(IntIvar(gCtl, "_mode") == 2, "进入标点候选态");
    CHECK([ObjIvar(gCtl, "_cands") count] == 4, "候选 4 个");
    Type('2', 0);
    CHECK([gClient.output isEqualToString:@"【"], "数字键选第 2 个 = 【：%s", CStr(gClient.output));

    Fresh();
    Type('[', 0);
    TypeKey(kVK_Escape, 0);
    CHECK(gClient.output.length == 0, "Esc 放弃标点候选，不上屏");
}

static void test_punctuation_pair(void)
{
    puts("\n== 标点：成对引号左右交替 ==");
    Fresh();
    Type('\'', 0);
    CHECK([gClient.output isEqualToString:@"‘"], "第一次 ' → ‘：%s", CStr(gClient.output));
    Type('\'', 0);
    CHECK([gClient.output isEqualToString:@"‘’"], "第二次 ' → ’：%s", CStr(gClient.output));
    Type('\'', 0);
    CHECK([gClient.output isEqualToString:@"‘’‘"], "第三次又回到左引号：%s", CStr(gClient.output));

    Fresh();
    Type('"', NSEventModifierFlagShift);
    CHECK([gClient.output isEqualToString:@"“"], "第一次 \" → “：%s", CStr(gClient.output));
}

static void test_punct_topscreen(void)
{
    puts("\n== 组字中逗号/句号顶屏 ==");
    NSString *code = FindCode(1);
    if (code.length == 0) { CHECK(NO, "找不到可测编码"); return; }

    Fresh();
    TypeString(code.UTF8String);
    Type(',', 0);
    NSString *want = [Cand(code.UTF8String, 0) stringByAppendingString:@"，"];
    CHECK([gClient.output isEqualToString:want], "顶屏：首选 + 逗号 = %s", CStr(gClient.output));
    CHECK([ObjIvar(gCtl, "_code") length] == 0, "顶屏后缓冲清空");
}

static void test_uppercase_and_modifiers(void)
{
    puts("\n== 大写字母与修饰键 ==");
    Fresh();
    Type('A', NSEventModifierFlagShift);
    CHECK([gClient.output isEqualToString:@"A"], "Shift+a 输出大写 A（不进编码）：%s", CStr(gClient.output));

    Fresh();
    BOOL handled = Type('c', NSEventModifierFlagCommand);
    CHECK(handled == NO && gClient.output.length == 0, "Cmd+C 交还应用，不由输入法上屏");

    Fresh();
    handled = Type('c', NSEventModifierFlagControl);
    CHECK(handled == NO && gClient.output.length == 0, "Ctrl+C 交还应用");

    Fresh();
    handled = TypeKey(kVK_LeftArrow, 0);
    CHECK(handled == NO, "空缓冲下方向键交还应用");
}

static void test_ascii_mode(void)
{
    puts("\n== 中英一键切换（单敲 Shift） ==");
    Fresh();
    CHECK(BoolIvar(gCtl, "_asciiMode") == NO, "初始是中文模式");

    ShiftTap();
    CHECK(BoolIvar(gCtl, "_asciiMode") == YES, "单敲 Shift → 英文模式");
    CHECK([gClient.output length] == 0, "切换本身不上屏");

    BOOL handled = Type('a', 0);
    CHECK(handled == NO, "英文模式下字母交还应用（不打汉字）");
    CHECK([gClient.output length] == 0, "英文模式下输入法不上屏");
    CHECK([ObjIvar(gCtl, "_code") length] == 0, "英文模式下不进编码");

    ShiftTap();
    CHECK(BoolIvar(gCtl, "_asciiMode") == NO, "再敲一次 Shift → 回中文模式");
    Type('a', 0);
    CHECK([ObjIvar(gCtl, "_code") isEqualToString:@"a"], "回到中文模式后重新组字");
}

static void test_shift_commit_raw_letters(void)
{
    puts("\n== 单敲 Shift 切英文时，已打出的字母原样上屏 ==");
    Fresh();
    /* 不写死编码（小鹤里「好」= hc 而不是 hao），运行时找一个有候选的合法码 */
    NSString *code = FindCode(1);
    CHECK(code.length >= 2, "找到合法测试编码");
    for (NSUInteger i = 0; i < code.length; i++)
        Type([code characterAtIndex:i], 0);
    CHECK([ObjIvar(gCtl, "_code") isEqualToString:code], "组字中缓冲为 %s", CStr(code));
    ShiftTap();
    CHECK([gClient.output isEqualToString:code], "切英文 → 缓冲字母原样上屏：%s", CStr(gClient.output));
    CHECK(BoolIvar(gCtl, "_asciiMode") == YES, "同时进入英文模式");
    CHECK([ObjIvar(gCtl, "_code") length] == 0, "缓冲清空");
    CHECK(IntIvar(gCtl, "_mode") == 0, "回到空闲态");

    /* 切回中文那一次没有组合，不应有额外输出 */
    ShiftTap();
    CHECK([gClient.output isEqualToString:code], "切回中文不再追加输出");
    CHECK(BoolIvar(gCtl, "_asciiMode") == NO, "回到中文模式");
}

static void test_shift_not_toggled_by_combo(void)
{
    puts("\n== Shift+字母不应触发切换 ==");
    Fresh();
    [gCtl handleEvent:FlagsEvent(NSEventModifierFlagShift) client:gClient];
    Type('a', NSEventModifierFlagShift);          /* Shift 按下期间敲了 a */
    [gCtl handleEvent:FlagsEvent(0) client:gClient];
    CHECK(BoolIvar(gCtl, "_asciiMode") == NO, "Shift+A 抬起后仍是中文模式");
}

static void test_punct_ascii_and_fullshape(void)
{
    puts("\n== Ctrl+. 切标点 / Shift+空格 切全半角 ==");
    Fresh();
    CHECK(Type('.', NSEventModifierFlagControl) == YES, "Ctrl+. 被输入法消费");
    CHECK(BoolIvar(gCtl, "_punctAscii") == YES, "Ctrl+. → 英文标点");
    Type(',', 0);
    CHECK([gClient.output isEqualToString:@","], "英文标点下 , → ,：%s", CStr(gClient.output));
    Type('.', NSEventModifierFlagControl);
    CHECK(BoolIvar(gCtl, "_punctAscii") == NO, "再按一次 → 回中文标点");

    Fresh();
    CHECK(Type(' ', NSEventModifierFlagShift) == YES, "Shift+空格 被输入法消费");
    CHECK(BoolIvar(gCtl, "_fullShape") == YES, "Shift+空格 → 全角");
    Type(' ', 0);
    CHECK([gClient.output isEqualToString:@"　"], "全角模式下空格 → 全角空格：%s", CStr(gClient.output));
    Type(',', 0);
    CHECK([gClient.output isEqualToString:@"　，"], "全角模式下 , 仍是 ，：%s", CStr(gClient.output));
    Type(' ', NSEventModifierFlagShift);
    CHECK(BoolIvar(gCtl, "_fullShape") == NO, "再按一次 Shift+空格 → 回半角");
}

static void test_empty_code_fallback(void)
{
    puts("\n== 空码回退 ==");
    /* 找一对「首字符有候选、两字符没有候选」的字母 */
    const char *letters = "abcdefghijklmnopqrstuvwxyz";
    char pair[3] = {0};
    BOOL found = NO;
    for (int a = 0; a < 26 && !found; a++) {
        char one[2] = { letters[a], 0 };
        SFHit h[SF_MAX_CANDS];
        if (sf_engine_lookup(SFSharedEngine(), one, h, 1, 0) <= 0) continue;
        for (int b = 0; b < 26 && !found; b++) {
            pair[0] = letters[a];
            pair[1] = letters[b];
            if (sf_engine_lookup(SFSharedEngine(), pair, h, 1, 1) <= 0) found = YES;
        }
    }
    CHECK(found, "找到无候选的两字符组合（%s）", pair);

    if (found) {
        Fresh();
        Type((unichar)pair[0], 0);
        BOOL handled = Type((unichar)pair[1], 0);
        CHECK(handled == YES, "空码这一键被吞掉（不落到文档里）");
        /* 注意：条件里不能出现方括号内的裸逗号 —— 预处理器只配对圆括号，
         * 会把 stringWithFormat:@"%c", x 的那个逗号当成宏参数分隔符。所以先算出来。 */
        NSString *expect = [NSString stringWithFormat:@"%c", pair[0]];
        CHECK([ObjIvar(gCtl, "_code") isEqualToString:expect],
              "空码后缓冲回退到 %c", pair[0]);
        CHECK(gClient.output.length == 0, "空码不上屏任何东西");
    }

    /* 空缓冲下敲 ' ：码表里没有任何以 ' 开头的编码，应落到标点 */
    Fresh();
    Type('\'', 0);
    CHECK([gClient.output isEqualToString:@"‘"], "空缓冲下 ' 当作中文左引号：%s", CStr(gClient.output));
    CHECK([ObjIvar(gCtl, "_code") length] == 0, "且不残留编码缓冲");
}

static void test_caret_position(void)
{
    puts("\n== 候选窗位置取自插入点 ==");
    Fresh();
    gClient.caretRect = NSMakeRect(200, 400, 8, 20);
    Type('h', 0);
    CHECK(gClient.caretQueries > 0, "组字时向客户端询问过插入点");
}

#pragma mark - 保护本机偏好

/* 控制器会把「中英标点 / 全半角」写回 NSUserDefaults（那是产品行为，不是测试需要）。
 * 测试期间先清空这些键，保证跑的是代码里的默认值；结束时原样还原，
 * 免得「跑个测试把用户的输入法偏好改了」。 */
static NSArray<NSString *> *SFTestDefaultsKeys(void)
{
    return @[ @"AutoCommit4", @"EnableCompletion", @"MaxCandidates", @"InlinePreedit",
              @"PunctAscii", @"FullShape", @"InitialAsciiMode",
              @"ReverseModeAutoExit", @"Theme",
              @"PanelOffsetX", @"PanelOffsetY", @"PanelFlipY", @"DebugPanelRect",
              @"FreqMemory" ];
}

static NSMutableDictionary *gSavedDefaults;

static void SaveDefaults(void)
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    gSavedDefaults = [NSMutableDictionary dictionary];
    for (NSString *k in SFTestDefaultsKeys())
        if ([d objectForKey:k]) gSavedDefaults[k] = [d objectForKey:k];
    for (NSString *k in SFTestDefaultsKeys()) [d removeObjectForKey:k];
    printf("（已暂存并清空本机偏好，测试结束还原；原有 %lu 项）\n",
           (unsigned long)gSavedDefaults.count);
}

static void RestoreDefaults(void)
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    for (NSString *k in SFTestDefaultsKeys()) [d removeObjectForKey:k];
    for (NSString *k in gSavedDefaults) [d setObject:gSavedDefaults[k] forKey:k];
    [d synchronize];
}

#pragma mark - 方向键选候选

static void test_arrow_selection(void)
{
    puts("\n== 方向键选候选 ==");
    NSString *code = FindCode(3);       /* 找至少 3 个候选的编码 */
    if (!code) { CHECK(NO, "找不到可测编码"); return; }

    /* 重码记忆会按选字历史重排候选 —— 本测试断言的是「高亮移动」机制本身，
     * 前面用例选过的词会把候选顺序搬动，位置断言全乱。整段关掉，结尾恢复。 */
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"FreqMemory"];
    if (gFreqPath) unlink(gFreqPath);

    /* → 移动高亮，空格上屏的是高亮项而不是第一项 */
    Fresh();
    TypeString(code.UTF8String);
    NSUInteger n = CandsCount();
    CHECK(n >= 3, "%s 至少 3 个候选（%lu）", code.UTF8String, (unsigned long)n);
    CHECK(IntIvar(gCtl, "_sel") == 0, "初始高亮第 1 项");

    CHECK(TypeKey(kVK_RightArrow, 0) == YES, "→ 被输入法消费");
    CHECK(IntIvar(gCtl, "_sel") == 1, "→ 高亮移到第 2 项");
    CHECK([ObjIvar(gCtl, "_code") isEqualToString:code], "移动高亮不改编码缓冲");

    TypeKey(kVK_RightArrow, 0);
    CHECK(IntIvar(gCtl, "_sel") == 2, "再按一次 → 到第 3 项");

    Type(' ', 0);
    CHECK([gClient.output isEqualToString:Cand(code.UTF8String, 2)],
          "空格上屏的是高亮项（第 3 个）：%s", CStr(gClient.output));

    /* ← 回绕到最后一个 */
    Fresh();
    TypeString(code.UTF8String);
    n = CandsCount();
    TypeKey(kVK_LeftArrow, 0);
    CHECK(IntIvar(gCtl, "_sel") == (int)(n - 1),
          "第 1 项按 ← 回绕到最后一项（第 %lu 项）", (unsigned long)n);

    /* 上下键同样能移动 */
    Fresh();
    TypeString(code.UTF8String);
    TypeKey(kVK_DownArrow, 0);
    CHECK(IntIvar(gCtl, "_sel") == 1, "↓ 高亮 +1");
    TypeKey(kVK_UpArrow, 0);
    CHECK(IntIvar(gCtl, "_sel") == 0, "↑ 高亮 -1");
    TypeKey(kVK_UpArrow, 0);
    CHECK(IntIvar(gCtl, "_sel") == (int)(CandsCount() - 1), "第 1 项按 ↑ 回绕到末尾");

    /* 回车也上屏高亮项 */
    Fresh();
    TypeString(code.UTF8String);
    TypeKey(kVK_RightArrow, 0);
    CHECK(TypeKey(kVK_Return, 0) == YES, "回车被消费");
    CHECK([gClient.output isEqualToString:Cand(code.UTF8String, 1)],
          "回车上屏高亮项：%s", CStr(gClient.output));

    /* 逗号顶屏顶的也是高亮项 */
    Fresh();
    TypeString(code.UTF8String);
    TypeKey(kVK_RightArrow, 0);
    Type(',', 0);
    NSString *want = [Cand(code.UTF8String, 1) stringByAppendingString:@"，"];
    CHECK([gClient.output isEqualToString:want], "逗号顶屏也是顶高亮项：%s", CStr(gClient.output));

    /* 数字键仍然直接选，并且不受高亮影响 */
    Fresh();
    TypeString(code.UTF8String);
    TypeKey(kVK_RightArrow, 0);
    Type('3', 0);
    CHECK([gClient.output isEqualToString:Cand(code.UTF8String, 2)],
          "数字键 3 直接选第 3 个：%s", CStr(gClient.output));

    /* 没有候选时方向键不该被吞掉（要放行给应用移动光标） */
    Fresh();
    CHECK(TypeKey(kVK_LeftArrow, 0) == NO, "没在组字时 ← 放行给应用");
    CHECK(TypeKey(kVK_UpArrow, 0) == NO, "没在组字时 ↑ 放行给应用");

    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"FreqMemory"];
}

#pragma mark - 标点候选的方向键

static void test_punct_arrow_selection(void)
{
    puts("\n== 标点候选也能用方向键选 ==");
    Fresh();
    CHECK(Type('[', 0) == YES, "[ 被消费");
    CHECK(IntIvar(gCtl, "_mode") == 2, "进入标点候选态");
    NSUInteger n = CandsCount();
    CHECK(n >= 2, "[ 有多个候选（%lu）", (unsigned long)n);

    /* 0.6.2：标点候选态必须占住组词态（marked text），否则真机上客户端
     * 不把方向键这类导航键转发给输入法 —— Intel 机实测踩过。 */
    CHECK(BoolIvar(gCtl, "_composing") == YES, "标点候选态占住组词态");
    NSString *first = ((SFCandidate *)Cands()[0]).text;
    CHECK([[gCtl composedString:nil] isEqualToString:first],
          "内嵌预览 = 高亮项（第 1 个）：%s", CStr([gCtl composedString:nil]));

    NSString *second = ((SFCandidate *)Cands()[1]).text;
    TypeKey(kVK_RightArrow, 0);
    CHECK(IntIvar(gCtl, "_sel") == 1, "→ 高亮移到第 2 项");
    CHECK([[gCtl composedString:nil] isEqualToString:second],
          "内嵌预览跟着高亮走（第 2 个）：%s", CStr([gCtl composedString:nil]));
    Type(' ', 0);
    CHECK([gClient.output isEqualToString:second],
          "空格上屏标点候选的高亮项：%s", CStr(gClient.output));
    CHECK(BoolIvar(gCtl, "_composing") == NO, "上屏后组词态结束");

    /* 分号次选对标点候选态同样生效（0.6.2 补：此前要求 _code 非空，
     * 标点态永远不成立，; 会落到编码路径把标点面板顶掉）。 */
    Fresh();
    CHECK(Type('[', 0) == YES, "[ 被消费");
    CHECK(IntIvar(gCtl, "_mode") == 2, "进入标点候选态");
    NSString *secondBrk = ((SFCandidate *)Cands()[1]).text;
    Type(';', 0);
    CHECK([gClient.output isEqualToString:secondBrk],
          "标点态分号 = 第 2 候选：%s", CStr(gClient.output));
    CHECK(BoolIvar(gCtl, "_composing") == NO, "上屏后组词态结束");
}

static void test_punct_composition_discard(void)
{
    puts("\n== 标点候选态的组词退出路径 ==");
    /* Esc：组词态一起清掉 */
    Fresh();
    Type('[', 0);
    CHECK(BoolIvar(gCtl, "_composing") == YES, "进入标点候选态（占住组词）");
    TypeKey(kVK_Escape, 0);
    CHECK(BoolIvar(gCtl, "_composing") == NO, "Esc 清掉组词态");
    CHECK([[gCtl composedString:nil] length] == 0, "Esc 后内嵌预览为空");
    CHECK(gClient.output.length == 0, "Esc 放弃不上屏");

    /* 退格：同 Esc */
    Fresh();
    Type('[', 0);
    TypeKey(kVK_Delete, 0);
    CHECK(BoolIvar(gCtl, "_composing") == NO, "退格清掉组词态");
    CHECK(gClient.output.length == 0, "退格放弃不上屏");

    /* 单候选 / 成对引号不占组词态（直接上屏） */
    Fresh();
    Type(',', 0);
    CHECK(BoolIvar(gCtl, "_composing") == NO, "单候选标点不占组词态");
    Fresh();
    Type('\'', 0);
    CHECK(BoolIvar(gCtl, "_composing") == NO, "成对引号不占组词态");

    /* 标点候选态下再按别的标点键：先清旧组词再处理新键，不残留 */
    Fresh();
    Type('[', 0);
    Type('$', 0);
    CHECK(IntIvar(gCtl, "_mode") == 2, "切到 $ 的候选态");
    CHECK(BoolIvar(gCtl, "_composing") == YES, "新候选态仍占住组词");
    NSString *dollarFirst = ((SFCandidate *)Cands()[0]).text;
    CHECK([[gCtl composedString:nil] isEqualToString:dollarFirst],
          "内嵌预览换成 $ 的首选：%s", CStr([gCtl composedString:nil]));
}

#pragma mark - 查编码

static void test_reverse_mode(void)
{
    puts("\n== 查编码模式（Ctrl+/ 切，全拼与双拼都认）==");
    Fresh();
    CHECK(BoolIvar(gCtl, "_reverseMode") == NO, "默认不开");

    CHECK(TypeKey(kVK_ANSI_Slash, NSEventModifierFlagControl) == YES, "Ctrl+/ 被消费");
    CHECK(BoolIvar(gCtl, "_reverseMode") == YES, "进入查编码模式");

    /* --- 全拼 hao → 双拼 hc → 同音字，每个字带音形码附注 --- */
    TypeString("hao");
    CHECK([ObjIvar(gCtl, "_code") isEqualToString:@"hao"],
          "整串拼音留在缓冲里（没有被判空码）：%s", CStr(ObjIvar(gCtl, "_code")));
    CHECK(IntIvar(gCtl, "_mode") == 3, "进入 SFPickSearch 候选态");

    SFCandidate *hao = CandidateNamed(@"好");
    CHECK(hao != nil, "候选里查到「好」（共 %lu 个）", (unsigned long)CandsCount());
    if (hao)
        CHECK([hao.note isEqualToString:@"hc·nz"],
              "「好」的编码附注 = 音 hc · 形 nz（得到 %s）", CStr(hao.note));

    /* 上屏后默认「常驻」：仍停在查编码模式，可以继续打下一个拼音（像普通拼音输入法） */
    Fresh();
    TypeKey(kVK_ANSI_Slash, NSEventModifierFlagControl);
    TypeString("hao");
    Type(' ', 0);
    CHECK([gClient.output isEqualToString:@"好"], "空格上屏查到的字：%s", CStr(gClient.output));
    CHECK(BoolIvar(gCtl, "_reverseMode") == YES, "上屏后默认常驻查编码模式（不退出）");

    /* 常驻模式下连续打拼音：再打 ni 出「你」，两字连起来上屏 */
    TypeString("ni");
    CHECK(CandidateNamed(@"你") != nil, "常驻模式再打 ni 也能查到「你」");
    Type(' ', 0);
    CHECK([gClient.output isEqualToString:@"好你"], "连续拼音上屏：%s", CStr(gClient.output));

    /* 想「查一个就退」仍可通过 ReverseModeAutoExit=YES 恢复旧行为 */
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"ReverseModeAutoExit"];
    Fresh();
    TypeKey(kVK_ANSI_Slash, NSEventModifierFlagControl);
    TypeString("hao");
    Type(' ', 0);
    CHECK([gClient.output isEqualToString:@"好"], "空格上屏查到的字：%s", CStr(gClient.output));
    CHECK(BoolIvar(gCtl, "_reverseMode") == NO, "ReverseModeAutoExit=YES 时上屏后自动退出");
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"ReverseModeAutoExit"];

    /* --- 双拼码也能查（"hc" 不是合法全拼，走「直接当双拼码」那条路）--- */
    Fresh();
    TypeKey(kVK_ANSI_Slash, NSEventModifierFlagControl);
    TypeString("hc");
    CHECK(CandidateNamed(@"好") != nil, "输入双拼码 hc 也能查到「好」");
    CHECK(IntIvar(gCtl, "_mode") == 3, "仍是查编码候选态");

    /* --- 全拼 hu → 应该也能查（hu 是合法全拼，双拼码 hu 也指向「和/户…」）--- */
    Fresh();
    TypeKey(kVK_ANSI_Slash, NSEventModifierFlagControl);
    TypeString("shuang");
    CHECK([ObjIvar(gCtl, "_code") isEqualToString:@"shuang"], "shuang 完整进入缓冲");
    CHECK(CandidateNamed(@"双") != nil, "全拼 shuang 查到「双」");

    /* --- 0.4.4：词语查询 —— 多音节拼音 nihao → nihc → 你好 --- */
    Fresh();
    TypeKey(kVK_ANSI_Slash, NSEventModifierFlagControl);
    TypeString("nihao");
    CHECK([ObjIvar(gCtl, "_code") isEqualToString:@"nihao"], "多音节拼音留在缓冲：%s", CStr(ObjIvar(gCtl, "_code")));
    SFCandidate *nihao = CandidateNamed(@"你好");
    CHECK(nihao != nil, "多音节拼音 nihao 查到词语「你好」（共 %lu 个）", (unsigned long)CandsCount());
    if (nihao)
        CHECK([nihao.note isEqualToString:@"nihc"],
              "「你好」的编码附注 = nihc（得到 %s）", CStr(nihao.note));

    /* --- 0.4.4：词语也出现在单字同前缀下（hc 前缀：单字好/号… 之后跟 好啊/好吧）--- */
    Fresh();
    TypeKey(kVK_ANSI_Slash, NSEventModifierFlagControl);
    TypeString("hc");
    CHECK(CandidateNamed(@"好") != nil, "hc 前缀查到单字「好」");
    CHECK(CandidateNamed(@"好啊") != nil || CandidateNamed(@"好吧") != nil,
          "hc 前缀也查到词语（好啊 / 好吧）");

    /* --- Esc：有缓冲先清缓冲，再按一次退出模式 --- */
    Fresh();
    TypeKey(kVK_ANSI_Slash, NSEventModifierFlagControl);
    TypeString("hao");
    TypeKey(kVK_Escape, 0);
    CHECK([ObjIvar(gCtl, "_code") length] == 0, "Esc 清掉缓冲");
    CHECK(BoolIvar(gCtl, "_reverseMode") == YES, "第一次 Esc 不退出模式");
    TypeKey(kVK_Escape, 0);
    CHECK(BoolIvar(gCtl, "_reverseMode") == NO, "再按一次 Esc 退出模式");

    /* --- 查编码模式下方向键照常可用 --- */
    Fresh();
    TypeKey(kVK_ANSI_Slash, NSEventModifierFlagControl);
    TypeString("hao");
    if (CandsCount() >= 2) {
        TypeKey(kVK_RightArrow, 0);
        CHECK(IntIvar(gCtl, "_sel") == 1, "查编码候选也能用方向键移");
        NSString *want = ((SFCandidate *)Cands()[1]).text;
        Type(' ', 0);
        CHECK([gClient.output isEqualToString:want], "上屏第 2 项：%s", CStr(gClient.output));
    }

    /* --- 查编码模式与普通模式的行为差别，用同一个串对比 ---
     * 查编码模式下 "hao" 三个字母全留下（要拿去转双拼）；
     * 退回普通模式后就按码表规则走：h、ha 都有候选，第三个 o 会让 "hao" 判空码
     * 而回退，所以缓冲停在 "ha"。 */
    Fresh();
    TypeKey(kVK_ANSI_Slash, NSEventModifierFlagControl);
    TypeKey(kVK_ANSI_Slash, NSEventModifierFlagControl);
    CHECK(BoolIvar(gCtl, "_reverseMode") == NO, "再按一次 Ctrl+/ 退出");
    TypeString("hao");
    CHECK([ObjIvar(gCtl, "_code") isEqualToString:@"ha"],
          "退出后恢复普通双拼行为（第三个字母使 hao 判空码而回退，缓冲停在 ha）：%s",
          CStr(ObjIvar(gCtl, "_code")));
}

#pragma mark - 主题切换

/* 当前候选窗 / 当前主题名 */
static SFCandidatePanel *Panel(void)
{
    return (SFCandidatePanel *)ObjIvar(gCtl, "_panel");
}

static NSString *ThemeName(void) { return (NSString *)ObjIvar(gCtl, "_themeName"); }

/* test_code_hint 里用到、但定义在更后面的符号 —— 前置声明 */
static NSString *HUDText(void);

/* 控制器私有方法没有公开头文件，测试直接调要自己补声明。
 * 注意这里**不声明 popUpThemeMenu** —— 那个方法会真的 popUp 出菜单并原地等用户操作，
 * 单测里一调就卡死（跑测试的机器上没人去点）。测试要的是 themePickerMenu 造出来的那张
 * 菜单本身，有了它就能逐项断言。 */
@interface SimpleFlyInputController (TestOnly)
- (void)menuToggleCodeHint:(id)sender;
- (void)menuPickTheme:(id)sender;
- (NSMenu *)themePickerMenu;
- (void)selectThemeNamed:(NSString *)name client:(id)client;
- (void)pickThemeNamed:(NSString *)name sender:(id)sender;
- (void)toggleThemeAutoWithClient:(id)client;
- (void)systemAppearanceChanged:(NSNotification *)note;
@end

/* 感知亮度（Rec.709 权重，直接用 sRGB 分量加权 —— 不做 gamma 解码）。
 * 专门给「这配色能看清吗」这类断言用：比逐个写 RGB 上下界省事，
 * 也不依赖 NSColor 处在哪个色彩空间。 */
static CGFloat SFLum(NSColor *c)
{
    return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent;
}

static void test_theme(void)
{
    puts("\n== 主题：Ctrl+; 循环切换 ==");
    NSArray<NSString *> *names = [SFCandidateTheme allThemeNames];
    CHECK(names.count >= 2, "内置至少 2 个主题（%lu 个）", (unsigned long)names.count);
    if (names.count < 2) return;
    CHECK([names[0] isEqualToString:@"metro"], "第 1 个是默认主题 metro（%s）", CStr(names[0]));

    Fresh();
    CHECK([Panel().theme.name isEqualToString:@"metro"], "初始主题 = metro（%s）",
          CStr(Panel().theme.name));

    /* --- 按一次切到下一个，并写回偏好，下次启动记得住 --- */
    CHECK(TypeKey(kVK_ANSI_Semicolon, NSEventModifierFlagControl) == YES, "Ctrl+; 被输入法消费");
    CHECK([ThemeName() isEqualToString:names[1]], "切到第 2 个主题：%s", CStr(names[1]));
    CHECK([Panel().theme.name isEqualToString:ThemeName()], "候选窗换成了该主题（%s）",
          CStr(Panel().theme.name));
    CHECK([[NSUserDefaults standardUserDefaults] objectForKey:@"Theme"] != nil,
          "切换写回了 NSUserDefaults");

    /* --- 循环一圈回到起点：已按过 1 次（在第 2 个），再按 count-1 次正好绕回 metro --- */
    for (NSUInteger i = 1; i < names.count; i++)
        TypeKey(kVK_ANSI_Semicolon, NSEventModifierFlagControl);
    CHECK([ThemeName() isEqualToString:@"metro"], "再切 %lu 次回到 metro",
          (unsigned long)(names.count - 1));

    /* --- 切换不该打断正在打的字 ---
     * 分号在组字态下是「次选」，带 Ctrl 时必须切主题而不是把候选顶上屏。 */
    Fresh();
    NSString *code = FindCode(1);
    if (!code) { CHECK(NO, "找不到可测编码"); return; }
    NSString *want = Cand(code.UTF8String, 0);
    TypeString(code.UTF8String);
    NSUInteger before = CandsCount();
    TypeKey(kVK_ANSI_Semicolon, NSEventModifierFlagControl);
    CHECK([ObjIvar(gCtl, "_code") isEqualToString:code], "切主题不清空编码缓冲（%s）", CStr(code));
    CHECK(CandsCount() == before, "候选还在（%lu 条）", (unsigned long)CandsCount());
    CHECK(gClient.output.length == 0, "Ctrl+; 不当次选，不上屏任何东西");
    Type(' ', 0);
    CHECK([gClient.output isEqualToString:want], "切完接着按空格照常上屏：%s", CStr(want));

    /* --- 手写错主题名（defaults write 笔误）要退回 metro，不能让面板拿不到配色 --- */
    [[NSUserDefaults standardUserDefaults] setObject:@"不存在的主题" forKey:@"Theme"];
    Fresh();
    CHECK([Panel().theme.name isEqualToString:@"metro"], "未知主题名退回 metro（%s）",
          CStr(Panel().theme.name));

    /* --- 内置主题清单（0.8.0 起 13 款） --- */
    CHECK(names.count == 13, "内置 13 套主题（%lu）", (unsigned long)names.count);
    for (NSString *t in @[@"metro", @"jade", @"blossom", @"linen", @"paper", @"ink", @"contrast",
                           @"dark", @"mojave_dark", @"amber", @"neon", @"retro", @"luna"]) {
        SFCandidateTheme *th = [SFCandidateTheme themeNamed:t];
        CHECK([th.name isEqualToString:t], "主题 %s 存在", t.UTF8String);
    }

    /* --- 0.8.0 下掉的两款：aqua / google 与 metro 同为「浅底 + 蓝」，留着只是让菜单变长。
     * 老配置里若还写着这两个名字，必须回退 metro 而不是拿到空配色（否则绘制时崩）。 --- */
    CHECK(![names containsObject:@"aqua"] && ![names containsObject:@"google"],
          "aqua / google 已从清单移除");
    CHECK([[SFCandidateTheme themeNamed:@"aqua"].name isEqualToString:@"metro"],
          "写老主题名 aqua 退回 metro");
    CHECK([[SFCandidateTheme themeNamed:@"google"].name isEqualToString:@"metro"],
          "写老主题名 google 退回 metro");

    /* --- 色相防呆：抄 Rime 色值是 BGR，换算错位会让红蓝对调 --- */
    SFCandidateTheme *mjdk = [SFCandidateTheme themeNamed:@"mojave_dark"];
    CHECK(mjdk.back.blueComponent > mjdk.back.redComponent, "mojave_dark 底色偏蓝灰");
    SFCandidateTheme *jd = [SFCandidateTheme themeNamed:@"jade"];
    CHECK(jd.selBack.greenComponent > jd.selBack.redComponent, "jade 高亮是青玉绿（绿分量最大）");
    SFCandidateTheme *bl = [SFCandidateTheme themeNamed:@"blossom"];
    CHECK(bl.selBack.redComponent > bl.selBack.greenComponent, "blossom 高亮是玫红（红分量最大）");
    SFCandidateTheme *am = [SFCandidateTheme themeNamed:@"amber"];
    CHECK(am.selBack.redComponent > am.selBack.blueComponent &&
          am.selBack.greenComponent > am.selBack.blueComponent,
          "amber 高亮是琥珀金（蓝分量最小 —— 低蓝光的重点就在这）");
    SFCandidateTheme *rt = [SFCandidateTheme themeNamed:@"retro"];
    CHECK(rt.selBack.greenComponent > rt.selBack.redComponent, "retro 高亮是磷光绿");
    SFCandidateTheme *nv = [SFCandidateTheme themeNamed:@"neon"];
    CHECK(nv.selBack.greenComponent > nv.selBack.blueComponent &&
          nv.selBack.blueComponent > nv.selBack.redComponent, "neon 高亮是青绿");

    /* --- 半透明（8 位 hex 的高字节）只该出现在 luna / ink 上 --- */
    SFCandidateTheme *luna = [SFCandidateTheme themeNamed:@"luna"];
    CHECK(luna.back.alphaComponent < 1.0, "luna 背板半透明（alpha %.2f）", luna.back.alphaComponent);
    CHECK(luna.selBack.alphaComponent < 0.5, "luna 高亮块是 25% 黑");
    CHECK([SFCandidateTheme themeNamed:@"ink"].back.alphaComponent < 1.0, "ink 背板半透明");
    CHECK([SFCandidateTheme themeNamed:@"jade"].back.alphaComponent == 1.0,
          "新主题一律不透明（没误写成 8 位 hex）");

    /* --- 通用防呆：每一款都得过 ---
     * ① 底色与候选字拉得开 —— 防「浅底配浅字」这种根本看不清的配色；
     * ② 高亮块底色与块内文字同理 —— 高亮项看不见等于方向键白按。
     * 阈值 0.25 留了余量：实测最紧的 amber 也有 0.46。 */
    for (NSString *t in names) {
        SFCandidateTheme *th = [SFCandidateTheme themeNamed:t];
        CGFloat d1 = fabs(SFLum(th.back) - SFLum(th.candText));
        /* 高亮块里三层文字：词是主角（阈值 0.25），编号与附注是次级（0.15）。
         * 次级松一档是故意的 —— 它们本就该比词弱；但低于 0.15 就是真看不见了：
         * neon / retro 的初稿把附注写成亮青 / 浅绿压在青绿块上（Δ 只有 0.09），
         * 单看色值没觉得有问题，是出预览图时肉眼才发现的，这两条断言就是为拦它加的。 */
        CGFloat d2 = fabs(SFLum(th.selBack) - SFLum(th.selText));
        CGFloat d3 = fabs(SFLum(th.selBack) - SFLum(th.selLabel));
        CGFloat d4 = fabs(SFLum(th.selBack) - SFLum(th.selNote));
        CHECK(d1 > 0.25, "%s 底色与候选字对比足够（Δ亮度 %.2f）", t.UTF8String, d1);
        CHECK(d2 > 0.25, "%s 高亮块与块内文字对比足够（Δ亮度 %.2f）", t.UTF8String, d2);
        CHECK(d3 > 0.15, "%s 高亮块与块内编号对比足够（Δ亮度 %.2f）", t.UTF8String, d3);
        CHECK(d4 > 0.15, "%s 高亮块与块内附注对比足够（Δ亮度 %.2f）", t.UTF8String, d4);
    }

    /* --- 菜单选款：菜单项走的就是这条路（picker 记住名字 → selectThemeNamed:） --- */
    Fresh();
    [gCtl selectThemeNamed:@"retro" client:nil];
    CHECK([ThemeName() isEqualToString:@"retro"], "手选 retro 生效：%s", CStr(ThemeName()));
    /* 先取出来再断言：CHECK 是宏，cond 里直接写两层嵌套的消息发送，本机 clang 会解析失败
     * （missing '[' at start of message send expression）。 */
    NSString *prefAfterPick = [[NSUserDefaults standardUserDefaults] stringForKey:@"Theme"];
    CHECK([prefAfterPick isEqualToString:@"retro"], "手选写回 Theme 偏好：%s", CStr(prefAfterPick));
    CHECK([Panel().theme.name isEqualToString:@"retro"], "候选窗配色同步到 retro");
    [gCtl selectThemeNamed:@"不存在的主题" client:nil];
    CHECK([ThemeName() isEqualToString:@"retro"], "手选未知名被忽略（不会切到空配色）");

    /* --- 跟随系统亮暗（ThemeAuto）---
     * 测试进程里改不了系统外观，用 SIMPLEFLY_FORCE_DARK 指定：1 = 深色、0 = 浅色。 */
    setenv("SIMPLEFLY_FORCE_DARK", "1", 1);
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"ThemeAuto"];
    [[NSUserDefaults standardUserDefaults] setObject:@"retro" forKey:@"Theme"];
    Fresh();
    CHECK([ThemeName() isEqualToString:@"amber"], "深色系统 → amber：%s", CStr(ThemeName()));
    NSString *prefInAuto = [[NSUserDefaults standardUserDefaults] stringForKey:@"Theme"];
    CHECK([prefInAuto isEqualToString:@"retro"],
          "跟随期间不动 Theme 偏好（那是用户手选的，关掉要还回去）：%s", CStr(prefInAuto));

    setenv("SIMPLEFLY_FORCE_DARK", "0", 1);
    [gCtl systemAppearanceChanged:nil];
    CHECK([ThemeName() isEqualToString:@"jade"], "系统转浅色 → jade：%s", CStr(ThemeName()));
    NSString *prefAfterSwitch = [[NSUserDefaults standardUserDefaults] stringForKey:@"Theme"];
    CHECK([prefAfterSwitch isEqualToString:@"retro"],
          "换过外观后 Theme 偏好依旧是 retro：%s", CStr(prefAfterSwitch));
    CHECK([Panel().theme.name isEqualToString:@"jade"], "候选窗配色跟着换到 jade");

    /* 关掉跟随 → 回到用户手选的那款，而不是停在自动值上 */
    [gCtl toggleThemeAutoWithClient:nil];
    CHECK([[NSUserDefaults standardUserDefaults] boolForKey:@"ThemeAuto"] == NO, "跟随开关已关");
    CHECK([ThemeName() isEqualToString:@"retro"], "关掉跟随回到手选的 retro：%s", CStr(ThemeName()));

    /* 开着跟随时手选一款 → 自动退出跟随（否则刚选的那款会被下次外观变化覆盖掉） */
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"ThemeAuto"];
    Fresh();
    CHECK([[NSUserDefaults standardUserDefaults] boolForKey:@"ThemeAuto"] == YES, "先开着跟随");
    [gCtl selectThemeNamed:@"linen" client:nil];
    CHECK([[NSUserDefaults standardUserDefaults] boolForKey:@"ThemeAuto"] == NO,
          "手选主题即退出跟随");
    CHECK([ThemeName() isEqualToString:@"linen"], "并停在手选的 linen");

    /* 收尾：恢复默认，别把偏好泄给后面的测试 */
    unsetenv("SIMPLEFLY_FORCE_DARK");
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"ThemeAuto"];
    [[NSUserDefaults standardUserDefaults] setObject:@"metro" forKey:@"Theme"];
    Fresh();
}

/* 底部编码提示（CodeHint，0.6.3）：候选窗文字底下显示当前高亮候选的音形码。
 * 开关在 showPanelWithClient 实时读，所以这里 setBool 后立刻 Fresh 就能测到。 */
static void test_code_hint(void)
{
    puts("\n== 候选窗底部编码提示（CodeHint） ==");

    /* 自己算「期望的编码文本」，不写死编码（教训见文件头）：
     * 与控制器 noteForText 同一套规则 —— 单字在音码 2 位后插中点，词语原样。 */
    NSString *code = FindCode(1);
    if (!code) { CHECK(NO, "找不到可测编码"); return; }
    NSString *want0 = Cand(code.UTF8String, 0);
    NSString *note0 = nil;
    {
        const char *c = sf_engine_code_for_text(SFSharedEngine(), want0.UTF8String);
        if (c) {
            NSString *raw = [NSString stringWithUTF8String:c];
            note0 = (want0.length == 1 && raw.length > 2)
                  ? [NSString stringWithFormat:@"%@·%@", [raw substringToIndex:2],
                                                       [raw substringFromIndex:2]]
                  : raw;
        }
    }

    /* --- 默认关：不出提示行 --- */
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"CodeHint"];
    Fresh();
    TypeString(code.UTF8String);
    CHECK(CandsCount() > 0, "出候选");
    CHECK([Panel() codeHint] == nil, "默认关：无编码提示");

    /* --- 打开：提示 = 高亮候选的音形码，且同步到了绘制视图 --- */
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"CodeHint"];
    Fresh();
    TypeString(code.UTF8String);
    CHECK([Panel() codeHint] != nil, "打开后出现编码提示");
    if (note0) CHECK([[Panel() codeHint] isEqualToString:note0],
                     "内容 = 首选的音形码（%s）", CStr(Panel().codeHint));
    id view = ObjIvar(Panel(), "_view");
    CHECK([view codeHint] != nil && [[view codeHint] isEqualToString:[Panel() codeHint]],
          "提示同步到了绘制视图");
    TypeKey(kVK_RightArrow, 0);
    if (CandsCount() > 1) {
        NSString *want1 = ((SFCandidate *)Cands()[1]).text;
        const char *c1 = sf_engine_code_for_text(SFSharedEngine(), want1.UTF8String);
        if (c1) {
            NSString *raw1 = [NSString stringWithUTF8String:c1];
            NSString *note1 = (want1.length == 1 && raw1.length > 2)
                  ? [NSString stringWithFormat:@"%@·%@", [raw1 substringToIndex:2],
                                                       [raw1 substringFromIndex:2]]
                  : raw1;
            CHECK([[Panel() codeHint] isEqualToString:note1],
                  "方向键后提示 = 第 2 候选的音形码（%s）", CStr(Panel().codeHint));
        }
    }

    /* --- 标点候选没有编码：行自动消失 --- */
    Fresh();
    Type('[', 0);
    CHECK(Panel().codeHint == nil, "标点候选无编码，不出提示行");

    /* --- 收尾：恢复默认关 --- */
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"CodeHint"];
    Fresh();
    TypeString(code.UTF8String);
    CHECK(Panel().codeHint == nil, "关闭后恢复无提示");

    /* --- 快捷键 Ctrl+Shift+H：翻转 defaults + HUD 确认（0.6.3） --- */
    NSEventModifierFlags mods = NSEventModifierFlagControl | NSEventModifierFlagShift;
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"CodeHint"];
    Fresh();
    CHECK(TypeKey(kVK_ANSI_H, mods) == YES, "Ctrl+Shift+H 被输入法消费");
    CHECK([[NSUserDefaults standardUserDefaults] boolForKey:@"CodeHint"] == YES,
          "快捷键把开关翻到开");
    CHECK([HUDText() containsString:@"编码提示"], "HUD 确认：%s", CStr(HUDText()));
    TypeKey(kVK_ANSI_H, mods);
    CHECK([[NSUserDefaults standardUserDefaults] boolForKey:@"CodeHint"] == NO,
          "再按一次翻回关");

    /* --- 菜单项路由（menu action 传字典，须从 kIMKCommandClientName 取 client） --- */
    [gCtl menuToggleCodeHint:@{}];
    CHECK([[NSUserDefaults standardUserDefaults] boolForKey:@"CodeHint"] == YES,
          "菜单项路由也能翻转开关");
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"CodeHint"];
}

#pragma mark - 重码记忆

static void test_freq_memory(void)
{
    puts("\n== 重码记忆：上次选的下次排第一 ==");
    if (!gFreqPath) { CHECK(NO, "没有 freq 路径（main 没设？）"); return; }
    unlink(gFreqPath);           /* 从干净状态开始 */

    /* 找一个 3 码、恰好 2 个候选的编码 —— 重排只在「码长>=3、候选>1」时生效，
     * 测试编码必须落在这个区间里才有意义。不写死编码（教训见文件头注释）。
     * 注意 lookup 的最后一个参数要跟控制器一致（EnableCompletion 默认开）：
     * 用 0 找到的「2 候选」到了控制器里会因补全变成一堆，白测（踩过一次）。 */
    NSString *code = nil;
    const char *L = "abcdefghijklmnopqrstuvwxyz";
    SFHit hits[SF_MAX_CANDS];
    for (int a = 0; a < 26 && !code; a++)
        for (int b = 0; b < 26 && !code; b++)
            for (int c = 0; c < 26 && !code; c++) {
                char buf[4] = { L[a], L[b], L[c], '\0' };
                if (sf_engine_lookup(SFSharedEngine(), buf, hits, 3, 1) == 2)
                    code = [NSString stringWithUTF8String:buf];
            }
    CHECK(code.length == 3, "找到 3 码 2 候选的编码%s",
          code ? [NSString stringWithFormat:@"（%@）", code].UTF8String : "（没找到，跳过）");
    if (!code) return;

    /* 第一轮：默认顺序，选第 2 个候选 */
    Fresh();
    TypeString(code.UTF8String);
    NSArray<SFCandidate *> *c0 = Cands();
    CHECK(c0.count == 2, "候选 2 个（%lu）", (unsigned long)c0.count);
    if (c0.count != 2) return;
    NSString *first = c0[0].text, *second = c0[1].text;
    TypeKey(kVK_RightArrow, 0);          /* 高亮移到第 2 项 */
    Type(' ', 0);
    CHECK([gClient.output isEqualToString:second],
          "选了第 2 个：%s", CStr(second));

    /* 第二轮：记忆生效 —— 上次选的重排到第 1 位，高亮仍从 0 开始 */
    Fresh();
    TypeString(code.UTF8String);
    CHECK(CandsCount() == 2, "重码记忆不减少候选");
    CHECK([((SFCandidate *)Cands()[0]).text isEqualToString:second],
          "上次选的（%s）排到了第 1 位", CStr(second));
    CHECK([((SFCandidate *)Cands()[1]).text isEqualToString:first], "原第 1 位顺延到第 2 位");
    CHECK(IntIvar(gCtl, "_sel") == 0, "高亮仍从第 1 项开始（只重排不移动）");
    Type(' ', 0);
    CHECK([gClient.output isEqualToString:second], "直接空格 = 上次选的");

    /* 2 码重码不记 —— 二简组的手感优先 */
    NSString *code2 = FindCode(2);
    if (code2 && code2.length == 2) {
        Fresh();
        TypeString(code2.UTF8String);
        NSArray<SFCandidate *> *c2 = Cands();
        if (c2.count >= 2) {
            NSString *f0 = c2[0].text;
            TypeKey(kVK_RightArrow, 0);
            Type(' ', 0);
            Fresh();
            TypeString(code2.UTF8String);
            CHECK([((SFCandidate *)Cands()[0]).text isEqualToString:f0], "2 码重码不记忆，顺序不变");
        } else {
            g_pass++; printf("  - （跳过：找到的 2 码编码实际只有 1 候选）\n");
        }
    }

    /* 单候选编码不会出事：freq 里记的是词，不是「强制变两个候选」 */
    NSString *code1 = FindCode(1);
    if (code1) {
        Fresh();
        TypeString(code1.UTF8String);
        NSUInteger before = CandsCount();
        Type(' ', 0);
        Fresh();
        TypeString(code1.UTF8String);
        CHECK(CandsCount() == before, "单候选编码不受重码记忆影响");
    }

    unlink(gFreqPath);           /* 别把本轮记忆留给后面的用例 */
}

#pragma mark - 选中查编码

/* HUD 当前显示的文字（面板把内容画在 view.hud 上） */
static NSString *HUDText(void)
{
    id view = ObjIvar(Panel(), "_view");
    if (!view) return nil;
    return [view valueForKey:@"hud"];
}

static void test_lookup_selection(void)
{
    puts("\n== 选中查编码（Ctrl+Shift+/）==");
    NSEventModifierFlags mods = NSEventModifierFlagControl | NSEventModifierFlagShift;

    /* 没有选区：提示先选中，不上屏任何东西 */
    Fresh();
    CHECK(TypeKey(kVK_ANSI_Slash, mods) == YES, "Ctrl+Shift+/ 被输入法消费");
    CHECK(gClient.output.length == 0, "不上屏任何东西");
    CHECK([HUDText() containsString:@"先选中"], "没选区时给提示：%s", CStr(HUDText()));

    /* 选中「好」：HUD 显示字 + 音形码（期望值问引擎，不写死编码） */
    const char *haocode = sf_engine_code_for_text(SFSharedEngine(), "好");
    CHECK(haocode != NULL, "引擎能反查「好」");
    if (!haocode) return;

    Fresh();
    gClient.selection = NSMakeRange(0, 1);
    gClient.selectionText = @"好";
    CHECK(TypeKey(kVK_ANSI_Slash, mods) == YES, "有选区时被消费");
    NSString *want = [NSString stringWithFormat:@"好  %c%c·%c%c",
                      haocode[0], haocode[1], haocode[2], haocode[3]];
    CHECK([HUDText() isEqualToString:want], "HUD = 字 + 音·形码（%s）", CStr(HUDText()));

    /* 双击选词带出的尾部空格要清掉 */
    Fresh();
    gClient.selection = NSMakeRange(0, 2);
    gClient.selectionText = @"好 ";
    TypeKey(kVK_ANSI_Slash, mods);
    CHECK([HUDText() isEqualToString:want], "尾部空格被清掉后结果一致：%s", CStr(HUDText()));

    /* 词也能查：你好 → nihc */
    Fresh();
    gClient.selection = NSMakeRange(0, 2);
    gClient.selectionText = @"你好";
    TypeKey(kVK_ANSI_Slash, mods);
    CHECK([HUDText() containsString:@"你好"], "词的 HUD 带词本身：%s", CStr(HUDText()));
    CHECK([HUDText() containsString:
           [NSString stringWithUTF8String:
            sf_engine_code_for_text(SFSharedEngine(), "你好")]],
          "词的 HUD 带整词编码：%s", CStr(HUDText()));

    /* 码表里没有的字 */
    Fresh();
    const char *missing = NULL;
    static char missbuf[5];
    for (unichar cp = 0x4E00; cp <= 0x9FFF; cp++) {
        char b[5];
        int len = 0;
        if (cp < 0x80) { b[len++] = (char)cp; }
        else if (cp < 0x800) {
            b[len++] = (char)(0xC0 | (cp >> 6));
            b[len++] = (char)(0x80 | (cp & 0x3F));
        } else {
            b[len++] = (char)(0xE0 | (cp >> 12));
            b[len++] = (char)(0x80 | ((cp >> 6) & 0x3F));
            b[len++] = (char)(0x80 | (cp & 0x3F));
        }
        b[len] = '\0';
        if (!sf_engine_code_for_text(SFSharedEngine(), b)) {
            missing = missbuf;
            memcpy(missbuf, b, (size_t)len + 1);
            break;
        }
    }
    if (missing) {
        gClient.selection = NSMakeRange(0, 1);
        gClient.selectionText = [NSString stringWithUTF8String:missing];
        TypeKey(kVK_ANSI_Slash, mods);
        CHECK([HUDText() containsString:@"不在码表里"],
              "生僻字给「不在码表里」：%s", CStr(HUDText()));
    } else {
        g_pass++; printf("  - （跳过：没找到码表外的汉字）\n");
    }

    /* 选了一整段：拦下，不硬查 */
    Fresh();
    gClient.selection = NSMakeRange(0, 10);
    gClient.selectionText = @"这一段文字实在太长了";
    TypeKey(kVK_ANSI_Slash, mods);
    CHECK([HUDText() containsString:@"太长"], "选区太长时提示只支持字词：%s", CStr(HUDText()));
}

#pragma mark - 打错日志

/* 读打错日志文件，返回行数组 */
static NSArray *ReadMislog(void)
{
    if (!gMislogPath) return @[];
    NSString *t = [NSString stringWithContentsOfFile:[NSString stringWithUTF8String:gMislogPath]
                                            encoding:NSUTF8StringEncoding error:NULL];
    if (t.length == 0) return @[];
    /* 按行切，并丢掉行尾空串 —— fprintf 每行自带 \n，直接切会多一个空元素（踩过） */
    NSMutableArray *rows = [NSMutableArray array];
    for (NSString *l in [t componentsSeparatedByString:@"\n"])
        if (l.length > 0) [rows addObject:l];
    return rows;
}

static void test_miss_log(void)
{
    puts("\n== 打错日志（LogMisses）==");
    if (!gMislogPath) { CHECK(NO, "没有 mislog 路径（main 没设？）"); return; }
    unlink(gMislogPath);
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"LogMisses"];

    NSString *code = FindCode(2);           /* 一个 ≥2 码、有候选的编码 */
    CHECK(code.length >= 2, "找到可测编码（%@）", code);
    if (code.length < 2) return;

    /* ① 打了又 Esc → 下一次上屏配对落盘 */
    Fresh();
    TypeString(code.UTF8String);
    TypeKey(kVK_Escape, 0);
    CHECK(gClient.output.length == 0, "Esc 不上屏");
    NSString *code2 = FindCode(1);
    TypeString(code2.UTF8String);
    Type(' ', 0);                           /* 上屏另一个词 */
    NSArray *lines = ReadMislog();
    BOOL ok = lines.count == 1 &&
              [lines[0] hasPrefix:[NSString stringWithFormat:@"\t%@", code]];
    // 时间戳在第一列，第二列是废弃码；用 components 检查更稳
    if (lines.count == 1) {
        NSArray *cols = [lines[0] componentsSeparatedByString:@"\t"];
        ok = cols.count == 3 &&
             [cols[1] isEqualToString:code] &&
             [cols[2] length] > 0;
    }
    CHECK(ok, "Esc 废弃的码在下次上屏时落盘（%lu 行）", (unsigned long)lines.count);

    /* ② 退格改一个字不算废弃：不落盘 */
    unlink(gMislogPath);
    Fresh();
    TypeString(code.UTF8String);
    TypeKey(kVK_Delete, 0);                 /* 退一格（缓冲非空，不算废弃） */
    TypeString("q");                        /* 续上新码 */
    Type(' ', 0);
    CHECK(ReadMislog().count == 0, "退格改字不是废弃，不落盘");

    /* ③ 退格退到空 = 废弃 */
    unlink(gMislogPath);
    Fresh();
    TypeString(code.UTF8String);
    for (NSUInteger i = 0; i < code.length; i++) TypeKey(kVK_Delete, 0);
    TypeString(code2.UTF8String);
    Type(' ', 0);
    lines = ReadMislog();
    ok = NO;
    if (lines.count == 1) {
        NSArray *cols = [lines[0] componentsSeparatedByString:@"\t"];
        ok = cols.count == 3 && [cols[1] isEqualToString:code];
    }
    CHECK(ok, "退到空算废弃，落盘的是完整旧码（%lu 行）", (unsigned long)lines.count);

    /* ④ 默认关：同样的操作不产生日志 */
    unlink(gMislogPath);
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"LogMisses"];
    Fresh();
    TypeString(code.UTF8String);
    TypeKey(kVK_Escape, 0);
    TypeString(code2.UTF8String);
    Type(' ', 0);
    CHECK(ReadMislog().count == 0, "LogMisses 默认关，不落盘");

    unlink(gMislogPath);
}

#pragma mark - 选中简转繁

static void test_s2t_convert(void)
{
    puts("\n== 选中简转繁（Ctrl+Shift+F）==");
    NSEventModifierFlags mods = NSEventModifierFlagControl | NSEventModifierFlagShift;

    /* 没有选区：提示，不上屏 */
    Fresh();
    CHECK(TypeKey(kVK_ANSI_F, mods) == YES, "Ctrl+Shift+F 被输入法消费");
    CHECK(gClient.output.length == 0, "没选区时不上屏任何东西");
    CHECK([HUDText() containsString:@"先选中"], "没选区时给提示：%s", CStr(HUDText()));

    /* 选中「简化」→ 原位替换为繁体（期望值问表，不写死数据）。
     * 注意 FakeClient 的选区坐标是相对 selectionText 的 —— 选区必须与
     * selectionText 对齐，否则 attributedSubstringFromRange 返回 nil（踩过）。 */
    SFS2T *t = sf_s2t_load("s2t.tsv");
    CHECK(t != NULL, "测试加载 s2t.tsv");
    if (!t) return;
    char exp[64];
    sf_s2t_convert(t, "简化", exp, sizeof exp);
    sf_s2t_free(t);

    Fresh();
    gClient.output = [@"简化" mutableCopy];
    gClient.selection = NSMakeRange(0, 2);
    gClient.selectionText = @"简化";
    CHECK(TypeKey(kVK_ANSI_F, mods) == YES, "有选区时被消费");
    /* 带逗号的表达式不能直接塞 CHECK（宏按逗号拆参）；
     * %s 在 NSString format 里对多字节内容不可靠 —— 用 UTF-8 接口拼。 */
    NSString *expect = [NSString stringWithUTF8String:exp];
    CHECK([gClient.output isEqualToString:expect],
          "选区被原位替换为繁体：%s", CStr(gClient.output));

    /* 无映射字符（ASCII）保持原样 */
    Fresh();
    gClient.output = [@"abc" mutableCopy];
    gClient.selection = NSMakeRange(0, 3);
    gClient.selectionText = @"abc";
    TypeKey(kVK_ANSI_F, mods);
    CHECK([gClient.output isEqualToString:@"abc"], "无映射内容原样保留：%s", CStr(gClient.output));
    CHECK([HUDText() containsString:@"未发现"], "纯 ASCII 给「未发现简繁差异」提示：%s", CStr(HUDText()));

    /* 双向（0.5.6）：选繁体文本 → 转回简体。期望值按实现同样的顺序现算：
     * 先问 s2t（万一繁体字同时是某个简体字的键），无差异再用 t2s。 */
    SFS2T *t1 = sf_s2t_load("s2t.tsv");
    SFS2T *r = sf_s2t_load("t2s.tsv");
    CHECK(r != NULL, "测试加载 t2s.tsv");
    if (!r) { if (t1) sf_s2t_free(t1); return; }
    char exp2[64];
    sf_s2t_convert(t1, "萬與", exp2, sizeof exp2);
    if (strcmp(exp2, "萬與") == 0)          /* s2t 无差异 → 期望值来自 t2s */
        sf_s2t_convert(r, "萬與", exp2, sizeof exp2);
    sf_s2t_free(t1);
    sf_s2t_free(r);

    Fresh();
    gClient.output = [@"萬與" mutableCopy];
    gClient.selection = NSMakeRange(0, 2);
    gClient.selectionText = @"萬與";
    CHECK(TypeKey(kVK_ANSI_F, mods) == YES, "繁→简方向也被消费");
    NSString *expect2 = [NSString stringWithUTF8String:exp2];
    CHECK([gClient.output isEqualToString:expect2],
          "选区被原位替换为简体：%s", CStr(gClient.output));
}

static void test_webdav_sync(void)
{
    puts("\n== WebDAV 同步：快捷键路由 + 状态栏菜单 + 配置文件 ==");
    NSEventModifierFlags mods = NSEventModifierFlagControl | NSEventModifierFlagShift;

    /* 未配置时两键都只给引导 HUD，不发起任何网络请求（离线可测的分支）
     *
     * 必须先把 conf 指向一个**不存在**的文件：否则谁的本机
     * ~/Library/Application Support/SimpleFly/webdav.conf 存在，这里就会走
     * 「已配置」分支，下面 3 项断言全挂 —— 这是环境泄漏，不是代码 bug。 */
    NSString *noConf = @"/tmp/simplefly-test-no-webdav.conf";
    [[NSFileManager defaultManager] removeItemAtPath:noConf error:NULL];
    setenv("SIMPLEFLY_WEBDAV_CONF_FILE", noConf.fileSystemRepresentation, 1);

    Fresh();
    CHECK(TypeKey(kVK_ANSI_U, mods) == YES, "Ctrl+Shift+U 被输入法消费");
    CHECK([HUDText() containsString:@"未配置网盘"], "未配置时给引导提示：%s", CStr(HUDText()));
    CHECK([HUDText() containsString:@"网盘配置"], "引导指向「网盘配置」菜单：%s", CStr(HUDText()));
    CHECK([gClient.output length] == 0, "未配置时不上屏");

    Fresh();
    CHECK(TypeKey(kVK_ANSI_D, mods) == YES, "Ctrl+Shift+D 被输入法消费");
    CHECK([HUDText() containsString:@"未配置网盘"], "恢复键同样给引导提示：%s", CStr(HUDText()));

    /* 状态栏菜单：b41 起 **11 项** —— 更新到最新版本 / 分隔线 / 编码提示 / 同步 / 恢复 /
     * 网盘配置 / 用户配置 / 快捷键一览（子菜单）/ 用户手册 / 分隔线 / 选择主题…。
     * 断言动作选择器、target，以及「标题只留动作名、不带括号补充说明」（说明在 用户手册.md）。
     *
     * 主题**不再摊在主菜单里**：b39 平铺过一版（13 款 + 跟随共 15 项），能点但太长 ——
     * 24 项里 15 项是主题。b41 改成主菜单只留一条「选择主题…」，点它弹出**我们自己建的**
     * 第二层菜单（断言见下面 themePickerMenu 那一段）。IMK 自己的 NSMenuItem.submenu
     * 不能用：子菜单里的项点了没有任何回调（日志 + 实拍证据见 SFInputController.m 文件头
     * 第 4 层），机制依据见第 5 层（IMK 建命令表时只遍历顶层项）。 */
    NSMenu *m = [gCtl menu];
    CHECK(m != nil && m.numberOfItems == 11, "菜单有十一项（实际 %lu）",
          (unsigned long)(m ? m.numberOfItems : 0));
    if (!m) return;
    CHECK([m itemAtIndex:0].action == @selector(menuUpdate:) &&
          [m itemAtIndex:0].target == gCtl, "第一项 = 更新到最新版本");
    CHECK([m itemAtIndex:1].isSeparatorItem, "第二项 = 分隔线");
    CHECK([m itemAtIndex:2].action == @selector(menuToggleCodeHint:) &&
          [m itemAtIndex:2].target == gCtl, "第三项 = 编码提示开关");
    CHECK([m itemAtIndex:3].action == @selector(menuWebDAVSyncUp:) &&
          [m itemAtIndex:3].target == gCtl, "第四项 = 同步到网盘");
    CHECK([m itemAtIndex:4].action == @selector(menuWebDAVSyncDown:) &&
          [m itemAtIndex:4].target == gCtl, "第五项 = 从网盘恢复");
    CHECK([m itemAtIndex:5].action == @selector(menuWebDAVConfig:) &&
          [m itemAtIndex:5].target == gCtl, "第六项 = 网盘配置");
    CHECK([m itemAtIndex:6].action == @selector(menuUserConfig:) &&
          [m itemAtIndex:6].target == gCtl, "第七项 = 用户配置");
    CHECK([m itemAtIndex:8].action == @selector(menuUserManual:) &&
          [m itemAtIndex:8].target == gCtl, "第九项 = 用户手册");
    CHECK([[m itemAtIndex:2].title containsString:@"编码提示"] &&
          [[m itemAtIndex:3].title containsString:@"同步"] &&
          [[m itemAtIndex:4].title containsString:@"恢复"] &&
          [[m itemAtIndex:5].title containsString:@"网盘配置"] &&
          [[m itemAtIndex:6].title containsString:@"用户配置"], "标题用中文动词，不写术语");
    /* 菜单文案精简：动作名精确匹配，且任何一项都不带括号补充说明 */
    CHECK([[m itemAtIndex:0].title isEqualToString:@"更新到最新版本"],
          "更新项标题 = 更新到最新版本：%s", CStr([m itemAtIndex:0].title));
    CHECK([[m itemAtIndex:3].title isEqualToString:@"同步到网盘"],
          "同步项标题 = 同步到网盘：%s", CStr([m itemAtIndex:3].title));
    CHECK([[m itemAtIndex:4].title isEqualToString:@"从网盘恢复"],
          "恢复项标题 = 从网盘恢复：%s", CStr([m itemAtIndex:4].title));
    CHECK([[m itemAtIndex:5].title isEqualToString:@"网盘配置"],
          "配置项标题 = 网盘配置：%s", CStr([m itemAtIndex:5].title));
    CHECK([[m itemAtIndex:6].title isEqualToString:@"用户配置"],
          "用户配置项标题 = 用户配置：%s", CStr([m itemAtIndex:6].title));
    CHECK([[m itemAtIndex:7].title isEqualToString:@"快捷键一览"],
          "快捷键一览项标题 = 快捷键一览：%s", CStr([m itemAtIndex:7].title));
    CHECK([[m itemAtIndex:8].title isEqualToString:@"用户手册"],
          "用户手册项标题 = 用户手册：%s", CStr([m itemAtIndex:8].title));
    CHECK([m itemAtIndex:9].isSeparatorItem, "第十项 = 分隔线（把主题入口与上面的动作项隔开）");
    /* 第十一项 = 主题入口。要的是**顶层可点项**（b39 起这条路径真机验证过），点它弹第二层菜单。 */
    CHECK([m itemAtIndex:10].action == @selector(menuPickTheme:) &&
          [m itemAtIndex:10].target == gCtl, "第十一项 = 选择主题…");
    CHECK([[m itemAtIndex:10].title isEqualToString:@"选择主题…"],
          "主题入口标题 = 选择主题…：%s", CStr([m itemAtIndex:10].title));
    CHECK([m itemAtIndex:10].submenu == nil,
          "主题入口不带 IMK 子菜单（放进 submenu 的项点了没反应）");

    /* --- 第二层主题菜单（b41）：主菜单只留入口，菜单本身由 themePickerMenu 造出来 ---
     *
     * 为什么不能直接用 IMK 的 NSMenuItem.submenu：b38 装上「点一下就写日志」的诊断后，
     * 用户连开 11 次菜单，日志里**只有** `menu built`，而 `validate` / `IMK cmd` /
     * `theme pick` 一条都没有 —— 点击没产生任何回调。同时用 `screencapture` 拍到了菜单
     * 展开时的实拍：**主题项根本不是灰的**（与可点的「用户手册」同色、`✓` 也正确打在
     * 当前款上）⇒「项被判成置灰」不成立。两条证据合起来只剩一个解释：**放进子菜单的项
     * 没被接上派发** —— 机制见 SFInputController.m 文件头第 5 层引的 IMKInputController.h
     * 282~296 行（菜单画在系统的 Text Input Menu 里、IMK 建命令表只遍历顶层项）。
     * 旁证：本机装着、能正常工作的鼠须管 0.15.2 `-menu` 里一个子菜单都没有。
     * 所以 b41 的做法是：主菜单留一条**顶层**「选择主题…」，在它的 action 里 popUp 出这张
     * **我们自己建的**菜单 —— 由 AppKit 在进程内派发，target 有效。
     *
     * 布局：0 = 置灰小标题「候选窗配色」/ 1..13 = 13 款 / 14 = 分隔线 / 15 = 跟随系统亮暗。
     * 这里**不缀「主题：」前缀**（那是平铺进主菜单才需要的语境补偿），标题就是主题名本身。
     *
     * 每项一个**独立 selector**（menuTheme_<主题名>:）。这是连踩三次的结论：
     *   · b35 给每项配自定义 target「让它自己记住是哪一款」→ IMK 根本不看 target，全废；
     *   · b36 改成共用 action、靠 infoDictionary 认领 → 只覆盖「sender 是字典」这一种
     *     形态，AppKit 直调时（sender 是 NSMenuItem）解析不出主题名，照样没反应；
     *   · b37 把主题名编进方法名 → 仍没反应，因为问题根本不在「认领」而在「点击到不了」。
     * 下面几条断言分别覆盖这些坑，少测任何一种，bug 就会从另一条路溜回来。 */
    NSArray<NSString *> *thNames = [SFCandidateTheme allThemeNames];
    NSMenu *tp = [gCtl themePickerMenu];
    CHECK(tp != nil, "themePickerMenu 拿得到第二层菜单（单测没法点菜单，只能直接拿它断言）");
    CHECK(tp != nil && tp.numberOfItems == 16,
          "第二层 16 项 = 小标题 + 13 款 + 分隔线 + 跟随（实际 %lu）",
          (unsigned long)(tp ? tp.numberOfItems : 0));
    if (tp) {
        CHECK([[tp itemAtIndex:0].title isEqualToString:@"候选窗配色"] &&
              ![tp itemAtIndex:0].isEnabled && [tp itemAtIndex:0].action == NULL,
              "首行 = 置灰小标题「候选窗配色」");
        CHECK([tp itemAtIndex:14].isSeparatorItem, "第 15 项 = 分隔线");
        CHECK(!tp.autoenablesItems, "第二层菜单 autoenablesItems = NO（同主菜单）");

        BOOL thTargetIsCtl = YES, thResponds = YES, thNamed = YES, thDistinct = YES,
             thTitled = YES, thEnabled = YES;
        NSMutableSet<NSString *> *thSeen = [NSMutableSet set];
        for (NSUInteger i = 0; i < thNames.count; i++) {
            NSMenuItem *it = [tp itemAtIndex:(NSInteger)(1 + i)];
            if (![it.title isEqualToString:thNames[i]]) thTitled = NO;
            if (!it.isEnabled) thEnabled = NO;
            if (it.target != gCtl) thTargetIsCtl = NO;
            /* selector 必须与主题名严格对应：只往 kThemes 加一款、忘了加方法，
             * 这一款真机上就是「点了没反应」，这里要能当场拦住。 */
            NSString *want = [NSString stringWithFormat:@"menuTheme_%@:", thNames[i]];
            NSString *have = NSStringFromSelector(it.action);
            if (![have isEqualToString:want]) thNamed = NO;
            if (![gCtl respondsToSelector:it.action]) thResponds = NO;
            if ([thSeen containsObject:have]) thDistinct = NO;
            [thSeen addObject:have];
            if (![it.representedObject isEqualToString:thNames[i]]) thNamed = NO;
        }
        CHECK(thTitled, "13 款标题就是主题名本身（语境由入口给足，不再缀「主题：」）");
        CHECK(thEnabled, "13 款都是可点的（autoenablesItems = NO 之下没被自己置灰）");
        CHECK(thTargetIsCtl, "各项 target 都是 controller（本进程派发，target 有效）");
        CHECK(thNamed, "各项 selector 严格等于 menuTheme_<主题名>: 且带着自己的主题名");
        CHECK(thResponds, "controller 真的响应每一项的 selector");
        CHECK(thDistinct, "各项 selector 互不相同（共用一个正是 b36 的坑）");
    }

    /* 第 3 层防线（b38）的可用性断言**保留** —— 它挡的是「项被系统判成置灰」那条路径。
     * b38 的实拍证明本次不是它，但换台机器/换个系统版本仍可能是，拆掉就等于把门敞开。 */
    CHECK(!m.autoenablesItems, "主菜单 autoenablesItems = NO（可用性不交给系统）");

    Class imk = NSClassFromString(@"IMKInputController");
    IMP impMine = [SimpleFlyInputController instanceMethodForSelector:
                       @selector(doCommandBySelector:commandDictionary:)];
    IMP impTheirs = [imk instanceMethodForSelector:
                         @selector(doCommandBySelector:commandDictionary:)];
    CHECK(impTheirs == NULL || impMine != impTheirs,
          "doCommandBySelector:commandDictionary: 是我们自己实现的那份");
    CHECK([gCtl respondsToSelector:@selector(doCommandBySelector:commandDictionary:)],
          "controller 响应检查（IMK 的默认实现就照这个决定派不派发）");

    /* validateMenuItem: 必须放行响应得动的动作、挡住响应不了的 ——
     * 返回 NO 就等于把菜单项置灰，症状与「点了没反应」一模一样。 */
    NSMenuItem *thAny = [m itemAtIndex:10];
    CHECK([gCtl validateMenuItem:thAny], "validateMenuItem: 对主题动作放行");
    NSMenuItem *thBogus = [[NSMenuItem alloc] initWithTitle:@"x"
                                                     action:@selector(noSuchMenuAction:)
                                              keyEquivalent:@""];
    CHECK(![gCtl validateMenuItem:thBogus], "validateMenuItem: 挡住响应不了的动作");

    CHECK([[tp itemAtIndex:15].title isEqualToString:@"跟随系统亮暗"],
          "末项 = 跟随系统亮暗（在第二层菜单里，主菜单不再单列）：%s",
          CStr([tp itemAtIndex:15].title));

    /* 派发形态一：IMK 转发路径 —— sender 是 infoDictionary。
     * IMK **不看菜单项 target**，它调 -doCommandBySelector:commandDictionary:，
     * 后者看 controller 响不响应，再把字典发过去。 */
    [[NSUserDefaults standardUserDefaults] setObject:@"metro" forKey:@"Theme"];
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"ThemeAuto"];
    Fresh();
    NSMenuItem *thPick = [[gCtl themePickerMenu] itemAtIndex:
        (NSInteger)(1 + [thNames indexOfObject:@"contrast"])];
    [gCtl doCommandBySelector:thPick.action
            commandDictionary:@{ kIMKCommandClientName: gClient }];
    NSString *thGot = ThemeName();
    CHECK([thGot isEqualToString:@"contrast"],
          "字典形态派发生效：主题切到 contrast（实际 %s）", CStr(thGot));
    CHECK([Panel().theme.name isEqualToString:@"contrast"], "候选窗配色跟着换");
    NSString *thPref = [[NSUserDefaults standardUserDefaults] stringForKey:@"Theme"];
    CHECK([thPref isEqualToString:@"contrast"], "并写回 Theme 偏好：%s", CStr(thPref));

    /* 派发形态二：AppKit 直接向 target 发 action —— sender 是 NSMenuItem 本身。
     * **这一条就是 b36 的盲区**：那版只测了上面的字典形态，所以结构断言全绿、真机照样没反应。 */
    [[NSUserDefaults standardUserDefaults] setObject:@"metro" forKey:@"Theme"];
    Fresh();
    NSMenuItem *thPick2 = [[gCtl themePickerMenu] itemAtIndex:
        (NSInteger)(1 + [thNames indexOfObject:@"retro"])];
    IMP impDirect = [gCtl methodForSelector:thPick2.action];
    ((void (*)(id, SEL, id))impDirect)(gCtl, thPick2.action, thPick2);
    NSString *thGot2 = ThemeName();
    CHECK([thGot2 isEqualToString:@"retro"],
          "菜单项直调形态同样生效：主题切到 retro（实际 %s）", CStr(thGot2));
    CHECK([Panel().theme.name isEqualToString:@"retro"], "候选窗配色跟着换");

    /* 认不出的主题名不能乱切，但必须出声（静默无反应最误导人） */
    [gCtl pickThemeNamed:@"no_such_theme" sender:nil];
    NSString *thStill = ThemeName();
    CHECK([thStill isEqualToString:@"retro"], "未知主题名时保持原状（%s）", CStr(thStill));
    CHECK(HUDText().length > 0, "并给出 HUD 提示而不是静默：%s", CStr(HUDText()));

    /* client 兜底：sender 是个裸 NSMenuItem（既不是字典、也不是 client）时，
     * **绝不能把它当 client 传下去** —— 那会让面板/HUD 定位退化成跟着鼠标走。
     * 这里只要求切对主题且不崩，位置计算由 candidateTopLeftWithClient: 的
     * respondsToSelector: 保护兜住。 */
    [[NSUserDefaults standardUserDefaults] setObject:@"metro" forKey:@"Theme"];
    Fresh();
    NSMenuItem *thBare = [[NSMenuItem alloc] initWithTitle:@"luna"
                                                    action:@selector(menuTheme_luna:)
                                             keyEquivalent:@""];
    IMP impBare = [gCtl methodForSelector:thBare.action];
    ((void (*)(id, SEL, id))impBare)(gCtl, thBare.action, thBare);
    NSString *thGot3 = ThemeName();
    CHECK([thGot3 isEqualToString:@"luna"], "裸菜单项当 sender 也能切对（%s）", CStr(thGot3));

    [[NSUserDefaults standardUserDefaults] setObject:@"metro" forKey:@"Theme"];
    Fresh();

    /* 打勾状态：默认（未跟随时）只有当前款打勾 —— 每项都打勾等于没打 */
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"ThemeAuto"];
    [[NSUserDefaults standardUserDefaults] setObject:@"metro" forKey:@"Theme"];
    Fresh();
    NSMenu *thMenuOn = [gCtl themePickerMenu];
    NSUInteger thOnCount = 0;
    for (NSUInteger i = 0; i < 13; i++)
        if ([thMenuOn itemAtIndex:(NSInteger)(1 + i)].state == NSControlStateValueOn)
            thOnCount++;
    CHECK(thOnCount == 1, "只当前款打勾（实际打勾 %lu 项）", (unsigned long)thOnCount);
    CHECK([thMenuOn itemAtIndex:1].state == NSControlStateValueOn, "metro 是当前款，打勾");

    /* 跟随开着时：主题列一个都不打勾（用哪款由系统决定，别假装选中某款） */
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"ThemeAuto"];
    Fresh();
    NSMenu *thMenuAuto = [gCtl themePickerMenu];
    CHECK([thMenuAuto itemAtIndex:15].state == NSControlStateValueOn, "跟随项打勾");
    BOOL thAnyThemeOn = NO;
    for (NSUInteger i = 0; i < 13; i++)
        if ([thMenuAuto itemAtIndex:(NSInteger)(1 + i)].state == NSControlStateValueOn)
            thAnyThemeOn = YES;
    CHECK(!thAnyThemeOn, "跟随开着时主题列不打勾");
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"ThemeAuto"];
    [[NSUserDefaults standardUserDefaults] setObject:@"metro" forKey:@"Theme"];
    Fresh();

    /* --- 「快捷键一览」子菜单：把 用户手册 §四 的键位搬进菜单，不用翻文档 ---
     * 断言三件事：① 行数与分隔线分段能对上手册的四组；② 每行都是只读的
     * （都不带 action —— 里面躺着「清空重码记忆」这种破坏性动作，能在菜单里被点中就是事故）；
     * ③ 键位文本与手册逐字一致（手册和菜单对不上等于两边都不可信）。 */
    NSMenu *km = [m itemAtIndex:7].submenu;
    CHECK(km != nil, "第八项带子菜单（父项无 action 也能展开）");
    CHECK(km.numberOfItems == 15, "一览 15 项 = 12 条键位 + 3 条分隔线（实际 %lu）",
          (unsigned long)(km ? km.numberOfItems : 0));
    if (km) {
        CHECK([[km itemAtIndex:3] isSeparatorItem] && [[km itemAtIndex:9] isSeparatorItem] &&
              [[km itemAtIndex:12] isSeparatorItem],
              "三条分隔线把键位分成四组（模式开关 / 查码 / 简繁 / 网盘）");
        BOOL readonly = YES;
        for (NSInteger i = 0; i < (NSInteger)km.numberOfItems; i++) {
            NSMenuItem *it = [km itemAtIndex:i];
            if (it.isSeparatorItem) continue;
            /* 还要求**显式置灰**：菜单 `autoenablesItems = NO` 之后，系统不再自动替
             * 没有 action 的项置灰，得自己 `enabled = NO` —— 否则这些行看着可点
             * （虽然点了也无效），而里面躺着「清空重码记忆」这种破坏性动作，容易误触。 */
            if (it.action != nil || it.target != nil || it.isEnabled) readonly = NO;
        }
        CHECK(readonly, "每一行都是只读说明（不带 action/target 且显式置灰）");
        CHECK([[km itemAtIndex:0].title containsString:@"中 / 英 切换"] &&
              [[km itemAtIndex:0].title containsString:@"单敲 ⇧"],
              "首行 = 中 / 英 切换 / 单敲 ⇧：%s", CStr([km itemAtIndex:0].title));
        CHECK([[km itemAtIndex:2].title containsString:@"⇧ 空格"],
              "全 / 半角切换的键位 = ⇧ 空格：%s", CStr([km itemAtIndex:2].title));
        CHECK([[km itemAtIndex:7].title containsString:@"⌃ ⇧ H"],
              "候选窗编码提示的键位 = ⌃ ⇧ H：%s", CStr([km itemAtIndex:7].title));
        CHECK([[km itemAtIndex:8].title containsString:@"⌃ ⇧ ;"] &&
              [[km itemAtIndex:10].title containsString:@"⌃ ⇧ F"] &&
              [[km itemAtIndex:11].title containsString:@"⌃ ⇧ T"],
              "清重码 / 简繁两项的键位与手册一致");
        CHECK([[km itemAtIndex:13].title containsString:@"⌃ ⇧ U"] &&
              [[km itemAtIndex:14].title containsString:@"⌃ ⇧ D"],
              "网盘两项的键位与手册一致");
    }
    for (NSInteger i = 0; i < (NSInteger)m.numberOfItems; i++) {
        NSString *t = [m itemAtIndex:i].title;
        CHECK([t rangeOfString:@"（"].location == NSNotFound &&
              [t rangeOfString:@"("].location == NSNotFound,
              "第 %ld 项标题不含括号说明：%s", (long)i, CStr(t));
        /* 省略号（… / ...）的约定是「点完还得再填一步」，而全菜单**只有一个例外**：
         * b41 的「选择主题…」确实还要再选一层（弹第二层菜单），那一项在下面单独断言；
         * 其余项都是点一下就做完，一律不许缀。中文省略号与三个半角句点都算。 */
        if ([t isEqualToString:@"选择主题…"]) continue;
        CHECK([t rangeOfString:@"…"].location == NSNotFound &&
              [t rangeOfString:@"..."].location == NSNotFound,
              "第 %ld 项标题不缀省略号：%s", (long)i, CStr(t));
    }
    /* 例外本身也要锁住：将来把主题入口改成「点一下就完事」（比如改成循环切下一款），
     * 这里会当场挂 —— 提醒同步改文案与 用户手册.md。 */
    CHECK([[[gCtl menu] itemAtIndex:10].title rangeOfString:@"…"].location != NSNotFound,
          "主题入口缀省略号（点完还要再选一层，与其余动作项不同）");
    /* 菜单项标题反映当前开关状态（默认关） */
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"CodeHint"];
    CHECK([[[gCtl menu] itemAtIndex:2].title containsString:@"关"],
          "关状态：菜单标题显示「关」");
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"CodeHint"];
    CHECK([[[gCtl menu] itemAtIndex:2].title containsString:@"开"],
          "开状态：菜单标题显示「开」");
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"CodeHint"];
}

static void test_webdav_config_file(void)
{
    puts("\n== WebDAV 配置文件：webdav.conf 解析 + 优先级 + 模板生成 ==");
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *tmpl = [NSTemporaryDirectory() stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"sfconf-%d.conf", (int)getpid()]];
    [d removeObjectForKey:@"WebDAVURL"];
    [d removeObjectForKey:@"WebDAVUser"];
    [d removeObjectForKey:@"WebDAVPass"];
    setenv("SIMPLEFLY_WEBDAV_CONF_FILE", tmpl.fileSystemRepresentation, 1);
    [[NSFileManager defaultManager] removeItemAtPath:tmpl error:NULL];

    /* ① 空环境：conf 不存在、defaults 也没设 → 未配置 */
    Fresh();
    CHECK([gCtl webdavConfig] == nil, "conf 与 defaults 都空 → 未配置");

    /* ② defaults 兜底：conf 还没有，defaults 三键齐 → 走旧配置路径 */
    [d setObject:@"https://dav.example.com/dav/X" forKey:@"WebDAVURL"];
    [d setObject:@"old@example.com" forKey:@"WebDAVUser"];
    [d setObject:@"oldpass" forKey:@"WebDAVPass"];
    NSDictionary *c = [gCtl webdavConfig];
    CHECK(c && [c[@"url"] isEqualToString:@"https://dav.example.com/dav/X"],
          "conf 缺席时回落到 defaults：%s", CStr(c));

    /* ③ conf 优先：文件里三项齐全 → 盖过 defaults */
    [@"# 注释行\nurl = https://dav.jianguoyun.com/dav/SimpleFly\n"
      @"user = me@example.com\n"
      @"pass = app-pass\n"
      writeToFile:tmpl atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    c = [gCtl webdavConfig];
    CHECK(c && [c[@"url"] isEqualToString:@"https://dav.jianguoyun.com/dav/SimpleFly"] &&
          [c[@"user"] isEqualToString:@"me@example.com"] &&
          [c[@"pass"] isEqualToString:@"app-pass"],
          "conf 三项齐全时优先于 defaults：%s", CStr(c));

    /* ④ 键大小写不敏感 + 部分填写回落合并：文件只填 url，user/pass 取 defaults */
    [@"URL = https://dav.other.com/dav/Y\n"
      @"# user = 被注释的行不参与解析\n"
      writeToFile:tmpl atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    c = [gCtl webdavConfig];
    CHECK(c && [c[@"url"] isEqualToString:@"https://dav.other.com/dav/Y"] &&
          [c[@"user"] isEqualToString:@"old@example.com"] &&
          [c[@"pass"] isEqualToString:@"oldpass"],
          "conf 部分键与 defaults 逐键合并：%s", CStr(c));

    /* ⑤ 「网盘配置」：文件不存在 → 先按模板生成；测试模式（conf 路径被
     *    环境变量指走）不弹 TextEdit，只给 HUD。先清掉 defaults ——
     *    合并语义下兜底键还在就会构成「已配置」，测不出模板本身的空状态。 */
    [d removeObjectForKey:@"WebDAVURL"];
    [d removeObjectForKey:@"WebDAVUser"];
    [d removeObjectForKey:@"WebDAVPass"];
    [[NSFileManager defaultManager] removeItemAtPath:tmpl error:NULL];
    Fresh();
    [gCtl openWebDAVConfig:gClient];
    NSString *s = [NSString stringWithContentsOfFile:tmpl
                                            encoding:NSUTF8StringEncoding error:NULL];
    CHECK(s != nil && [s containsString:@"坚果云"] && [s containsString:@"# url ="] &&
          [s containsString:@"# user ="] && [s containsString:@"# pass ="],
          "模板已生成且含坚果云引导与三个待填键");
    CHECK([HUDText() containsString:@"配置文件"], "测试模式不弹编辑器、给 HUD：%s", CStr(HUDText()));
    /* 模板全是注释 → 解析出来是空 → 依然算「未配置」 */
    CHECK([gCtl webdavConfig] == nil, "全注释模板不构成已配置");

    [[NSFileManager defaultManager] removeItemAtPath:tmpl error:NULL];
    unsetenv("SIMPLEFLY_WEBDAV_CONF_FILE");
}

static void test_user_config_dir(void)
{
    puts("\n== 用户配置：打开配置目录（建目录 + 补示例 + 不覆盖已有）==");
    NSFileManager *fm = [NSFileManager defaultManager];
    /* 目录指到临时目录：这个动作本意是「访达打开配置目录」，绝不能让它真去碰用户
     * ~/Library/Application Support/SimpleFly/，也不该在测试机上弹窗口。 */
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:
                     [NSString stringWithFormat:@"sfusercfg-%d", (int)getpid()]];
    [fm removeItemAtPath:dir error:NULL];
    setenv("SIMPLEFLY_USER_CONFIG_DIR", dir.fileSystemRepresentation, 1);
    NSString *phrase = [dir stringByAppendingPathComponent:@"phrase.txt"];

    /* ① 目录与短语表都不存在 → 目录建出来，并补一份带说明的示例（否则打开的是空目录） */
    CHECK(![fm fileExistsAtPath:dir], "起始状态：配置目录不存在");
    Fresh();
    [gCtl openUserConfig:gClient];
    BOOL isDir = NO;
    CHECK([fm fileExistsAtPath:dir isDirectory:&isDir] && isDir, "点一次就把配置目录建出来");
    NSString *s = [NSString stringWithContentsOfFile:phrase
                                            encoding:NSUTF8StringEncoding error:NULL];
    CHECK(s != nil && [s containsString:@"自定义快捷输入"] && [s containsString:@"编码 = 内容"],
          "首次打开补一份带说明的短语示例");
    CHECK(HUDText().length > 0, "测试模式不弹访达、只给 HUD：%s", CStr(HUDText()));
    CHECK([HUDText() containsString:@"配置目录"], "HUD 点明开的是配置目录：%s", CStr(HUDText()));

    /* ② 已有短语表原样不动 —— 这是「别毁用户数据」的底线，模板只在文件缺席时写 */
    [@"abc = 我自己的短语\n" writeToFile:phrase
                              atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    Fresh();
    [gCtl openUserConfig:gClient];
    s = [NSString stringWithContentsOfFile:phrase
                                  encoding:NSUTF8StringEncoding error:NULL];
    CHECK([s isEqualToString:@"abc = 我自己的短语\n"],
          "已有短语表不被模板覆盖：%s", CStr(s));

    [fm removeItemAtPath:dir error:NULL];
    unsetenv("SIMPLEFLY_USER_CONFIG_DIR");
}

static void test_user_manual(void)
{
    puts("\n== 用户手册：随包内嵌路径解析 + 找不到时不静默 ==");
    NSFileManager *fm = [NSFileManager defaultManager];

    /* ① 路径指到一个不存在的文件 → 给提示，不能拿着空路径去调 openFile。
     *    用环境变量预设而不是指望「测试机上恰好没有」，断言就与运行环境无关。 */
    NSString *missing = [NSTemporaryDirectory() stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"sfmanual-missing-%d.md", (int)getpid()]];
    [fm removeItemAtPath:missing error:NULL];
    setenv("SIMPLEFLY_USER_MANUAL", missing.fileSystemRepresentation, 1);
    Fresh();
    [gCtl openUserManual:gClient];
    CHECK(HUDText().length > 0, "手册不在时点菜单有提示、不静默：%s", CStr(HUDText()));
    CHECK([HUDText() containsString:@"没找到"], "提示点明没找到手册：%s", CStr(HUDText()));

    /* ② 指到一个真实存在的 md → 认得出，且测试模式只给 HUD、不开编辑器
     *    （这个动作本意是「弹一个编辑器窗口」，测试机上绝不能真弹） */
    NSString *md = [NSTemporaryDirectory() stringByAppendingPathComponent:
                    [NSString stringWithFormat:@"sfmanual-%d.md", (int)getpid()]];
    [@"# 用户手册\n测试用正文\n" writeToFile:md atomically:YES
                                     encoding:NSUTF8StringEncoding error:NULL];
    /* 现在把环境变量改指到这份**真实存在**的文件上（① 那份仍是不存在的路径）。
     * 少了这一行，env 还停在 ① 上，② 会一路报「没找到」—— 首轮就踩了这个。 */
    setenv("SIMPLEFLY_USER_MANUAL", md.fileSystemRepresentation, 1);
    Fresh();
    [gCtl openUserManual:gClient];
    CHECK([HUDText() containsString:@"用户手册"], "HUD 点明开的是用户手册：%s", CStr(HUDText()));
    CHECK([HUDText() containsString:md], "HUD 带上环境变量指的那份路径（env 优先）：%s",
          CStr(HUDText()));
    CHECK([HUDText() rangeOfString:@"没找到"].location == NSNotFound,
          "文件在就不该报没找到：%s", CStr(HUDText()));

    /* ③ 同一份路径上文件被删 → 立刻回到「没找到」，不缓存上一次的判空结果 */
    [fm removeItemAtPath:md error:NULL];
    Fresh();
    [gCtl openUserManual:gClient];
    CHECK([HUDText() containsString:@"没找到"], "文件删掉后不再当作可用：%s", CStr(HUDText()));

    unsetenv("SIMPLEFLY_USER_MANUAL");
}

static void test_output_trad(void){
    puts("\n== 输出模式：简/繁 切换（Ctrl+Shift+T）==");
    NSEventModifierFlags mods = NSEventModifierFlagControl | NSEventModifierFlagShift;
    /* setBool 会写进测试进程的持久 defaults —— 上次运行若中途夭折（比如 cwd 不对
     * 加载不到表提前 return），残留的 OutputTrad=YES 会污染本次及以后的全部用例。
     * 开头先清一次，保证「默认输出简体」这条断言测的是真默认值。 */
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"OutputTrad"];
    Fresh();
    CHECK(BoolIvar(gCtl, "_outputTrad") == NO, "默认输出简体");
    CHECK(TypeKey(kVK_ANSI_T, mods) == YES, "Ctrl+Shift+T 被输入法消费");
    CHECK(BoolIvar(gCtl, "_outputTrad") == YES, "切换到繁体输出");
    CHECK([HUDText() containsString:@"繁体"], "HUD 提示输出：繁体：%s", CStr(HUDText()));

    /* 找一个「首选经 s2t 后会变」的编码，保证断言的不是直通路径 */
    SFS2T *t = sf_s2t_load("s2t.tsv");
    CHECK(t != NULL, "加载 s2t.tsv");
    if (!t) {   /* 提前退也要清持久状态，否则污染后续运行（0.5.8 实测踩过） */
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"OutputTrad"];
        return;
    }
    const char *L = "abcdefghijklmnopqrstuvwxyz";
    NSString *code = nil, *want = nil;
    for (int len = 2; len <= 3 && !code; len++) {
        int idx[4] = {0};
        char buf[8] = {0};
        while (1) {
            for (int i = 0; i < len; i++) buf[i] = L[idx[i]];
            NSString *first = Cand(buf, 0);
            if (first.length > 0) {
                char cv[64];
                size_t need = sf_s2t_convert(t, first.UTF8String, cv, sizeof cv);
                NSString *conv = (need > 1) ? [NSString stringWithUTF8String:cv] : nil;
                if (conv && ![conv isEqualToString:first]) {
                    code = [NSString stringWithUTF8String:buf];
                    want = conv;
                    break;
                }
            }
            int p = len - 1;
            while (p >= 0 && ++idx[p] == 26) { idx[p] = 0; p--; }
            if (p < 0) break;
        }
    }
    sf_s2t_free(t);
    CHECK(code.length > 0, "找到首选会被转换的编码（%s）", CStr(code));
    if (code.length == 0) return;

    TypeString(code.UTF8String);
    Type(' ', 0);
    CHECK([gClient.output isEqualToString:want],
          "繁体输出模式：上屏首选被转换 %s → %s", CStr(Cand(code.UTF8String, 0)), CStr(gClient.output));

    /* 切回简体输出（恢复默认，别污染后续用例），再打一遍应原样上屏 */
    CHECK(TypeKey(kVK_ANSI_T, mods) == YES, "再按一次被消费");
    CHECK(BoolIvar(gCtl, "_outputTrad") == NO, "切回简体输出");
    /* 连持久层一起清，下次运行不受本次影响 */
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"OutputTrad"];
    Fresh();
    TypeString(code.UTF8String);
    Type(' ', 0);
    CHECK([gClient.output isEqualToString:Cand(code.UTF8String, 0)],
          "简体输出模式：首选原样上屏 %s", CStr(gClient.output));
}

static void test_custom_phrase(void)
{
    puts("\n== 自定义快捷输入（abc = 测试短语）==");
    if (!gPhrasePath) { CHECK(NO, "没有指定短语表路径"); return; }

    NSString *gap = FindGapCode();
    CHECK(gap.length == 3, "找到一个码表里没有的编码用于测试（%s）", CStr(gap));
    if (gap.length != 3) return;

    NSString *head2 = [gap substringToIndex:2];
    WritePhraseFile([NSString stringWithFormat:
                        @"# 测试用\n%@ = 测试短语\n", gap]);

    /* --- 中途不能判空码：首字符码表有，两字符码表没有，全靠短语前缀保护 --- */
    Fresh();
    CHECK(Type([gap characterAtIndex:0], 0) == YES, "第 1 个字符被消费");
    CHECK(Type([gap characterAtIndex:1], 0) == YES,
          "第 2 个字符被消费（码表此时查不到，但短语 %s 有此前缀）", gap.UTF8String);
    CHECK([ObjIvar(gCtl, "_code") isEqualToString:head2],
          "缓冲保留住前缀 %s（没被回退）", CStr(head2));

    Type([gap characterAtIndex:2], 0);
    CHECK([ObjIvar(gCtl, "_code") isEqualToString:gap], "第 3 个字符补齐：%s", CStr(gap));
    CHECK(CandsCount() >= 1, "有候选");
    if (CandsCount() >= 1)
        CHECK([((SFCandidate *)Cands()[0]).text isEqualToString:@"测试短语"],
              "自定义短语排在候选第一位：%s", CStr(((SFCandidate *)Cands()[0]).text));

    Type(' ', 0);
    CHECK([gClient.output isEqualToString:@"测试短语"], "空格上屏：%s", CStr(gClient.output));

    /* --- 数字键 1 也能上屏 --- */
    Fresh();
    TypeString(gap.UTF8String);
    Type('1', 0);
    CHECK([gClient.output isEqualToString:@"测试短语"], "数字键 1 上屏短语：%s", CStr(gClient.output));

    /* --- 短语编码是 4 码时不该触发四键自动上屏（要让用户确认）--- */
    NSString *four = [gap stringByAppendingString:@"z"];   /* gap 是 3 码且码表无此码 */
    WritePhraseFile([NSString stringWithFormat:@"%@ = 四码短语\n", four]);
    Fresh();
    TypeString(four.UTF8String);
    CHECK(gClient.output.length == 0, "四码短语不自动上屏，等用户按空格");
    if (CandsCount() >= 1)
        CHECK([((SFCandidate *)Cands()[0]).text isEqualToString:@"四码短语"],
              "四码短语仍是第一候选");
    Type(' ', 0);
    CHECK([gClient.output isEqualToString:@"四码短语"], "空格上屏：%s", CStr(gClient.output));

    /* --- 快符上混了自定义短语时，同样不该自动上屏（pn == 0 那条守卫）--- */
    WritePhraseFile(@";a=测试快符\n");
    Fresh();
    TypeString(";a");
    CHECK(gClient.output.length == 0, ";a 有自定义短语时不自动上屏，等用户确认");
    if (CandsCount() >= 1)
        CHECK([((SFCandidate *)Cands()[0]).text isEqualToString:@"测试快符"],
              "短语仍排第一：%s", CStr(((SFCandidate *)Cands()[0]).text));
    Type(' ', 0);
    CHECK([gClient.output isEqualToString:@"测试快符"], "空格上屏短语：%s", CStr(gClient.output));

    /* --- 清掉短语表后，同一个编码就该回到「空码回退」的老行为 --- */
    WritePhraseFile(@"# 空的\n");
    Fresh();
    Type([gap characterAtIndex:0], 0);
    Type([gap characterAtIndex:1], 0);
    CHECK([ObjIvar(gCtl, "_code") isEqualToString:[gap substringToIndex:1]],
          "没有短语表时，第二个字符仍按空码回退（缓冲只剩 %s）",
          CStr(ObjIvar(gCtl, "_code")));
}

int main(int argc, char **argv)
{
    (void)argc; (void)argv;
    @autoreleasepool {
        [NSApplication sharedApplication];       /* 造 NSEvent 需要 AppKit 就绪 */

        /* 清掉上次运行可能残留的持久开关（OutputTrad 等会写真实 defaults plist，
         * 残留会让「默认值」断言和上屏内容全错 —— 0.5.8 实测踩过）。 */
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"OutputTrad"];

        puts("===== 控制器按键路由单测 =====");
        if (!SFSharedEngine()) {
            /* 缺码表也得是个「能活」的状态 —— 这是 clone 本仓库的人第一个撞到的情形
             * （仓库不含码表，见 README §6）。只验证三件事：按键不吞、不崩、有可见提示。
             * 其余用例都要真码表，缺表时跑下去没有意义，所以跑完这项就退出。 */
            Fresh();
            CHECK(TypeKey(kVK_ANSI_A, 0) == NO, "缺码表：按键不被吞（字母照常上屏）");
            CHECK(gClient.output.length == 0, "缺码表：输入法自身不上屏任何东西");
            CHECK(HUDText().length > 0, "缺码表：弹出可见提示，而不是只 NSLog 一行");
            printf("\n===== %d 通过 / %d 失败 =====\n", g_pass, g_fail);
            fprintf(stderr, "（SIMPLEFLY_DICT_FILE 指向的码表不存在，只跑了缺表守卫用例）\n");
            return 2;
        }
        printf("码表：%zu 条 / %zu 个编码\n",
               sf_engine_size(SFSharedEngine()), sf_engine_code_count(SFSharedEngine()));

        /* 短语表指到临时文件 —— 测试绝不碰用户真实的自定义短语。
         * 必须在任何控制器实例化之前设好（path 是进程级环境变量）。 */
        static char phrasePath[512];
        snprintf(phrasePath, sizeof phrasePath, "/tmp/sf_ctrl_phrase_%d.txt", (int)getpid());
        setenv("SIMPLEFLY_PHRASE_FILE", phrasePath, 1);
        gPhrasePath = phrasePath;
        unlink(phrasePath);                      /* 先确保没有残留 */
        WritePhraseFile(@"# 空的\n");

        /* 重码记忆同理：文件指到临时目录，必须在任何控制器实例化之前设好 */
        static char freqPath[512];
        snprintf(freqPath, sizeof freqPath, "/tmp/sf_ctrl_freq_%d.txt", (int)getpid());
        setenv("SIMPLEFLY_FREQ_FILE", freqPath, 1);
        gFreqPath = freqPath;
        unlink(freqPath);

        /* 打错日志同理 */
        static char mislogPath[512];
        snprintf(mislogPath, sizeof mislogPath, "/tmp/sf_ctrl_mislog_%d.txt", (int)getpid());
        setenv("SIMPLEFLY_MISLOG_FILE", mislogPath, 1);
        gMislogPath = mislogPath;
        unlink(mislogPath);

        SaveDefaults();

        test_composition();
        test_select();
        test_backspace_escape();
        test_autocommit();
        test_quick_symbol();
        test_punctuation_single();
        test_punctuation_pair();
        test_punct_topscreen();
        test_uppercase_and_modifiers();
        test_ascii_mode();
        test_shift_commit_raw_letters();
        test_shift_not_toggled_by_combo();
        test_punct_ascii_and_fullshape();
        test_empty_code_fallback();
        test_caret_position();
        test_arrow_selection();
        test_punct_arrow_selection();
        test_punct_composition_discard();
        test_freq_memory();         /* 用临时 freq 文件，放 phrase 之前不互相污染 */
        test_lookup_selection();
        test_miss_log();
        test_s2t_convert();
        test_output_trad();
        test_webdav_sync();
        test_webdav_config_file();
        test_user_config_dir();
        test_user_manual();
        test_reverse_mode();
        test_theme();
        test_code_hint();
        test_custom_phrase();       /* 放最后：它会写短语表，可能影响空码判断 */

        RestoreDefaults();
        unlink(phrasePath);

        printf("\n===== %d 通过 / %d 失败 =====\n", g_pass, g_fail);
        return g_fail == 0 ? 0 : 1;
    }
}
