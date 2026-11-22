<#
.SYNOPSIS
    在 Windows 上从 Xcode.xip 里抽出 iPhoneOS.sdk —— 补上最后一块（SwiftUI / 真 actool 依赖的 SDK）。
.DESCRIPTION
    .xip 是 xar → pbzx → cpio 三层，解析器在 tools\xip-extract.py（已用自造包往返验证）。
    抽出来的 SDK 有两种用法：
      1) 给本仓库的构建脚本：Build-IosAppNative.ps1 -Sdk <path>，从此用真头文件/真 .tbd
      2) 给 Swift：SDK 里带 usr/lib/swift/iphoneos/*.swiftmodule，配合 swiftc -target arm64-apple-ios
         才有可能编 SwiftUI（这是唯一能碰到 SwiftUI 的路径）

    怎么拿到 .xip（不需要 Mac，只需要 Apple ID）：
      https://developer.apple.com/download/all/ → 搜 Xcode → 下载 .xip（7–10 GB）
      或只下 Command Line Tools（约 1 GB，含 SDK，但通常不含 iOS 平台 SDK）
.EXAMPLE
    .\Get-IosSdk.ps1 -Xip D:\dl\Xcode_16.xip -OutDir F:\sdks
.EXAMPLE
    .\Get-IosSdk.ps1 -SdkDir F:\sdks\iPhoneOS.sdk      # 只做体检，不解包
#>
[CmdletBinding()]
param(
    [string]$Xip,
    [string]$OutDir = 'F:\sdks',
    [string]$SdkDir,
    [string]$Only = 'iPhoneOS.platform/Developer/SDKs'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $root
$env:PYTHONIOENCODING = 'utf-8'

function Test-Sdk([string]$dir) {
    $ok = $true
    foreach ($rel in 'usr\include', 'usr\lib', 'System\Library\Frameworks') {
        $p = Join-Path $dir $rel
        if (Test-Path $p) { Write-Host ("  OK   {0}" -f $rel) -ForegroundColor Green }
        else { Write-Host ("  MISS {0}" -f $rel) -ForegroundColor Red; $ok = $false }
    }
    $tbds = @(Get-ChildItem (Join-Path $dir 'usr\lib') -Filter '*.tbd' -ErrorAction SilentlyContinue)
    Write-Host ("  .tbd 存根: {0} 个" -f $tbds.Count)
    $swift = Join-Path $dir 'usr\lib\swift'
    if (Test-Path $swift) {
        $mods = @(Get-ChildItem $swift -Recurse -Filter '*.swiftmodule' -ErrorAction SilentlyContinue)
        Write-Host ("  Swift 模块: {0} 个（>0 才可能编 SwiftUI）" -f $mods.Count) -ForegroundColor Cyan
    } else {
        Write-Host '  Swift 模块: 无（这个 SDK 编不了 Swift）' -ForegroundColor Yellow
    }
    return $ok
}

if ($SdkDir) {
    Write-Host "==> 体检 $SdkDir" -ForegroundColor Cyan
    if (-not (Test-Path $SdkDir)) { throw "目录不存在：$SdkDir" }
    $ok = Test-Sdk $SdkDir
    exit $(if ($ok) { 0 } else { 1 })
}

if (-not $Xip -or -not (Test-Path $Xip)) { throw "请给 -Xip <Xcode.xip> 或 -SdkDir <已解包的 SDK>" }
$sizeGB = [Math]::Round((Get-Item $Xip).Length / 1GB, 2)
Write-Host "==> $Xip ($sizeGB GB)" -ForegroundColor Cyan
if ($sizeGB -lt 0.5) { Write-Warning '文件偏小，Xcode.xip 通常 7 GB 以上；确认不是下了一半' }

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$sw = [Diagnostics.Stopwatch]::StartNew()
& python (Join-Path $root 'tools\xip-extract.py') $Xip --out $OutDir --only $Only
if ($LASTEXITCODE -ne 0) { throw "解包失败（exit $LASTEXITCODE）" }
Write-Host ("==> 解包用时 {0:N1} 分钟" -f ($sw.Elapsed.TotalMinutes)) -ForegroundColor Green

$sdk = Get-ChildItem $OutDir -Recurse -Directory -Filter 'iPhoneOS.sdk' -ErrorAction SilentlyContinue |
       Select-Object -First 1
if (-not $sdk) {
    Write-Host '没找到 iPhoneOS.sdk。可能 -Only 过滤掉了，试试不带 -Only 重跑（会解出整个 Xcode）。' -ForegroundColor Yellow
    exit 1
}
Write-Host "==> SDK: $($sdk.FullName)" -ForegroundColor Cyan
$ok = Test-Sdk $sdk.FullName

Write-Host ''
Write-Host '下一步：' -ForegroundColor Cyan
Write-Host "  .\scripts\xc\Build-IosAppNative.ps1 -Source .\samples\UIKitApp\AppCoreUI.m -Sdk `"$($sdk.FullName)`""
if ($ok) { Write-Host '  （真 SDK 下 .tbd/头文件都能用，不再需要 sdk\iPhoneOS-shim）' }
exit $(if ($ok) { 0 } else { 1 })
