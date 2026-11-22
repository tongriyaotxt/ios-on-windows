# 03 · 从 Windows 把 IPA 传进 App Store Connect

> 这一节是整套方案的技术核心：**上传不再需要 macOS**。
> 实现：`scripts/asc-upload.ps1`　鉴权：`scripts/lib/AscJwt.ps1`

---

## 1. 三选一：把二进制交给 Apple 的四条路

| 方式 | 能在 Windows 跑 | 说明 |
|---|---|---|
| **REST `buildUploads`** | ✅ | WWDC25 新增，纯 HTTPS。本仓库默认 |
| Java 版 `iTMSTransporter` | ✅ | Apple 分发的跨平台 Java CLI，2026 起必须用 `-assetFile` 而不是 `-f` |
| `Transporter.app` | ❌ | macOS 图形程序 |
| `xcrun altool` | ❌ | 躺在 Xcode 里，纯 macOS 二进制 |

> 一句话：**REST 是唯一「干净、可审计、不依赖 JVM」的路**，而且 CI 和本地是同一份代码。

---

## 2. 四步上传的完整时序

```
POST /v1/buildUploads           { bundleVersion:"42", platform:"IOS" }
   ← 201 { data: { id: "bu-xxx", attributes: { state: "AWAITING_UPLOAD" } } }

POST /v1/buildUploadFiles       { fileName, fileSize, assetType:"BUILD",
                                  relationships:{ buildUpload:{ data:{ id:"bu-xxx" }}}}
   ← 201 { data: { attributes: { uploadOperations: [
              { method:"PUT", url:"https://…", offset:0,        length:10485760,
                requestHeaders:[{name:"Content-Type",value:"application/octet-stream"}] },
              { method:"PUT", url:"https://…", offset:10485760, length:10485760, … } ]}}}

PUT  <url>  ×N                   body = ipa[offset : offset+length]
                                 headers = 完全照抄 requestHeaders，**不要加 Authorization**

PATCH /v1/buildUploads/bu-xxx    { uploaded: true }
   ← 200 { data: { attributes: { state: "COMPLETE" } } }

GET  /v1/builds?filter[app]=…&filter[version]=42
   ← processingState: PROCESSING → VALID / INVALID / FAILED
```

### 三个容易翻车的点

1. **不要给预签名 URL 加 `Authorization`**。它自带签名凭据，多一个头直接 403。
2. **分片的 `offset`/`length` 必须严丝合缝**。脚本在上传后会核对「已授权字节数 == 文件大小」，
   不等就拒绝 `PATCH uploaded:true`（否则 Apple 侧会一直卡在 PROCESSING 然后 INVALID）。
3. **`CFBundleVersion` 必须递增**。重复版本 Apple 回 `ITMS-90189 Redundant Binary Upload`，
   而 REST 侧表现为 `processingState=INVALID`。`ios.ps1 bump` 就是干这个的。

---

## 3. 跑起来

```powershell
# 凭证（一次性）
$env:ASC_KEY_ID     = 'ABCDE12345'
$env:ASC_ISSUER_ID  = '11111111-2222-3333-4444-555555555555'
$env:ASC_KEY_PATH   = '.\secrets\AuthKey_ABCDE12345.p8'
$env:ASC_APP_ID     = '6471234567'      # ASC 里 App 的数字 ID

# 传
.\scripts\asc-upload.ps1 -Ipa .\build\AppCore.ipa -BundleVersion 42

# 只看状态
.\scripts\asc-status.ps1 -AppId 6471234567 -BundleVersion 42
```

输出会在 `build\asc\upload-42.json` 留回执：

```json
{ "ipa": "...", "sizeBytes": 5242880, "bundleVersion": "42",
  "buildUploadId": "bu-xxx", "state": "COMPLETE", "uploadedAt": "2026-11-22T…" }
```

---

## 4. 离线验证（不烧真凭证）

```powershell
.\tools\test-upload.ps1
```

它做四件事：
1. 用 .NET 现场造一把 P-256 密钥，拼成**结构等价于 Apple `.p8`** 的 PKCS#8 PEM；
2. 造一个 5 MB 假 IPA；
3. 起 `tools/mock-asc-server.py`，这个 mock 会真的校验 JWT（alg/kid/aud/64 字节签名/≤20 min）、
   分片头、offset 覆盖，并在 `PATCH` 时**重组分片算 sha256**；
4. 跑完整 `asc-upload.ps1`，核对回执与 mock 报告。

本机实测输出：

```
jwt_checks: 3   chunks: 4   uploaded: true   errors: []
PASS — JWT 校验通过、4 个分片按 offset 重组、sha256 一致、回执落盘。
```

---

## 5. JWT 为什么要自己签

App Store Connect 要 ES256（P-256 + SHA-256）的 JWT，签名必须是 **R||S 定长 64 字节**，不是 DER。

Windows 上的坑：

| 尝试 | 结果 |
|---|---|
| `[ECDsa]::ImportPkcs8PrivateKey` | .NET Framework 没有这个方法（只有 .NET Core 3+） |
| `ImportParameters` 只给 `D` | 抛 `Q.X and Q.Y are required fields` |
| 自己算 `Q = d*G` | 可行（实测 200 ms），但要自己写 P-256 域运算，出错就是「签名无效」且难查 |
| **openssl 签** | 一行 `openssl dgst -sha256 -sign key.p8`，Git for Windows 自带 |

所以 `AscJwt.ps1` 的选择是：**用 openssl 签，PowerShell 只负责 DER→R||S 和 base64url**。
`selftest-jwt.ps1` 会在本地把这条路端到端验一遍（造 .p8 → 签 → 用公钥验签）。

---

## 6. 常见错误码对照

| 现象 | 含义 | 处理 |
|---|---|---|
| `401` + `NOT_AUTHORIZED` | JWT 过期 / `kid` 错 / 不是 Team Key | 重新签；确认用的是 Team API Key |
| `403` on `PUT` chunk | 给预签名 URL 加了 Authorization | 删掉那个头 |
| `409` `ENTITY_ERROR.ATTRIBUTE.INVALID` | `bundleVersion` 与 IPA 里不一致 | 用 `Info.plist` 里的真实值 |
| `processingState = INVALID` | 签名/权限/图标/隐私清单问题 | 看 `GET /v1/builds/{id}` 的 `errors`，常见 `ITMS-90034`/`90161`/`90742` |
| `ITMS-90189` | 重复 build 号 | `ios.ps1 bump` |
| 一直 `PROCESSING` > 60 min | Apple 侧卡住 | 换 build 号重传；或查 ASC 状态页 |

---

## 7. CI 里复用同一份脚本

`ci/ios-build.example.yml` 的做法值得抄：macOS runner **自带 `pwsh`**，所以 Windows 和 CI 跑的是
同一个 `asc-upload.ps1`：

```yaml
- name: Upload to App Store Connect (REST buildUploads)
  run: |
    mkdir -p ~/.appstoreconnect/private_keys
    printf '%s' "${{ secrets.ASC_API_KEY_P8 }}" > ~/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8
    pwsh -NoProfile -File scripts/asc-upload.ps1 -Ipa "$IPA" -BundleVersion "$BUILD_NUMBER" -SkipPoll
```

好处：上传逻辑只有一份，本地能对 mock 跑测试，出问题不用去 CI 里猜。
