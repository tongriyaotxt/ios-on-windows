<#
.SYNOPSIS
    零 macOS 的「真编译」构建：zig 编 UIKit dylib + machogen 造可执行体 + 双签名 + 嵌套 .app + .ipa。
.DESCRIPTION
    这是 docs/07 里「做不到」那条边界的补丁：

      可执行体（machogen，零外部符号）
        └─ LC_LOAD_DYLIB @executable_path/Frameworks/AppCore.dylib
             └─ AppCore.dylib（zig cc -target aarch64-ios -dynamiclib）
                  ├─ LC_LOAD_DYLIB UIKit / Foundation / libobjc
                  └─ __attribute__((constructor)) → UIApplicationMain(...)

    为什么这么拆：zig 内置的 Mach-O 链接器在链接「可执行文件 + 外部符号」时会溢出，
    链接 dylib 却完全正常。于是把界面放进 dylib，让可执行体保持零外部符号。
    dyld 会先跑依赖库的 initializer，再进 main —— 界面在 constructor 里就起来了。

    产物：<OutDir>\<Name>.ipa，内含 Frameworks/AppCore.dylib（已签名）。
.EXAMPLE
    .\Build-IosAppNative.ps1 -Source .\samples\UIKitApp\AppCoreUI.m -Name AppCore -Build 5
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Source,
    [string]$BundleId = 'com.tongriyaotxt.appcore',
    [string]$Name = 'AppCore',
    [string]$Version = '1.0.0',
    [string]$Build = '1',
    [string]$OutDir = '.\build\xc',
    [string]$P12,
    [string]$Password = '',
    [string]$TeamId,
    [string]$Entitlements,
    [string]$ProvisioningProfile,
    [int]$SignatureReserve = 16384,
    [string]$IconColor = '0A84FF',
    [string]$Sdk,
    [switch]$Deterministic
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $root
$env:PYTHONIOENCODING = 'utf-8'

# ---- 定位 zig --------------------------------------------------------------
$zig = $null
$cmd = Get-Command zig -ErrorAction SilentlyContinue
if ($cmd) { $zig = $cmd.Source }
if (-not $zig) {
    try { $zig = (& python -c "import ziglang,os;print(os.path.join(os.path.dirname(ziglang.__file__),'zig.exe'))").Trim() } catch { }
}
if (-not $zig -or -not (Test-Path $zig)) {
    throw 'zig 未安装。装它：pip install ziglang'
}

$shim = Join-Path $root 'sdk\iPhoneOS-shim'
if ($Sdk) {
    if (-not (Test-Path (Join-Path $Sdk 'usr\include'))) { throw "这个路径不像 iPhoneOS.sdk：$Sdk" }
    $shim = $Sdk
    Write-Host "==> 使用真 SDK：$Sdk" -ForegroundColor Green
} else {
    Write-Host '==> 使用手写 shim（sdk\iPhoneOS-shim，无 SDK 时的最小替身）' -ForegroundColor Yellow
}
$fw = Join-Path $shim 'System\Library\Frameworks'
$inc = Join-Path $shim 'usr\lib'
$stubs = Join-Path $root 'build\xc\stubs'
New-Item -ItemType Directory -Path $stubs, $OutDir -Force | Out-Null

# ---- 生成三个 .tbd 存根（LF 换行！zig 的解析器不吃 CRLF）-------------------
function Write-Tbd([string]$Path, [string]$InstallName, [string[]]$Symbols) {
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append("--- !tapi-tbd`n")
    [void]$sb.Append("tbd-version: 4`n")
    [void]$sb.Append("targets: [ arm64-ios ]`n")
    [void]$sb.Append("install-name: '$InstallName'`n")
    [void]$sb.Append("current-version: 1`n")
    [void]$sb.Append("exports:`n")
    [void]$sb.Append("  - targets: [ arm64-ios ]`n")
    [void]$sb.Append("    symbols: [ " + ($Symbols -join ', ') + " ]`n")
    [void]$sb.Append("...`n")
    [IO.File]::WriteAllText($Path, $sb.ToString(), (New-Object Text.UTF8Encoding($false)))
}
Write-Tbd (Join-Path $stubs 'libUIKit.tbd') '/System/Library/Frameworks/UIKit.framework/UIKit' @('_UIApplicationMain')
Write-Tbd (Join-Path $stubs 'libFoundation.tbd') '/System/Library/Frameworks/Foundation.framework/Foundation' @('_NSStringFromClass')
Write-Tbd (Join-Path $stubs 'libMetal.tbd') '/System/Library/Frameworks/Metal.framework/Metal' @('_MTLCreateSystemDefaultDevice')
Write-Tbd (Join-Path $stubs 'libobjc.tbd') '/usr/lib/libobjc.A.dylib' @(
    '_objc_getClass', '_sel_registerName', '_objc_msgSend', '_objc_allocateClassPair',
    '_objc_registerClassPair', '_class_addMethod')

# ---- 1. 编 dylib -----------------------------------------------------------
Write-Host "==> zig cc -target aarch64-ios -dynamiclib $Source" -ForegroundColor Cyan
$work = Join-Path $OutDir "$Name.work"
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $work -Force | Out-Null
$dylib = Join-Path $work 'AppCore.dylib'

$args = @('cc', '-target', 'aarch64-ios.17.0', '-dynamiclib', '-O2', '-install_name', '@rpath/AppCore.dylib',
          '-isysroot', $shim, '-F', $fw,
          '-L', $stubs, '-lUIKit', '-lFoundation', '-lMetal', '-lobjc',
          (Join-Path $shim 'platform_stubs.c'),
          $Source, '-o', $dylib)
& $zig @args
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $dylib)) { throw "dylib 编译/链接失败（exit $LASTEXITCODE）" }
Write-Host "    dylib: $([Math]::Round((Get-Item $dylib).Length/1KB,1)) KB" -ForegroundColor Green

# ---- 2. 造可执行体（零外部符号，只加载 dylib）-----------------------------
Write-Host '==> machogen 生成可执行体' -ForegroundColor Cyan
$exe = Join-Path $work $Name
& python (Join-Path $root 'tools\machogen.py') -o $exe --identifier $BundleId `
    --signature-size $SignatureReserve --load-dylib "@executable_path/Frameworks/AppCore.dylib" `
    $(if ($Deterministic) { '--deterministic' })
if ($LASTEXITCODE -ne 0) { throw 'machogen 失败' }

# ---- 3. 组 bundle ---------------------------------------------------------
Write-Host '==> 组装 .app（含 Frameworks/）' -ForegroundColor Cyan
$app = Join-Path $work "$Name.app"
$frameworksDir = Join-Path $app 'Frameworks'
New-Item -ItemType Directory -Path $frameworksDir -Force | Out-Null
Copy-Item $exe (Join-Path $app $Name) -Force
Copy-Item $dylib (Join-Path $frameworksDir 'AppCore.dylib') -Force
# 着色器源码当资源打包（运行时编译，不需要 metal 工具）
$shaderSrc = Join-Path $root 'samples\UIKitApp\Shaders.metal'
if (Test-Path $shaderSrc) { Copy-Item $shaderSrc (Join-Path $app 'Shaders.metal') -Force }

$bundleArgs = @('bundle', '--out', $app, '--identifier', $BundleId,
                '--executable-name', $Name, '--name', $Name, '--version', $Version, '--build', $Build)
if ($ProvisioningProfile) { $bundleArgs += @('--provisioning-profile', $ProvisioningProfile) }
& python (Join-Path $root 'tools\codesign_lite.py') @bundleArgs
if ($LASTEXITCODE -ne 0) { throw 'bundle 失败' }

Write-Host '==> 生成图标并写入 Info.plist' -ForegroundColor Cyan
& python (Join-Path $root 'tools\make-icons.py') --out $app --color $IconColor
if ($LASTEXITCODE -ne 0) { throw '图标生成失败' }
& python (Join-Path $root 'tools\attach-icons.py') --app $app
if ($LASTEXITCODE -ne 0) { throw '图标写入 Info.plist 失败' }

# ---- 4. 双层签名（先内层 dylib，再外层可执行体）---------------------------
Write-Host '==> 生成资源信封 _CodeSignature/CodeResources' -ForegroundColor Cyan
& python (Join-Path $root 'tools\make-resources.py') --app $app
if ($LASTEXITCODE -ne 0) { throw 'CodeResources 生成失败' }

Write-Host '==> 签名' -ForegroundColor Cyan
$signCommon = @()
if ($TeamId) { $signCommon += @('--team-id', $TeamId) }
if ($P12) { $signCommon += @('--p12', $P12, '--password', $Password) }

& python (Join-Path $root 'tools\codesign_lite.py') sign --inject --binary (Join-Path $frameworksDir 'AppCore.dylib') `
    --identifier "$BundleId.appcore" @signCommon
if ($LASTEXITCODE -ne 0) { throw 'dylib 签名失败' }

$exeSign = @('sign', '--binary', (Join-Path $app $Name), '--identifier', $BundleId, '--bundle-id', $BundleId, '--info-plist', (Join-Path $app 'Info.plist'))
if ($Entitlements) { $exeSign += @('--entitlements', $Entitlements) }
$exeSign += $signCommon
& python (Join-Path $root 'tools\codesign_lite.py') @exeSign
if ($LASTEXITCODE -ne 0) { throw '可执行体签名失败' }

& python (Join-Path $root 'tools\codesign_lite.py') verify --binary (Join-Path $app $Name)
& python (Join-Path $root 'tools\codesign_lite.py') verify --binary (Join-Path $frameworksDir 'AppCore.dylib')

# ---- 5. 打 ipa ------------------------------------------------------------
Write-Host '==> 打包 .ipa' -ForegroundColor Cyan
$payload = Join-Path $work 'Payload'
New-Item -ItemType Directory -Path $payload -Force | Out-Null
$stage = Join-Path $payload "$Name.app"
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
Copy-Item $app $stage -Recurse
$payload = (Resolve-Path -LiteralPath $payload).Path

$ipa = Join-Path $OutDir "$Name-native.ipa"
if (Test-Path $ipa) { Remove-Item $ipa -Force }
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zipStream = [IO.File]::Open($ipa, [IO.FileMode]::CreateNew)
$zip = New-Object IO.Compression.ZipArchive($zipStream, [IO.Compression.ZipArchiveMode]::Create)
try {
    $files = Get-ChildItem $payload -Recurse -File | Sort-Object FullName   # 排序保证顺序稳定
    $fixedTime = [DateTimeOffset]::new(1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
    $files | ForEach-Object {
        $rel = $_.FullName.Substring($payload.Length + 1).Replace('\', '/')
        $entry = $zip.CreateEntry("Payload/$rel", [IO.Compression.CompressionLevel]::Optimal)
        if ($Deterministic) { $entry.LastWriteTime = $fixedTime }
        $es = $entry.Open()
        try { $fs = [IO.File]::OpenRead($_.FullName); try { $fs.CopyTo($es) } finally { $fs.Dispose() } }
        finally { $es.Dispose() }
    }
} finally { $zip.Dispose(); $zipStream.Dispose() }

Write-Host ''
Write-Host "IPA      : $ipa ($([Math]::Round((Get-Item $ipa).Length/1KB,1)) KB)" -ForegroundColor Green
Write-Host "编译     : zig $(& $zig version) -target aarch64-ios -dynamiclib（真编译 + 真链接）"
Write-Host "结构     : Payload/$Name.app/{$Name, Info.plist, Frameworks/AppCore.dylib}"
Write-Host "签名     : $(if ($P12) { '证书 CMS' } else { 'ad-hoc' })（外层 + 内层各一份）"

[ordered]@{
    ipa = (Resolve-Path $ipa).Path
    bundleId = $BundleId
    compiler = 'zig/clang aarch64-ios'
    linker = 'zig Mach-O (dylib path)'
    dylib = 'Frameworks/AppCore.dylib'
    signing = $(if ($P12) { 'cms' } else { 'adhoc' })
    createdAt = (Get-Date).ToString('o')
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutDir 'native-receipt.json') -Encoding UTF8
