<#
.SYNOPSIS
    判断「这台手机怎么装上并跑起来」：三条路里选一条，并打印确切的命令。
.DESCRIPTION
    目标不是上架，只是在自己手机上跑，所以有三条路：

      A. TrollStore（iOS ≤ 17.0，且未修复 CoreTrust）—— 不需要任何 Apple 账号，
         永久签名，直接装我们产出的 ad-hoc ipa。**这是最省事的一条**
      B. 免费 Apple ID（Sideloadly / AltStore）—— 需要账号，证书 7 天，到期要重签；
         我们负责它之后的每一步（构建/签名/打包/装机）
      C. 付费账号（$99/年）—— 证书 1 年，最省心

    本脚本做三件事：读设备信息 → 判断可用路径 → 打印下一步命令。
.EXAMPLE
    .\Get-InstallPath.ps1
#>
[CmdletBinding()]
param(
    [string]$Ipa = '.\build\xc\AppCore-native.ipa',
    [string]$Profile,
    [string]$P12,
    [string]$Udid
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $root
$env:PYTHONIOENCODING = 'utf-8'
. (Join-Path $root 'scripts\lib\Bootstrap.ps1')

Write-Host "==> 1/3 读取设备" -ForegroundColor Cyan
$dev = $null
try {
    $json = & (Join-Path $PSScriptRoot 'Get-DeviceInfo.ps1') -Json (Join-Path $root 'build\device.json') 2>$null
    if (Test-Path (Join-Path $root 'build\device.json')) {
        $dev = @(Get-Content (Join-Path $root 'build\device.json') -Raw | ConvertFrom-Json)[0]
    }
} catch { }

if (-not $dev) {
    Write-Host '    没读到设备。先解决这三件：' -ForegroundColor Yellow
    Write-Host '      1) winget install Apple.AppleDevices' 
    Write-Host '      2) pip install pymobiledevice3'
    Write-Host '      3) 插线 → 解锁 → 点「信任」→ 设置里打开「开发者模式」(iOS 16+)'
    Write-Host ''
    Write-Host '    没有设备也能先判断路径：把 iOS 版本告诉我，或直接看 docs/16-INSTALL-ON-DEVICE.md'
    exit 1
}

Write-Host ("    设备：{0}  iOS {1}  UDID={2}" -f $dev.Name, $dev.iOS, $dev.Udid)
if (-not $Udid) { $Udid = $dev.Udid }

Write-Host "`n==> 2/3 判断可用路径" -ForegroundColor Cyan
$ios = $null
try { $ios = [version]$dev.iOS } catch { }
$trollOk = $false
if ($ios) {
    # TrollStore 2 支持范围（截至 2026：14.0 – 16.6.1、17.0；17.0.1 起修复）
    if ($ios -lt [version]'17.0.1' -and $ios -ge [version]'14.0') { $trollOk = $true }
}

$hasProfile = $Profile -and (Test-Path $Profile)
$hasP12 = $P12 -and (Test-Path $P12)
$hasIpa = Test-Path $Ipa

if ($trollOk) {
    Write-Host '    [A] TrollStore 可用（iOS ≤ 17.0）—— 不需要 Apple 账号，推荐' -ForegroundColor Green
} else {
    Write-Host ("    [A] TrollStore 不适用（iOS {0} 已修复 CoreTrust）" -f $dev.iOS) -ForegroundColor DarkGray
}
if ($hasProfile -and $hasP12) {
    Write-Host '    [B] 免费/付费账号签名：已找到 p12 + mobileprovision' -ForegroundColor Green
} else {
    Write-Host '    [B] 还缺证书/描述文件（Sideloadly 生成后导出，见 docs/16）' -ForegroundColor Yellow
}

Write-Host "`n==> 3/3 下一步" -ForegroundColor Cyan
if ($trollOk) {
    Write-Host '  # 1. 手机上装 TrollStore（一次性，用 TrollInstallerX）' -ForegroundColor Cyan
    Write-Host '  # 2. 把 ipa 推进去：'
    Write-Host ("     pymobiledevice3 apps install `"{0}`"" -f $Ipa)
    Write-Host '  #    或 AirDrop / 文件 App 把 ipa 传给手机，用 TrollStore 打开'
    Write-Host '  # 3. 完成 —— 没有 7 天限制，不需要重签'
} elseif ($hasProfile -and $hasP12) {
    Write-Host '  .\scripts\release.ps1 -Profile <mobileprovision> -P12 <p12> -P12Password *** -AutoUdid'
    Write-Host ("  .\scripts\ios.ps1 install -Ipa `"{0}`"" -f $Ipa)
    Write-Host '  # 免费账号 7 天到期：.\scripts\xc\Register-RefreshTask.ps1 自动续'
} else {
    Write-Host '  免费账号路线：' -ForegroundColor Cyan
    Write-Host '    1) 装 Sideloadly（免费 Apple ID 也能签）'
    Write-Host '    2) 用它签任意一个 ipa，让它把证书/描述文件落到本机'
    Write-Host '    3) 把导出的 .p12 与 .mobileprovision 指给 release.ps1'
    Write-Host '  或者直接买 $99 账号，用 docs/02 的 REST 流程自动出证书。'
}

if ($hasIpa) {
    $size = [Math]::Round((Get-Item $Ipa).Length / 1KB, 1)
    Write-Host "`n  当前产物：$Ipa ($size KB)"
} else {
    Write-Host "`n  还没有 ipa：先跑 .\scripts\ios.ps1 nomac" -ForegroundColor Yellow
}
exit 0
