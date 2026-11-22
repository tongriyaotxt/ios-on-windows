<#
.SYNOPSIS
    一键发布：描述文件校验 → 构建 → 真证书签名 → 校验 → 上传 → 轮询。（-DryRun 只打印计划）
.DESCRIPTION
    这是「剩下那一步」的收口：一旦你有 Apple 账号（.p8 / .p12 / .mobileprovision），
    一条命令完成从源码到 TestFlight。

    它不会替你做的事（也不该做）：伪造证书、猜描述文件、替你点审核。
.EXAMPLE
    .\release.ps1 -Profile .\AppCore.mobileprovision -P12 .\dist.p12 -P12Password *** `
                  -KeyPath .\secrets\AuthKey_ABCDE12345.p8 -KeyId ABCDE12345 -IssuerId 1111... `
                  -AppId 6471234567 -TeamId ABCDE12345 -Upload
.EXAMPLE
    .\release.ps1 -Profile .\AppCore.mobileprovision -P12 .\dist.p12 -P12Password *** -DryRun
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Profile,
    [Parameter(Mandatory)][string]$P12,
    [string]$P12Password = $env:P12_PASSWORD,
    [string]$P8 = $env:ASC_KEY_PATH,
    [string]$KeyId = $env:ASC_KEY_ID,
    [string]$IssuerId = $env:ASC_ISSUER_ID,
    [string]$AppId = $env:ASC_APP_ID,
    [string]$TeamId = $env:TEAM_ID,
    [string]$BundleId = $env:BUNDLE_ID,
    [string]$Source = '.\samples\UIKitApp\AppCoreUI.m',
    [string]$Name = 'AppCore',
    [string]$Version = $null,
    [string]$Build = $null,
    [string]$Udid,
    [switch]$AutoUdid,
    [switch]$Upload,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
. (Join-Path $PSScriptRoot 'lib\Bootstrap.ps1')
$env:PYTHONIOENCODING = 'utf-8'

function Step($t) { Write-Host "`n==> $t" -ForegroundColor Cyan }
function Fail($t) { Write-Host "    !! $t" -ForegroundColor Red; throw $t }

# ---- 版本号
if (-not $Version -or -not $Build) {
    $state = @{ MARKETING_VERSION = '1.0.0'; BUILD_NUMBER = '1' }
    if (Test-Path (Join-Path $root 'VERSION')) {
        Get-Content (Join-Path $root 'VERSION') | ForEach-Object {
            if ($_ -match '^\s*([A-Z_]+)\s*=\s*(.+?)\s*$') { $state[$Matches[1]] = $Matches[2] }
        }
    }
    if (-not $Version) { $Version = $state.MARKETING_VERSION }
    if (-not $Build) { $Build = $state.BUILD_NUMBER }
}
if (-not $BundleId) { $BundleId = 'com.example.appcore' }

if ($AutoUdid -and -not $Udid) {
    Write-Host '==> 自动读取已连接设备的 UDID' -ForegroundColor Cyan
    $ids = & (Join-Path $PSScriptRoot 'xc\Get-DeviceInfo.ps1') -UdidOnly 2>$null
    if ($ids) { $Udid = @($ids)[0].Trim(); Write-Host "    UDID = $Udid" -ForegroundColor Green }
    else { Write-Host '    没找到设备，继续走不依赖 UDID 的检查（App Store 分发不需要）' -ForegroundColor Yellow }
}

Step "1/5 描述文件校验（bundle=$BundleId team=$TeamId）"
if ($DryRun) {
    Write-Host "    (dry) python tools\check-provisioning.py --profile `"$Profile`" --bundle-id $BundleId --p12 `"$P12`" --udid $Udid"
} else {
    if (-not (Test-Path $Profile)) { Fail "描述文件不存在：$Profile" }
    if (-not (Test-Path $P12)) { Fail "证书不存在：$P12" }
    $entOut = Join-Path $root 'build\xc\ent-from-profile.plist'
    New-Item -ItemType Directory -Path (Split-Path $entOut) -Force | Out-Null
    $checkArgs = @((Join-Path $root 'tools\check-provisioning.py'),
                   '--profile', $Profile, '--bundle-id', $BundleId,
                   '--p12', $P12, '--p12-password', $P12Password,
                   '--emit-entitlements', $entOut)
    if ($Udid) { $checkArgs += @('--udid', $Udid) }
    & python @checkArgs
    $rc = $LASTEXITCODE
    if ($rc -eq 1) { Fail '描述文件/证书校验失败（先解决上面的 FAIL 再发布）' }
    if ($rc -eq 2) { Write-Host '    （有警告，继续）' -ForegroundColor Yellow }
}

Step "2/5 构建（$Version ($Build)）"
$buildArgs = @{
    Source     = $Source
    Name       = $Name
    BundleId   = $BundleId
    Version    = $Version
    Build      = $Build
    P12        = $P12
    Password   = $P12Password
    Entitlements = (Join-Path $root 'build\xc\ent-from-profile.plist')
    ProvisioningProfile = $Profile
    Deterministic = $true
}
if ($TeamId) { $buildArgs.TeamId = $TeamId }
if ($DryRun) {
    Write-Host ('    (dry) Build-IosAppNative.ps1 ' + (($buildArgs.GetEnumerator() | ForEach-Object { "-$($_.Key) $($_.Value)" }) -join ' '))
} else {
    & (Join-Path $PSScriptRoot 'xc\Build-IosAppNative.ps1') @buildArgs
    if ($LASTEXITCODE -ne 0) { Fail '构建失败' }
}
$ipa = Join-Path $root "build\xc\$Name-native.ipa"

Step '3/5 静态校验 + 启动审计'
if ($DryRun) {
    Write-Host "    (dry) verify-ipa.py / audit-device.py / check-provisioning.py --ipa"
} else {
    & python (Join-Path $root 'tools\verify-ipa.py') $ipa
    if ($LASTEXITCODE -eq 1) { Fail 'IPA 静态校验失败' }
    & python (Join-Path $root 'tools\audit-device.py') $ipa | Out-Host
    if ($LASTEXITCODE -eq 1) { Fail '启动审计发现 FATAL 问题' }
    $checkArgs2 = @((Join-Path $root 'tools\check-provisioning.py'), '--profile', $Profile,
                    '--bundle-id', $BundleId, '--ipa', $ipa, '--p12', $P12,
                    '--p12-password', $P12Password)
    if ($Udid) { $checkArgs2 += @('--udid', $Udid) }
    & python @checkArgs2
    if ($LASTEXITCODE -eq 1) { Fail '签名 entitlements 与描述文件不一致' }
}

Step '4/5 上传'
if (-not $Upload) {
    Write-Host '    （未加 -Upload，跳过；产物在 build\xc）'
} elseif ($DryRun) {
    Write-Host "    (dry) asc-upload.ps1 -Ipa $ipa -BundleVersion $Build -AppId $AppId"
} else {
    if (-not $P8 -or -not $KeyId -or -not $IssuerId) { Fail '上传需要 -P8 / -KeyId / -IssuerId（或对应环境变量）' }
    $upArgs = @{ Ipa = $ipa; BundleVersion = $Build; KeyPath = $P8; KeyId = $KeyId; IssuerId = $IssuerId }
    if ($AppId) { $upArgs.AppId = $AppId } else { $upArgs.SkipPoll = $true }
    & (Join-Path $PSScriptRoot 'asc-upload.ps1') @upArgs
    if ($LASTEXITCODE -ne 0) { Fail '上传失败' }
}

Step '5/5 完成'
Write-Host "    ipa      : $ipa"
Write-Host "    bundle   : $BundleId $Version ($Build)"
Write-Host "    签名     : $(if ($P12) { '分发证书 + 描述文件 entitlements' } else { '未签名' })"
if ($Upload -and $AppId -and -not $DryRun) {
    Write-Host "    TestFlight: https://appstoreconnect.apple.com/apps/$AppId/testflight"
}
