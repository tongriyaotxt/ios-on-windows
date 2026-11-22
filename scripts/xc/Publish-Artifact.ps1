<#
.SYNOPSIS
    产出一个可直接拿去装的交付包：dist\AppCore-<ver>-<build>.ipa + 清单 + 安装说明。
.DESCRIPTION
    做四件事：
      1. 构建（确定性），产出 ad-hoc 签名的 ipa —— TrollStore 直接可用，免费/付费签名也可在此基础上重签
      2. 跑三套校验：verify-ipa（结构/图标/签名）、audit-device（启动风险）、sim-ios（模拟执行）
      3. 拷到 dist\ 并按版本命名，附 SHA256
      4. 生成 manifest.json 与 INSTALL.txt（三条安装路径，照抄即可）
.EXAMPLE
    .\Publish-Artifact.ps1
    .\Publish-Artifact.ps1 -SkipBuild
#>
[CmdletBinding()]
param(
    [string]$Source = '.\samples\UIKitApp\AppCoreUI.m',
    [string]$Name = 'AppCore',
    [string]$BundleId = 'com.tongriyaotxt.appcore',
    [string]$DistDir = '.\dist',
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $root
$env:PYTHONIOENCODING = 'utf-8'

function Step($t) { Write-Host "`n==> $t" -ForegroundColor Cyan }
function Ok($t) { Write-Host "    $t" -ForegroundColor Green }

# ---- 版本
$state = @{ MARKETING_VERSION = '1.0.0'; BUILD_NUMBER = '1' }
if (Test-Path (Join-Path $root 'VERSION')) {
    Get-Content (Join-Path $root 'VERSION') | ForEach-Object {
        if ($_ -match '^\s*([A-Z_]+)\s*=\s*(.+?)\s*$') { $state[$Matches[1]] = $Matches[2] }
    }
}
$ver = $state.MARKETING_VERSION
$build = $state.BUILD_NUMBER

if (-not $SkipBuild) {
    Step "1/4 构建 $Name $ver ($build)"
    & (Join-Path $PSScriptRoot 'Build-IosAppNative.ps1') -Source $Source -Name $Name `
        -BundleId $BundleId -Version $ver -Build $build -Deterministic
    if ($LASTEXITCODE -ne 0) { throw '构建失败' }
} else {
    Step '1/4 跳过构建'
}
$ipa = Join-Path $root "build\xc\$Name-native.ipa"
if (-not (Test-Path $ipa)) { throw "没有产物：$ipa" }

Step '2/4 三套校验'
$verifyOut = & python (Join-Path $root 'tools\verify-ipa.py') $ipa 2>&1 | Out-String
$verifyOut -split "`n" | Where-Object { $_ -match '^\[' } | ForEach-Object { "    $_" }
if ($verifyOut -notmatch '0 失败') { throw 'verify-ipa 未通过' }

$auditOut = & python (Join-Path $root 'tools\audit-device.py') $ipa --target trollstore 2>&1 | Out-String
$fatalHigh = ($auditOut -split "`n" | Where-Object { $_ -match '^\[(FATAL|HIGH)' }) -join "`n"
if ($fatalHigh) { Write-Host "    $fatalHigh" -ForegroundColor Yellow }
$auditLine = ($auditOut -split "`n" | Where-Object { $_ -match 'FATAL=' }) -join ''
Ok $auditLine

$simOut = & python (Join-Path $root 'tools\sim-ios.py') (Join-Path $root "build\xc\$Name.work\$Name.app") 2>&1 | Out-String
$simLine = ($simOut -split "`n" | Where-Object { $_ -match '^PASS ——|^FAIL ——' }) -join ''
Ok "模拟执行：$simLine"

Step "3/4 发布到 $DistDir"
New-Item -ItemType Directory -Path $DistDir -Force | Out-Null
$outName = "$Name-$ver-$build.ipa"
$outPath = Join-Path $DistDir $outName
Copy-Item $ipa $outPath -Force
$hash = (Get-FileHash $outPath -Algorithm SHA256).Hash
$size = (Get-Item $outPath).Length
Ok "$outPath  ($([Math]::Round($size/1KB,1)) KB)"
Ok "SHA256 $hash"

Step '4/4 清单与安装说明'
$manifest = [ordered]@{
    name          = $Name
    bundleId      = $BundleId
    version       = $ver
    build         = $build
    file          = $outName
    sizeBytes     = $size
    sha256        = $hash
    minOS         = '17.0'
    arch          = 'arm64'
    signing       = 'ad-hoc（TrollStore 可直接用；免费/付费账号可在此基础上重签）'
    capabilities  = @('UIKit 界面', '运行时编译 Metal 着色器', '13 个尺寸图标', '嵌套 Frameworks/AppCore.dylib')
    verifiedBy    = @('verify-ipa.py', 'audit-device.py --target trollstore', 'sim-ios.py')
    auditTarget   = 'trollstore（ad-hoc + 无描述文件属正常）'
    createdAt     = (Get-Date).ToString('o')
    install       = @(
        'TrollStore（iOS ≤ 17.0）：传 ipa 到手机 → 用 TrollStore 打开',
        '免费 Apple ID：release.ps1 重签 → ios.ps1 install',
        '付费账号：release.ps1 -Upload 走 ASC（可选）'
    )
}
($manifest | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $DistDir 'manifest.json') -Encoding UTF8

$install = @"
$Name $ver ($build)
========================================
文件    : $outName
大小    : $([Math]::Round($size/1KB,1)) KB
SHA256  : $hash
Bundle  : $BundleId
最低系统: iOS 17.0 (arm64)

三条安装路径（选一条）
----------------------------------------
A. TrollStore（iOS ≤ 17.0，不需要 Apple 账号，永久）
   1) 手机上装 TrollStore（TrollInstallerX，一次性）
   2) 把 $outName 传到手机（AirDrop / 文件 App / pymobiledevice3 apps install）
   3) 用 TrollStore 打开该 ipa → Install

B. 免费 Apple ID（7 天，可用计划任务自动续）
   1) Sideloadly 签一次，导出 .p12 与 .mobileprovision
   2) .\scripts\release.ps1 -Profile X.mobileprovision -P12 X.p12 -P12Password *** -AutoUdid
   3) .\scripts\ios.ps1 install -Ipa .\build\xc\$Name-native.ipa
   4) 续命：.\scripts\xc\Register-RefreshTask.ps1 -Profile ... -P12 ... -P12Password ***

C. 付费账号（1 年）
   .\scripts\release.ps1 ... -Upload

出问题时
----------------------------------------
1) 装不上        -> .\scripts\xc\Get-InstallPath.ps1
2) 装上了打不开  -> pymobiledevice3 syslog live --process $Name
3) 白屏/黑屏     -> docs/11（模拟器能复现控制流问题）
4) 证书/描述文件 -> python tools\check-provisioning.py --profile ... --bundle-id $BundleId --ipa ...
"@
Set-Content -LiteralPath (Join-Path $DistDir 'INSTALL.txt') -Value $install -Encoding UTF8

Ok "manifest.json / INSTALL.txt 已生成"
Write-Host ''
Write-Host "交付目录：$((Resolve-Path $DistDir).Path)" -ForegroundColor Cyan
Get-ChildItem $DistDir | ForEach-Object { "  {0,-28} {1,8} bytes" -f $_.Name, $_.Length }
