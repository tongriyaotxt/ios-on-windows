# Changelog

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号用 [SemVer](https://semver.org/lang/zh-CN/)。

## [Unreleased]

## [0.2.0] · 2026-11-22

### Added

- `tools/check-provisioning.py`：描述文件 ↔ 证书 ↔ bundle id ↔ entitlements ↔ UDID 五方一致性校验，支持 `--emit-entitlements`
- `scripts/release.ps1`：一条命令从源码到 TestFlight（校验 → 构建 → 审计 → 上传），`-DryRun` 无需凭证
- `py_tests/test_provisioning.py`：5 个正反用例（自造 CMS 描述文件，不需要 Apple 账号）
- `scripts/xc/Get-DeviceInfo.ps1`：插上手机自动读 UDID/名称/iOS 版本；`release.ps1 -AutoUdid` 自动带 UDID 校验
- `docs/15-SIGNING-CHAIN-AND-DEVICE.md`：签名链角色说明（私钥在本地、手机只验签、免费账号如何自动出证书）

### Changed

- 真证书路径实测：审计从 `FATAL=1 / HIGH=2` 变为 `FATAL=0 / HIGH=0`（用等价测试凭证）
- `audit-device.py` 退出码改为 0/1/2 约定

## [0.1.0] · 2026-11-22

第一个可用版本：Windows 上完成 iOS App 的编译、签名、打包、上传、分发、验证，全程不需要 macOS 设备。

### Added

- **交叉编译**：`tools/machogen.py`（arm64 Mach-O 生成，16KB 段对齐、`LC_LOAD_DYLINKER`/`LC_DYLD_INFO`/`LC_SYMTAB`/`LC_UUID` 齐全）、`scripts/xc/Build-IosAppNative.ps1`（zig `-target aarch64-ios` 编 UIKit dylib + 迷你可执行体）
- **代码签名**：`tools/codesign_lite.py`（CodeDirectory v0x20400、超级块、entitlements 槽、Info.plist 槽、真证书 CMS、`--inject` 注入 `LC_CODE_SIGNATURE`、页大小可切换）
- **打包**：`.app` 组装、图标全套（`tools/make-icons.py`）、`CFBundleIcons` 写入（`attach-icons.py`）、`_CodeSignature/CodeResources`（`make-resources.py`）、`.ipa`（正斜杠 + `Payload/` 前缀）
- **上传**：`scripts/asc-upload.ps1`（REST `buildUploads` 四步 + 轮询）、`scripts/lib/AscJwt.ps1`（openssl 签 ES256）、`scripts/asc-status.ps1`
- **分发**：`scripts/make-ota-manifest.ps1`（itms-services）、`scripts/ios.ps1 install`（pymobiledevice3/ideviceinstaller）
- **验证**：`tools/verify-ipa.py`（上架前 9 项校验）、`tools/audit-device.py`（真机启动审计）、`tools/sim-ios.py`（dyld + Unicorn ARM64 模拟执行）、`tools/xip-extract.py`（xar→pbzx→cpio）
- **工程**：`scripts/install.ps1`、`scripts/lint.ps1`、`py_tests/`（pytest）、`.github/workflows/ci.yml`、`requirements*.txt`、`PSScriptAnalyzerSettings.psd1`、`pyproject.toml`
- **调研**：`docs/13-PRIOR-ART.md`（osxcross / Theos / iosc / zsign / rcodesign / zig-ios-example 对照）
- **文档**：`docs/00`–`docs/13`（架构、签名、上传、设备、无 Mac 极限、零 Mac 全流程、原生工具链、缺口关闭、风险审计、无真机验证、工程约定）

### Known limitations

- SwiftUI 仍需 Xcode 的 `.swiftmodule`（`scripts/xc/Get-IosSdk.ps1` 可从 `.xip` 抽取）
- 真机安装需要 Apple 分发证书 + 描述文件（本仓库只做到 ad-hoc 签名为止）
- `zig` 的 iOS 目标是实验性用法，升级需重跑全链路自测
