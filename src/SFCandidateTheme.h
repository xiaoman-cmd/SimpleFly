#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/*!
 @class  SFCandidateTheme
 @brief  候选窗配色主题（一组颜色）。

 把原先写死在 SFCandidatePanel.m 顶部的配色宏抽成可运行时切换的对象。
 内置若干主题，按名字索引；用法：

     SFCandidateTheme *t = [SFCandidateTheme themeNamed:@"dark"];
     panel.theme = t;   // 之后的候选窗 / HUD 全部用这套色

 想加主题：往 SFCandidateTheme.m 的 kThemes 表里加一行 10 个色值即可，
 名字会自动出现在 allThemeNames，循环切换也会带上它。
 */
@interface SFCandidateTheme : NSObject

@property (nonatomic, copy,   readonly) NSString *name;       /* 主题名，用于 NSUserDefaults 存储 */
@property (nonatomic, strong, readonly) NSColor *back;        /* 候选窗背景 */
@property (nonatomic, strong, readonly) NSColor *candText;    /* 候选词条（非高亮） */
@property (nonatomic, strong, readonly) NSColor *label;       /* 次选编号 */
@property (nonatomic, strong, readonly) NSColor *selBack;     /* 高亮块底色 */
@property (nonatomic, strong, readonly) NSColor *selText;     /* 高亮候选词条 */
@property (nonatomic, strong, readonly) NSColor *selLabel;    /* 高亮编号 */
@property (nonatomic, strong, readonly) NSColor *codeText;    /* 编码行（页眉） */
@property (nonatomic, strong, readonly) NSColor *hairline;    /* 边框/分割线 */
@property (nonatomic, strong, readonly) NSColor *note;        /* 附注（音形码，非高亮） */
@property (nonatomic, strong, readonly) NSColor *selNote;     /* 附注（高亮） */

/*! 内置主题名列表（含默认的 metro）。循环切换 / 配置 UI 都用它。 */
+ (NSArray<NSString *> *)allThemeNames;

/*! 按名字取主题。名字不存在或为空时回退到 metro，不会返回 nil。 */
+ (SFCandidateTheme *)themeNamed:(nullable NSString *)name;

@end

NS_ASSUME_NONNULL_END
