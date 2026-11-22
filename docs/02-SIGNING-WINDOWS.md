# 02 · 在 Windows 上做代码签名资产

> 目标：不打开 Xcode，也能拿到 **分发证书 .p12 + 描述文件 .mobileprovision + 设备 UDID 注册**。
> 全部走 App Store Connect REST + 本地 openssl（Git for Windows 自带）。

---

## 1. 一次性准备：ASC API Key

App Store Connect → **Users and Access → Integrations → App Store Connect API** → 生成 Team Key。

| 拿到什么 | 形如 | 放哪 |
|---|---|---|
| Key ID | `ABCDE12345`（10 位） | `$env:ASC_KEY_ID` |
| Issuer ID | `11111111-2222-3333-4444-555555555555` | `$env:ASC_ISSUER_ID` |
| `.p8` 文件 | `AuthKey_ABCDE12345.p8` | `~\.appstoreconnect\private_keys\`（只能下一次） |

> 必须用 **Team Key**。Individual Key 在上传环节历史上一直有坑（fastlane 至今有 issue）。

```powershell
.\scripts\ios.ps1 doctor    # 会检查 key 有没有放对位置
```

---

## 2. 造证书：CSR → ASC → .cer → .p12

全部命令在 Windows PowerShell 里跑，`%OPENSSL%` 指 `C:\Program Files\Git\usr\bin\openssl.exe`。

```powershell
$ssl = 'C:\Program Files\Git\usr\bin\openssl.exe'
$dir = '.\secrets'; New-Item -ItemType Directory $dir -Force | Out-Null

# 1) 私钥 + CSR（Apple 只要 CSR，私钥永远留在你机器上）
& $ssl req -new -newkey rsa:2048 -nodes `
    -keyout "$dir\dist.key" -out "$dir\dist.csr" `
    -subj "/emailAddress=you@example.com/CN=AppCore Distribution/C=CN"

# 2) 提交 CSR 换证书（certificateType 可选 IOS_DISTRIBUTION / IOS_DEVELOPMENT）
$jwt = . scripts\lib\AscJwt.ps1; $token = New-AscJwt -KeyPath "$env:USERPROFILE\.appstoreconnect\private_keys\AuthKey_$($env:ASC_KEY_ID).p8" -KeyId $env:ASC_KEY_ID -IssuerId $env:ASC_ISSUER_ID
$csr = Get-Content "$dir\dist.csr" -Raw
$body = @{ data = @{ type = 'certificates'
                     attributes = @{ certificateType = 'IOS_DISTRIBUTION'; csrContent = $csr } } } |
        ConvertTo-Json -Depth 6
$cert = Invoke-RestMethod -Method Post -Uri 'https://api.appstoreconnect.apple.com/v1/certificates' `
          -Headers @{ Authorization = "Bearer $token" } -ContentType 'application/json' -Body $body
$cert.data.attributes.certificateContent | Set-Content "$dir\dist.cer.b64"

# 3) 解 base64 成 DER，转 PEM
[IO.File]::WriteAllBytes("$dir\dist.cer", [Convert]::FromBase64String((Get-Content "$dir\dist.cer.b64" -Raw).Trim()))
& $ssl x509 -inform der -in "$dir\dist.cer" -out "$dir\dist.pem"

# 4) 合并成 .p12（CI 只认这个）
& $ssl pkcs12 -export -inkey "$dir\dist.key" -in "$dir\dist.pem" `
    -out "$dir\dist.p12" -passout pass:$env:P12_PASSWORD -name "AppCore Distribution"
```

> 也可以完全不碰 openssl：`certreq -new` + `Import-Certificate` + `Export-PfxCertificate`
> 走 Windows 证书库，但私钥会进用户 store，换机器时导出更麻烦。个人推荐 openssl，可复现。

---

## 3. 描述文件（profile）

```powershell
# 3.1 找到（或建）bundle id
$ids = Invoke-RestMethod -Uri 'https://api.appstoreconnect.apple.com/v1/bundleIds?filter[identifier]=com.example.appcore' `
         -Headers @{ Authorization = "Bearer $token" }
$bundleIdResId = $ids.data[0].id

# 3.2 注册设备（ad-hoc 必须；App Store 分发可跳过）
$udid = '00008030-001A2C3E0E91802E'      # iPhone 上：设置 → 通用 → 关于本机（或 pymobiledevice3 usbmux list）
$dev = @{ data = @{ type = 'devices'
                    attributes = @{ name = 'iPhone-YG'; platform = 'IOS'; udid = $udid } } } | ConvertTo-Json -Depth 6
Invoke-RestMethod -Method Post -Uri 'https://api.appstoreconnect.apple.com/v1/devices' `
  -Headers @{ Authorization = "Bearer $token" } -ContentType 'application/json' -Body $dev

# 3.3 建 profile（profileType: IOS_APP_STORE / IOS_APP_ADHOC / IOS_APP_DEVELOPMENT）
$pf = @{ data = @{
    type = 'profiles'
    attributes = @{ name = 'AppCore AdHoc'; profileType = 'IOS_APP_ADHOC' }
    relationships = @{
      bundleId  = @{ data = @{ type = 'bundleIds'; id = $bundleIdResId } }
      certificates = @{ data = @(@{ type = 'certificates'; id = $cert.data.id }) }
      devices   = @{ data = @(@{ type = 'devices'; id = '<device resource id>' }) }
    } } } | ConvertTo-Json -Depth 8

$profile = Invoke-RestMethod -Method Post -Uri 'https://api.appstoreconnect.apple.com/v1/profiles' `
             -Headers @{ Authorization = "Bearer $token" } -ContentType 'application/json' -Body $pf
[IO.File]::WriteAllBytes("$dir\AppCore.mobileprovision", [Convert]::FromBase64String($profile.data.attributes.profileContent))
```

**校验装对了没**（不需要 Mac）：

```powershell
# 用 openssl 解 profile 里的 plist，确认 UDID / 证书 / 过期时间
& $ssl smime -verify -noverify -inform der -in .\secrets\AppCore.mobileprovision 2>$null |
  Select-String -Pattern 'UDID|ExpirationDate|com.example'
```

---

## 4. 两条签名路线的分工

| 场景 | 谁来签 | 命令 |
|---|---|---|
| 云端 CI 编译 | `xcodebuild -allowProvisioningUpdates` 自动取/建 | 见 `.github/workflows/ios.yml` |
| CI 要「固定资产」 | `fastlane match`（Windows 可跑，纯 Ruby） | `fastlane certs_read` |
| 本地给 IPA 重签（换证书/换设备） | `zsign`（C++，Windows 有构建） | `zsign -k dist.p12 -p pass -m App.mobileprovision -o out.ipa in.ipa` |
| 纯离线、手工 | `rcodesign`（Rust，跨平台） | `rcodesign sign --p12-file dist.p12 --p12-password pass App.app` |

> 重签是「OTA 直装」和「拿到别人给的 IPA 自己装」的关键一步，`zsign` 在 Windows 上工作良好；
> `rcodesign`（apple-codesign）还能生成 `.p12`、验签、甚至解封装 `.mobileprovision`。

---

## 5. 别踩这些坑

| 坑 | 症状 | 解法 |
|---|---|---|
| 用了 Development 证书上传 | `ITMS-90034 Invalid Signature` | 分发必须 `IOS_DISTRIBUTION` + `IOS_APP_STORE` profile |
| profile 里没有设备 UDID | 装到手机提示「无法安装」 | ad-hoc profile 必须包含目标设备，改完要重新下载 |
| `.p12` 密码为空 | CI 报 `MAC verification failed` | 密码统一走 `$env:P12_PASSWORD` |
| 证书数量到上限（3 张分发证书） | `409 ENTITY_ERROR` | 先 `GET /v1/certificates` 列出，`DELETE` 掉旧的 |
| 描述文件过期（1 年） | 突然装不上/上传被拒 | `GET /v1/profiles` 查 `expirationDate`，写进日历 |
| 换了 Team | key 的 Issuer ID 也变 | 重新生成 key，别复用旧 .p8 |
