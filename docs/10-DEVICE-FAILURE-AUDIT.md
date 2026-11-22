# 10 · 真机启动失败风险清单（审计结果）

> 工具：`tools/audit-device.py`（静态审计，逐条给证据）
> 对象：`build/xc/AppCore-native.ipa`（zig 真编译 + 自研签名 + 嵌套 Frameworks）
> 判定口径：**FATAL = 必然起不来；HIGH = 多数设备/版本起不来；MED = 能装但可能不对；INFO = 仅供观察**

审计从 **2 FATAL / 8 HIGH** 起步，代码能修的全部修完，现在剩 **1 FATAL / 2 HIGH** ——
剩下三条都不是代码问题，是「还没有 Apple 账号」和「还没有设备」。

---

## A. 已经修掉的（每条都能复现）

| # | 问题 | 为什么致命 | 修法 |
|---|---|---|---|
| 1 | **缺 `LC_LOAD_DYLINKER`** | 内核看到没有 dyld 声明的 Mach-O 会当静态可执行文件处理，`dyld` 根本不运行 → 进程起来就死 | `machogen.py` 增加 `LC_LOAD_DYLINKER /usr/lib/dyld` |
| 2 | **缺 `__DATA` 段** | 段布局异常，PAC 设备映射可能拒绝 | machogen 增加空 `__DATA`（16B）+ 全段 16KB 对齐 |
| 3 | **无 `LC_DYLD_INFO_ONLY` / chained fixups** | dyld 无法建立绑定表（本例零外部符号，理论上可省，但空表更稳） | 写一个全零的 `LC_DYLD_INFO_ONLY` |
| 4 | **无 `LC_SYMTAB`** | 不影响启动，影响崩溃符号化 | 写空符号表 |
| 5 | **段未按 16KB 对齐** | `dyld: malformed mach-o` | 所有段起点对齐 0x4000 |
| 6 | **Info.plist 哈希没进特殊槽 1** | bundle 级验签失败（iOS 会认为包被改过） | `codesign_lite.py --info-plist`：`nSpecialSlots=5`，slot1 = SHA-256(Info.plist) |
| 7 | **dylib 的 minos=18.0** | iOS 17 设备直接拒绝启动 | 链接目标改 `aarch64-ios.17.0` |
| 8 | **`LC_ID_DYLIB` 是构建机路径** | dyld 警告/依赖解析异常 | `-install_name @rpath/AppCore.dylib` |
| 9 | **Info.plist 缺 `CFBundleSupportedPlatforms` 等** | iOS 安装判定用 | bundle 默认补 `CFBundleSupportedPlatforms/LSRequiresIPhoneOS/DTPlatformName/DTSDKName` |

修复后的关键字段（审计输出原文）：

```
[INFO] exec.dylinker   AppCore: LC_LOAD_DYLINKER=/usr/lib/dyld
[INFO] macho.minos     AppCore: minos=17.0
[INFO] sig.cd          AppCore: CD v0x20400 pages=8 special=5 pageSize=2^12
```

---

## B. 剩下 3 条：不是代码问题

| 严重度 | 问题 | 为什么 | 怎么解 |
|---|---|---|---|
| **FATAL** | 没有 `embedded.mobileprovision` | development/ad-hoc 安装时，installd 必须比对包里的描述文件与签名里的 entitlements | 把描述文件放进 `.app`（`Build-IosAppNative -ProvisioningProfile`） |
| **HIGH** | 签名是 ad-hoc | 非越狱设备只接受 Apple 签发的证书链（amfid 校验） | `-P12 <分发证书> -Password ...`；证书用 `docs/02` 的 REST 流程在 Windows 上生成 |
| **HIGH** | 缺 entitlements（`application-identifier` / `get-task-allow`） | 没有它，安装阶段就报 `ApplicationVerificationFailed` | `-Entitlements ent.plist -TeamId <TEAMID>`，内容必须与描述文件一致 |

一句话：**这三条只要你有 $99 账号，一条命令就能补齐。**

```powershell
$env:P12_PATH='.\secrets\dist.p12'; $env:P12_PASSWORD='***'; $env:TEAM_ID='ABCDE12345'
.\scripts\xc\Build-IosAppNative.ps1 -Source .\samples\UIKitApp\AppCoreUI.m `
    -P12 $env:P12_PATH -Password $env:P12_PASSWORD -TeamId $env:TEAM_ID `
    -Entitlements .\ent.plist -ProvisioningProfile .\AppCore.mobileprovision
```

---

## C. 静态审计查不出、只能真机验的 4 条

这几条是我在设计上做的赌注，**必须在设备上跑一次才能确认**，按失败概率排序：

| # | 赌注 | 失败表现 | 兜底 |
|---|---|---|---|
| 1 | **在 dylib 的 `__attribute__((constructor))` 里调 `UIApplicationMain`** | 启动黑屏 / 卡在 launch screen；日志出现 UIKit 初始化断言 | 改用「可执行体 main 里调一个导出函数」：把 `main` 写成 `extern int appcore_main(int,char**); int main(...){return appcore_main(...);}`，可执行体不再零符号 → 需要能链接外部符号的可执行体（把 zig 的 dylib 路径换成 `-bundle` 再试，或换 rcodesign/自研链接） |
| 2 | **`objc_msgSend` 可变参数传 `CGRect`（32 字节结构）** | 界面尺寸错乱 / 崩溃在 `initWithFrame:` | 改用 `CGRectZero` + 后续 `setFrame:`（同样传结构体），或直接不设 frame（用 Auto Layout 的 `setTranslatesAutoresizingMaskIntoConstraints:` + anchor API 全是标量参数） |
| 3 | **签名页大小用 4KB**（CD 里 `pageSize=2^12`） | amfid 报 `invalid signature`（若设备按 16KB 校验） | `codesign_lite.py` 里 `PAGE_SIZE = 14` 重签再试；两个值各试一次即可定位 |
| 4 | **没有 `_CodeSignature/CodeResources` 资源信封** | 安装时报 `code object is not signed at all`（少数 iOS 版本对 bundle 级封印更严） | 生成一个最小 `CodeResources` plist（`codesign_lite.py` 可扩展） |

另外两条 MED 属于「外观」不是「能不能跑」：

- `seg.filesize` 不是页的整数倍（`__TEXT 0x49D8`、`__LINKEDIT 0x2850`）——dyld 接受，但和 Xcode 产物不一致，排查别的坑时容易误判。
- `__DATA filesize=0x10` ——空段，Apple 链接器一般给 0 或整页，我们给 16 字节。

---

## D. 装到设备后按这个顺序看日志

```powershell
# 1) 安装阶段失败（还没启动）
pymobiledevice3 apps install .\build\xc\AppCore-native.ipa
#    ApplicationVerificationFailed  -> 证书/描述文件/entitlements 不匹配（B 类）
#    A valid provisioning profile ... not found -> 没放 embedded.mobileprovision

# 2) 启动阶段失败（dyld）
pymobiledevice3 syslog live --process AppCore
#    Library not loaded: @executable_path/Frameworks/AppCore.dylib -> 路径/嵌套签名
#    Symbol not found: _xxx        -> .tbd 里少符号（把符号加进 libUIKit/libobjc）
#    code signature invalid        -> C-3（页大小）或 C-4（信封）

# 3) 起来了但白屏/黑屏
#    -> C-1（constructor 里起 UI 的时机）或 C-2（CGRect 传参）
```

---

## E. 结论

- **代码侧的启动障碍已清零**：2 个 FATAL 级的 Mach-O 结构错误、5 个 HIGH 级的签名/版本错误都修完了。
- **剩下 3 条全部指向同一件事**：还没有 Apple 账号（证书 + 描述文件 + entitlements）。
- **还有 4 条只能真机确认**，其中 2 条（constructor 时机、CGRect 传参）有明确兜底方案，1 条（页大小）改一个常量就能试，1 条（资源信封）需要补一个 plist。

换句话说：**这包现在装不上，是因为没签名；不是因为它不是 App。**
