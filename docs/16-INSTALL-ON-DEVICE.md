# 16 · 只要在手机上跑起来（不上架）

> 目标变了：不提交 App Store，只让自己手机装上能跑。
> 这样选择就宽了 —— **有三条路，最省事的那条可能根本不需要 Apple 账号。**

---

## 1. 先判断你的设备能走哪条

```powershell
.\scripts\xc\Get-InstallPath.ps1
```

它会读设备（iOS 版本 / UDID）、检查本机有没有证书与产物，然后直接告诉你走哪条、敲什么命令。

| 你的情况 | 推荐路径 | 需要 Apple 账号 | 有效期 |
|---|---|---|---|
| iOS **≤ 17.0**（CoreTrust 未修复） | **A. TrollStore** | ❌ 完全不需要 | **永久** |
| iOS ≥ 17.0.1，愿意每 7 天续一次 | **B. 免费 Apple ID**（Sideloadly） | 免费即可 | 7 天 |
| 想一劳永逸 | **C. 付费账号 $99/年** | 需要 | 1 年 |

---

## 2. 路线 A：TrollStore（最省事，前提是系统版本够老）

TrollStore 利用 CoreTrust 漏洞，**接受 ad-hoc 签名的 ipa** —— 也就是我们已经产出的那种包，
完全不需要 Apple 的证书和描述文件。

```powershell
# 1) 手机上装 TrollStore（一次性）：用 TrollInstallerX，扫一下就行
# 2) 把包推上去
pymobiledevice3 apps install .\build\xc\AppCore-native.ipa
#    或者把 ipa 传到手机（AirDrop / 文件 App），用 TrollStore 打开
```

**我们这边的优势**：`ios.ps1 nomac` 产出的就是 ad-hoc 签名包，正好是 TrollStore 要的形式；
甚至连签名都可以省（TrollStore 会自己重签）。

限制：只覆盖 iOS 14.0–16.6.1 与 17.0（截至 2026）。17.0.1 之后 CoreTrust 已修复。

---

## 3. 路线 B：免费 Apple ID（7 天）

```text
Sideloadly（Windows，免费 Apple ID 可签）
   └─ 登录 Apple ID → 自动本地生成密钥 → 提交 CSR → 拿开发证书
      → 注册 UDID → 生成 7 天描述文件 → 导出 .p12 / .mobileprovision
           ↓
本仓库接管后面全部：
  .\scripts\release.ps1 -Profile X.mobileprovision -P12 X.p12 -P12Password *** -AutoUdid
  .\scripts\ios.ps1 install -Ipa .\build\xc\AppCore-native.ipa
```

### 7 天到期的自动化

```powershell
.\scripts\xc\Register-RefreshTask.ps1 -Profile .\AppCore.mobileprovision -P12 .\dist.p12 -P12Password ***
```

注册一个 Windows 计划任务，每 6 天自动「重签 + 重装」，日志在 `build\refresh.log`。

**必须知道的一点**：免费账号的**描述文件本身也只有 7 天**。到期后脚本会明确报错
（而不是静默失败），这时要用 Sideloadly 重新生成一份 —— 那一步是 Apple 的限制，
任何工具都绕不开，只能把间隔压到最短。

---

## 4. 路线 C：付费账号

和上架一样，只是不做提交：

```powershell
# 证书/描述文件用 docs/02 的 REST 流程自动生成（不需要 Xcode）
.\scripts\release.ps1 -Profile AppCore.mobileprovision -P12 dist.p12 -P12Password *** `
    -P8 .\secrets\AuthKey_XXXX.p8 -KeyId XXXXXXXX -IssuerId <uuid> -TeamId <10位> -AutoUdid
.\scripts\ios.ps1 install -Ipa .\build\xc\AppCore-native.ipa
```

有效期 1 年，中间不用管。

---

## 5. 三条路都能用的部分（本仓库已实现）

| 步骤 | 命令 | 说明 |
|---|---|---|
| 编出包 | `ios.ps1 nomac` | ad-hoc 签名，TrollStore 直接用；正式签名走 `release.ps1` |
| 读设备 | `Get-DeviceInfo.ps1` | UDID / 名称 / iOS 版本 |
| 校验签名物料 | `check-provisioning.py` | bundle id / UDID / 证书 / entitlements 五方比对 |
| 装包 | `ios.ps1 install` | pymobiledevice3 或 ideviceinstaller |
| 看日志 | `pymobiledevice3 syslog live --process AppCore` | 崩了第一时间能看到原因 |
| 判断装机失败原因 | `docs/10` 的排查顺序 | 安装失败 vs 启动失败 vs 白屏，三类不同 |

---

## 6. 常见问题

| 现象 | 原因 | 处理 |
|---|---|---|
| 装完打不开，提示「无法验证 App」 | 证书过期（免费 7 天） | 重签，或开计划任务 |
| `ApplicationVerificationFailed` | 描述文件不含这台设备的 UDID | `release.ps1 -AutoUdid` 重签 |
| `pymobiledevice3` 找不到设备 | 没信任 / 没驱动 / 没开发者模式 | `Get-DeviceInfo.ps1` 会列四步 |
| TrollStore 装不上 ipa | 系统版本已修复 CoreTrust | 换路线 B/C |
| 装上了但白屏 | 见 `docs/11`：用模拟器排查控制流，或看 syslog | `pymobiledevice3 syslog live` |

---

## 7. 一句话

**不上架的话，最硬的约束只有「iOS 版本」。**
iOS ≤ 17.0 → TrollStore，一个 Apple 账号都不用；
否则 → 免费账号 7 天续一次，或者花 $99 换一年清净。
从「编出来」到「装上去」，本仓库都已经接好了。
