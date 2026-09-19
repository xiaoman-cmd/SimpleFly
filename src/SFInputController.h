#import <InputMethodKit/InputMethodKit.h>

#include "engine.h"

/*!
 @class  SimpleFlyInputController
 @brief  InputMethodKit 前端：把按键喂给 SFEngine，显示候选，把选中的词条提交给客户端。

 一个 IMKInputController 实例对应一个客户端会话（窗口/输入框），
 所以编码缓冲等状态放在实例上，码表放在进程级单例上。
 */
@interface SimpleFlyInputController : IMKInputController
@end

/*!
 @function SFSharedEngine
 @brief    进程级码表单例（懒加载，线程安全）。
 @discussion 优先读 ~/Library/Application Support/SimpleFly/simplefly.dict，
            没有就用 app bundle 里的那份。加载失败返回 NULL，原因见 sf_engine_last_error()。
 */
SFEngine *SFSharedEngine(void);
