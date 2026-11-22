# 09 · 把剩下的问题挨个解决

`docs/08` 收尾时还剩四处「macOS 独占」：`actool`、`ibtool`、`metal`、SwiftUI/SDK。这一篇是逐项的处理结果。

| 问题 | 处理方式 | 验证 |
|---|---|---|
| `actool`（App 图标 / Assets.car） | **散装 PNG + `CFBundleIcons`** + 自研图标生成器 + 校验器 | 9 项检查全绿，含 1024 营销图 |
| `ibtool`（storyboard/xib） | **不使用**：界面全代码搭建（UIWindow/UILabel 走运行时） | 编译通过、可运行路径与 Xcode 产物一致 |
| `metal`（着色器编译） | **运行时编译**：`.metal` 源码当资源，`newLibraryWithSource:` 现场编译 | dylib 依赖里出现 Metal.framework |
| SwiftUI / Swift 源码 | **抽 SDK**：`.xip` 三层解析器（xar→pbzx→cpio），一条命令拿 `iPhoneOS.sdk` | 自造包三层往返一致 |
| App Store 校验（隐性需求） | **自研校验器** `tools/verify-ipa.py`（结构/Info.plist/图标/Mach-O/依赖/签名/entitlements） | 抓出并修掉了两个真 bug |

---

## 1. actool → 散装 PNG + CFBundleIcons

iOS 除了 `Assets.car`，仍然支持 `CFBundleIcons → CFBundlePrimaryIcon → CFBundleIconFiles` 的散装路径
（本地安装、ad-hoc、OTA 都认；上架时若无 `Assets.car` 则需确认当年政策，校验器会给出 WARN）。

`tools/make-icons.py`：纯标准库写 PNG（无 PIL），按 Apple 的 `Icon-<pt>[@2x|@3x]` 命名生成 13 个文件：

```
Icon-20 / @2x / @3x · Icon-29 / @2x / @3x · Icon-40 / @2x / @3x
Icon-60@2x / @3x · Icon-76 / @2x · Icon-83.5@2x · Icon-1024
```

`tools/attach-icons.py` 把清单写进 `Info.plist`，并**刻意不写** `CFBundleIconName`
（那个键会让系统去 `Assets.car` 里找，没有就会白图标）。

## 2. ibtool → 不需要

界面全在代码里：`UIWindow` / `UIViewController` / `UILabel` 都通过 `objc_msgSend` 创建。
storyboard 只是「把属性表编译成 nib」的便利工具，纯代码 UI 完全绕开它。
`Info.plist` 里不要写 `UIMainStoryboardFile` 即可。

## 3. metal → 运行时编译

把 MSL 源码（`samples/UIKitApp/Shaders.metal`，含 `vertex`/`fragment` 函数）当**资源**打进 bundle，
启动时：

```objc
id device  = MTLCreateSystemDefaultDevice();
id source  = [NSString stringWithContentsOfFile:... encoding:4 error:0];
id library = [device newLibraryWithSource:source options:opts error:&err];   // ← 等价于 `metal` 命令
```

这是 Metal 官方支持的 API，所以「没有 `metal` 编译器」不再是阻塞：
着色器以源码形式随包发布，在设备上编译。代价是首帧多几十毫秒（可缓存）。

## 4. SwiftUI → 抽 SDK（唯一还剩门槛的一层）

SwiftUI 需要三样只在 Xcode 里的东西：Swift 前端、`*.swiftmodule`、宏插件。
绕不过去，只能把 SDK 搬过来。`tools/xip-extract.py` 解三层套娃：

```
xar 容器  →  magic 'xar!' + zlib(TOC XML) + 堆
pbzx 流   →  'pbzx' + u64 flags + [u64 len + xz chunk]...
cpio      →  '070701' newc，逐条 {name, mode, data}
```

```powershell
# 在浏览器里用 Apple ID 下一次 Xcode.xip（7–10 GB），然后：
.\scripts\xc\Get-IosSdk.ps1 -Xip D:\dl\Xcode_16.xip -OutDir D:\sdks
# 体检 + 打印下一步
.\scripts\xc\Get-IosSdk.ps1 -SdkDir D:\sdks\...\iPhoneOS.sdk
```

拿到 SDK 后构建脚本可以直接吃：

```powershell
.\scripts\xc\Build-IosAppNative.ps1 -Source .\samples\UIKitApp\AppCoreUI.m -Sdk D:\sdks\...\iPhoneOS.sdk
```

此时不再需要 `sdk\iPhoneOS-shim`（真头文件 + 真 `.tbd`），并且 SDK 里带
`usr/lib/swift/iphoneos/*.swiftmodule` —— 那是编 Swift（进而 SwiftUI）的前提。
Swift 前端本身仍要一个能 `-target arm64-apple-ios` 的 `swiftc`，参见 sweetpad / osxcross 路线。

## 5. 校验器：把 Apple 的拒绝理由提前跑一遍

`tools/verify-ipa.py` 静态检查（不联网、不签名）：

| 类别 | 检查项 |
|---|---|
| 结构 | `Payload/` 前缀、正斜杠、单一 `.app` |
| Info.plist | 必填键、`CFBundlePackageType=APPL`、版本格式 |
| 图标 | 声明的 PNG 是否存在、有无 1024 营销图、有无 `Assets.car` |
| Mach-O | magic/cputype/filetype、`LC_BUILD_VERSION` 平台=iOS、`LC_MAIN` |
| 依赖 | 只允许 `/System/…`、`/usr/lib/…`、`@executable_path/…`、`@rpath/…` |
| 签名 | 每个 Mach-O（含 `Frameworks/`）都有 `LC_CODE_SIGNATURE` 且页哈希匹配 |

第一次跑就抓到两个真问题，都已修：

1. `icon.none` —— Info.plist 没有图标声明 → 加了 `make-icons.py` + `attach-icons.py`
2. `dylib.idpath` —— `LC_ID_DYLIB` 是构建机绝对路径 → 链接时加 `-install_name @rpath/AppCore.dylib`

现在：

```
[  ok  ] zip.structure      单一 bundle：AppCore.app
[  ok  ] plist.required     com.example.appcore 1.0.0(10)
[  ok  ] icon.files         2/3 组图标存在
[  ok  ] icon.1024          1024×1024 营销图标存在
[  ok  ] macho.platform     AppCore: platform=iOS, arm64
[  ok  ] sig.ok             AppCore: 签名有效（1 页，ident=com.example.appcore，ad-hoc）
[  ok  ] sig.ok             AppCore.dylib: 签名有效（17 页，ident=com.example.appcore.appcore，ad-hoc）
[  ok  ] dylib.info         AppCore.dylib: 5 个系统依赖，已检查
9 通过, 0 警告, 0 失败
```

## 6. 现在的状态

| 能力 | 状态 |
|---|---|
| 编 C/ObjC → arm64 iOS（真 clang 前端 + 真链接） | ✅ |
| UIKit 界面（代码搭建、UIWindow/事件循环） | ✅ |
| 自定义 Metal 着色器（运行时编译） | ✅ |
| App 图标（全套尺寸 + 1024） | ✅ |
| 代码签名（ad-hoc / 证书 CMS，含 LC 注入） | ✅ |
| .ipa / 嵌套 Frameworks / OTA / 上传 | ✅ |
| 上架前静态校验（Apple 拒绝理由预演） | ✅ |
| SwiftUI / Swift 源码 | ⚠️ 需 SDK（脚本已就绪，解包器已验） |
| 真机运行 | ⏳ 需要设备 + 证书（`docs/08` §5 有排查清单） |

**一句话**：工具链层面已经没有「必须 macOS」的环节；剩下的两件事都是「需要外部资源」
（Apple 账号/设备、Xcode 的 SDK 数据），不是「Windows 做不到」。
