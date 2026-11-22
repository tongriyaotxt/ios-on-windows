<#
.SYNOPSIS
    插上 iPhone，自动读出 UDID / 设备名 / iOS 版本（不需要 macOS，不需要 Apple 账号）。
.DESCRIPTION
    手机**不给**签名私钥（那东西在你自己的机器上生成），但能给三样发布必需的信息：
      · UDID     —— 描述文件里必须登记，缺了装机报 ApplicationVerificationFailed
      · 设备名 / iOS 版本 —— 决定最低系统版本与是否支持某些 API
      · 配对状态 —— pymobiledevice3 / libimobiledevice 能不能连上

    优先用 pymobiledevice3（纯 Python），退回 libimobiledevice。
.EXAMPLE
    .\Get-DeviceInfo.ps1
    .\Get-DeviceInfo.ps1 -Json .\build\device.json
#>
[CmdletBinding()]
param(
    [string]$Json,
    [switch]$UdidOnly
)

$ErrorActionPreference = 'Stop'
$env:PYTHONIOENCODING = 'utf-8'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $root
. (Join-Path $root 'scripts\lib\Bootstrap.ps1')

$devices = @()

function Try-Pymobiledevice3 {
    if (-not (Get-Command pymobiledevice3 -ErrorAction SilentlyContinue)) { return $null }
    try {
        $raw = & pymobiledevice3 usbmux list --json 2>$null | Out-String
        if (-not $raw.Trim()) { return $null }
        return ($raw | ConvertFrom-Json)
    } catch { return $null }
}

function Try-IdeviceId {
    if (-not (Get-Command idevice_id -ErrorAction SilentlyContinue)) { return $null }
    $ids = & idevice_id -l 2>$null
    if (-not $ids) { return $null }
    return @($ids | ForEach-Object { [pscustomobject]@{ Udid = $_.Trim() } })
}

$pm = Try-Pymobiledevice3
if ($pm) {
    foreach ($d in @($pm)) {
        $udid = $d.UniqueDeviceID
        if (-not $udid) { $udid = $d.Identifier }
        if (-not $udid) { continue }
        $devices += [pscustomobject]@{
            Udid       = $udid
            Name       = $d.DeviceName
            iOS        = $d.ProductVersion
            Connection = if ($d.ConnectionType) { $d.ConnectionType } else { 'USB' }
            Source     = 'pymobiledevice3'
        }
    }
}

if (-not $devices) {
    $ids = Try-IdeviceId
    if ($ids) {
        foreach ($i in $ids) {
            $name = $null; $ver = $null
            if (Get-Command ideviceinfo -ErrorAction SilentlyContinue) {
                try {
                    $name = (& ideviceinfo -u $i.Udid -k DeviceName 2>$null | Out-String).Trim()
                    $ver = (& ideviceinfo -u $i.Udid -k ProductVersion 2>$null | Out-String).Trim()
                } catch { }
            }
            $devices += [pscustomobject]@{
                Udid = $i.Udid; Name = $name; iOS = $ver; Connection = 'USB'; Source = 'libimobiledevice'
            }
        }
    }
}

if (-not $devices) {
    Write-Host '没有检测到设备。' -ForegroundColor Yellow
    Write-Host '  1) 装驱动：winget install Apple.AppleDevices' -ForegroundColor Yellow
    Write-Host '  2) 装命令行：pip install pymobiledevice3' -ForegroundColor Yellow
    Write-Host '  3) 插上手机、解锁、点「信任」' -ForegroundColor Yellow
    Write-Host '  4) iOS 16+ 需要打开「设置 → 隐私与安全性 → 开发者模式」' -ForegroundColor Yellow
    exit 1
}

if ($UdidOnly) {
    $devices | ForEach-Object { $_.Udid }
    exit 0
}

$devices | Format-Table -AutoSize Udid, Name, iOS, Connection, Source

if ($Json) {
    $dir = Split-Path -Parent $Json
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    ($devices | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $Json -Encoding UTF8
    Write-Host "已写入 $Json"
}

Write-Host ''
Write-Host '下一步：' -ForegroundColor Cyan
Write-Host ("  .\scripts\release.ps1 -Profile ... -P12 ... -Udid {0}" -f $devices[0].Udid)
exit 0
