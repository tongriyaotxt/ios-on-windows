# iOS on Windows — compile, sign, package, verify. No Mac.

[![ci](https://github.com/tongriyaotxt/ios-on-windows/actions/workflows/ci.yml/badge.svg)](https://github.com/tongriyaotxt/ios-on-windows/actions/workflows/ci.yml)

[中文说明](README.zh-CN.md) · [docs](docs/README.md) · [contributing](CONTRIBUTING.md) · [changelog](CHANGELOG.md)

A toolkit that builds a **real UIKit iOS app entirely on Windows** — no Mac, no Xcode, no macOS VM,
no cloud Mac. Then signs it, packages a valid `.ipa`, verifies it, and (optionally) uploads it to
App Store Connect over the REST API.

It also ships the part nobody else ships: **a dyld + ARM64 emulator** that actually *executes* the
binary on Windows so you can see the app boot before touching a phone.

> ## ⚠️ Status: **never run on a physical iPhone**
>
> Everything in this repo is verified **on Windows only**:
> compilation, linking, code signing, `.app`/`.ipa` packaging, static audit, and **emulated**
> execution (dyld + Unicorn ARM64 + a fake UIKit).
>
> **No build from this repo has been launched on real hardware, signed with an Apple-issued
> certificate, or uploaded to Apple.** Treat it as a working prototype with strong static and
> emulated evidence — not as a shipped product.
>
> The two assumptions that still need a device are listed in [`docs/17`](docs/17-CRITIQUE.md) §1:
> `UIApplicationMain` being called from a dylib constructor, and 4 KB signature pages.
> If you run it, please report the result — [`CONTRIBUTING.md`](CONTRIBUTING.md) has the template.


```
   source (.m)                zig cc -target aarch64-ios            AppCore.dylib
      │                              │                                  │
      ├──► tools/machogen.py ────────┴──► loader executable ────────────┤
      │                                     (LC_LOAD_DYLIB)            │
      └──► icons / CodeResources ──────────────► .app ──► .ipa ◄───────┘
                                                   │
                     tools/codesign_lite.py ───────┤  CodeDirectory + CMS + LC injection
                     tools/verify-ipa.py ──────────┤  9 structural checks
                     tools/audit-device.py ────────┤  will-it-launch audit
                     tools/sim-ios.py ─────────────┘  actually runs it (Unicorn ARM64)
```

---

## Why this exists

Apple's compiler is macOS software. Everything *around* compiling — signing, packaging, uploading,
installing, verifying — does not need to be. Since WWDC25 the App Store Connect API accepts binaries
over plain HTTPS (`POST /v1/buildUploads`), which removed the last hard macOS dependency outside the
compiler itself.

This repo pushes that idea to the limit: it replaces the compiler stage too, using zig's
`aarch64-ios` target plus hand-written linker stubs (`.tbd`), and works around the one linker bug
that blocks executables by splitting the app into a dylib + a minimal loader.

## What works / what doesn't

| | Status | Notes |
|---|---|---|
| Compile C / Objective-C → arm64 iOS | ✅ | zig (clang frontend), `-target aarch64-ios` |
| Link UIKit / Foundation / Metal / libobjc | ✅ | hand-written `.tbd` stubs, no SDK needed |
| Real UIKit UI (UIWindow, UILabel, run loop) | ✅ | `objc_msgSend` + `UIApplicationMain` |
| Custom Metal shaders | ✅ | MSL compiled at runtime via `newLibraryWithSource:` |
| App icons (13 sizes incl. 1024) | ✅ | loose PNGs + `CFBundleIcons` (no `actool`) |
| Code signing (ad-hoc **and** real cert CMS) | ✅ | CodeDirectory v0x20400, entitlements + Info.plist slots |
| `.ipa` with nested `Frameworks/` | ✅ | forward slashes, `Payload/` prefix, `_CodeSignature` |
| Upload to App Store Connect | ✅ | REST `buildUploads`, 4 steps, chunked |
| Pre-flight validation | ✅ | `verify-ipa.py` (9 checks) + `audit-device.py` |
| Execute the binary on Windows | ✅ | `sim-ios.py`: dyld loader + Unicorn ARM64 + fake UIKit |
| **SwiftUI / Swift sources** | ❌ | needs the SDK's `.swiftmodule`; `scripts/xc/Get-IosSdk.ps1` extracts one from `Xcode.xip` |
| **Storyboards (`ibtool`), `actool`** | ❌ | macOS-only binaries; avoidable with code-built UI + loose PNG icons |
| Reproducible builds | ✅ | `-Deterministic`: fixed UUID + fixed zip timestamps |

Full capability matrix and evidence: [`docs/09`](docs/09-ALL-GAPS-CLOSED.md), [`docs/11`](docs/11-NO-DEVICE-VERIFICATION.md).

## Quickstart

```powershell
# 0) toolchain (Python 3.11+, plus Git for Windows for openssl)
git clone <this repo> ; cd <repo>
.\scripts\install.ps1 -Dev          # pip install -r requirements-dev.txt, verify zig/openssl

# 1) build an app (UIKit, icons, Metal shader, ad-hoc signed)
.\scripts\ios.ps1 nomac

# 2) validate it three ways
python tools\verify-ipa.py build\xc\AppCore-native.ipa
python tools\audit-device.py build\xc\AppCore-native.ipa --target trollstore
python tools\sim-ios.py build\xc\AppCore.work\AppCore.app

# 3) publish a handoff bundle (ipa + manifest + INSTALL.txt)
.\scripts\xc\Publish-Artifact.ps1
```

Getting it onto a phone without the App Store — three paths, pick by iOS version:

```powershell
.\scripts\xc\Get-InstallPath.ps1    # reads the device, tells you which path applies
```

| Path | Requirement | Lifetime |
|---|---|---|
| TrollStore | iOS ≤ 17.0 | permanent, no Apple account |
| Free Apple ID (Sideloadly) | any iOS | 7 days, auto-renew task included |
| Paid account ($99/yr) | any iOS | 1 year |

Details: [`docs/16`](docs/16-INSTALL-ON-DEVICE.md).

## The tools

Every tool is standalone and runs on Windows (and Linux/macOS via pwsh where applicable).

| Tool | What it does |
|---|---|
| [`tools/machogen.py`](tools/machogen.py) | Emits a valid arm64 Mach-O: page-aligned segments, `LC_LOAD_DYLINKER`, `LC_DYLD_INFO`, `LC_SYMTAB`, `LC_UUID`, `LC_BUILD_VERSION(iOS)`, `LC_MAIN` |
| [`tools/codesign_lite.py`](tools/codesign_lite.py) | `codesign` equivalent: CodeDirectory, superblob, entitlements/Info.plist special slots, detached PKCS#7 CMS, `LC_CODE_SIGNATURE` injection, fixed-point iteration for `datasize` ↔ page hashes |
| [`tools/verify-ipa.py`](tools/verify-ipa.py) | Static pre-flight: bundle structure, Info.plist, icons, Mach-O platform/arch, dependency paths, signature page hashes |
| [`tools/audit-device.py`](tools/audit-device.py) | "Will it launch on a phone" — kernel/dyld/amfid checks, target-aware (`device` / `trollstore` / `appstore`) |
| [`tools/sim-ios.py`](tools/sim-ios.py) | Userland dyld + Unicorn ARM64 + fake UIKit: runs the real code and prints the call trace + ABI evidence |
| [`tools/xip-extract.py`](tools/xip-extract.py) | Pure-Python `xar → pbzx → cpio` unpacker for `Xcode.xip` |
| [`tools/check-provisioning.py`](tools/check-provisioning.py) | Profile ↔ certificate ↔ bundle id ↔ entitlements ↔ UDID consistency |
| [`tools/make-icons.py`](tools/make-icons.py) | PNG encoder + full iOS icon set (no PIL) |

## Repo layout

```
Sources/AppCore/     pure Swift logic (testable on Windows with swift test)
App/                 SwiftUI shell, compiled only on macOS
sdk/iPhoneOS-shim/   hand-written UIKit/Metal headers + .tbd linker stubs
scripts/             ios.ps1 (entry), release.ps1, lib/, xc/, vm/
tools/               standalone Python tools (see table above)
py_tests/            pytest (14 cases: Mach-O, signing, ipa, xip, provisioning)
docs/                00–16: architecture → conventions → prior art → install paths
```

## Evidence, not claims

```
pytest              14 passed
ruff                All checks passed
verify-ipa          9 passed, 0 warnings, 0 failures
audit --target device      FATAL=1 HIGH=2   (needs your cert + profile)
audit --target trollstore  FATAL=0 HIGH=0   (installable as-is)
sim-ios             PASS — constructor → UIApplicationMain → full UI call trace
deterministic       two builds → identical SHA256
```

`docs/11` shows the execution trace the emulator produces, including the exact `d0–d3` values that
prove `CGRect` travels correctly through variadic `objc_msgSend`.

## Gaps — contributions welcome

[`CONTRIBUTING.md`](CONTRIBUTING.md) lists 15 concrete gaps with acceptance criteria. The short list:

| Effort | Gap | Why it matters |
|---|---|---|
| **device report** | Install on a phone, report the result | turns our two biggest unknowns (constructor-time `UIApplicationMain`, 4 KB signature pages) into facts — see [`docs/17`](docs/17-CRITIQUE.md) |
| good first issue | merge the 5 duplicated Mach-O parsers into `tools/macho.py` | "audit says OK but reality differs" is the worst class of bug |
| good first issue | `--json` output for `audit-device.py` / `verify-ipa.py` | lets CI assert on results |
| help wanted | `Assets.car` writer | removes the last "you cannot submit" caveat |
| help wanted | nested-code sealing, deterministic CMS time | `codesign` parity |
| research | SwiftUI without Xcode | needs a Swift frontend that targets iOS |

Self-critique and risk matrix: [`docs/17-CRITIQUE.md`](docs/17-CRITIQUE.md).

## Limitations, honestly

- **SwiftUI is out of reach** without Xcode's `.swiftmodule` files. `scripts/xc/Get-IosSdk.ps1` can
  extract them from an `Xcode.xip` you download yourself; then `-Sdk <path>` feeds the build.
- **`actool` / `ibtool` / `metal`** are macOS-only binaries. Worked around (loose PNG icons,
  code-built UI, runtime MSL compilation) rather than reimplemented.
- **zig's iOS target is not an officially supported workflow.** Pin `ziglang==0.17.1`; upgrades must
  re-run the full self-test.
- **The emulator proves control flow, ABI and data flow — not pixels.** Rendering and UIKit lifecycle
  still need a device.

## Prior art

Compared with [osxcross](https://github.com/tpoechtrager/osxcross), [Theos](https://github.com/theos/theos),
[iosc](https://github.com/DiamondDeadMaw/iosc), [rcodesign](https://github.com/indygreg/apple-platform-rs),
[zsign](https://github.com/zhlynn/zsign) and [zig-ios-example](https://github.com/kubkon/zig-ios-example) —
see [`docs/13`](docs/13-PRIOR-ART.md) for the full matrix. Short version: they move the SDK, this repo
moves only the symbol tables; and none of them validate the result.

## License

MIT — see [LICENSE](LICENSE). This repo contains **no Apple SDK files**; `sdk/iPhoneOS-shim` is
hand-written and lists only the symbol names the sample uses. `xip-extract.py` unpacks archives you
supply; obtaining Apple's SDK is subject to Apple's terms.
