# 07 · 连 macOS 都不要：纯 Windows 能走到哪一步

> 约束升级：**没有 Mac 设备，也没有 macOS 虚拟机，也没有云端 Mac**。机器上只有 Windows。
> 本文给出这条路的**可做部分（已实现并测试）**、**不可做部分的原理**，以及**想再往前推一步的路线**。

---

## 1. 先把「iOS App」拆成四件事，逐件看能不能在 Windows 完成

| # | 组成 | 依赖 | 纯 Windows 可行性 |
|---|---|---|---|
| 1 | **编译**：源码 → arm64 Mach-O | 编译器（clang/Swift）+ **iOS SDK** | 🟡 编译器可装；**SDK 只在 Xcode 里** |
| 2 | **资源**：Asset Catalog / storyboard / Metal | `actool` / `ibtool` / `metal` | ❌ 三个都是 macOS 二进制 |
| 3 | **打包**：`.app` 目录 + `Info.plist` + `.ipa` zip | 无 | ✅ 纯文件操作 |
| 4 | **签名**：CodeDirectory + CMS | 无（格式公开） | ✅ 已用 Python 实现并验证 |

结论一句话：**1 和 2 卡在「Apple 的工具链是 macOS 二进制」，3 和 4 完全能自己做。**

---

## 2. 本仓库已经做出来的（`ios.ps1 nomac`）

```
源码/占位 ──► Mach-O(arm64, iOS 17, LC_MAIN) ──► 代码签名 ──► .app ──► .ipa ──► 上传/OTA
             tools/machogen.py                tools/codesign_lite.py        Build-IosApp.ps1
```

| 组件 | 文件 | 做了什么 |
|---|---|---|
| Mach-O 生成 | `tools/machogen.py` | 写 `MH_MAGIC_64` + `__PAGEZERO/__TEXT/__LINKEDIT` + `LC_BUILD_VERSION(platform=iOS 17.0)` + `LC_MAIN` + `LC_LOAD_DYLIB(libSystem)` + `LC_CODE_SIGNATURE` 占位 |
| 代码签名 | `tools/codesign_lite.py` | `CodeDirectory v0x20400`（SHA-256、4096 页）、超级块、entitlements 特殊槽、`.p12` 的 **PKCS#7 分离签名** |
| 打包 | `scripts/xc/Build-IosApp.ps1` | 组 `.app`、写 `Info.plist`、zip 成 `.ipa`（`Payload/` 前缀 + 正斜杠） |
| 一键 | `scripts/ios.ps1 nomac` | 上面三步 + 回执 |

### 2.1 签名里最容易错的地方

`LC_CODE_SIGNATURE.datasize` 在**被哈希的头部里**，而它的值又取决于签名块长度；
签名块里的 CMS 长度会因 DER 编码抖动 ±1 字节 —— 直接迭代会震荡。本实现的解法：

1. 先估一个 `datasize`，算出页哈希与 `CodeDirectory`；
2. 用它对 CMS 签名，量出真实长度；
3. 取 `datasize = need + 64`（留余量），把 superblob 之后的区域**用 0 填充**；
   `superblob.length` 记录真实长度，尾部填充不影响校验（真 `codesign` 的 datasize 也常大于 blob 实际长度）。

### 2.2 实测输出（本机）

```
$ python tools/codesign_lite.py verify --binary build\xc\HelloIOSCms\HelloIOSCms.app\HelloIOSCms
superblob: 1453 bytes, 3 entries
  slot 0x0000 @ 36          <- CodeDirectory
  slot 0x0005 @ 353         <- Entitlements
  slot 0x10000 @ 675        <- CMS
CodeDirectory v0x20400 len=317 flags=0x0 ident=com.tongriyaotxt.helloios
  hashType=2 hashSize=32 pageSize=2^12 nCode=1 nSpecial=5 codeLimit=464
pages: 1 checked, all match
cms: present
RESULT: VALID
```

`tools/test-nomac-build.ps1` 六步全绿：Mach-O → 签名自校验 → IPA 结构 → CMS → OTA 清单 → mock 上传。

---

## 3. 卡点在哪：为什么「有界面的 App」做不出来

### 3.1 iOS SDK 是什么

`iPhoneOS.sdk` 里有三样东西，缺一不可：

| 内容 | 作用 | 没有它会怎样 |
|---|---|---|
| `usr/include/**` | C/ObjC 头文件（`UIKit/UIKit.h` 等） | `#import <UIKit/UIKit.h>` 直接失败 |
| `usr/lib/**/*.tbd` | 系统库的符号存根（链接期用） | 链接 `UIApplicationMain` 时找不到符号 |
| `usr/lib/swift/**/*.swiftmodule` | Swift 标准库/SwiftUI 的接口模块 | `import SwiftUI` 直接失败 |

这三样**只随 Xcode 分发**。所以：

```c
// 没有 SDK 时，这行就编不过：
#import <UIKit/UIKit.h>
```

而本仓库的 `samples/HelloIOS/main.c` 刻意不 import 任何头文件 —— 这是「无 SDK 编译」的现实边界。

### 3.2 资源工具链

| 工具 | 产物 | 为什么绕不开 |
|---|---|---|
| `actool` | `Assets.car` | App 图标、颜色、图片集；上架时缺它直接 `ITMS-90022` |
| `ibtool` | `.nib` | storyboard/xib；SwiftUI 不需要，但 UIKit 项目需要 |
| `metal` | `.metallib` | 自定义着色器 |

三者都是 macOS Mach-O 二进制，没有开源等价物（`actool` 的 `Assets.car` 格式是私有的，社区只能部分读）。

---

## 4. 想再往前推：三条可行路线（按代价排序）

### 路线 A：把 SDK 当「数据」拿到 Windows（仍不需要 Mac 设备）

SDK 是文件，不是程序。只要有 Apple ID，就可以在浏览器里下载 Xcode 的 `.xip`，然后在 Windows 上拆：

```powershell
# 1) 7-Zip 打开 .xip（xar 容器）
7z l Xcode_16.xip
# 2) xip 的 Content 是 pbzx 流：magic 'pbzx' + xz 分块
#    Windows 上可用 Python 拆（本仓库 tools/ 里那套思路：读块 → lzma 解 → cpio 解）
# 3) 目标只有三样：
#    .../iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk/usr/{include,lib}
#    .../usr/lib/swift/iphoneos/*.swiftmodule
```

拿到之后，配上 LLVM（clang + `ld64.lld`）就能：

```powershell
clang -target arm64-apple-ios17.0 -isysroot <iPhoneOS.sdk> -c app.m -o app.o
ld64.lld -arch arm64 -platform_version ios 17.0 17.0 -syslibroot <iPhoneOS.sdk> `
         -lSystem -lobjc -framework UIKit -e _main -o App
```

**能到哪**：可以写一个**真的用 UIKit 的 App**（手写 `UIApplicationMain` + ObjC 运行时），
装到真机上能跑。**仍然不行**：SwiftUI（要 Swift 前端 + 宏插件）、Asset Catalog、storyboard。

### 路线 B：自己写 `.tbd` 存根（不下载 SDK）

`.tbd` 是文本文件（YAML），列出符号名即可：

```yaml
--- !tapi-tbd
tbd-version: 4
targets: [ arm64-ios ]
install-name: '/usr/lib/libSystem.B.dylib'
exports:
  - targets: [ arm64-ios ]
    symbols: [ _printf, _exit, _malloc ]
...
```

给 `libSystem` / `libobjc` 手写存根，就能链接「只调用这几个函数」的程序。
代价：UIKit 的 ObjC 类符号（`_OBJC_CLASS_$_UIApplication`）要一个个列，实际项目不现实。

### 路线 C：把「编译」外包一次（最省事的现实解）

| 方式 | 需要 Mac 设备吗 | 时间 |
|---|---|---|
| GitHub Actions `macos-15` 跑一次 `xcodebuild` | ❌ 你名下没有 | 5 分钟配置 |
| 借朋友 Mac 十分钟 | ✅ | 一次性 |
| 二手 Mac mini M1 | ✅ | 一次性买断 |

**这条路不是「零 macOS」，而是「零 Mac 设备」**——如果你的底线是「不买/不租/不借硬件」，
云端 runner 依然满足（硬件是 Apple 的机房，你只提交代码）。

---

## 5. 能力矩阵（把这四种约束摊开）

| 约束 | 能做到 | 做不到 |
|---|---|---|
| 无 Mac 设备，可用云端 | 全部（含 SwiftUI 上架） | 断点调试、Instruments |
| 无 Mac 设备、无云端，本机 macOS 虚拟机 | 全部（慢） | 模拟器、Metal 加速 |
| **无 macOS 任何形态（本文）** | **结构合法的 IPA、真签名、上传、OTA、装机** | **有界面的 App、上架** |
| 同上 + 抽 Xcode SDK | UIKit App（手写 ObjC） | SwiftUI、Asset Catalog、storyboard |

---

## 6. 命令速查

```powershell
# 一键：Mach-O → 签名 → .app → .ipa
.\scripts\ios.ps1 nomac

# 用真证书（ASC 下发的分发证书，见 docs/02）
.\scripts\ios.ps1 nomac            # 先 export P12_PATH / P12_PASSWORD / TEAM_ID

# 分步骤
python .\tools\machogen.py -o .\build\xc\HelloIOS --identifier com.a.b --signature-size 8192
python .\tools\codesign_lite.py sign --binary .\build\xc\HelloIOS --identifier com.a.b `
        --team-id ABCDE12345 --entitlements .\build\xc\ent.plist --p12 .\secrets\dist.p12 --password ***
python .\tools\codesign_lite.py verify --binary .\build\xc\HelloIOS
.\scripts\xc\Build-IosApp.ps1 -BundleId com.a.b -Name HelloIOS -Build 3

# 全链路自测（6 步，不需要任何凭证）
.\tools\test-nomac-build.ps1
```

---

## 7. 诚实结论

> **能签、能打、能传、能装；不能画界面。**
>
> 「零 macOS 出一个可上架的 App」在 2026 年仍然不成立——不是因为签名或分发被 Apple 锁住（那两块已经被 REST API 打开了），
> 而是因为 `actool` / `ibtool` / `metal` / Swift 前端这四件工具本身只有 macOS 版本。
>
> 如果你要的是「不买 Mac 也能上架」，最省时间的组合是：**Windows 上开发 + 云端 macOS 编译 5 分钟 + Windows 上签名/上传/装机**（docs/00 路线 A）。

---

## 8. 附：这套实现顺带解决了什么

即使你最终走云端编译，这些代码也有用：

- `codesign_lite.py` 能在 Windows 上**离线验签**任何 IPA（拆开看 CodeDirectory、槽位、证书链），排查 `ITMS-90034` 这类问题不用打开 Xcode
- `machogen.py` 是理解 Mach-O 布局的最小例子，改 `LC_BUILD_VERSION` 就能造 tvOS/watchOS 目标
- 签名那块的不动点迭代（datasize ↔ CMS 长度）是 Apple 签名格式的真实约束，换成 `rcodesign` 也一样会遇到
