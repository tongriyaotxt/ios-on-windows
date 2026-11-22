<#
.SYNOPSIS
    一条命令把开发环境装好（Windows / Linux 均可，PowerShell 5.1+ 或 pwsh 7+）。
.DESCRIPTION
    做四件事：检查 Python → 装钉死版本的依赖 → 验证 zig 能跑 → 打印下一步。
    -Dev 额外装 pytest / ruff（跑测试与静态检查用）。
.EXAMPLE
    .\scripts\install.ps1
    .\scripts\install.ps1 -Dev
#>
[CmdletBinding()]
param(
    [switch]$Dev,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
$env:PYTHONIOENCODING = 'utf-8'

function Step($t) { Write-Host "==> $t" -ForegroundColor Cyan }
function Ok($t)   { Write-Host "    OK  $t" -ForegroundColor Green }
function Bad($t)  { Write-Host "    !!  $t" -ForegroundColor Red }

# ---- 1. Python
Step '检查 Python'
$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) { throw ' 找不到 python。装 Python 3.11+ 并加入 PATH。' }
$ver = (& python -c "import sys;print('%d.%d'%sys.version_info[:2])").Trim()
Ok "python $ver ($($py.Source))"
$major, $minor = $ver.Split('.') | ForEach-Object { [int]$_ }
if ($major -lt 3 -or ($major -eq 3 -and $minor -lt 11)) { throw " 需要 Python 3.11+，当前 $ver" }

# ---- 2. 依赖
$req = if ($Dev) { 'requirements-dev.txt' } else { 'requirements.txt' }
Step "安装依赖（$req）"
$pipArgs = @('-m', 'pip', 'install', '--disable-pip-version-check', '-r', $req)
if ($Force) { $pipArgs += '--upgrade' }
& python @pipArgs
if ($LASTEXITCODE -ne 0) { throw "pip 安装失败（exit $LASTEXITCODE）" }
Ok '依赖已安装'

# ---- 3. 验证 zig
Step '验证 zig'
try {
    $zig = (& python -c "import ziglang,os;print(os.path.join(os.path.dirname(ziglang.__file__),'zig.exe' if os.name=='nt' else 'zig'))").Trim()
} catch {
    throw ' 找不到 ziglang 包'
}
if (-not (Test-Path $zig)) { Bad "zig 路径不存在：$zig"; exit 1 }
$zv = (& $zig version).Trim()
Ok "zig $zv"

# ---- 4. 验证 openssl（签名 JWT 用）
Step '验证 openssl'
$openssl = $null
foreach ($c in @($env:OPENSSL_EXE,
                 'C:\Program Files\Git\usr\bin\openssl.exe',
                 'C:\Program Files\Git\mingw64\bin\openssl.exe')) {
    if ($c -and (Test-Path $c)) { $openssl = $c; break }
}
if (-not $openssl) { $openssl = (Get-Command openssl -ErrorAction SilentlyContinue).Source }
if ($openssl) { Ok "$(& $openssl version) ($openssl)" }
else { Bad ' 没有 openssl：JWT 签名会失败。装 Git for Windows 或 winget install ShiningLight.OpenSSL.Light' }

# ---- 5. 自检
Step '跑一遍离线自检'
& python (Join-Path $root 'tools\test-xip.py') | Out-Null
if ($LASTEXITCODE -eq 0) { Ok 'xip 解包器' } else { Bad 'xip 解包器失败' }
if (Test-Path (Join-Path $root 'scripts\selftest-jwt.ps1')) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\selftest-jwt.ps1') 2>&1 |
        Select-Object -Last 1 | ForEach-Object { Write-Host "    $_" }
}

Write-Host ''
Write-Host '下一步：' -ForegroundColor Cyan
Write-Host '  .\scripts\ios.ps1 doctor        # 工具链体检'
Write-Host '  .\tools\test-nomac-build.ps1    # 10 步全链路自测'
if ($Dev) { Write-Host '  python -m pytest tests -q       # 单元测试' ; Write-Host '  .\scripts\lint.ps1              # 静态检查' }
