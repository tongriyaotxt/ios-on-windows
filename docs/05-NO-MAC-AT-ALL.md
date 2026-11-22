# 05 · 彻底没有 Mac：能走多远

> 两条野路子：**(A) 在 Windows 里跑一台 macOS 虚拟机**（要编译就编译），
> **(B) 在 Windows 上交叉编译出 iOS 二进制**（不碰 macOS）。
> 结论先给：A 能干活但难伺候；B 只对「无 UI 的纯 Swift 产物」成立，做不出可上架的 App。
> 下面是把边界量出来的过程，方便你判断值不值得。

---

## A. Windows 上的 macOS 虚拟机（QEMU + OpenCore）

### A.1 前提

| 项 | 要求 |
|---|---|
| CPU | Intel VT-x 或 AMD-V 打开（本机 `HypervisorPresent=True`，满足） |
| 内存 | 给虚拟机 ≥ 12 GB（Xcode 编译吃内存） |
| 磁盘 | ≥ 80 GB（Xcode + 模拟器 runtime 就 40 GB+） |
| 系统 | Windows 11 + WSL2 可用（本机满足） |

### A.2 两条实现路径

**A.2.1 原生 QEMU + WHPX（Windows 直跑）**

```powershell
winget install SoftwareFreedomConservancy.QEMU

# macOS 安装镜像（Apple 官方 recovery，不是盗版 dmg）
# OpenCore 引导盘用 OSX-KVM 的 OpenCore.qcow2，SMBIOS 用 iMacPro1,1 之类
qemu-system-x86_64.exe `
  -machine q35,accel=whpx,kernel-irqchip=on -cpu host -smp 8 -m 16384 `
  -drive if=pflash,format=raw,file=OVMF_CODE.fd `
  -drive if=pflash,format=raw,file=OVMF_VARS.fd `
  -drive id=OpenCore,if=none,format=qcow2,file=OpenCore.qcow2 -device ide-hd,bus=sata.2,drive=OpenCore `
  -drive id=MacHDD,if=none,format=qcow2,file=macos.qcow2 -device ide-hd,bus=sata.3,drive=MacHDD `
  -netdev user,id=net0 -device e1000-82545em,netdev=net0 `
  -device VGA,vgamem_mb=64 -display sdl
```

**A.2.2 WSL2 里跑 KVM（嵌套虚拟化）**

```powershell
# Windows 侧
wsl --update
# .wslconfig 里加 nestedVirtualization=true（Win11 22H2+ 支持）
# WSL 里
sudo apt install qemu-system-x86 ovmf
ls -l /dev/kvm        # 有就说明嵌套 KVM 通了
```

> 实测经验：WHPX 路线在 Intel 上通常能起图形界面；AMD 需要 `-cpu host,hv-relaxed` 之类调整，
> 且模拟器（CoreSimulator）基本别想。**Xcode 能编译，模拟器不能用。**

### A.3 Xcode 怎么进去

Apple 的 Xcode 是 `.xip`（xz 压缩的 xar）。Windows 上可以解：

```powershell
# 7-Zip 能直接开 .xip
7z x Xcode_16.xip -oXcode16
# 解出来是 Xcode.app 目录树，整包拷进虚拟机的 /Applications
```

或者更省事：虚拟机里装好 macOS 后，直接用 Apple ID 从 App Store 下（需要 Apple ID，首次 12 GB）。

### A.4 现实预期（别被教程骗）

| 项 | 体验 |
|---|---|
| 首次安装 | 半天到两天（OpenCore 调参是玄学） |
| 编译速度 | 同代 CPU 的 40–70%，比 M 系列慢 3–5 倍 |
| 模拟器 | 基本不可用（无 Metal 加速） |
| Xcode 升级 | 每次大版本都可能把引导搞挂 |
| 稳定性 | 睡眠/唤醒、USB 直通、剪贴板共享都要单独修 |

**只在这一种情况下选它**：完全离线、且不允许代码离开本机。否则同样的时间成本，租一个月云 Mac 更划算。

---

## B. 纯 Windows 交叉编译 IPA：能到哪一步

### B.1 理论链路

```
swiftc(Windows) --target arm64-apple-ios17.0 -sdk <iOS SDK>  →  Mach-O 目标文件
lld -flavor darwin                                           →  可执行文件
手工组装 .app（Info.plist + 资源）                            →  bundle
rcodesign / zsign 签名                                        →  已签名 .app
zip 成 Payload/App.app                                       →  .ipa
```

### B.2 各部分实际可行性

| 组件 | 可行性 | 说明 |
|---|---|---|
| iOS SDK（头文件 + `.tbd`） | 🟡 可绕过 | 从 Xcode `.xip` 里 `7z` 抽出 `iPhoneOS.sdk`（合法与否是另一回事，这里只谈技术） |
| `swiftc` 交叉到 `arm64-apple-ios` | 🟡 部分可行 | Swift for Windows 的 clang 支持该 triple；但 Swift 运行时/标准库需要 iOS 版 `.swiftmodule`，得从 SDK 里带 |
| `lld` 产 Mach-O | ✅ 可行 | LLVM 自带 `ld64.lld`，`-fuse-ld=lld` |
| `codesign` | ✅ 替代品成熟 | `rcodesign`（Rust，跨平台）、`zsign`（C++，Windows 可编译） |
| **`actool`（Asset Catalog → Assets.car）** | ❌ | 只有 macOS 二进制。App 图标、颜色、图片集全挂在这上面 |
| **`ibtool`（storyboard/xib 编译）** | ❌ | 同上 |
| **`swift-frontend` 的 SwiftUI 支持** | ❌ | SwiftUI 框架本身在 SDK 里有，但 `@main`/宏展开依赖 macOS 侧插件 |
| **Metal 着色器编译（`metal`）** | ❌ | 只有 macOS |
| Xcode 的 `xcodebuild` 构建图 | ❌ | `.xcodeproj`/`Package.swift` 的 iOS 目标解析深度依赖 Xcode |

### B.3 所以边界是：

- ✅ **能做出**：纯 Foundation 的 CLI 风格产物、静态库、`.framework`、单测逻辑层
- ❌ **做不出**：任何带 Asset Catalog、storyboard、Metal、SwiftUI 宏的真实 App

换句话说：**这条路的产出物塞不进 App Store 的审核要求**（缺 `Assets.car` 直接 `ITMS-90022` 缺图标）。
它的真实用途是：在 CI 之外快速验证「iOS 目标的纯逻辑代码能否编译」，而不是交付。

### B.4 如果你想亲手摸一下边界（最小可跑实验）

```powershell
# 1) 装 Swift for Windows（download.swift.org 可达，见 网络实测（见 docs/12））
winget install Swift.Toolchain

# 2) 从 Xcode.xip 抽出 iOS SDK（只在本机验证用）
7z x Xcode_16.xip -oXcode16 "Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk/*"

# 3) 试编一个不依赖 UIKit 的文件
$sdk = "F:\Xcode16\Xcode.app\Contents\Developer\Platforms\iPhoneOS.platform\Developer\SDKs\iPhoneOS.sdk"
swiftc -target arm64-apple-ios17.0 -sdk $sdk -emit-executable -o hello.out .\Sources\AppCore\AppCore.swift
#   → 会止步于链接/运行时模块缺失，这正是「能到哪一步」的证据

# 4) 签名（拿现成 .app 试）
rcodesign sign --p12-file .\secrets\dist.p12 --p12-password $env:P12_PASSWORD .\Payload\AppCore.app
```

---

## C. 「没有 Mac」但也不折腾的三条替代

| 方案 | 一句话 |
|---|---|
| **GitHub Actions macOS runner** | 免费额度够个人项目，`gh workflow run` 一条命令触发，产物 `gh run download` 拉回 |
| **Codemagic / Appcircle** | 有免费额度，签名托管更省心 |
| **EAS Build** | Expo/RN 工程可做到「零接触证书」：`eas build -p ios` + `eas submit` |

---

## D. 结论表

| 你想要 | 选 |
|---|---|
| 快速上架 / 日常开发 | 路线 A（云端 macOS + 本仓库脚本） |
| 要断点调试、性能分析 | 路线 B（租 Mac / 买 Mac mini） |
| 完全离线、隔离环境 | 路线 C（Windows 里的 macOS 虚拟机） |
| 只想验证纯 Swift 逻辑能否为 iOS 编译 | B.4 的最小实验（不要指望出 IPA） |
