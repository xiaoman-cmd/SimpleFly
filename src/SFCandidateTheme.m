#import "SFCandidateTheme.h"
#include <string.h>

static NSColor *SFHex(uint32_t rgb)
{
    /* 6 位 0xRRGGBB = 不透明；8 位 0xAARRGGBB 高字节是 alpha（半透明候选窗用，
     * 窗口本身 opaque=NO + clearColor，支持透出底下的内容）。 */
    uint8_t a = (uint8_t)((rgb >> 24) & 0xFF);
    return [NSColor colorWithSRGBRed:((rgb >> 16) & 0xFF) / 255.0
                               green:((rgb >> 8) & 0xFF) / 255.0
                                blue:(rgb & 0xFF) / 255.0
                               alpha:a ? a / 255.0 : 1.0];
}

/* 每个主题一组 10 个色值（uint32 RGB），顺序与 SFCandidateTheme 的属性一一对应：
 *   back, candText, label, selBack, selText, selLabel, codeText, hairline, note, selNote
 *
 * 内置 13 款，分两组（数组顺序见下）：
 *
 *   【日间组 · 浅底深字】
 *   metro        浅色背景、青蓝高亮（对齐鼠须管 preset_color_schemes/metro，默认主题）
 *   jade         青玉：雾青底、青玉绿高亮（低饱和护眼，长时间码字不刺眼）
 *   blossom      桃夭：暖粉底、玫红高亮（柔和明快）
 *   linen        亚麻：中性暖白、深灰蓝高亮（几乎无色相干扰，比 metro 更「没存在感」）
 *   paper        暖白纸底、深棕字、暖橙高亮（偏「纸笔」观感）
 *   ink          墨池：白底黑字、墨黑高亮块（鼠须管 ink）
 *   contrast     极简高对比：纯黑白，对比度 21:1（视力障碍 / 强光 / 投屏）
 *
 *   【夜间组 · 深底浅字】
 *   dark         深灰底、浅字、靛蓝高亮（暗光环境下不刺眼）
 *   mojave_dark  沙漠夜：macOS 深灰底、系统蓝高亮（鼠须管 Mojave Dark）
 *   amber        琥珀：暖棕黑底、琥珀金高亮（整体压在橙黄区，蓝光最少，睡前用）
 *   neon         霓虹：近黑底、高饱和青绿高亮（赛博观感）
 *   retro        终端：近黑底、磷光绿（复古 CRT 观感）
 *   luna         明月：Rime 经典深色半透明黑、黄青高亮（鼠须管 luna）
 *
 * 0.8.0 移除了 aqua（碧水）与 google（谷歌）：三款里 metro/aqua/google 都是
 * 「浅底 + 蓝高亮」，辨识度几乎为零，主题一多反而挑花眼。老配置若仍写着这两个名字，
 * themeNamed 会回退 metro（控制器也会先校验 allThemeNames），不会拿到空配色。
 *
 * 注意两件事：
 *  ① Rime/鼠须管色值是 **BGR**（0xAABBGGRR），抄官方色值时必须换算成 RGB 再入表，
 *     否则红蓝对调；
 *  ② 6 位 hex = 不透明，8 位 = 高字节是 alpha（luna / ink 的半透明背板靠它）。
 * 测试里对这两点都有防呆（test_theme 的色相方向与亮度差断言）。 */
static const struct {
    const char *name;
    uint32_t c[10];
} kThemes[] = {
    /* 日间组（浅底深字）。数组顺序 = Ctrl+; 的循环顺序，刻意排成「前半浅、后半深」，
     * 循环切换时有一段昼夜过渡，而不是浅深浅深来回跳。 */
    { "metro",       { 0xFFFFFF, 0x000000, 0x555555, 0x009FE8, 0xFFFFFF, 0xEEEEEE, 0x333333, 0xE6E6E6, 0x8A8A8A, 0xD8D8D8 } },
    { "jade",        { 0xEDF2EF, 0x1E2A26, 0x74857E, 0x2E7D64, 0xFFFFFF, 0xC6E3D6, 0x4F615A, 0xD2DED8, 0x83938C, 0xA9D8C4 } },
    { "blossom",     { 0xFDF3F2, 0x2E2124, 0x8C7276, 0xC64C6B, 0xFFFFFF, 0xF6D6DE, 0x5E4A4E, 0xEEDCDD, 0x94807F, 0xEFC3CF } },
    { "linen",       { 0xF6F4F0, 0x26292E, 0x7A7F87, 0x3B4A5A, 0xFFFFFF, 0xC3CCD6, 0x545A63, 0xE2E0DA, 0x8A8F96, 0xB9C4CF } },
    { "paper",       { 0xFAF6EF, 0x2B2B2B, 0x6B6259, 0xC8772E, 0xFFF8EE, 0xF2E4D2, 0x5A534B, 0xE2D8C8, 0x9A8E7E, 0xE8D8C0 } },
    { "ink",         { 0xEEFFFFFF, 0x000000, 0x5A5A5A, 0xCC000000, 0xFFFFFF, 0xFFFFFF, 0x5A5A5A, 0xDDDDDD, 0x5A5A5A, 0x808080 } },
    { "contrast",    { 0xFFFFFF, 0x000000, 0x000000, 0x000000, 0xFFFFFF, 0xFFFFFF, 0x000000, 0x000000, 0x000000, 0xFFFFFF } },
    /* 夜间组（深底浅字） */
    { "dark",        { 0x1E1E1E, 0xD6D6D6, 0x8A8A8A, 0x3A7AFE, 0xFFFFFF, 0xE6E6E6, 0x9A9A9A, 0x3A3A3A, 0x707070, 0xC8C8C8 } },
    { "mojave_dark", { 0x202325, 0xDDDDDE, 0x858788, 0x005DCB, 0xFFFFFF, 0xFFFFFF, 0xDDDDDE, 0x020202, 0xDDDDDE, 0xDDDDDE } },
    { "amber",       { 0x2A2118, 0xE8DCC8, 0x9A8B74, 0xC98A2E, 0x241A0F, 0xF0D9A8, 0xB5A488, 0x463A2A, 0x9A8B74, 0xE8D2A0 } },
    { "neon",        { 0x0E1116, 0xC8D4E8, 0x5E6B82, 0x22D3C5, 0x04211F, 0x0E5A52, 0x7B8AA3, 0x232A36, 0x6C7A92, 0x0B4A44 } },
    { "retro",       { 0x0B0F0C, 0xB8D9BE, 0x4E6B52, 0x2BBF5E, 0x06180C, 0x0C4A22, 0x7FA886, 0x1E2A20, 0x5C7C63, 0x0A3D1E } },
    { "luna",        { 0xDD000000, 0xEEEEEC, 0xA5A5A5, 0x40000000, 0xFFFF7F, 0xFFFF7F, 0xA5A5A5, 0x444444, 0xA5A5A5, 0x9D9C44 } },
};

@implementation SFCandidateTheme {
    NSString *_name;
    NSColor *_back, *_candText, *_label, *_selBack, *_selText, *_selLabel,
            *_codeText, *_hairline, *_note, *_selNote;
}

- (instancetype)initWithName:(NSString *)name colors:(const uint32_t *)c
{
    if ((self = [super init])) {
        _name     = name;
        _back     = SFHex(c[0]);
        _candText = SFHex(c[1]);
        _label    = SFHex(c[2]);
        _selBack  = SFHex(c[3]);
        _selText  = SFHex(c[4]);
        _selLabel = SFHex(c[5]);
        _codeText = SFHex(c[6]);
        _hairline = SFHex(c[7]);
        _note     = SFHex(c[8]);
        _selNote  = SFHex(c[9]);
    }
    return self;
}

+ (NSArray<NSString *> *)allThemeNames
{
    NSMutableArray<NSString *> *a = [NSMutableArray array];
    for (size_t i = 0; i < sizeof(kThemes) / sizeof(kThemes[0]); i++)
        [a addObject:[NSString stringWithUTF8String:kThemes[i].name]];
    return a;
}

+ (SFCandidateTheme *)themeNamed:(NSString *)name
{
    if (name.length == 0) name = @"metro";
    for (size_t i = 0; i < sizeof(kThemes) / sizeof(kThemes[0]); i++) {
        if (strcmp(kThemes[i].name, name.UTF8String) == 0)
            return [[SFCandidateTheme alloc] initWithName:
                        [NSString stringWithUTF8String:kThemes[i].name]
                                                 colors:kThemes[i].c];
    }
    return [[SFCandidateTheme alloc] initWithName:@"metro" colors:kThemes[0].c];
}

@end
