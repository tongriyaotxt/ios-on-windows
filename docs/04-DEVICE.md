# 04 · 设备侧：不用 Mac 也能装包、看日志、抓崩溃

> 现状（本机实测）：`Apple Mobile Device Service` 未安装、`libimobiledevice` 全缺、
> USB 历史里**从未插过 iPhone**。所以这是「把 App 弄到手机上」的第一道硬阻塞，也是最好解决的一道。

---

## 1. 一次装好驱动栈

```powershell
winget install Apple.AppleDevices          # 或装 iTunes（Microsoft Store 版不含驱动，要用 exe 版）
# 验证：插上 iPhone，应该在
Get-Service 'Apple Mobile Device Service'
Get-PnpDevice -PresentOnly | Where-Object InstanceId -like 'USB\VID_05AC*'
```

**判断成功**：`Get-PnpDevice` 能列出 VID_05AC 设备，`Apple Mobile Device Service` 处于 Running。

---

## 2. 命令行装包 / 日志 / 崩溃：两条路

### A. pymobiledevice3（推荐，纯 Python，Windows 支持最好）

```powershell
pip install pymobiledevice3

# 列设备（USB 与 WiFi 都支持；WiFi 需要先在同一网络配对）
pymobiledevice3 usbmux list

# 装 IPA（需要已签名，且设备 UDID 在 profile 里）
pymobiledevice3 apps install .\build\AppCore.ipa

# 实时日志（等价于 macOS 的 Console.app / idevicesyslog）
pymobiledevice3 syslog live --process AppCore

# 崩溃报告
pymobiledevice3 crash pull .\build\crashes

# 截屏（iOS 17+ 需要 Developer Mode 打开）
pymobiledevice3 developer dvt screenshot .\build\shot.png
```

### B. libimobiledevice 套件（经典 C 工具，需驱动）

| 命令 | 用途 |
|---|---|
| `idevice_id -l` | 列 UDID |
| `ideviceinstaller -i app.ipa` | 装 |
| `ideviceinstaller -U com.x.y` | 卸 |
| `idevicesyslog` | 实时日志 |
| `idevicecrashreport -e .\crashes` | 拉崩溃 |
| `ideviceinfo` | 设备信息（含 UDID、iOS 版本） |

> Windows 上没有官方二进制，用 `vcpkg install libimobiledevice` 或社区构建。**优先级低于 pymobiledevice3**：
> 后者是纯 Python，升级不依赖编译工具链。

---

## 3. 三条「装进手机」的路

| 路 | 需要 | 有效期 | 适合 |
|---|---|---|---|
| **TestFlight** | $99 账号 + 上传成功（docs/03） | 90 天/构建 | 日常自测、给别人装 |
| **OTA itms-services** | ad-hoc/enterprise 签名 + HTTPS | 描述文件有效期（1 年） | 内网秒装、不想等审核 |
| **Sideloadly / AltStore** | 免费 Apple ID | **7 天**，到期重签 | 零成本先跑起来 |

### OTA 直装（本仓库已实现）

```powershell
.\scripts\ios.ps1 ota -Ipa .\build\AppCore.ipa -Host 192.168.2.2 -Port 8443
```

生成 `build\ota\{manifest.plist, install.html, *.ipa}`。然后：

```powershell
# 自签证书（iOS 只收 https）
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 365 -subj "/CN=192.168.2.2"

# 起 HTTPS 服务（python 自带，无需装 nginx）
python -c "import http.server,ssl;s=http.server.HTTPServer(('0.0.0.0',8443),http.server.SimpleHTTPRequestHandler);c=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);c.load_cert_chain('cert.pem','key.pem');s.socket=c.wrap_socket(s.socket,server_side=True);s.serve_forever()"
```

iPhone Safari 打开 `https://192.168.2.2:8443/install.html` → 点「安装」。
自签证书需要先在 iOS「设置 → 通用 → 关于本机 → 证书信任设置」里信任（或用真证书/内网 CA）。

> 关键前提：**IPA 必须是 ad-hoc 签名**，且 `com.tongriyaotxt.appcore` 对应 profile 里包含这台设备的 UDID。
> App Store 签名的 IPA 无法 OTA 安装。

---

## 4. 调试的替代品（没有 lldb 怎么办）

| 手段 | 做法 | 能看到什么 |
|---|---|---|
| 结构化日志 | `Logger(subsystem:category:)` + `pymobiledevice3 syslog live` | 时间线、错误、状态 |
| 崩溃符号化 | 传 IPA 时带 dSYM（`uploadSymbols=true`），崩溃在 ASC / Crashlytics 里自动符号化 | 堆栈、崩溃率 |
| 远程开关 | 把行为开关放服务端配置，改配置不用重装 | 快速试错 |
| SwiftUI Preview 替代 | 纯逻辑抽到 `AppCore` + 本地 `swift test` | 80% 逻辑不用上机 |
| 真机断点（必须时） | 租 Mac / 家里 Mac mini + Tailscale | 完整调试 |

**工程约束**：把「能本地测的」和「必须上机看的」分清楚。本仓库的结构就是这个约束的产物——
`Sources/AppCore` 在 Windows 上秒级 `swift test`，`App/Sources/AppMain.swift` 只剩布局。

---

## 5. 常见故障

| 症状 | 原因 | 处理 |
|---|---|---|
| `Get-PnpDevice` 看不到 VID_05AC | 驱动没装 / 线是充电线 | 装 Apple Devices；换数据线 |
| `pymobiledevice3` 报 `No device found` | 手机没点「信任」 | 解锁手机，点信任，重插 |
| 安装报 `ApplicationVerificationFailed` | profile 不含 UDID / 证书不匹配 | 重新生成 profile（docs/02） |
| 装完图标灰、点开闪退 | 用了 Development 证书但描述文件是 App Store 的 | 类型必须匹配 |
| iOS 17+ 截屏/DVT 报错 | 没开 Developer Mode | 设置 → 隐私与安全性 → 开发者模式 |
| OTA 点安装没反应 | 用的 http，或证书不受信 | 必须 https + 信任证书 |
