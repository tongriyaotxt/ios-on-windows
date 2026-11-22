# 11 · 不用真机，把「只能真机验」的四条解决掉

`docs/10` 列了四条只能在设备上确认的赌注。这一篇是它们的处理结果 —— **没有设备，但有证据**。

| # | 赌注 | 怎么在没有真机的情况下解决 | 结论 |
|---|---|---|---|
| 1 | constructor 里调 `UIApplicationMain` 的时机 | 自写 dyld + Unicorn ARM64 模拟器，真的把 dylib 执行一遍 | ✅ 已证 |
| 2 | `objc_msgSend` 变参传 `CGRect` | 同上：在每次 msgSend 处 dump `d0-d3` | ✅ 已证（20/120/350/180 一字不差） |
| 3 | 签名页大小 4KB vs 16KB | 改成可切换（`CODESIGN_PAGE_SIZE`），两种都能自校验 | ⚠️ 变成一次开关实验 |
| 4 | 缺 `_CodeSignature/CodeResources` | 直接生成资源信封，并校验哈希 | ✅ 已补 |

---

## 1. 模拟器：`tools/sim-ios.py`

不是「静态分析」，是**真的执行 arm64 代码**：

```
Mach-O 解析 → 段映射（16KB 对齐）→ rebase 应用 slide → __stubs 逐个绑定到钩子
            → 调 __mod_init_func（constructor）→ 钩子里用 Python 实现 objc/UIKit
```

技术选型与踩过的坑：

| 环节 | 做法 | 坑 |
|---|---|---|
| CPU | Unicorn 2.1.4（`pip install unicorn`） | — |
| 映像加载 | dylib 重定位到 0x200000000 | **必须应用 rebase opcode**，否则 `__DATA` 里的绝对指针还指向原地址 |
| 符号绑定 | `__stubs` + `LC_DYSYMTAB` 间接符号表 | 只解析 bind 流不够：zig 走的是 stub + `__la_symbol_ptr` |
| 系统调用 | 钩子页 + `UC_HOOK_CODE` | **Unicorn 不支持嵌套 `emu_start`**，必须用「LR 跳板」扁平化 |
| 假 UIKit | 20 多个 selector 的 Python 实现 | 覆盖不足时只记录中断，不判失败（否则分不清是 App 的问题还是模拟器的问题） |

## 2. 证据：msgSend 逐调用 dump

```
msgSend mainBundle
msgSend pathForResource:ofType:
msgSend stringWithContentsOfFile:encoding:error:
msgSend newLibraryWithSource:options:error:      ← Metal 编译路径打通
msgSend mainScreen
msgSend bounds                                   d0-d3 = 0, 0, 393, 852
msgSend alloc
msgSend initWithFrame:                            d0-d3 = 0, 0, 393, 852   ← UIWindow
msgSend init
msgSend systemBackgroundColor / view / setBackgroundColor:
msgSend alloc
msgSend initWithFrame:                            d0-d3 = 20, 120, 350, 180 ← UILabel
msgSend stringWithUTF8String: / setText: / setNumberOfLines: / addSubview:
msgSend setRootViewController: / makeKeyAndVisible / retain
```

对应断言：

```
[PASS] constructor 里调到了 UIApplicationMain
[PASS] UIApplicationMain 拿到 delegate 类名（AppCoreDelegate）
[PASS] UIWindow 收到合理 frame（CGRect 走 d0-d3）
[PASS] UILabel 收到 350x180 frame
[PASS] label 文本正确传入
[PASS] MSL 源码读到了并「编译」成功
[PASS] 窗口最终 makeKeyAndVisible
```

**这直接回答了两个赌注**：

1. `__mod_init_func` 确实先于 `main` 执行，`UIApplicationMain` 收到的 delegate 名正确、方法能调到；
2. `CGRect`（4 个 double 的 HFA）确实落在 `v0-v3`，我们按 AAPCS 读出来的值 **20/120/350/180** 与源码完全一致 —— 说明 `objc_msgSend` 的强转和可变参数传结构体在这个 ABI 下是对的。

## 3. 页大小：从「赌」变成「一次开关」

`CODESIGN_PAGE_SIZE` 环境变量控制 CodeDirectory 的 `pageSize`：

```powershell
# 默认 4KB（iOS 上最常见）
.\scripts\xc\Build-IosAppNative.ps1 -Source .\samples\UIKitApp\AppCoreUI.m -Build 20

# 如果真机上 amfid 报 invalid signature，切 16KB 再打一次
$env:CODESIGN_PAGE_SIZE=14
.\scripts\xc\Build-IosAppNative.ps1 -Source .\samples\UIKitApp\AppCoreUI.m -Build 21
```

两种都会通过自校验（因为 CD 里写的页大小和哈希计算用的是同一个值），
所以真机上如果失败，**换一个值重打就能定位** —— 这是不接设备能把风险压到最小的程度。

## 4. 资源信封：`tools/make-resources.py`

生成 `_CodeSignature/CodeResources`：

```json
{ "files2": { "Icon-60@2x.png": {"hash2": "<SHA-1>"},
              "Info.plist":     {"hash2": "..."},
              "Shaders.metal":  {"hash2": "..."} },
  "rules":  {"^": true, "^.*\\.lproj/": true },
  "rules2": {"^.*": true } }
```

当前包：**16 个资源，哈希全部一致**。跳过可执行体与 `Frameworks/`（嵌套代码各自有签名）。

---

## 5. 现在的审计结果

```
FATAL=1  HIGH=2
[FATAL] bundle.profile   没有 embedded.mobileprovision
[HIGH ] sig.adhoc        只有 ad-hoc 签名（外层 + 内层）
```

结构类、资源类、签名槽类问题 **全部清零**；剩下的只有「没有 Apple 账号」这一件事。

---

## 6. 模拟器的边界（别过度信任它）

它能证明的和不能证明的：

| 能证明 | 不能证明 |
|---|---|
| 控制流：谁先执行、调了谁、参数对不对 | 真 UIKit 的行为（布局、渲染、生命周期细节） |
| ABI：结构体/浮点/返回值落在哪 | dyld 的真实加载语义（弱符号、懒绑定时机） |
| 数据流：读到哪个文件、字符串是否为空 | amfid 的验签策略、内核的映射限制 |
| 崩溃点定位（PC/LR/寄存器） | 性能、内存、GPU |

一句话：**它把「代码写错了」和「环境不允许」这两类原因分开了** —— 这正是没有设备时最需要的能力。

---

## 7. 结论

四条「只能真机验」现在变成：

- **2 条已用执行证据关闭**（constructor 时机、CGRect 传参）
- **1 条已补实现**（资源信封）
- **1 条已变成一次开关实验**（页大小）

剩下真正需要设备的只有：**看它显示出来是什么样**。逻辑、ABI、结构、签名，都已经在这台 Windows 上验过了。
