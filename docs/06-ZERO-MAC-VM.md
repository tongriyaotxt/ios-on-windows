# 06 · 零 Mac 设备全流程（编译也不借 Mac）

> 约束：**整个过程不出现任何 Mac 硬件**——不买、不租、不借、不连别人的 Mac。
> 做法：把这台 Windows PC 变成 macOS 的宿主机（QEMU + WHPX + OpenCore），Xcode 装在客户机里。
> 你仍然会「用到 macOS 软件」，但**不需要 Mac 设备**。

---

## 0. 全景图

```
┌────────────────────────── Windows 11（你的机器）──────────────────────────┐
│                                                                          │
│  VS Code / Rider  ← 写代码（AppCore + SwiftUI 壳）                        │
│  swift test        ← 纯逻辑单测，秒级（Swift for Windows）                 │
│         │                                                                │
│         ▼  git / 共享目录 / HTTP                                          │
│  ┌──────────────── QEMU 虚拟机（macOS 客户机）────────────────┐            │
│  │  xcodegen generate                                       │            │
│  │  xcodebuild archive + -exportArchive  →  AppCore.ipa     │            │
│  │  python3 -m http.server 8000                             │            │
│  └───────────────────────────┬──────────────────────────────┘            │
│        hostfwd tcp::8000-:8000│（用户态网络，不需要桥接/装驱动）           │
│         ▼                                                                │
│  scripts\vm\Get-Artifact.ps1  →  build\AppCore.ipa                        │
│         │                                                                │
│         ├─ scripts\asc-upload.ps1      → App Store Connect（REST）        │
│         ├─ scripts\make-ota-manifest.ps1 → itms-services 直装             │
│         └─ pymobiledevice3 apps install  → USB 直装                      │
└──────────────────────────────────────────────────────────────────────────┘
```

**唯一在 macOS 里做的事**：`xcodegen` + `xcodebuild`。其余全部在 Windows 原生完成。

---

## 1. 前置（都在 Windows 上）

```powershell
# QEMU（含 qemu-img 与 OVMF 固件）
winget install SoftwareFreedomConservancy.QEMU

# 7-Zip：解 .xip / .dmg 用
winget install 7zip.7zip

# 体检 + 建盘（-DryRun 只打印计划，先看清楚）
.\scripts\vm\New-MacVm.ps1 -OpenCoreDisk F:\vm\OpenCore.qcow2 -DryRun
```

### 1.1 要准备的两个文件

| 文件 | 从哪来 | 说明 |
|---|---|---|
| `OpenCore.qcow2` | OSX-KVM 发布物里的 `OpenCore.qcow2` | 引导器。GitHub 直连不通时用镜像/代理先下到本地，再传路径 |
| `edk2-x86_64-code.fd` | QEMU 安装目录的 `share\` | UEFI 固件，脚本会自动找 |

> 网络实测（见 `docs/12-CONVENTIONS.md`）：`github.com` 12 s 超时、`objects.githubusercontent.com` 可达、
> `download.swift.org` 1.27 s。所以「先下到本地再喂给脚本」是这套流程的默认姿势，不要指望脚本替你翻墙。

### 1.2 macOS 安装介质

OpenCore 起来后，在引导菜单里选 **macOS Base System**（走 Apple 的 recovery，需要联网下载约 700 MB–12 GB）。
QEMU 的用户态网络 NAT 直接可用，不需要额外配网。

---

## 2. 装 macOS 客户机（一次性，约 1–3 小时）

```powershell
.\scripts\vm\New-MacVm.ps1 -OpenCoreDisk F:\vm\OpenCore.qcow2 -Launch -RamMB 16384 -Cpu 8 -DiskGB 96
```

客户机里的步骤：

1. 引导菜单 → `macOS Base System` → 进恢复模式
2. **磁盘工具** → 选中 `QEMU HARDDISK`（96 GB 那块）→ 抹掉 → 格式 `APFS`、方案 `GUID`
3. 关掉磁盘工具 → **安装 macOS** → 选刚抹的盘 → 等 40–90 分钟（视 CPU）
4. 首次进系统：跳过 Apple ID 也可以（后面装 Xcode 时再登），但**建议登录**——`-allowProvisioningUpdates`
   需要账号态
5. 系统设置 → 通用 → 共享 → 打开 **远程登录**（这样 Windows 侧可以 `ssh -p 2222` 进来）
6. 系统设置 → 隐私与安全性 → 开发者模式（可选，真机调试用）

> 装完先拍个快照：`Copy-Item macos.qcow2 macos-clean.qcow2`。以后 Xcode 升级把系统搞挂了，直接换回来。

---

## 3. 装 Xcode（三种，都不需要 Mac）

| 方式 | 步骤 | 适合 |
|---|---|---|
| **客户机内 App Store** | 登录 Apple ID → 搜 Xcode → 安装（约 12 GB + 解压 40 GB） | 最省事，网络好时首选 |
| **Windows 侧下 .xip 再传进去** | 浏览器在 Windows 下 `Xcode_16.xip` → `7z x` 解出 `Xcode.app` → 通过 HTTP/共享目录拷进客户机 `/Applications` | 客户机网络慢、或想固定版本 |
| **Command Line Tools 先行** | 客户机内 `xcode-select --install` | 只要 `swift`/`clang`，不装完整 Xcode 时 |

`7z` 解 `.xip` 后注意：**保留符号链接**（`.app` 里大量 symlink），用 `7z x -snl` 或在客户机里用 `ditto` 复原。
拷进客户机最稳的方式是打一个 tar 再传：

```powershell
# Windows 侧
7z a -ttar Xcode16.tar Xcode16\Xcode.app
# 传：客户机里 python3 -m http.server 8001，Windows 侧不需要——反过来，Windows 起 http 让客户机来取
python -m http.server 9000 --directory F:\vm
# 客户机里： curl -O http://10.0.2.2:9000/Xcode16.tar && tar xf Xcode16.tar -C /Applications
```

> `10.0.2.2` 是 QEMU 用户态网络里「宿主 Windows」的固定地址。

---

## 4. 编译：客户机里一条命令

把仓库放进客户机（`git clone`，或上面那种 HTTP 方式）：

```bash
# 客户机内
brew install xcodegen            # 只需一次
bash scripts/vm/macos-build.sh ~/src/ios-app 42
# 末尾会自动 python3 -m http.server 8000 把 IPA 目录暴露出去
```

它做四件事：`xcodegen generate` → `swift test` → `xcodebuild archive` → `xcodebuild -exportArchive`。

---

## 5. 把 IPA 拉回 Windows

```powershell
.\scripts\vm\Get-Artifact.ps1 -BundleVersion 42
# 或一步到底（拉回 + 上传）
.\scripts\vm\Get-Artifact.ps1 -BundleVersion 42 -Upload
```

`hostfwd tcp::8000-:8000` 让 `http://127.0.0.1:8000` 直接指到客户机里的那个 http 服务；
脚本会列目录、挑最新的 `.ipa`、下载、校验大小。

---

## 6. 之后三件事（全部 Windows 原生，已实现并自测通过）

```powershell
# 传 App Store Connect（REST buildUploads，docs/03）
.\scripts\asc-upload.ps1 -Ipa .\build\AppCore.ipa -BundleVersion 42

# 不经过 TestFlight，直接装（ad-hoc 签名 + HTTPS，docs/04）
.\scripts\ios.ps1 ota -Ipa .\build\AppCore.ipa -Addr 192.168.1.10 -Port 8443

# USB 直装（需要 Apple 设备驱动 + pymobiledevice3）
.\scripts\ios.ps1 install -Ipa .\build\AppCore.ipa
```

---

## 7. 性能预期（估算，非实测）

| 项 | 预期 | 说明 |
|---|---|---|
| macOS 首次安装 | 40–90 min | 受 NAT 下载速度限制 |
| Xcode 首次安装 | 20–60 min | 12 GB + 解压 |
| 本项目全量编译 | 1–3 min | 小工程；M 系列上约 40 s |
| 增量编译 | 10–30 s | 比原生 Mac 慢 2–5 倍 |
| 模拟器 | ❌ 基本不可用 | 无 Metal 加速，`simctl` 能起但卡 |
| 真机调试 | 🟡 可做 | USB 直通 `-PassthroughIphone`，或走 TestFlight/OTA |

---

## 8. 坑表（按踩到概率排序）

| 症状 | 原因 | 处理 |
|---|---|---|
| QEMU 起不来，报 `whpx: failed to initialize` | Hyper-V/WHPX 冲突，或 BIOS 里 VT-x 没开 | `bcdedit /set hypervisorlaunchtype auto` 后重启；BIOS 打开 VT-x |
| 引导卡在 Apple logo 一半 | CPU 型号不被 macOS 接受 | `-CpuModel Penryn,kvm=on,vendor=GenuineIntel`；AMD 用 `-cpu host,-svm` 之类 |
| 图形花屏 / 极慢 | `-vga std` 无加速 | 换 `-device VGA,vgamem_mb=128` 或 `-vga vmware`（部分版本可用） |
| 键盘鼠标点不准 | 缺 usb-tablet | 已在脚本里带 `-device usb-tablet` |
| 客户机时间乱跳 | RTC 基准不一致 | 脚本已带 `-rtc base=localtime,clock=host` |
| Xcode 登不上 Apple ID | 客户机网络/时间证书问题 | 校时；用 `-allowProvisioningUpdates` 前先手动登一次 |
| iPhone 插上客户机认不到 | USB 直通不稳定 | 用 OTA / TestFlight 替代（docs/04），或 `-device usb-host,vendorid=0x05ac` 逐个试 productid |
| 磁盘越用越大 | qcow2 不自动回收 | 客户机内 `sudo fstrim -av`，宿主 `qemu-img convert` 压缩 |

---

## 9. 一句话总结

**编译是唯一必须 macOS 的地方，而现在 macOS 可以只是这台 PC 上的一个进程。**
前面三步（写代码、单测、签名资产）本来就不需要 Mac；后面三步（上传、分发、装机）已经在 Windows 上验证跑通。
