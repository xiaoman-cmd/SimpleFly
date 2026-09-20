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
- (void)openWebDAVConfig:(id)sender;                      /* 「网盘配置…」实现 */
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

static void Fresh(void)
{
    gClient = [[FakeClient alloc] init];
    gClient.caretRect = NSMakeRect(200, 400, 8, 20);
    /* 不走 initWithServer:delegate:client: —— IMKInputController 那一步会校验 client
     * 必须是真实的输入会话代理，塞个假对象进去直接抛异常。alloc + setupState 等价，
     * 只是跳过了 IMK 自己的那点内部初始化，而本测试根本不碰 IMK 内部。 */
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

/* 控制器私有方法没有公开头文件，测试直接调要自己补声明 */
@interface SimpleFlyInputController (TestOnly)
- (void)menuToggleCodeHint:(id)sender;
@end

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

    /* --- 0.6.2 新增的 5 套鼠须管官方配色：名字齐全 + BGR/RGB 换算防呆 --- */
    CHECK(names.count == 8, "内置 8 套主题（%lu）", (unsigned long)names.count);
    for (NSString *t in @[@"aqua", @"luna", @"ink", @"google", @"mojave_dark"]) {
        SFCandidateTheme *th = [SFCandidateTheme themeNamed:t];
        CHECK([th.name isEqualToString:t], "主题 %s 存在", t.UTF8String);
    }
    /* Rime 官方色值是 BGR，抄表时换算错位会让红蓝对调 ——
     * aqua/google/mojave_dark 的高亮块/底色都是蓝系，蓝分量必须大于红分量。 */
    SFCandidateTheme *aqua = [SFCandidateTheme themeNamed:@"aqua"];
    CHECK(aqua.selBack.blueComponent > aqua.selBack.redComponent, "aqua 高亮是蓝系（BGR 换算正确）");
    CHECK(aqua.back.alphaComponent < 1.0, "aqua 背板半透明（alpha %.2f）", aqua.back.alphaComponent);
    SFCandidateTheme *luna = [SFCandidateTheme themeNamed:@"luna"];
    CHECK(luna.back.alphaComponent < 1.0, "luna 背板半透明（alpha %.2f）", luna.back.alphaComponent);
    CHECK(luna.selBack.alphaComponent < 0.5, "luna 高亮块是 25% 黑");
    SFCandidateTheme *goog = [SFCandidateTheme themeNamed:@"google"];
    CHECK(goog.selBack.blueComponent > goog.selBack.redComponent, "google 高亮是蓝系");
    SFCandidateTheme *mjdk = [SFCandidateTheme themeNamed:@"mojave_dark"];
    CHECK(mjdk.back.blueComponent > mjdk.back.redComponent, "mojave_dark 底色偏蓝灰");
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
    CHECK([HUDText() containsString:@"网盘配置"], "引导指向「网盘配置…」菜单：%s", CStr(HUDText()));
    CHECK([gClient.output length] == 0, "未配置时不上屏");

    Fresh();
    CHECK(TypeKey(kVK_ANSI_D, mods) == YES, "Ctrl+Shift+D 被输入法消费");
    CHECK([HUDText() containsString:@"未配置网盘"], "恢复键同样给引导提示：%s", CStr(HUDText()));

    /* 状态栏菜单：四项（0.6.3 起第 1 项是编码提示开关）、动作选择器正确、target 指向控制器 */
    NSMenu *m = [gCtl menu];
    CHECK(m != nil && m.numberOfItems == 4, "菜单有四项（实际 %lu）",
          (unsigned long)(m ? m.numberOfItems : 0));
    if (!m) return;
    CHECK([m itemAtIndex:0].action == @selector(menuToggleCodeHint:) &&
          [m itemAtIndex:0].target == gCtl, "第一项 = 编码提示开关");
    CHECK([m itemAtIndex:1].action == @selector(menuWebDAVSyncUp:) &&
          [m itemAtIndex:1].target == gCtl, "第二项 = 同步到网盘");
    CHECK([m itemAtIndex:2].action == @selector(menuWebDAVSyncDown:) &&
          [m itemAtIndex:2].target == gCtl, "第三项 = 从网盘恢复");
    CHECK([m itemAtIndex:3].action == @selector(menuWebDAVConfig:) &&
          [m itemAtIndex:3].target == gCtl, "第四项 = 网盘配置…");
    CHECK([[m itemAtIndex:0].title containsString:@"编码提示"] &&
          [[m itemAtIndex:1].title containsString:@"同步"] &&
          [[m itemAtIndex:2].title containsString:@"恢复"] &&
          [[m itemAtIndex:3].title containsString:@"网盘配置"], "标题用中文动词，不写术语");
    /* 菜单项标题反映当前开关状态（默认关） */
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"CodeHint"];
    CHECK([[[gCtl menu] itemAtIndex:0].title containsString:@"关"],
          "关状态：菜单标题显示「关」");
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"CodeHint"];
    CHECK([[[gCtl menu] itemAtIndex:0].title containsString:@"开"],
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

    /* ⑤ 「网盘配置…」：文件不存在 → 先按模板生成；测试模式（conf 路径被
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
