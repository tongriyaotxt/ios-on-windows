# 12 · 工程约定

这份文件是「第二个人接手时需要知道的所有规则」。

---

## 1. 退出码

所有脚本统一：

| 码 | 含义 | 谁用 |
|---|---|---|
| **0** | 通过 | 全部 |
| **1** | 阻断性失败（不能继续/不能交付） | 全部 |
| **2** | 通过但有警告（值得看，不阻塞） | `verify-ipa.py`、`audit-device.py`、`lint.ps1` |

CI 里 `set -e` 会拦 1，但允许 2 —— 由调用方决定是否升级为错误。
`test-nomac-build.ps1` 只把 1 当失败，2 记录为 `warn`。

## 2. 目录职责

```
Sources/AppCore/        纯 Swift 逻辑（Windows 可 swift test）
App/                    SwiftUI 壳（仅 macOS 编译）
scripts/                编排层：ios.ps1 是唯一入口，其余按功能命名
scripts/lib/            被 dot-source 的库（AscJwt / Bootstrap）
scripts/xc/             交叉编译相关（zig / 签名 / 打包 / SDK）
tools/                  单文件工具（Python 为主），每个都能独立 CLI 运行
py_tests/               pytest（不要放 Tests/，那里是 SwiftPM 的）
Tests/                  SwiftPM 单测（Xcode/CI 用）
docs/                   编号即顺序：00 架构 → 12 约定
build/                  产物与临时物（git 忽略）
```

## 3. 命名与编码

| 项 | 规则 |
|---|---|
| PowerShell 文件 | `Verb-Noun.ps1`（PSScriptAnalyzer 检查）；**必须 UTF-8 with BOM**（PS 5.1 否则按 GBK 读，中文注释会吞行） |
| Python 文件 | 小写+短横线；`main()` + `sys.exit()`；`PYTHONIOENCODING=utf-8` |
| 常量 | 全大写；Mach-O 常量与 Apple 头文件同名（`LC_*`、`MH_*`） |
| 注释语言 | 中文解释「为什么」，英文保留 API/字段名 |

## 4. 版本与可复现

- 依赖钉死在 `requirements.txt`：`ziglang==0.17.1`、`unicorn==2.1.4`、`cryptography==48.0.1`
- 构建加 `-Deterministic` 时：Mach-O 的 `LC_UUID` 由 `identifier+minos` 派生，
  zip 条目时间戳固定为 1980-01-01 并排序 —— 同样输入产出同样字节
- 产物回执（`build-receipt.json` / `upload-*.json`）里的时间戳不影响二进制本身

## 5. 签名与凭证

| 凭证 | 放哪 | 谁能读 |
|---|---|---|
| ASC API Key `.p8` | `~/.appstoreconnect/private_keys/`（或 `secrets/`，已 gitignore） | 本机 |
| 分发证书 `.p12` | `secrets/`，密码走 `$env:P12_PASSWORD` | 本机 |
| 描述文件 | 构建时传入，产物内 `embedded.mobileprovision` | 公开 |

禁止：把 `.p8`/`.p12`/`.env` 提交进仓库；把密码写进脚本。

## 6. 改动流程

1. 改代码 → `.\scripts\lint.ps1`（ruff + PSScriptAnalyzer + 语法解析）
2. `python -m pytest py_tests -q`
3. `.\tools\test-nomac-build.ps1`（10 步全链路）
4. 动了签名/打包/加载命令 → 必须重跑 `tools\audit-device.py` 与 `tools\sim-ios.py`
5. CHANGELOG 加一行，提交

## 7. 已知约束（改之前先读）

- `zig` 的 `-target aarch64-ios` 是非官方用法：**升级 zig 必须重跑 10 步自测**
- 手写 `.tbd` 只列了用到的符号：新增系统 API 时**编译能过、运行会崩**，必须补符号并跑模拟器
- 可执行体走「dylib + constructor」是为了绕开 zig 链接器在 `MH_EXECUTE` 上的溢出：
  换 zig 版本后若溢出消失，应改回正常的 `main` 路径
- iOS SDK 相关脚本（`Get-IosSdk.ps1`、`xip-extract.py`）只处理文件，不修改系统
