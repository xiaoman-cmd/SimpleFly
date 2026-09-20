#import <Cocoa/Cocoa.h>
#import "SFCandidateTheme.h"

NS_ASSUME_NONNULL_BEGIN

/*!
 @class  SFCandidate
 @brief  一条候选。

 `note` 是跟在词条后面的小字附注。「查编码」模式下用它显示该字的音形码，
 例如「好 hc·nz」（中点左边是音码、右边是形码）；普通输入时为 nil。
 */
@interface SFCandidate : NSObject
@property (nonatomic, copy) NSString *text;
@property (nonatomic, copy, nullable) NSString *note;
+ (instancetype)text:(NSString *)text note:(nullable NSString *)note;
@end

/*!
 @class  SFCandidatePanel
 @brief  自绘候选窗（metro 主题）。

 刻意不用系统自带的 IMKCandidates：它在近几代 macOS 上定位/刷新行为不稳定，
 而自绘一个无边框 NSPanel 的成本很低（本文件即全部代码）。

 视觉规格逐条对齐鼠须管的 `preset_color_schemes/metro` 主题（见 .m 顶部注释）。
 */
@interface SFCandidatePanel : NSObject

/*! 当前配色主题。默认 metro；切主题时由控制器赋值（[SFCandidateTheme themeNamed:]）。
 *  每次显示候选 / HUD 前会同步给内部绘制视图，所以赋值后下一次绘制即生效。 */
@property (nonatomic, strong) SFCandidateTheme *theme;

/*! 底部编码提示行：非空时候选窗文字底下多显示一行这个小字（当前高亮候选的音形码）。
 *  控制器按 CodeHint 开关算好传入；空/nil = 不显示（高度还原）。HUD 模式自动隐藏。 */
@property (nonatomic, copy, nullable) NSString *codeHint;

/*! 候选窗一页放几条 —— 3 行 × 9 列 = 27。
 *
 * 普通组字最多 9 条（码表一次就查这么多），永远只有一页；
 * 「查编码」会一次列出同音的一整族（hao 42 个、yi 199 个），多了要翻页。
 * 翻页不是靠额外的按键：方向键移动高亮，一页放不下时**高亮越过分页边界就自动翻页**，
 * 所以 ↑↓←→ 四个键在单页和多页下语义完全一样（都是一维 -1 / +1）。
 * 页面由高亮所在位置推出来，不单独记状态 —— 少一个会不同步的变量。 */
+ (NSUInteger)pageSize;                                       /* 27 */
+ (NSUInteger)pageCountFor:(NSUInteger)count;                 /* 总页数（count=0 时为 0） */
+ (NSRange)pageRangeForSelected:(NSUInteger)selected          /* 高亮落在哪一页 */
                          count:(NSUInteger)count;

/*! 显示候选。
 @param candidates 候选列表（非空）
 @param code       当前编码，画在候选左边。开了「编码嵌入输入框」（metro 的 inline_preedit）时传空串
 @param selected   高亮第几项（方向键移动的就是它）。越界会被夹到合法范围
 @param topLeft    候选窗左上角在屏幕坐标系的位置 */
- (void)showCandidates:(NSArray<SFCandidate *> *)candidates
                  code:(NSString *)code
              selected:(NSUInteger)selected
             atTopLeft:(NSPoint)topLeft;

/*! 模式提示（中文/英文、半角/全角…）。短暂显示后自动消失，不打断输入。
 *  accent=YES 时用高亮色，用来区分「非默认状态」。 */
- (void)showHUD:(NSString *)text accent:(BOOL)accent atTopLeft:(NSPoint)topLeft;
- (void)showHUD:(NSString *)text accent:(BOOL)accent seconds:(NSTimeInterval)secs
       atTopLeft:(NSPoint)topLeft;

- (void)hide;
- (BOOL)isVisible;

@end

NS_ASSUME_NONNULL_END
