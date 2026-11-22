# iOS on Windows · 零 Mac 设备

[English](README.md) · [docs](docs/README.md) · [changelog](CHANGELOG.md)


> ## ⚠️ 状态：**从未在真机上运行过**
>
> 本仓库的一切验证都发生在 **Windows 上**：编译、链接、代码签名、`.app`/`.ipa` 打包、静态审计、
> 以及**模拟执行**（dyld + Unicorn ARM64 + 假 UIKit）。
>
> **没有任何一次构建在真实设备上启动过，也没有用 Apple 签发的证书签过名、没有向 Apple 上传过。**
> 请把它当作「有充分静态与模拟证据的原型」，不是「已交付的产品」。
>
> 仍待真机确认的两个假设见 [`docs/17`](docs/17-CRITIQUE.md) §1：dylib constructor 里调
> `UIApplicationMain`、以及 4KB 签名页大小。如果你跑通了，请按 [`CONTRIBUTING.md`](CONTRIBUTING.md) 的模板回报。
> 目标约束（按最严格解释）：**全程不出现任何 Mac 设备**——不买、不租、不借、不连别人的 Mac。
> 结论：**可以**。编译所需要的只有「macOS 这个软件」，不是「Mac 这台硬件」；把它跑成这台 PC 上的一个虚拟机即可。
> 其余环节（写码、单测、签名、上传、分发、装机、看日志）Windows 原生就能做，且已在本机自测通过。

---

## 1. 为什么能做到（2026 年的事实）

| 环节 | 曾经 | 现在 |
|---|---|---|
| 写代码 / 单测逻辑 | 任意平台 | ✅ Swift for Windows + SwiftPM |
| 编译 IPA | 必须 macOS | 🟡 必须 **macOS 软件**，但可跑在 Windows 的虚拟机里（本文路线） |
| 证书 / 描述文件 | Xcode 图形界面 | ✅ App Store Connect REST（`POST /v1/certificates`、`/v1/profiles`） |
| 上传二进制 | `xcrun altool`（macOS 二进制） | ✅ **`POST /v1/buildUploads`**（WWDC25，纯 HTTPS） |
| 分发 / 装机 | Xcode Devices 窗口 | ✅ TestFlight / `itms-services` OTA / `pymobiledevice3` |
| 日志 / 崩溃 | Console.app | ✅ `pymobiledevice3 syslog` / `crash pull` |

最关键的那一条：**上传搬进了 REST API**，所以「Windows 只能编不能传」的旧结论作废了。

---

## 2. 三条路线（都满足「无 Mac 设备」）

| 路线 | 编译在哪 | 有 Mac 硬件吗 | 首次跑通 | 长期成本 | 代价 |
|---|---|---|---|---|---|
| **① 本机 macOS 虚拟机**（默认推荐） | 这台 PC 上的 QEMU 客户机 | ❌ 完全没有 | 2–4 小时 | 电费 | 编译慢 2–5×，模拟器基本不可用 |
| ② 云端 macOS runner | 别人的 Mac（GitHub/Codemagic） | ❌ 你名下没有 | 半小时 | 免费额度 / 分钟计费 | 代码要推到云；断点调试没有 |
| ③ **零 macOS**（zig + 自造工具链） | 本机（zig 真编译 aarch64-ios） | ❌ | 1 小时 | 0 | 真 UIKit App + 图标 + Metal 着色器 + 签名 + 打包 + 校验；仅 SwiftUI 需抽 SDK |

- 路线 ① 的完整步骤：[`docs/06-ZERO-MAC-VM.md`](docs/06-ZERO-MAC-VM.md)
- 路线 ② 的配置：`.github/workflows/ios.yml`、`ci/codemagic.yaml`
- 路线 ③ 的边界实测：[`docs/05-NO-MAC-AT-ALL.md`](docs/05-NO-MAC-AT-ALL.md)
- 路线 ④ 的实现与实测（Mach-O / 代码签名 / .ipa 全在 Windows 造）：[`docs/07-NO-MACOS-AT-ALL.md`](docs/07-NO-MACOS-AT-ALL.md)
- 路线 ④ 的突破（zig 真编译 UIKit + dylib 拆分 + LC 注入 + 同类项目调研）：[`docs/08-NATIVE-TOOLCHAIN.md`](docs/08-NATIVE-TOOLCHAIN.md)
- 路线 ④ 的收尾（图标/Metal/校验器/SDK 解包，四项全解）：[`docs/09-ALL-GAPS-CLOSED.md`](docs/09-ALL-GAPS-CLOSED.md)
- 真机启动风险审计（2 FATAL/8 HIGH → 1 FATAL/2 HIGH，全部为凭证类）：[`docs/10-DEVICE-FAILURE-AUDIT.md`](docs/10-DEVICE-FAILURE-AUDIT.md)
- 不用真机的验证（自写 dyld + ARM64 模拟器，跑出启动链路与 CGRect ABI 证据）：[`docs/11-NO-DEVICE-VERIFICATION.md`](docs/11-NO-DEVICE-VERIFICATION.md)

---

## 3. 快速上手（路线 ①，零 Mac 设备）

```powershell
# ---- 一次性准备 ----
winget install SoftwareFreedomConservancy.QEMU 7zip.7zip
.\scripts\vm\New-MacVm.ps1 -OpenCoreDisk D:\vm\OpenCore.qcow2 -DryRun   # 先看计划
.\scripts\vm\New-MacVm.ps1 -OpenCoreDisk D:\vm\OpenCore.qcow2 -Launch   # 装 macOS（见 docs/06）

# ---- 每次发版 ----
.\scripts\ios.ps1 bump                          # build 号 +1，同步 App\project.yml
#   （客户机内）bash scripts/vm/macos-build.sh ~/src/ios-app 2
.\scripts\vm\Get-Artifact.ps1 -BundleVersion 2 -Upload   # 拉回来 + 直传 ASC
.\scripts\ios.ps1 status -BundleVersion 2                # 等 processingState=VALID
.\scripts\ios.ps1 ota -Ipa .\build\AppCore.ipa           # 或：不走 TestFlight，直接装
```

想用云端 macOS（路线 ②）就换成：

```powershell
.\scripts\ios.ps1 cloud -Target github
.\scripts\ios.ps1 download
.\scripts\ios.ps1 upload -Ipa .\build\AppCore.ipa
```

---

## 4. 仓库结构

```
Package.swift                 SwiftPM：AppCore 核心逻辑（Windows 上 swift build / swift test）
Sources/AppCore/              纯 Foundation 逻辑，任何平台可编译
Tests/AppCoreTests/           单测（Windows 跑一遍，CI 再跑一遍）
App/                          SwiftUI 壳，只在 macOS 里编译
  project.yml                 XcodeGen 描述（不提交 .xcodeproj）
  ExportOptions.plist         app-store-connect + destination=export
  Sources/AppMain.swift       @main + ContentView
scripts/
  ios.ps1                     ★ 总入口：doctor/bump/cloud/download/upload/status/ota/install/selftest
  check-toolchain.ps1         工具链体检（-Fix 修当前进程 PATH）
  lib/AscJwt.ps1              ASC 的 ES256 JWT（openssl 签名）
  lib/Bootstrap.ps1           .env 加载 + PATH 引导
  asc-upload.ps1              ★ REST buildUploads 四步上传 + 轮询
  asc-status.ps1              查 processingState
  make-ota-manifest.ps1       itms-services 清单 + install.html
  selftest-jwt.ps1            离线自检：造 .p8 → 签 JWT → 验签
  vm/New-MacVm.ps1            ★ QEMU 虚拟机创建/启动（-DryRun 可先看命令）
  vm/macos-build.sh           客户机内：xcodegen → xcodebuild → 起 http 服务
  vm/Get-Artifact.ps1         从客户机拉 IPA（hostfwd 8000）
tools/
  mock-asc-server.py          本地 ASC mock（校验 JWT/分片/重组哈希）
  machogen.py                 零 macOS：生成 arm64 iOS Mach-O（含 LC_BUILD_VERSION/LC_MAIN）
  codesign_lite.py            零 macOS：CodeDirectory + 超级块 + entitlements 槽 + 真证书 CMS 签名/验签
  test-nomac-build.ps1        零 macOS 全链路自测（7 步，含 zig 真编译）
  make-icons.py / attach-icons.py  全套 App 图标 + 写进 Info.plist（替代 actool 的散装路径）
  verify-ipa.py               App Store 校验器替身（结构/图标/Mach-O/依赖/签名）
  xip-extract.py              xar→pbzx→cpio 解 Xcode.xip，抽 iPhoneOS.sdk
  test-xip.py                 三层解包往返自测
  audit-device.py             真机启动审计：dyld/内核/amfid 会拒绝的每一项
  sim-ios.py                  dyld + ARM64 模拟器：在 Windows 上真跑 App 的启动链路
  make-resources.py           生成 _CodeSignature/CodeResources 资源信封
samples/UIKitApp/AppCoreUI.m   真 UIKit 界面（ObjC 运行时 + UIApplicationMain）
samples/HelloIOS/main.c        最小 C 源（验证交叉编译）
sdk/iPhoneOS-shim/            手写 iOS SDK 替身：UIKit.h + 三个 .tbd 符号存根
scripts/xc/Build-IosApp.ps1     零 macOS 打包（machogen 路径）
scripts/xc/Build-IosAppNative.ps1  zig 真编译 UIKit dylib → 双层签名 → 嵌套 .ipa
  test-upload.ps1             端到端上传自测
.github/workflows/ios.yml     macOS 编译 + 复用 scripts/asc-upload.ps1
ci/codemagic.yaml             备选 CI
fastlane/Fastfile             签名资产管理（Windows 可跑的那几个 lane）
VERSION                       MARKETING_VERSION / BUILD_NUMBER
docs/                         00 架构 · 02 签名 · 03 上传 · 04 设备 · 05 无 Mac 极限 · 06 零 Mac 全流程
```

---

## 5. 已验证 / 待你补凭证

| 项 | 状态 | 证据 |
|---|---|---|
| ES256 JWT（Windows 原生） | ✅ 已验 | `scripts/selftest-jwt.ps1` → 造 PKCS#8 → 签 → 公钥验签 PASS |
| 分片上传 + 重组 | ✅ 已验 | `tools/test-upload.ps1` → 5 MB / 4 片 / mock 端 sha256 一致 PASS |
| OTA 清单生成 | ✅ 已验 | 合成 zip IPA → 解析 bundle id/version → manifest.plist |
| `ios.ps1 bump` | ✅ 已验 | VERSION 1→2，project.yml 同步 |
| 工具链体检 | ✅ 已验 | 本机实跑：OK=11 / MISSING=10，逐项给修补命令 |
| 虚拟机创建脚本 | ✅ 已验（`-DryRun`） | 打印完整 QEMU 命令行；缺 QEMU/OpenCore 时标红并给安装命令 |
| 真机上传到 Apple | ⏳ 待 .p8 + App ID | 代码路径与 mock 完全一致 |
| 客户机内编译 | ⏳ 待装好 macOS | `macos-build.sh` 已写好 |
| 零 macOS 生成 Mach-O + 签名 | ✅ 已验 | `codesign_lite.py verify` → pages all match / RESULT: VALID
| 零 macOS IPA 结构 | ✅ 已验 | Payload/ 前缀、正斜杠、Info.plist 可解析
| 零 macOS 全链路 | ✅ 已验 | `tools/test-nomac-build.ps1` 六步全绿（含 CMS 与 OTA）
| zig 真编译 UIKit App | ✅ 已验 | dylib 依赖 UIKit/Foundation/libobjc，platform=iOS，双层签名 VALID |
| 图标 / Metal / 校验 | ✅ 已验 | 散装 PNG + 运行时 MSL + 9 项静态检查全绿（docs/09）
| SwiftUI | ⚠️ 需 SDK | 解包器已验，`Get-IosSdk.ps1` 一条命令抽 iPhoneOS.sdk |

### 还需要你补的三样（都不涉及 Mac 设备）

1. **App Store Connect API Key**（.p8 + Key ID + Issuer ID）→ `~\.appstoreconnect\private_keys\`
2. **Apple Developer Program**（$99/年）：TestFlight / ad-hoc / 上架必需
3. **Apple 设备驱动**：`winget install Apple.AppleDevices`（让 Windows 认 iPhone）

`.\scripts\ios.ps1 doctor` 会把这三样逐项标红，并给出一行修复命令。

---

## 6. 一句话

**Windows 干完写码 → 单测 → 签名 → 上传 → 分发 → 装机 → 看日志；编译交给这台 PC 上的 macOS 客户机，全程不出现任何 Mac 设备。**
