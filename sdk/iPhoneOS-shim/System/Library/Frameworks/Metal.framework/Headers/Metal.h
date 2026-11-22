/* Metal 的最小替身头文件。
 *
 * 关键点：**不需要 `metal` 编译器**。
 * Metal 支持在设备上用 `newLibraryWithSource:options:error:` 直接编译 MSL 源码字符串，
 * 所以我们可以把 .metal 源码当作普通资源打进 bundle，运行时再编译成 MTLibrary。
 * 这样「Metal 着色器」这一环就从「必须有 macOS 工具」降级成「打一段文本 + 一次运行时调用」。
 */
#ifndef APPCORE_METAL_SHIM_H
#define APPCORE_METAL_SHIM_H

#include <UIKit/UIKit.h>   /* 复用 id / SEL / objc_msgSend */

/* 设备上的真实符号（Metal.framework） */
extern id MTLCreateSystemDefaultDevice(void);

/* MTLCompileOptions 只是个对象，用 objc_msgSend 构造即可；
 * newLibraryWithSource:options:error: 的签名：
 *     id newLibraryWithSource:(NSString*)src options:(id)opts error:(id*)error
 */
#endif
