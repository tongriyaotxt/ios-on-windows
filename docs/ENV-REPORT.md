# iOS App 工具链 · 环境基线报告

采样时间：2026-11-18 19:5x（Asia/Shanghai）　工作目录：`F:\shit\ios-app`

---

## 1. 机器本体

| 项 | 实测值 | 对 iOS 开发的意义 |
|---|---|---|
| 系统 | Windows 11 家庭版 build **26200** x64 | 家庭版**没有 Hyper-V 管理器/组策略**，但 WSL2 可用 |
| CPU | Intel Core Ultra 9 275HX，24C/24T | 编译绰绰有余 |
| 内存 | 31.5 GB | 够跑模拟器替代方案 + Docker + 云 CLI |
| 磁盘 | C: 41G / D: 17.7G / E: 4.1G / **F: 915.3G** | 工具链一律装 F:，C: 只装驱动类小件 |
| 虚拟化 | HypervisorPresent = True | WSL2/Docker 可用；x86 macOS 虚拟机不具备可用性 |
| 网络位置 | WLAN 192.168.2.2，网关 192.168.2.1 | 局域网内**没有 Mac**（无 22/5900 监听、无 SMB 共享） |

**结论：本机不能原生编译 iOS。** iOS 二进制必须由 Xcode（macOS）产出，这一点无法用任何 Windows 侧工具绕开；Windows 侧的职责是「写代码 + 编译可跨平台的核心逻辑 + 云端/借机编译 + 把 IPA 装进 iPhone + 抓日志」。

---

## 2. 已经具备（可直接用）

| 组件 | 版本 / 位置 | 状态 |
|---|---|---|
| Git | **2.45.1** `C:\Program Files\Git\cmd\git.exe` | 已装，但**不在 PATH**（新开 shell 敲 `git` 会找不到） |
| GitHub CLI | 2.98.0 `C:\Program Files\GitHub CLI\gh.exe` | 已登录账号 `tongriyaotxt`，scope 含 `repo`/`workflow` → **可直接跑云端构建** |
| Node.js | **v24.14.1** / npm 11.11.0，registry 已指 `registry.npmmirror.com` | React Native / Expo / EAS 路线可用 |
| Python | 3.13.5（另有 D:\DevTools\Python310） | 脚本、资源处理可用 |
| .NET | host 10.0.11，**无 SDK** | 与 iOS 无关，忽略 |
| Visual Studio 2022 Community | 17.14.37012.4，MSVC **14.44.35207** | 编译器在，但见下方「缺口①」 |
| Windows SDK 组件 | VS 清单里有 `Windows11SDK.26100` / `22621` | **目录是空的**：`Windows Kits\10` 只剩 `Catalogs`、`Debuggers`，没有 `Include`/`Lib`/`Bin` → 实际未落地 |
| Docker Desktop | 已装，`docker-desktop` WSL 发行版可启动 | 可跑 Linux 侧签名/打包脚本 |
| WSL2 | Ubuntu（Stopped）+ docker-desktop | 备用 Linux 环境 |
| VS Code | **1.146.0**（`E:\Microsoft VS Code`） | 扩展偏 C++/Python：`cpptools`、`cmake-tools`、`vscode-lldb`、`python`… |
| Flutter | **3.50.0 stable / Dart 3.14.0**，已解压到 `F:\toolchains\flutter` | 已能跑 `flutter --version`；未初始化、未进 PATH、未配镜像变量 |

---

## 3. 缺口（按阻塞程度排序）

### ① Swift 编译器：没有
`swift` / `swiftc` 均不存在，`C:\Program Files\Swift` 不存在。
用途：在 Windows 上编译/单测**纯 Swift 核心模块**（SwiftPM），让 80% 的业务逻辑不依赖 Mac 就能跑测试。
依赖条件：**Windows SDK 头文件/库（当前缺损）**，否则 `swift build` 链接阶段必挂。

### ② Apple 移动设备栈：完全没有
| 检查项 | 结果 |
|---|---|
| Apple Mobile Device Support / iTunes / Apple Devices | 未安装 |
| `usbmuxd` / `Bonjour` / `Apple Mobile Device Service` | 无此服务 |
| 设备管理器 Apple/iPhone 设备 | 无 |
| USB 历史（VID_05AC） | **从未插过 iPhone** |

含义：现在把 iPhone 插上电脑，系统只会把它当「相机/U 盘」，`ideviceinstaller`、Sideloadly、AltStore 全都认不到设备。**这是「把 App 弄到手机上」的第一道硬阻塞。**

### ③ 签名/装包 CLI：没有
`idevice_id` / `ideviceinstaller` / `idevicedebug` / `idevicesyslog` / `idevicecrashreport`（libimobiledevice 套件）全缺 → 无法命令行装 IPA、看实时日志、拉崩溃报告。

### ④ 构建与签名账户侧：空
- 无 Apple Developer Program 账号记录（决定能不能 TestFlight / 免 7 天重签）
- 无 App Store Connect API Key、无证书 `.p12`、无 provisioning profile
- 无 fastlane / XcodeGen / xcbeautify 本地配置（这些在 macOS/CI 跑，配置可以先写好）

### ⑤ 网络：GitHub 直连不通（重要）
| 目标 | 实测 |
|---|---|
| `github.com` | 12s 超时 |
| `raw.githubusercontent.com` | 12s 超时 |
| `codeload.github.com` | 12s 超时 |
| `objects.githubusercontent.com` | 可达（810ms） |
| `registry.npmmirror.com` | **175ms 可用** |
| `download.swift.org` | **1.27s 可用** |
| `storage.flutter-io.cn` | 可用（HEAD 403 但 GET 正常，1.78G 已拉完） |

含义：**`git clone` / `gh repo clone` / Actions 产物直链下载会卡死**（刚才 winget 装 Git 就是 20 分钟 0 字节）。必须走 npmmirror / gh 代理 / 公司代理，否则「云端构建 → 本地取包」这条链会断在最后一步。

### ⑥ 编辑器侧：无 iOS 语言支持
缺 Swift LSP、iOS 项目管理、模拟器/设备面板类扩展。

---

## 4. 三条「把 App 装进 iPhone」的路线

| 路线 | 需要什么 | 首次可装时间 | 有效期 | 适合场景 |
|---|---|---|---|---|
| **A. Sideloadly / AltStore 本机直签** | Windows + iTunes 驱动 + Apple ID（免费即可） | 30 分钟 | **免费账号 7 天**，到期重签 | 先看到 App 在自己手机上跑起来 |
| **B. 云端 macOS 构建 + TestFlight** | GitHub 账号（已有）+ Apple Developer $99/年 | 半天（配置 CI） | 90 天/构建，可长期分发 | 正式开发、给他人装、上架 |
| **C. 借/租 Mac（Mac mini / 云 Mac）** | 一台能跑 Xcode 的 macOS | 1 小时 | 免费账号 7 天，付费账号 1 年 | 要打断点调试、Instruments 性能分析 |

**推荐组合：A 用于今天就能装到手机验证；B 作为日常构建主线；C 仅在需要真机断点调试时短租。**

---

## 5. 下一步安装清单（按顺序，均不需要 Mac）

| # | 动作 | 体积 | 说明 |
|---|---|---|---|
| 1 | 修 PATH：`C:\Program Files\Git\cmd`、`F:\toolchains\flutter\bin` 写入用户 PATH | — | 立刻可用 git / flutter |
| 2 | Flutter 初始化：`PUB_HOSTED_URL` + `FLUTTER_STORAGE_BASE_URL` 指境内镜像 | — | 之后 `flutter pub get` 不卡 |
| 3 | 补 Windows SDK 的 Include/Lib（VS Installer 修 `Windows11SDK.26100`） | ~3 GB | Swift 编译前提 |
| 4 | Swift 6.4.2 工具链（`download.swift.org`，可达） | ~3.5 GB | `swift build` / `swift test` |
| 5 | Apple Mobile Device Support + Apple Application Support（winget） | ~250 MB | 让 Windows 认 iPhone |
| 6 | libimobiledevice CLI 套件（ideviceinstaller 等） | ~20 MB | 命令行装包/日志/崩溃 |
| 7 | Sideloadly（免费 Apple ID 签名）+ zsign（CLI 签名备用） | ~80 MB | 路线 A 的执行器 |
| 8 | Node 侧：EAS CLI + React Native 模板（可选路线） | ~300 MB | 跨端备选 |
| 9 | VS Code：Swift LSP + SweetPad（iOS 项目管理，可接云端 Mac） | ~150 MB | 编辑器补齐 |
| 10 | 工程骨架：`Package.swift` + `project.yml`(XcodeGen) + Fastfile + `.github/workflows/ios.yml` | — | 已开始写，见仓库根 |
| 11 | 云端构建流水线打通：push → macos runner → 未签名 .app → 签名 → IPA/TestFlight | — | 路线 B |
| 12 | 自检脚本 `scripts/check-toolchain.ps1` + `docs/DEVICE-DEPLOY.md` | — | 一条命令验证全链路 |

---

## 6. 一句话结论

机器本身够强，**软件栈目前只到「能写代码」的一半**：跨平台运行时（Node/Python/Docker/WSL/Flutter）齐了，但 **Swift、Windows SDK 头文件、Apple 设备驱动、签名/装包 CLI 四件全缺**，而且 **GitHub 直连不通**。把第 1–7 项补齐后，Windows 上就能完成「写 → 云编译 → 装进 iPhone → 抓日志」的完整闭环。
