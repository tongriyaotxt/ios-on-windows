# 14 · 剩下那一步：把「凭证 + 设备」压成两条命令

`docs/10` 结尾说剩下的都是「没有 Apple 账号」。这篇是那件事的处理结果。

---

## 1. 先把「剩下」拆开

| 剩下的事 | 能不能在 Windows 上做 | 处理 |
|---|---|---|
| Apple 签发的证书 | ❌ 必须有账号 | 用**结构等价**的测试证书把链路跑通，换真证书只改参数 |
| 描述文件 | ❌ 必须从 ASC 生成 | 同上；并写了校验器，换真的前先把四种不一致排掉 |
| entitlements 与描述文件对齐 | ✅ | `check-provisioning.py --emit-entitlements` 自动导出 |
| 装到手机 | ❌ 必须有设备 | 装机命令早就有（`ios.ps1 install` / OTA），只等设备 |
| 提交审核 | ✅（REST） | 未实现，可复用同一套 JWT（见 §5） |

**结论**：真正做不了的只有两件 —— Apple 的私钥、苹果的手机。其余全部可以在 Windows 上闭环。

---

## 2. 新增两样东西

### 2.1 `tools/check-provisioning.py` —— 装机失败的头号原因检测器

真机上 `ApplicationVerificationFailed` 几乎都出在这四者的不一致上，而这些**全都能静态比对**：

```
[ ok  ] 描述文件：AppCore AdHoc  team=ABCDE12345  设备=1  ad-hoc/development
[ ok  ] 有效期还剩 299 天（2027-09-18）
[ ok  ] application-identifier 匹配：ABCDE12345.com.tongriyaotxt.appcore
[ ok  ] UDID 已登记：00008030-001A2C3E0E91802E
[ ok  ] 证书匹配描述文件（CN=Apple Distribution: Test (ABCDE12345)）
[ ok  ] 签名 entitlements 是描述文件的子集（4 项）
[ ok  ] ipa 内的描述文件与你给的是同一份
```

反例都验过（`py_tests/test_provisioning.py`，5 个用例）：

- bundle id 不匹配 → FAIL，并指出实际值
- UDID 未登记 → FAIL，并提示会 `ApplicationVerificationFailed`
- p12 密码错 → FAIL（不抛栈）
- `--emit-entitlements` → 导出可直接喂给构建的 plist

### 2.2 `scripts/release.ps1` —— 一条命令从源码到 TestFlight

```
1/5 描述文件校验（含 entitlements 自动导出）
2/5 构建（真证书 + 描述文件 + 确定性构建）
3/5 静态校验 + 启动审计 + 签名/描述文件一致性
4/5 上传（REST buildUploads）
5/5 回执与 TestFlight 链接
```

`-DryRun` 只打印计划，不需要任何凭证。

---

## 3. 用「等价凭证」跑出来的结果

用自签的分发证书 + 自造的描述文件（CMS 格式与 Apple 一致）跑真链路：

```
==> 1/5 描述文件校验      7 通过, 0 警告, 0 失败
==> 2/5 构建              CMS 签名（flags=0x0，非 ad-hoc）
==> 3/5 审计              FATAL=0  HIGH=0   共 12 条
==> 4/5 上传              跳过（-Upload 未给）
```

**关键变化**：`docs/10` 里那三条 FATAL/HIGH（缺描述文件、ad-hoc 签名 ×2）**全部消失**——
因为这次是「证书 + 描述文件 + entitlements」齐套签的。剩下 0 条阻断项。

换句话说：**换掉证书文件，剩下的全一样。**

---

## 4. 拿到账号后的操作顺序（10 分钟）

```powershell
# 1) 把 Apple 给的三个文件放好
#    AuthKey_XXXXXXXXXX.p8 / dist.p12 / AppCore.mobileprovision

# 2) 校验（不一致会明确告诉你哪一项）
.\scripts\check-provisioning.py --profile AppCore.mobileprovision `
    --bundle-id com.tongriyaotxt.appcore --p12 dist.p12 --p12-password *** `
    --udid <你的 UDID>

# 3) 一条命令发布
.\scripts\release.ps1 -Profile AppCore.mobileprovision -P12 dist.p12 `
    -P12Password *** -P8 .\secrets\AuthKey_XXXX.p8 -KeyId XXXXXXXX `
    -IssuerId <uuid> -AppId <数字ID> -TeamId <10位> -Upload

# 4) 装机（有设备时）
.\scripts\ios.ps1 install -Ipa .\build\xc\AppCore-native.ipa
```

---

## 5. 还没做的（可选，不影响装机）

- **提交审核**：`POST /v1/appStoreVersions` → `POST /v1/reviewSubmissions` → `POST /v1/reviewSubmissionItems`。
  端点已知，鉴权同一套 JWT；目前尚未实现。
- **真机 UI 回归**：模拟器能给控制流/ABI/数据流证据（`docs/11`），但像素问题只能上机看。

---

## 6. 一句话

**剩下的问题不是「Windows 做不到」，而是「Apple 的私钥不在我手里」。**
现在这条链路上，除了那把私钥和那台手机，没有任何一步依赖别人。
