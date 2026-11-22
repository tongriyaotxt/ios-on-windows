/* 一个真正的 UIKit App —— 全程在 Windows 上编译、链接、签名、打包。
 *
 * 没有 Xcode、没有 iOS SDK、没有 macOS：
 *   · 编译器/链接器：zig 自带 clang 前端 + Mach-O 链接器
 *   · 链接期符号：sdk/iPhoneOS-shim 里手写的 .tbd 存根（libUIKit / libobjc / libSystem）
 *   · 头文件：sdk/iPhoneOS-shim/System/Library/Frameworks/UIKit.framework/Headers/UIKit.h
 *
 * 为什么用 .tbd 存根：dyld 在设备上会真的加载 /System/Library/Frameworks/UIKit.framework/UIKit，
 * 编译期只需要知道「符号存在且类型是函数」。这就是不装 SDK 也能链接框架的全部秘密。
 *
 * ObjC 细节：
 *   · msgSend 必须按调用点强转（arm64 上结构体参数与可变参数的传递规则不同）
 *   · class_addMethod 的 type encoding 是 "返回值 self:_cmd 参数..."，BOOL 用 'c'
 */
#include <UIKit/UIKit.h>

static id cls(const char *name) { return objc_getClass(name); }
static SEL sel(const char *name) { return sel_registerName(name); }

/* application:didFinishLaunchingWithOptions: */
static BOOL app_did_finish(id self, SEL _cmd, id application, id launchOptions) {
    (void)self; (void)_cmd; (void)application; (void)launchOptions;

    id screen = ((id(*)(id, SEL))objc_msgSend)(cls("UIScreen"), sel("mainScreen"));
    CGRect bounds = ((CGRect(*)(id, SEL))objc_msgSend)(screen, sel("bounds"));

    id window = ((id(*)(id, SEL))objc_msgSend)(cls("UIWindow"), sel("alloc"));
    window = ((id(*)(id, SEL, CGRect))objc_msgSend)(window, sel("initWithFrame:"), bounds);

    id vc = ((id(*)(id, SEL))objc_msgSend)(cls("UIViewController"), sel("alloc"));
    vc = ((id(*)(id, SEL))objc_msgSend)(vc, sel("init"));

    id bg = ((id(*)(id, SEL))objc_msgSend)(cls("UIColor"), sel("systemBackgroundColor"));
    id view = ((id(*)(id, SEL))objc_msgSend)(vc, sel("view"));
    ((void(*)(id, SEL, id))objc_msgSend)(view, sel("setBackgroundColor:"), bg);

    id label = ((id(*)(id, SEL))objc_msgSend)(cls("UILabel"), sel("alloc"));
    CGRect frame = { 20.0, 120.0, 350.0, 160.0 };
    label = ((id(*)(id, SEL, CGRect))objc_msgSend)(label, sel("initWithFrame:"), frame);
    id text = ((id(*)(id, SEL, const char *))objc_msgSend)(
        cls("NSString"), sel("stringWithUTF8String:"),
        "Built on Windows\nzig + handwritten .tbd stubs");
    ((void(*)(id, SEL, id))objc_msgSend)(label, sel("setText:"), text);
    ((void(*)(id, SEL, long))objc_msgSend)(label, sel("setNumberOfLines:"), 2L);
    ((void(*)(id, SEL, id))objc_msgSend)(view, sel("addSubview:"), label);

    ((void(*)(id, SEL, id))objc_msgSend)(window, sel("setRootViewController:"), vc);
    ((void(*)(id, SEL))objc_msgSend)(window, sel("makeKeyAndVisible"));
    ((id(*)(id, SEL))objc_msgSend)(window, sel("retain"));
    return 1;
}

int main(int argc, char *argv[]) {
    Class delegate = objc_allocateClassPair(cls("NSObject"), "AppCoreDelegate", 0);
    if (!delegate) return 3;
    class_addMethod(delegate, sel("application:didFinishLaunchingWithOptions:"),
                    (IMP)app_did_finish, "c@:@@");
    objc_registerClassPair(delegate);
    return UIApplicationMain(argc, argv, (id)0, NSStringFromClass(delegate));
}
