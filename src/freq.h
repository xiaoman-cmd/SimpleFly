/* freq.h —— 重码记忆（纯 C，无 UI 依赖，可单测）
 *
 * 记「某个编码上次选了哪个词条」，下次查到同一编码时把它重排到第一位。
 * 解决的是：码表里 4,317 个编码有重码（其中 4,071 个是 2 候选），
 * 用户每天都在「按一次方向键再空格」和「直接空格赌一把」之间纠结。
 *
 * 与「词频自学习」的区别（这是刻意的设计边界，别模糊掉）：
 *   - 它是**单值记忆**：一个编码只记一个词，不是频次统计。可复现、可手改、清空即回默认。
 *   - 官方 flypy.schema.yaml 明写 enable_user_dict: false —— 小鹤音形的设计就是
 *     「一张静态码表，结果完全确定」，练出来的手感要可复现。频次自学习会让
 *     同一个码这次出 A、下次出 B，练码就白练了。单值记忆不改变候选集合，
 *     只在重码组内调整顺序，与官方设计取向不冲突（类似官方手改的 flypy_top.txt 置顶表）。
 *
 * 文件格式（UTF-8，一行一条，人可读可手改）：
 *      # 注释
 *      hc<TAB>好          ← 1751729000
 * 前两列是「编码 <TAB> 词条」，第三列是最后使用时间戳（可选，手写时可省略）。
 * 过期判断在**读入时**做：超过 SF_FREQ_TTL_DAYS 天没用的条目直接不收。
 *
 * 写回策略（在实现方，不在本模块）：debounce —— 进程退出/空闲时批量写，
 * 每次上屏都同步写文件会把 SSD 写爆（一次按键 = 一次 fsync 不是工程）。
 */
#ifndef SF_FREQ_H
#define SF_FREQ_H

#include <stddef.h>
#include <stdint.h>

typedef struct SFFreq SFFreq;

/* 加载。文件不存在 / 为空 / 全部过期 → 返回 NULL（「没有记忆」，不算错误）。 */
SFFreq *sf_freq_load(const char *path);

/* 造一个空记忆对象（文件还不存在、等第一次 put 时惰性创建用）。
 * path 会被复制，flush 没给路径时用它。失败返回 NULL。 */
SFFreq *sf_freq_new(const char *path);

/* 记忆条目的上限。超过就淘汰最久没用的 —— 重码编码全码表才 4,317 个，
 * 2,000 条足够覆盖一个人常打的所有重码，同时防止文件无限膨胀。 */
#define SF_FREQ_MAX_ITEMS 2000

void   sf_freq_free(SFFreq *f);
size_t sf_freq_count(const SFFreq *f);

/* 查这个编码记住了哪个词条。返回指向内部存储的指针（不随本对象销毁前失效），
 * 没记住返回 NULL。 */
const char *sf_freq_get(const SFFreq *f, const char *code);

/* 记住/更新一条（只在内存里改，sf_freq_flush 才落盘）。
 * code 和 text 都会被复制。同一个 code 再记一次就是覆盖。 */
void sf_freq_put(SFFreq *f, const char *code, const char *text, int64_t now);

/* 条目数超过 limit 时，把最久没用的淘汰掉（在 put 之后调用）。 */
void sf_freq_trim(SFFreq *f, size_t limit);

/* 把内存里的全部条目写回文件。path 为 NULL 时用加载时的路径。 */
int sf_freq_flush(SFFreq *f, const char *path);

/* 清空内存并删掉文件（ClearFreq 偏好用）。 */
int sf_freq_purge(const char *path);

#endif /* SF_FREQ_H */
