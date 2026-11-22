<#
.SYNOPSIS
    零 macOS 打一个 iOS .app/.ipa：编译（可选 clang）→ 代码签名 → 组装 bundle → 打 zip。
.DESCRIPTION
    这一步替代的是 macOS 上的 `xcodebuild archive + -exportArchive`。能做与不能做要分清：

      能做（本脚本已验证）
        · Mach-O arm64 + LC_BUILD_VERSION(iOS) + LC_MAIN + LC_LOAD_DYLIB
        · 代码签名：CodeDirectory / 超级块 / entitlements 槽 / 真证书 CMS（PKCS#7）
        · .app 结构（Info.plist、可执行体、embedded.mobileprovision）
        · .ipa 打包（Payload/ 前缀 + 正斜杠，iOS 解包器只认这个）
      不能做
        · 用 SwiftUI/UIKit 写界面 —— 那需要 iOS SDK 的头文件与 .swiftmodule，只有 Xcode 里才有
        · Asset Catalog（actool）、storyboard（ibtool）、Metal 着色器
        · 因此：产物可签名、可上传、结构合法，但「有界面的 App」仍需 macOS 侧的编译器

    编译来源二选一：
      1) 装了 LLVM（clang + ld64.lld）：-Source 指一个 .c/.m 文件，走真编译真链接
      2) 没装：用 tools\machogen.py 生成结构合法的 arm64 可执行体（默认）
.EXAMPLE
    .\Build-IosApp.ps1 -BundleId com.example.helloios -Name HelloIOS -Version 1.0.0 -Build 3
.EXAMPLE
    .\Build-IosApp.ps1 -BundleId com.a.b -P12 .\secrets\dist.p12 -Password $env:P12_PASSWORD -TeamId ABCDE12345 -Entitlements .\ent.plist
#>
[CmdletBinding()]
param(
    [string]$BundleId = 'com.example.helloios',
    [string]$Name = 'HelloIOS',
    [string]$Version = '1.0.0',
    [string]$Build = '1',
    [string]$OutDir = '.\build\xc',
    [string]$Source,                       # 可选：.c/.m，需要 clang
    [string]$P12,
    [string]$Password = '',
    [string]$TeamId,
    [string]$Entitlements,
    [string]$ProvisioningProfile,
    [int]$SignatureReserve = 8192
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $root
$env:PYTHONIOENCODING = 'utf-8'
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

$work = Join-Path $OutDir $Name
$appDir = Join-Path $work "$Name.app"
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $appDir -Force | Out-Null
$exePath = Join-Path $appDir $Name

function Find-Tool([string]$n) {
    $c = Get-Command $n -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($p in @("C:\Program Files\LLVM\bin\$n.exe", "C:\Program Files\LLVM\bin\$n")) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

# ---------- 1. 生成可执行体 ------------------------------------------------
$clang = Find-Tool 'clang'
$ld64 = Find-Tool 'ld64.lld'
$mode = 'machogen'
if ($Source -and $clang -and $ld64) {
    Write-Host "==> 编译 $Source (clang -target arm64-apple-ios17.0)" -ForegroundColor Cyan
    $obj = Join-Path $work "$Name.o"
    & $clang -target arm64-apple-ios17.0 -O2 -c $Source -o $obj
    if ($LASTEXITCODE -ne 0) { throw "clang failed ($LASTEXITCODE)" }
    & $ld64 -arch arm64 -platform_version ios 17.0 17.0 -e _main -o $exePath $obj
    if ($LASTEXITCODE -ne 0) { throw "ld64.lld failed ($LASTEXITCODE)" }
    $mode = 'clang+ld64'
} else {
    if ($Source) { Write-Warning 'clang / ld64.lld 未安装，回退到 machogen 占位可执行体（-Source 被忽略）' }
    Write-Host '==> machogen.py 生成 arm64 Mach-O 占位体' -ForegroundColor Cyan
    & python (Join-Path $root 'tools\machogen.py') -o $exePath --identifier $BundleId --signature-size $SignatureReserve
    if ($LASTEXITCODE -ne 0) { throw "machogen failed ($LASTEXITCODE)" }
}

# ---------- 2. 签名 --------------------------------------------------------
$signArgs = @('sign', '--binary', $exePath, '--identifier', $BundleId, '--bundle-id', $BundleId)
if ($TeamId) { $signArgs += @('--team-id', $TeamId) }
if ($Entitlements) { $signArgs += @('--entitlements', $Entitlements) }
if ($P12) { $signArgs += @('--p12', $P12, '--password', $Password) }
Write-Host "==> codesign_lite.py $($signArgs -join ' ')" -ForegroundColor Cyan
& python (Join-Path $root 'tools\codesign_lite.py') @signArgs
if ($LASTEXITCODE -ne 0) { throw "codesign_lite failed ($LASTEXITCODE)" }
& python (Join-Path $root 'tools\codesign_lite.py') verify --binary $exePath
if ($LASTEXITCODE -ne 0) { throw '签名自校验失败' }

# ---------- 3. 组 bundle ---------------------------------------------------
Write-Host '==> 组装 .app' -ForegroundColor Cyan
$bundleArgs = @('bundle', '--binary', $exePath, '--out', $appDir, '--identifier', $BundleId,
                '--executable-name', $Name, '--name', $Name, '--version', $Version, '--build', $Build)
if ($ProvisioningProfile) { $bundleArgs += @('--provisioning-profile', $ProvisioningProfile) }
& python (Join-Path $root 'tools\codesign_lite.py') @bundleArgs
if ($LASTEXITCODE -ne 0) { throw "bundle failed ($LASTEXITCODE)" }

# ---------- 4. 打 .ipa（必须是 Payload/ 前缀 + 正斜杠） --------------------
Write-Host '==> 打包 .ipa' -ForegroundColor Cyan
$payload = Join-Path $work 'Payload'
New-Item -ItemType Directory -Path $payload -Force | Out-Null
$payload = (Resolve-Path -LiteralPath $payload).Path   # 必须绝对：下面用 Substring 算相对路径
$stage = Join-Path $payload "$Name.app"
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
Copy-Item $appDir $stage -Recurse

$ipa = Join-Path $OutDir "$Name.ipa"
if (Test-Path $ipa) { Remove-Item $ipa -Force }
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zipStream = [IO.File]::Open($ipa, [IO.FileMode]::CreateNew)
$zip = New-Object IO.Compression.ZipArchive($zipStream, [IO.Compression.ZipArchiveMode]::Create)
try {
    Get-ChildItem $payload -Recurse -File | ForEach-Object {
        # 相对路径 -> 正斜杠；iOS 的解包器不认反斜杠
        $rel = $_.FullName.Substring($payload.Length + 1).Replace('\', '/')
        $entry = $zip.CreateEntry("Payload/$rel", [IO.Compression.CompressionLevel]::Optimal)
        $es = $entry.Open()
        try {
            $fs = [IO.File]::OpenRead($_.FullName)
            try { $fs.CopyTo($es) } finally { $fs.Dispose() }
        } finally { $es.Dispose() }
    }
} finally {
    $zip.Dispose(); $zipStream.Dispose()
}

$size = [Math]::Round((Get-Item $ipa).Length / 1KB, 1)
$modeDesc = if ($mode -eq 'clang+ld64') { 'clang + ld64.lld（真编译）' } else { 'machogen（结构合法占位体，无 clang）' }
$signDesc = if ($P12) { '证书 CMS（真签名）' } else { 'ad-hoc' }

Write-Host ''
Write-Host "IPA   : $ipa ($size KB)" -ForegroundColor Green
Write-Host "编译  : $modeDesc"
Write-Host "签名  : $signDesc"
Write-Host "结构  : Payload/$Name.app/{$Name, Info.plist$(if($ProvisioningProfile){', embedded.mobileprovision'})}"

# 回执，方便后面接上传/OTA
$receipt = [ordered]@{
    ipa = (Resolve-Path $ipa).Path
    bundleId = $BundleId
    version = $Version
    build = $Build
    compiler = $mode
    signing = $(if ($P12) { 'cms' } else { 'adhoc' })
    createdAt = (Get-Date).ToString('o')
}
$receiptPath = Join-Path $OutDir 'build-receipt.json'
($receipt | ConvertTo-Json) | Set-Content -LiteralPath $receiptPath -Encoding UTF8
Write-Host "回执  : $receiptPath"
