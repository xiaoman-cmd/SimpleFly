/* SimpleFly —— 本机自用的小鹤音形 / 小鹤双拼输入法（macOS）。
 *
 * 进程入口：按 Info.plist 里的 InputMethodConnectionName 起一个 IMKServer，
 * 之后由系统为每个客户端会话创建 SimpleFlyInputController 实例。
 */
#import <Cocoa/Cocoa.h>
#import <InputMethodKit/InputMethodKit.h>

#import "SFInputController.h"
#include "phrase.h"

static IMKServer *gServer = nil;   /* 必须持有，IMKServer 自己不保活 */

/* 首次运行时把自定义快捷输入的示例文件写出来。
 * 用户不用去猜格式 —— 打开 ~/Library/Application Support/SimpleFly/phrase.txt
 * 把 "abc = 测试短语" 那一行改成自己要的就行，改完立即生效（不必重启输入法）。 */
static void SFEnsurePhraseSample(void)
{
    NSArray<NSString *> *dirs =
        NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString *base = dirs.firstObject ?: [@"~/Library/Application Support" stringByExpandingTildeInPath];
    NSString *dir  = [base stringByAppendingPathComponent:@"SimpleFly"];

    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:NULL];

    NSString *path = [dir stringByAppendingPathComponent:@"phrase.txt"];
    if (sf_phrase_write_sample(path.fileSystemRepresentation))
        NSLog(@"[SimpleFly] 自定义快捷输入示例已就绪 ← %@", path);
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        NSBundle *bundle = [NSBundle mainBundle];
        NSString *connectionName = [bundle objectForInfoDictionaryKey:@"InputMethodConnectionName"];
        NSString *bundleId       = [bundle bundleIdentifier];

        if (connectionName.length == 0 || bundleId.length == 0) {
            NSLog(@"[SimpleFly] Info.plist 缺少 InputMethodConnectionName 或 CFBundleIdentifier，无法启动");
            return 1;
        }

        /* --check：只加载码表并报告状态，然后退出。
         * 用来在不切换输入法的前提下确认码表读得到。 */
        if (argc > 1 && strcmp(argv[1], "--check") == 0) {
            SFEngine *engine = SFSharedEngine();
            if (!engine) {
                fprintf(stderr, "码表不可用：%s\n", sf_engine_last_error());
                return 1;
            }
            printf("码表可用：%zu 条 / %zu 个编码\n", sf_engine_size(engine), sf_engine_code_count(engine));
            return 0;
        }

        SFEnsurePhraseSample();

        /* 启动时就把码表读进来：加载失败会立刻写进日志，而不是等第一次按键才暴露 */
        (void)SFSharedEngine();

        gServer = [[IMKServer alloc] initWithName:connectionName bundleIdentifier:bundleId];
        if (!gServer) {
            NSLog(@"[SimpleFly] IMKServer 启动失败（连接名 %@）", connectionName);
            return 1;
        }

        NSLog(@"[SimpleFly] 已启动，连接名 %@", connectionName);
        [[NSApplication sharedApplication] run];
    }
    return 0;
}
