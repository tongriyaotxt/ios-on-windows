# 文档索引

按阅读顺序编号。只想上手 → 直接看 [README](../README.md) 的第 3 节。

| # | 文档 | 一句话 |
|---|---|---|
| — | *(machine baseline report not included — it is host-specific)* | 本机基线体检（硬件、已装工具、缺口、网络实测） |
| 00 | [ARCHITECTURE.md](00-ARCHITECTURE.md) | 三条路线的取舍：云端 macOS / 租 Mac / 本机虚拟机 |
| 02 | [SIGNING-WINDOWS.md](02-SIGNING-WINDOWS.md) | 不打开 Xcode 造证书与描述文件（CSR→ASC→p12） |
| 03 | [UPLOAD.md](03-UPLOAD.md) | REST `buildUploads` 四步上传，从 Windows 直传 |
| 04 | [DEVICE.md](04-DEVICE.md) | 设备侧：驱动、pymobiledevice3、OTA 直装、日志 |
| 05 | [NO-MAC-AT-ALL.md](05-NO-MAC-AT-ALL.md) | 「一台 Mac 都没有」能走多远（含交叉编译边界实测） |
| 06 | [ZERO-MAC-VM.md](06-ZERO-MAC-VM.md) | 零 Mac 硬件：Windows 上跑 macOS 虚拟机编译 |
| 07 | [NO-MACOS-AT-ALL.md](07-NO-MACOS-AT-ALL.md) | 连 macOS 都不要：能力边界与四条绕行 |
| 08 | [NATIVE-TOOLCHAIN.md](08-NATIVE-TOOLCHAIN.md) | 突破：zig 真编译 UIKit + dylib 拆分 + LC 注入 + 同类项目调研 |
| 09 | [ALL-GAPS-CLOSED.md](09-ALL-GAPS-CLOSED.md) | 图标 / Metal / 校验器 / SDK 解包，四项收尾 |
| 10 | [DEVICE-FAILURE-AUDIT.md](10-DEVICE-FAILURE-AUDIT.md) | 真机启动风险清单（2 FATAL/8 HIGH → 只剩凭证类） |
| 11 | [NO-DEVICE-VERIFICATION.md](11-NO-DEVICE-VERIFICATION.md) | 不用真机：自写 dyld + ARM64 模拟器跑出证据 |
| 12 | [CONVENTIONS.md](12-CONVENTIONS.md) | 工程约定：退出码、命名、编码、改动流程、已知约束 |
| 13 | [PRIOR-ART.md](13-PRIOR-ART.md) | 同类项目调研：osxcross / Theos / iosc / zsign / rcodesign 等 |
| 14 | [RELEASE-PATH.md](14-RELEASE-PATH.md) | 剩下那一步：描述文件校验 + 一键发布（含等价凭证实测） |
| 15 | [SIGNING-CHAIN-AND-DEVICE.md](15-SIGNING-CHAIN-AND-DEVICE.md) | 私钥从哪来、手机能给什么（UDID）、免费账号怎么自动出证书 |
| 16 | [INSTALL-ON-DEVICE.md](16-INSTALL-ON-DEVICE.md) | **只要在手机上跑**：TrollStore / 免费 7 天 / 付费三条路 |

## 按问题找文档

| 我想… | 看 |
|---|---|
| 在 Windows 上装好这套工具 | [README §3](../README.md) + `scripts/install.ps1` |
| 编一个能跑的 App | [08](08-NATIVE-TOOLCHAIN.md) + `scripts/xc/Build-IosAppNative.ps1` |
| 签一个能装到手机上的包 | [02](02-SIGNING-WINDOWS.md) + [10](10-DEVICE-FAILURE-AUDIT.md) |
| 传到 App Store Connect | [03](03-UPLOAD.md) |
| 不经过 TestFlight 直接装 | [04](04-DEVICE.md)（OTA） |
| 搞清楚为什么起不来 | [10](10-DEVICE-FAILURE-AUDIT.md)（审计）+ [11](11-NO-DEVICE-VERIFICATION.md)（模拟） |
| 改代码前先知道规矩 | [12](12-CONVENTIONS.md) |
