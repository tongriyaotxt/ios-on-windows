/* AppCore 的 UIKit 界面 + 运行时编译 Metal 着色器 —— 编译成 dylib 由可执行体加载。
 *
 * 三个「必须 macOS 工具」的替代方案，全在这里：
 *   actool     → 散装 PNG + CFBundleIcons（tools/make-icons.py 生成，verify-ipa.py 校验）
 *   metal      → 运行时用 newLibraryWithSource: 编译打进 bundle 的 .metal 源码
 *   ibtool     → 不用 storyboard，界面全用代码搭
 *
 * SwiftUI 是唯一没有等价物的一层：它需要 Swift 前端 + Apple 的 .swiftmodule，
 * 只能靠把 Xcode 的 SDK 搬过来（scripts/xc/Get-IosSdk.ps1）。
 */
#include <UIKit/UIKit.h>
#include <Metal/Metal.h>

static id cls(const char *name) { return objc_getClass(name); }
static SEL sel(const char *nm) { return sel_registerName(nm); }

/* ---------- 运行时编译着色器：等价于 `metal` 命令行 ---------- */
static id compile_shaders(void) {
    id device = MTLCreateSystemDefaultDevice();
    if (!device) return (id)0;

    id bundle = ((id(*)(id, SEL))objc_msgSend)(cls("NSBundle"), sel("mainBundle"));
    id path = ((id(*)(id, SEL, const char *, const char *))objc_msgSend)(
        bundle, sel("pathForResource:ofType:"), "Shaders", "metal");
    if (!path) return (id)0;

    id source = ((id(*)(id, SEL, id, long, id *))objc_msgSend)(
        cls("NSString"), sel("stringWithContentsOfFile:encoding:error:"), path, 4L, (id *)0);  /* NSUTF8StringEncoding = 4 */
    if (!source) return (id)0;

    id options = ((id(*)(id, SEL))objc_msgSend)(cls("MTLCompileOptions"), sel("new"));
    id error = (id)0;
    /* -[MTLDevice newLibraryWithSource:options:error:] */
    id library = ((id(*)(id, SEL, id, id, id *))objc_msgSend)(
        device, sel("newLibraryWithSource:options:error:"), source, options, &error);
    if (!library && error) {
        id desc = ((id(*)(id, SEL))objc_msgSend)(error, sel("localizedDescription"));
        ((void(*)(id, SEL, id))objc_msgSend)(cls("NSLog"), sel("log:"), desc);
    }
    return library;   /* 非 0 就说明 MSL 在设备上编译成功 */
}

static BOOL app_did_finish(id self, SEL _cmd, id application, id launchOptions) {
    (void)self; (void)_cmd; (void)application; (void)launchOptions;

    id shaderLibrary = compile_shaders();   /* 失败也不影响界面，只是没有自定义着色器 */

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
    CGRect frame = { 20.0, 120.0, 350.0, 180.0 };
    label = ((id(*)(id, SEL, CGRect))objc_msgSend)(label, sel("initWithFrame:"), frame);
    const char *msg = shaderLibrary
        ? "Built on Windows\nzig + .tbd stubs\nMSL compiled at runtime"
        : "Built on Windows\nzig + .tbd stubs\n(no GPU library)";
    id text = ((id(*)(id, SEL, const char *))objc_msgSend)(
        cls("NSString"), sel("stringWithUTF8String:"), msg);
    ((void(*)(id, SEL, id))objc_msgSend)(label, sel("setText:"), text);
    ((void(*)(id, SEL, long))objc_msgSend)(label, sel("setNumberOfLines:"), 3L);
    ((void(*)(id, SEL, id))objc_msgSend)(view, sel("addSubview:"), label);

    ((void(*)(id, SEL, id))objc_msgSend)(window, sel("setRootViewController:"), vc);
    ((void(*)(id, SEL))objc_msgSend)(window, sel("makeKeyAndVisible"));
    ((id(*)(id, SEL))objc_msgSend)(window, sel("retain"));
    return 1;
}

__attribute__((constructor)) static void appcore_boot(void) {
    Class delegate = objc_allocateClassPair(cls("NSObject"), "AppCoreDelegate", 0);
    if (!delegate) return;
    class_addMethod(delegate, sel("application:didFinishLaunchingWithOptions:"),
                    (IMP)app_did_finish, "c@:@@");
    objc_registerClassPair(delegate);

    int argc = 1;
    char *argv[] = { (char *)"AppCore", 0 };
    UIApplicationMain(argc, argv, (id)0, NSStringFromClass(delegate));
}
