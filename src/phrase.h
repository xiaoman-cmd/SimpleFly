/* phrase.h —— 用户自定义快捷输入（纯 C，无 UI 依赖，可单测）
 *
 * 场景：把一长串常用内容绑到一个短编码上，例如
 *      fmc = 凤满成
 *      dz  = 我的常用地址
 *
 * 与码表的关系：**自定义词条优先**。精确命中时排在候选窗最前面（第一项），
 * 空格或数字键上屏 —— 这正是 Rime custom_phrase 的语义，也保证永远不会
 * 因为用户自定义了某个编码就把码表原有候选顶掉。
 *
 * 文件格式（UTF-8，一行一条）：
 *      # 注释
 *      fmc = 凤满成
 *      dz<TAB>我的常用地址
 * 分隔符用 = 或制表符都行，编码前后空白会被去掉，编码一律转小写。
 */
#ifndef SF_PHRASE_H
#define SF_PHRASE_H

#include <stddef.h>

typedef struct SFPhrases SFPhrases;

/* 从文件加载。文件不存在 / 为空 → 返回 NULL（这不算错误，就是「没有自定义短语」）。 */
SFPhrases *sf_phrase_load(const char *path);

void   sf_phrase_free(SFPhrases *p);
size_t sf_phrase_count(const SFPhrases *p);

/* 精确匹配 code，把词条指针写进 out（最多 max 个），返回个数。
 * 返回的指针指向内部存储，调用方不要释放。同码多条时按文件顺序。 */
int sf_phrase_lookup(const SFPhrases *p, const char *code, const char **out, int max);

/* 有没有以 code 为前缀的自定义编码。
 *
 * 这个函数不是可有可无的：自定义 fmc=凤满成 时，用户敲到 f 码表有候选、
 * 敲到 fm 码表里什么都没有 —— 没有这个判断，输入法会在 fm 这一下判「空码」，
 * 回退并 beep，用户永远打不出 fmc。 */
int sf_phrase_has_prefix(const SFPhrases *p, const char *code);

/* 文件是否在加载之后被改过（按 mtime 判断）。改了就重载，不用重启输入法。 */
int sf_phrase_stale(const SFPhrases *p, const char *path);

/* 首次运行时写一份带说明的示例文件，免得用户猜格式。文件已存在则不动。 */
int sf_phrase_write_sample(const char *path);

#endif /* SF_PHRASE_H */
