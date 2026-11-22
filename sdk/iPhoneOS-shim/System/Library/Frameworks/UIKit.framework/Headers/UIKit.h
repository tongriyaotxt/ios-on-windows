/* 没有 iOS SDK 时的 UIKit 头文件替身。
 *
 * 真正的 <UIKit/UIKit.h> 有几十万行；这个文件只声明「本示例真的用到」的东西：
 * ObjC 运行时入口 + UIApplicationMain。所有 UI 对象的创建都走 objc_msgSend，
 * 因此不需要为每个类链接 _OBJC_CLASS_$ 符号 —— 运行时按名字查就行。
 *
 * 这就是「不用 Xcode 也能编 UIKit App」的关键：UIKit 在设备上本来就有，
 * 编译期只需要知道符号长什么样，链接期只需要 .tbd 存根。
 */
#ifndef APPCORE_UIKIT_SHIM_H
#define APPCORE_UIKIT_SHIM_H

#include <stddef.h>

typedef void *id;
typedef void *SEL;
typedef void *Class;
typedef void *IMP;
typedef signed char BOOL;

typedef struct { double x, y, width, height; } CGRect;

/* ---- ObjC 运行时（真实符号在 /usr/lib/libobjc.A.dylib） ---- */
extern id objc_getClass(const char *name);
extern SEL sel_registerName(const char *name);
extern id objc_msgSend(id self, SEL op, ...);
extern id objc_msgSendSuper2(void *super, SEL op, ...);
extern Class objc_allocateClassPair(Class superclass, const char *name, size_t extraBytes);
extern void objc_registerClassPair(Class cls);
extern BOOL class_addMethod(Class cls, SEL name, IMP imp, const char *types);
extern void *objc_autoreleasePoolPush(void);
extern void objc_autoreleasePoolPop(void *pool);

/* ---- Foundation ---- */
extern id NSStringFromClass(Class cls);
extern void NSLog(id format, ...);

/* ---- UIKit ---- */
extern int UIApplicationMain(int argc, char *argv[], id principalClassName, id delegateClassName);

#endif
