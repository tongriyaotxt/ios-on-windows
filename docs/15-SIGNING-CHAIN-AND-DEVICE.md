# 15 · 签名链：私钥从哪来，手机能给什么

> 一句话回答「能不能连上手机自动拿到私钥」：**不能。私钥从来不在手机里，也不需要"获取"——它由你自己的机器生成。**
> 手机能给的是 **UDID**，Apple 能给的是**证书**，两者都不是私钥。

---

## 1. 先把四个角色的职责摆清楚

```
你（这台 Windows）                Apple                         iPhone
─────────────────                ─────                         ──────
生成密钥对  ──CSR──►  用 WWDR CA 给 CSR 签字
                     ◄──证书──
私钥 + 证书 = 签名能力
                     ──描述文件──►  （TeamID + bundle id + UDID + 证书）
                                          amfid 只做验证：拿公钥验签名
```

| 东西 | 谁生成 | 存在哪 | 能不能"从手机拿" |
|---|---|---|---|
| **私钥（.p8 / .p12 里的 key）** | 你（`openssl req` / Keychain / 我们的脚本） | 你的机器 | ❌ 手机里根本没有 |
| **证书（.cer）** | Apple 签发（对你的 CSR 签名） | 你的机器 + ASC | ❌ 手机不存 |
| **描述文件（.mobileprovision）** | Apple（ASC） | 你的机器 + 包里 | ❌ |
| **UDID** | 手机硬件 | 手机 | ✅ **这就是连手机的意义** |
| 设备证书（lockdown 配对用） | 手机 + 主机各存一份 | 两边 | ✅ 但它**不能签 App** |

手机上的 `amfid` 是**验证方**：它拿 `embedded.mobileprovision` 里的证书去验你包的 CMS 签名。
验证方不持有签名私钥 —— 这是公钥密码学的基本结构，不是 Apple 的限制。

---

## 2. 那"自动"能自动到什么程度

| 目标 | 免费 Apple ID | 付费开发者账号（$99/年） |
|---|---|---|
| 自动拿到 UDID | ✅ | ✅ |
| 自动生成**私钥** | ✅（本地生成，本来就自动） | ✅ |
| 自动拿到**证书** | 🟡 只能通过第三方工具（AltStore / Sideloadly）调 Apple 的免费配置接口 | ✅ `POST /v1/certificates`（`docs/02` 已实现） |
| 自动生成描述文件 | 🟡 同上 | ✅ `POST /v1/profiles`（已实现） |
| 有效期 | **7 天**，到期要重签 | 1 年 |
| 上架 / TestFlight | ❌ | ✅ |

### 免费 Apple ID 那条路具体怎么走

```text
Sideloadly / AltStore（Windows）
  ├─ 用你的 Apple ID 登录（含 2FA）
  ├─ 调 Apple 的免费配置接口，在你本机生成密钥对 → 提交 CSR → 拿回开发证书
  ├─ 注册这台设备 UDID → 生成 7 天描述文件
  └─ 可以导出 .p12 与 .mobileprovision
        ↓
  喂给本仓库：release.ps1 -P12 <导出的.p12> -Profile <导出的.mobileprovision> -Udid <自动读到的>
```

也就是说：**"连上手机 → 自动有可用证书"在免费账号下是成立的，但那是第三方工具在做，不是手机给的。**

---

## 3. 为什么不自己实现那条"免费配置协议"

它需要三样东西：

1. Apple 私有的 `developerservices2` 接口（无公开文档，靠逆向）
2. **anisette** 设备证明头（由 Apple 的 AOSKit 生成，本质是一段机器指纹 + 签名，社区实现需要每台机器注入）
3. 2FA 会话管理

Apple 会周期性改这些；AltStore 社区为此维护了多年（`anisette-server`、`Provision` 等）。
自己重写一遍 = 长期军备竞赛，收益却只是"省掉装一个 Sideloadly"。

**所以本仓库的选择是：把证书获取交给成熟工具，把证书之后的每一步（构建、签名、打包、校验、上传、装机）握在自己手里。**

---

## 4. 已经自动化掉的部分

### `scripts/xc/Get-DeviceInfo.ps1`

插上手机就能读（优先 `pymobiledevice3`，退回 `libimobiledevice`）：

```
Udid                                  Name        iOS     Connection  Source
00008030-001A2C3E0E91802E             YG-iPhone   18.1    USB         pymobiledevice3
```

没装工具/没插设备时优雅退化，并给出四步修复提示（驱动 → 命令行 → 信任 → 开发者模式）。

### `scripts/release.ps1 -AutoUdid`

```powershell
.\scripts\release.ps1 -Profile AppCore.mobileprovision -P12 dist.p12 -P12Password *** -AutoUdid -Upload
```

`-AutoUdid` 会自动去问设备拿 UDID，然后带着它去校验描述文件。
**App Store 分发不需要 UDID**，所以这条只是开发/ad-hoc 的便利。

---

## 5. 一句话

**手机是验签方，不是签名方。**
"自动获取私钥"这个需求本身不成立 —— 私钥一直在你手里；真正需要向 Apple 要的只有那张证书，
而它需要的是**一个 Apple ID**（免费 7 天 / 付费 1 年），不是一台手机。
