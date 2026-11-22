# 08 · 补上最后一块：在 Windows 上真编译出 UIKit App

> `docs/07` 的结论是「能签、能打、不能画界面」。这一篇把它补上：
> **界面也是真的了** —— zig 编出 UIKit dylib，手写可执行体加载它，双层签名，装进 .ipa。

---

## 1. 为什么之前不行，这次怎么绕过去的

| 卡点 | 之前 | 现在 |
|---|---|---|
| 编译器 | 没装 LLVM（winget 拉 GitHub 超时） | **`pip install ziglang`** 拿到 zig 0.17.1，自带 clang 前端 + Mach-O 链接器 |
| iOS SDK | 没有头文件/存根 | **手写 `.tbd` 存根**（UIKit / Foundation / libobjc，各 1~6 个符号）+ 一个 30 行的 `UIKit.h` |
| 可执行文件链接 | — | zig 的链接器在「可执行文件 + 外部符号」时报 `could not calculate size of lazy binding section: Overflow` |
| 绕过办法 | — | **拆成 dylib + 迷你可执行体**：dylib 链接正常（实测 344 KB / 65 KB 都 OK），可执行体零外部符号 |
| 签名 | zig 产物没有 `LC_CODE_SIGNATURE` | `codesign_lite.py --inject` 自动插入该命令、扩展 `__LINKEDIT`，再走原来的签名流程 |

### 1.1 架构图

```
Payload/AppCore.app/
├─ AppCore                       ← machogen.py 生成；只有 2 条指令 + LC_LOAD_DYLIB
│    LC_LOAD_DYLIB @executable_path/Frameworks/AppCore.dylib
│    LC_BUILD_VERSION platform=iOS 17.0
│    LC_CODE_SIGNATURE（ad-hoc 或证书 CMS）
├─ Info.plist
└─ Frameworks/
   └─ AppCore.dylib              ← zig cc -target aarch64-ios -dynamiclib 真编译
        LC_LOAD_DYLIB /System/Library/Frameworks/UIKit.framework/UIKit
        LC_LOAD_DYLIB /System/Library/Frameworks/Foundation.framework/Foundation
        LC_LOAD_DYLIB /usr/lib/libobjc.A.dylib
        LC_LOAD_DYLIB /usr/lib/libSystem.B.dylib
        __attribute__((constructor)) → 注册 AppDelegate → UIApplicationMain(...)
        LC_CODE_SIGNATURE（ad-hoc 或证书 CMS）
```

dyld 的初始化顺序是「依赖先初始化」：UIKit 的 initializer 跑完后才轮到我们的 constructor，
所以此时 `UIApplicationMain` 可以安全调用（它自己会建立 run loop，永远不返回，`main` 不会被执行到）。

---

## 2. 实测证据（本机，零 macOS）

```powershell
$ .\scripts\xc\Build-IosAppNative.ps1 -Source .\samples\UIKitApp\AppCoreUI.m -Name AppCore -Build 5
==> zig cc -target aarch64-ios -dynamiclib .\samples\UIKitApp\AppCoreUI.m
    dylib: 65.9 KB
==> machogen 生成可执行体
wrote ...\AppCore: 16864 bytes, __LINKEDIT@480, entry=__text
==> 签名
  inject: 找不到 LC_CODE_SIGNATURE，自动插入
signed ...\AppCore: blob=229B codeLimit=480 pages=1
signed ...\AppCore.dylib: blob=685B codeLimit=67520 pages=17
RESULT: VALID  (外层)
RESULT: VALID  (内层, 17 页全对)
==> 打包 .ipa
IPA: .\build\xc\AppCore-native.ipa
```

机器可读的校验（`tools/test-nomac-build.ps1` 第 7 步）：

```
exe deps: ['@executable_path/Frameworks/AppCore.dylib']            LC_CODE_SIGNATURE: True
dylib deps: ['.../Foundation.framework/Foundation', '/usr/lib/libSystem.B.dylib',
             '.../UIKit.framework/UIKit', '/usr/lib/libobjc.A.dylib']
dylib platform: 2 (iOS)                                            LC_CODE_SIGNATURE: True
```

真正的 UI 代码（`samples/UIKitApp/AppCoreUI.m`）走的是标准 ObjC 运行时：

```objc
id screen = ((id(*)(id,SEL))objc_msgSend)(cls("UIScreen"), sel("mainScreen"));
CGRect bounds = ((CGRect(*)(id,SEL))objc_msgSend)(screen, sel("bounds"));
id window = ((id(*)(id,SEL))objc_msgSend)(cls("UIWindow"), sel("alloc"));
window = ((id(*)(id,SEL,CGRect))objc_msgSend)(window, sel("initWithFrame:"), bounds);
...
class_addMethod(delegate, sel("application:didFinishLaunchingWithOptions:"), (IMP)app_did_finish, "c@:@@");
UIApplicationMain(argc, argv, 0, NSStringFromClass(delegate));
```

---

## 3. 同类工作调研（GitHub / 公开资料）

别人解决的是同一类问题的不同切片，放在一起看很清楚「哪一块已经有人做了、哪一块还得自己写」：

| 项目 | 做什么 | 与本文的关系 |
|---|---|---|
| [tpoechtrager/osxcross](https://github.com/tpoechtrager/osxcross) | 在 Linux 上用「从 Xcode 里抽出的 SDK」交叉编译 macOS/iOS 程序；配套 `README.SDK` 讲怎么打包 SDK | 它的核心假设就是「SDK 是可搬运的文件」。本文的 `.tbd` 存根是这条路的极简版（不搬 SDK，只搬符号表） |
| [sweetpad-dev/sweetpad](https://github.com/sweetpad-dev/sweetpad) | VS Code 的 iOS 开发扩展；文档里专门有一节讲**在非 macOS 上准备 Apple 工具链**（SDK 传输） | 与本文定位最接近的工业级实现：它选择「把 Xcode 的 SDK 搬过去」，本文选择「不搬，靠运行时解析」 |
| [kateinoigakukun/swift-sdk-generator](https://github.com/kateinoigakukun/swift-sdk-generator) | 生成 Swift 交叉编译用的 SDK（stdlib + 模块） | SwiftUI/Swift 路线的钥匙：有它 + 官方 SDK 的 `.swiftmodule` 才可能在没有 Xcode 的机器上编 Swift |
| [facebook/xcbuild](https://github.com/facebook/xcbuild)（多个 fork 仍在维护） | 重写 `xcodebuild`：解析 `xcodeproj`/`xcconfig` 并在 Linux/macOS 上跑构建图 | 解决「工程文件解析」这一层；它仍然调用真实编译器与 `actool`，所以不能脱离 macOS 工具 |
| [rcodesign / apple-codesign](https://github.com/indygreg/apple-platform-rs) | Rust 写的跨平台签名工具（Mach-O、.p12、profile、公证） | 本文的 `codesign_lite.py` 是它的最小等价物；生产环境建议直接用它 |
| [Darling](https://github.com/darlinghq/darling) | 在 Linux 上跑 macOS 二进制（Darwin 翻译层） | 想直接跑 `actool`/`ibtool` 的唯一现实希望；目前对 GUI 工具链支持有限 |
| Theos（[theos/theos](https://github.com/theos/theos)） | 越狱生态的构建系统，Linux 上可用「下载的 iOS SDK + clang + ldid」 | 证明「不在 Mac 上编 iOS 二进制」早就成立，只是产物面向越狱/侧载 |

**从调研里得到的三条判断**

1. **「不需要 Mac 硬件」早已被证明**（osxcross / Theos）——真正稀缺的是「不需要 Xcode 的那几个闭源工具」（`actool`/`ibtool`/`metal`）。
2. 大家的一致做法是**搬 SDK**；本文证明了另一条：**只搬符号表**（`.tbd`），把解析推迟到 dyld 运行时。省掉 8 GB 下载，代价是没有编译期类型检查（头文件自己写）。
3. SwiftUI 这一层目前**没有**绕过方案：它需要 Swift 前端 + `swiftmodule` + 宏插件，三者都绑在 Xcode 上。想走这条路只能搬 SDK（sweetpad / osxcross 路线）。

---

## 4. 现在的能力矩阵

| 能力 | 状态 | 说明 |
|---|---|---|
| 编 C / Objective-C 到 arm64 iOS | ✅ | zig（clang 前端），`-target aarch64-ios` |
| 链接 UIKit / Foundation / libobjc | ✅ | 手写 `.tbd` 存根 + dylib 技巧 |
| 真实 UI（UIWindow / UILabel / 事件循环） | ✅ 编译层面 | 代码路径与 Xcode 产物一致；**真机运行待验证**（见 §5） |
| 代码签名（ad-hoc / 证书 CMS） | ✅ | 含 LC 注入，双层签名 |
| .ipa / 嵌套 Frameworks | ✅ | 已验证结构 |
| 上传 / OTA / 装机 | ✅ | docs/03、docs/04 |
| Asset Catalog（App 图标） | ❌ | `actool` 是 macOS 二进制。本地安装可用 `CFBundleIconFiles` 回退；上架需要 `Assets.car` |
| storyboard / xib | ❌ | `ibtool`。但**纯代码 UI 不需要它** |
| Metal 着色器 | ❌ | `metal` 编译器 |
| SwiftUI / Swift 源码 | ❌ | 需要 Swift 前端 + SDK 的 `.swiftmodule`（→ 搬 SDK 路线） |

---

## 5. 真机验证清单（拿到设备后按这个顺序做）

1. `.\scripts\ios.ps1 doctor` 确认 Apple 设备服务已装
2. 用真实分发证书重跑：`$env:P12_PATH=...; $env:TEAM_ID=...; .\scripts\xc\Build-IosAppNative.ps1 -Source ... -P12 $env:P12_PATH -Password $env:P12_PASSWORD -TeamId $env:TEAM_ID -Entitlements ent.plist`
3. `pymobiledevice3 apps install .\build\xc\AppCore-native.ipa`
4. `pymobiledevice3 syslog live --process AppCore` 看有没有 `dyld: Library not loaded`
5. 若报符号缺失 → 把缺的符号加进对应 `.tbd`（这是**唯一**需要迭代的地方）

> 最可能出问题的两处：`UIApplicationMain` 在 constructor 里被调用（若 UIKit 尚未就绪会黑屏）；
> dylib 未带 `LC_ID_DYLIB` 的 `@rpath` 安装名（dyld 会警告但通常仍能加载）。

---

## 6. 一句话

**「不能画界面」这条边界，现在是「不能画 SwiftUI 的界面」。**
C/ObjC + UIKit 的 App 已经可以全程在 Windows 上编出来、签好、打成 ipa、传上 App Store Connect。
剩下的三件（`actool`、`ibtool`、`metal`）是 Apple 的闭源工具，绕开它们的代价比自己写一个 Asset Catalog 打包器还高。
