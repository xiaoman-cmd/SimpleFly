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
 * 颜色取值说明（沿用 metro 原始注释的 BGR→RGB 换算）：
 *   metro        浅色背景、青蓝高亮（对齐鼠须管 preset_color_schemes/metro）
 *   dark         深灰底、浅字、靛蓝高亮（暗光环境下不刺眼）
 *   paper        暖白纸底、深棕字、暖橙高亮（偏「纸笔」观感）
 *   aqua         碧水：浅色半透明背板、亮蓝高亮（鼠须管 aqua，原值 0xAABBGGRR 已换算）
 *   luna         明月：Rime 经典深色半透明黑、黄青高亮（鼠须管 luna）
 *   ink          墨池：白底黑字、墨黑高亮块（鼠须管 ink）
 *   google       谷歌：白底、Google 蓝高亮（鼠须管 google）
 *   mojave_dark  沙漠夜：macOS 深灰底、系统蓝高亮（鼠须管 Mojave Dark）
 *
 * 注意：Rime/鼠须管色值是 **BGR**（0xAABBGGRR），抄官方时必须换算成 RGB 再入表，
 * 否则红蓝对调 —— 测试里有「selBack 蓝分量必须最大」的断言防呆（test_theme）。 */
static const struct {
    const char *name;
    uint32_t c[10];
} kThemes[] = {
    { "metro",       { 0xFFFFFF, 0x000000, 0x555555, 0x009FE8, 0xFFFFFF, 0xEEEEEE, 0x333333, 0xE6E6E6, 0x8A8A8A, 0xD8D8D8 } },
    { "dark",        { 0x1E1E1E, 0xD6D6D6, 0x8A8A8A, 0x3A7AFE, 0xFFFFFF, 0xE6E6E6, 0x9A9A9A, 0x3A3A3A, 0x707070, 0xC8C8C8 } },
    { "paper",       { 0xFAF6EF, 0x2B2B2B, 0x6B6259, 0xC8772E, 0xFFF8EE, 0xF2E4D2, 0x5A534B, 0xE2D8C8, 0x9A8E7E, 0xE8D8C0 } },
    { "aqua",        { 0xEEEEECEC, 0x000000, 0x606060, 0xEE0A3AFA, 0xFFFFFF, 0xFFFFFF, 0x606060, 0xCDCBCB, 0x5A5A5A, 0x9DACFC } },
    { "luna",        { 0xDD000000, 0xEEEEEC, 0xA5A5A5, 0x40000000, 0xFFFF7F, 0xFFFF7F, 0xA5A5A5, 0x444444, 0xA5A5A5, 0x9D9C44 } },
    { "ink",         { 0xEEFFFFFF, 0x000000, 0x5A5A5A, 0xCC000000, 0xFFFFFF, 0xFFFFFF, 0x5A5A5A, 0xDDDDDD, 0x5A5A5A, 0x808080 } },
    { "google",      { 0xFFFFFF, 0x000000, 0x666666, 0x3975CE, 0xFFFFFF, 0xFFFFFF, 0x666666, 0xE2E2E2, 0x6D6D6D, 0xB0C6EB } },
    { "mojave_dark", { 0x202325, 0xDDDDDE, 0x858788, 0x005DCB, 0xFFFFFF, 0xFFFFFF, 0xDDDDDE, 0x020202, 0xDDDDDE, 0xDDDDDE } },
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
