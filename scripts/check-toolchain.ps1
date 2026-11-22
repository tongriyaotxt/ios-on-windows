<#
.SYNOPSIS
    iOS-on-Windows 工具链体检。报出每一项「能不能用 / 缺什么 / 一行修好」。
.DESCRIPTION
    只读探测，不改系统；-Fix 只做两件事：把已知路径写进当前进程 PATH、把 ~/.appstoreconnect
    目录建好。所有判定都基于真实调用，不看目录名猜。
.EXAMPLE
    .\check-toolchain.ps1
    .\check-toolchain.ps1 -Fix -Json .\build\toolchain.json
#>
[CmdletBinding()]
param(
    [switch]$Fix,
    [string]$Json
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\Bootstrap.ps1')
$rows = New-Object System.Collections.Generic.List[object]

function Add-Row([string]$Area, [string]$Item, [string]$Status, [string]$Detail, [string]$FixHint) {
    $rows.Add([pscustomobject]@{ Area = $Area; Item = $Item; Status = $Status; Detail = $Detail; Fix = $FixHint })
}

function Test-Cmd([string]$Name) {
    $c = Get-Command $Name -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    return $null
}

# ---- 0. PATH 修补（只影响当前进程） ---------------------------------------
$pathFixes = @(
    'C:\Program Files\Git\cmd',
    'C:\Program Files\Git\usr\bin',
    'C:\Program Files\GitHub CLI',
    'F:\toolchains\flutter\bin'
)
if ($Fix) {
    foreach ($p in $pathFixes) {
        if ((Test-Path $p) -and ($env:PATH -notlike "*$p*")) {
            $env:PATH = "$p;$env:PATH"
        }
    }
    $ascDir = Join-Path $env:USERPROFILE '.appstoreconnect\private_keys'
    if (-not (Test-Path $ascDir)) { New-Item -ItemType Directory -Path $ascDir -Force | Out-Null }
}

# ---- 1. 构建侧 ------------------------------------------------------------
foreach ($t in @(
        @{ N = 'git';      A = 'build'; D = '版本控制 / CI 触发' },
        @{ N = 'gh';       A = 'build'; D = 'GitHub CLI，触发云端构建' },
        @{ N = 'node';     A = 'build'; D = 'Expo / EAS CLI / RN 生态' },
        @{ N = 'npm';      A = 'build'; D = '包管理' },
        @{ N = 'python';   A = 'build'; D = '脚本 / pymobiledevice3' },
        @{ N = 'flutter';  A = 'build'; D = 'Flutter 3.x（可选路线）' },
        @{ N = 'swift';    A = 'build'; D = 'Windows 上编译纯 Swift 核心模块' },
        @{ N = 'dotnet';   A = 'build'; D = '.NET（MAUI 路线 / 本工具链脚本宿主）' }
    )) {
    $p = Test-Cmd $t.N
    if ($p) {
        $ver = try { (& $t.N --version 2>&1 | Select-Object -First 1) } catch { '' }
        Add-Row $t.A $t.N 'OK' "$p  $ver" ''
    } else {
        Add-Row $t.A $t.N 'MISSING' $t.D "装它，或把含 $($t.N).exe 的目录加进 PATH"
    }
}

# ---- 2. 签名/上传侧 --------------------------------------------------------
$openssl = $null
foreach ($c in @($env:OPENSSL_EXE, 'C:\Program Files\Git\usr\bin\openssl.exe', 'C:\Program Files\Git\mingw64\bin\openssl.exe')) {
    if ($c -and (Test-Path $c)) { $openssl = $c; break }
}
if (-not $openssl) { $openssl = Test-Cmd 'openssl' }
if ($openssl) { Add-Row 'sign' 'openssl' 'OK' "$openssl  (JWT ES256 签名)" '' }
else { Add-Row 'sign' 'openssl' 'MISSING' 'ASC JWT 签名引擎' 'winget install Git.Git（自带 openssl）' }

$keyDir = Join-Path $env:USERPROFILE '.appstoreconnect\private_keys'
$keys = @()
if (Test-Path $keyDir) { $keys = Get-ChildItem $keyDir -Filter 'AuthKey_*.p8' -ErrorAction SilentlyContinue }
if ($keys.Count -gt 0) { Add-Row 'sign' 'ASC API key' 'OK' "$($keys.Count) key(s) in $keyDir" '' }
else { Add-Row 'sign' 'ASC API key' 'MISSING' 'App Store Connect → Users and Access → Integrations' '下载 AuthKey_XXXXXXXXXX.p8 到 ~\.appstoreconnect\private_keys\' }

foreach ($v in 'ASC_KEY_ID', 'ASC_ISSUER_ID') {
    if ([Environment]::GetEnvironmentVariable($v)) { Add-Row 'sign' $v 'OK' '已设置' '' }
    else { Add-Row 'sign' $v 'MISSING' '环境变量未设置' "setx $v <value>" }
}

# ---- 3. 设备侧 ------------------------------------------------------------
$amds = Get-Service -Name 'Apple Mobile Device Service' -ErrorAction SilentlyContinue
if ($amds) { Add-Row 'device' 'Apple Mobile Device Service' 'OK' $amds.Status '' }
else { Add-Row 'device' 'Apple Mobile Device Service' 'MISSING' 'Windows 认不到 iPhone 的前提' 'winget install Apple.AppleDevices（或装 iTunes）' }

foreach ($t in @(
        @{ N = 'idevice_id';       D = '列设备' },
        @{ N = 'ideviceinstaller'; D = '装/卸 IPA' },
        @{ N = 'idevicesyslog';    D = '实时日志' },
        @{ N = 'idevicecrashreport'; D = '拉崩溃报告' }
    )) {
    $p = Test-Cmd $t.N
    if ($p) { Add-Row 'device' $t.N 'OK' $p '' }
    else { Add-Row 'device' $t.N 'MISSING' $t.D 'libimobiledevice 套件（或 pymobiledevice3）' }
}

# ---- 4. 云端构建侧 --------------------------------------------------------
if (Test-Cmd 'gh') {
    $auth = (& gh auth status 2>&1) -join ' '
    if ($auth -match 'Logged in') { Add-Row 'cloud' 'gh auth' 'OK' '已登录' '' }
    else { Add-Row 'cloud' 'gh auth' 'WARN' '未登录或 token 失效' 'gh auth login' }
} else { Add-Row 'cloud' 'gh auth' 'MISSING' 'GitHub CLI 不在 PATH' 'winget install GitHub.cli' }

$eas = Test-Cmd 'eas'
if ($eas) { Add-Row 'cloud' 'eas-cli' 'OK' $eas '' }
else { Add-Row 'cloud' 'eas-cli' 'MISSING' 'Expo 云端 iOS 构建（真·零 Mac 路线）' 'npm i -g eas-cli' }

# ---- 5. 网络（云端构建产物拉取 / 上传） ------------------------------------
foreach ($h in 'api.appstoreconnect.apple.com', 'github.com', 'registry.npmjs.org') {
    $r = Test-Connection -ComputerName $h -Count 1 -Quiet -ErrorAction SilentlyContinue
    if ($r) { Add-Row 'net' $h 'OK' 'ICMP 可达' '' }
    else { Add-Row 'net' $h 'WARN' 'ICMP 不通（可能只是禁 ping，需实测 HTTPS）' "Test-NetConnection $h -Port 443" }
}

# ---- 输出 -----------------------------------------------------------------
$rows | Format-Table -AutoSize -Property Area, Item, Status, Detail
$ok = ($rows | Where-Object Status -eq 'OK').Count
$miss = ($rows | Where-Object Status -eq 'MISSING').Count
$warn = ($rows | Where-Object Status -eq 'WARN').Count
Write-Host ""
Write-Host "OK=$ok  MISSING=$miss  WARN=$warn" -ForegroundColor ($(if ($miss) { 'Yellow' } else { 'Green' }))
$blocking = $rows | Where-Object Status -eq 'MISSING'
if ($blocking) {
    Write-Host "`n需要补的：" -ForegroundColor Yellow
    $blocking | ForEach-Object { Write-Host ("  - {0,-24} {1}" -f $_.Item, $_.Fix) }
}
if ($Json) {
    $dir = Split-Path -Parent $Json
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    ($rows | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $Json -Encoding UTF8
    Write-Host "`nreport -> $Json"
}
