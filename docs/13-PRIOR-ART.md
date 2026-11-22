# 13 · 同类项目调研

> 结论先说：**「不用 Mac 编 iOS」这件事有人做过（并且有几个成熟项目），但「从 Windows 走完
> 编译→签名→打包→上传→分发→验证」这一条完整链路，公开项目里没有等价的。**
> 我们和它们的关系是「互补」：它们解决某一段，本仓库把各段接起来并在 Windows 上验通。

---

## 1. 编译这一段

| 项目 | 做什么 | 和我们的关系 |
|---|---|---|
| [kubkon/zig-ios-example](https://github.com/kubkon/zig-ios-example) | 最小 `build.zig`，演示 zig 怎么 `-target aarch64-ios` 出 Mach-O | **直接印证**我们的编译选型：zig 的 iOS 目标不是我们瞎试的路 |
| [jmrico01/zig-ios-example](https://github.com/jmrico01/zig-ios-example) | 同上，更小的构建脚本 | 同上；可作为 build.zig 参考 |
| [tpoechtrager/osxcross](https://github.com/tpoechtrager/osxcross) | Linux 上用「从 Xcode 抽出的 SDK」交叉编译 macOS/iOS | 走「搬 SDK」路线；我们用「只搬符号表（.tbd）」路线，省 8 GB 但没类型检查 |
| [sweetpad-dev/sweetpad](https://github.com/sweetpad-dev/sweetpad) | VS Code 的 iOS 扩展，文档专讲非 macOS 准备 Apple 工具链 | 工业级方案，选择搬 SDK；我们是自造替代 |
| Theos | 越狱生态构建系统，Linux 上可用下载的 SDK + clang + ldid | 证明「不在 Mac 上编 iOS 二进制」早已成立，但产物面向越狱/侧载 |

**我们的差异**：不依赖 SDK 也能出可签名、结构合法的包；链接器溢出时用「dylib + 加载器」绕过。

## 2. 签名这一段

| 项目 | 做什么 | 和我们的关系 |
|---|---|---|
| [apple-platform-rs（rcodesign）](https://github.com/indygreg/apple-platform-rs) | Rust 写的跨平台 codesign / 公证 / p12 工具 | **生产级替代**；我们的 `codesign_lite.py` 是最小等价物，建议真上生产时换它 |
| [zhlynn/zsign](https://github.com/zhlynn/zsign)、[xibbon/zsign](https://github.com/xibbon/zsign)、[zsign-rust](https://github.com/nab138/zsign-rust) | C++/Rust 的 IPA 重签工具，Windows 可编译 | 我们没做「重签现成 ipa」，它擅长这块；两者可组合 |
| `ldid` | 越狱圈的老牌签名工具（ad-hoc + entitlements） | 只能 ad-hoc；我们支持真证书 CMS |

**我们的差异**：CodeDirectory 特殊槽（Info.plist / entitlements）、`LC_CODE_SIGNATURE` 注入、
datasize 与页哈希的不动点迭代 —— 这几处是自己摸出来的（见 `tools/codesign_lite.py` 注释）。

## 3. 整条链路

| 项目 | 做什么 | 和我们的关系 |
|---|---|---|
| [DiamondDeadMaw/iosc](https://github.com/DiamondDeadMaw/iosc) | **「Build, sign, and install arbitrary (ish) iOS apps from Windows」** | 定位最接近的一个项目。它偏「拿到别人的 ipa 重签 + 装进去」；我们把「自己写代码 → 编出二进制」也补上了 |
| [MobAI-App/ios-builder](https://github.com/MobAI-App/ios-builder) | 不用 Mac 开发：把构建丢给 GitHub Actions/Codemagic/Bitrise，配模拟器与热重载 | 走云端 macOS 路线（我们的路线 ②）；本仓库的路线 ④ 是「连云端 Mac 也不要」 |
| [facebook/xcbuild](https://github.com/facebook/xcbuild) | 重写 `xcodebuild` 的工程图解析 | 解决 `.xcodeproj` 解析；仍调用真编译器与 `actool`，离不开 macOS 工具 |
| [darlinghq/darling](https://github.com/darlinghq/darling) | 在 Linux 上跑 macOS 二进制 | 想直接跑 `actool`/`ibtool` 的唯一现实希望；GUI 工具链支持有限 |
| [kateinoigakukun/swift-sdk-generator](https://github.com/kateinoigakukun/swift-sdk-generator) | 生成 Swift 交叉编译 SDK | SwiftUI 路线的钥匙（我们的 `Get-IosSdk.ps1` 是它的前置：先把 SDK 弄到 Windows） |

## 4. 能力对照

| 能力 | osxcross | Theos | iosc | ios-builder | **本仓库** |
|---|---|---|---|---|---|
| 不需要 Mac 设备 | ✅ | ✅ | ✅ | ✅ | ✅ |
| 不需要云端 Mac | ✅ | ✅ | ✅ | ❌ | ✅ |
| 自己写代码 → 编二进制 | ✅（需 SDK） | ✅（需 SDK） | 🟡 | ❌（云端编） | ✅（无 SDK 也可） |
| 真证书签名 | 🟡 | 🟡 | ✅ | ✅ | ✅ |
| 上传 App Store Connect | ❌ | ❌ | ❌ | ✅（云端） | ✅（Windows 本地） |
| OTA 直装 | ❌ | 🟡 | ✅ | ❌ | ✅ |
| 静态校验 / 启动审计 | ❌ | ❌ | ❌ | ❌ | ✅ |
| 模拟执行验证 | ❌ | ❌ | ❌ | ❌（真模拟器） | ✅（dyld + Unicorn） |
| SwiftUI | ✅（搬 SDK） | ❌ | ❌ | ✅（云端 Xcode） | ❌（需 SDK，脚本已备） |

## 5. 从调研里得到的三条判断

1. **「不需要 Mac 硬件」早被证明**（osxcross / Theos / iosc），真正稀缺的是
   `actool` / `ibtool` / `metal` 这三个闭源工具 —— 我们用「散装图标 + 运行时编译 MSL + 纯代码 UI」绕开。
2. **大家默认「搬 SDK」**；本仓库证明了另一条：**只搬符号表**（`.tbd` + 手写头文件），
   代价是没有编译期类型检查，收益是零下载、零依赖。
3. **没有人做「验证」这一段**。上传靠 fastlane/altool，装机靠 ideviceinstaller，
   但「这个包在真机上会不会起不来」一直是靠人肉试。`verify-ipa.py` + `audit-device.py` + `sim-ios.py`
   是我们补的那块空白。

## 6. 如果要继续推进，优先接这几个

| 需求 | 直接用 | 我们的脚本怎么配 |
|---|---|---|
| 生产级签名 / 公证 | `rcodesign` | 替换 `codesign_lite.py` 的 sign/verify 子命令 |
| 重签第三方 ipa | `zsign` | `Build-IosAppNative.ps1` 之后加一步 |
| 真正的 SwiftUI | `swift-sdk-generator` + `Get-IosSdk.ps1` 抽出的 SDK | `-Sdk` 参数已就绪 |
| 云端构建兜底 | `ios-builder` 的思路 | `.github/workflows/ios.yml` 已实现同构流程 |
