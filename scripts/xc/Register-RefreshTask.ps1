<#
.SYNOPSIS
    免费 Apple ID 的 7 天续命：建一个 Windows 计划任务，到期前自动重签 + 重装。
.DESCRIPTION
    免费账号签出来的 App 只能活 7 天。到期后手机会打不开（提示「无法验证 App」）。
    本脚本注册一个计划任务，每 N 天（默认 6）跑一次：

        release.ps1（重签，用同一套 p12/profile）→ ios.ps1 install（重装）

    前提：证书与描述文件仍在有效期内。**描述文件本身也是 7 天**，
    所以到第 7 天必须用 Sideloadly/AltStore 重新生成一份 —— 那一步是 Apple 的限制，
    脚本会在描述文件过期时明确报错，而不是静默失败。
.EXAMPLE
    .\Register-RefreshTask.ps1 -Profile .\AppCore.mobileprovision -P12 .\dist.p12 -P12Password ***
    .\Register-RefreshTask.ps1 -Remove
#>
[CmdletBinding()]
param(
    [string]$Profile,
    [string]$P12,
    [string]$P12Password = $env:P12_PASSWORD,
    [int]$EveryDays = 6,
    [string]$TaskName = 'ios-app-refresh',
    [switch]$Remove,
    [switch]$RunNow
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $root

if ($Remove) {
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($t) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "已删除计划任务：$TaskName" -ForegroundColor Green
    } else {
        Write-Host "没有这个任务：$TaskName" -ForegroundColor Yellow
    }
    exit 0
}

foreach ($p in $Profile, $P12) {
    if (-not $p) { throw '需要 -Profile 与 -P12（免费账号签出来的那两份文件）' }
    if (-not (Test-Path $p)) { throw "文件不存在：$p" }
}

# 目标脚本：一个自包含的刷新入口
$refresh = Join-Path $root 'scripts\xc\Invoke-Refresh.ps1'
if (-not (Test-Path $refresh)) {
    @'
<#
.SYNOPSIS
    计划任务调用的入口：重签 + 重装。参数从同目录的 refresh.json 读。
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSScriptRoot
$root = Split-Path -Parent $here
Set-Location $root
$cfg = Get-Content (Join-Path $PSScriptRoot 'refresh.json') -Raw | ConvertFrom-Json
$log = Join-Path $root 'build\refresh.log'
"[$(Get-Date -Format o)] 开始刷新 (build=$($cfg.Build))" | Tee-Object -FilePath $log -Append

$env:PYTHONIOENCODING = 'utf-8'
& (Join-Path $root 'scripts\release.ps1') -Profile $cfg.Profile -P12 $cfg.P12 `
    -P12Password $cfg.P12Password -BundleId $cfg.BundleId -AutoUdid -Build $cfg.Build
if ($LASTEXITCODE -ne 0) { "[$(Get-Date -Format o)] 重签失败" | Tee-Object -FilePath $log -Append; exit 1 }

& (Join-Path $root 'scripts\ios.ps1') install -Ipa (Join-Path $root "build\xc\$($cfg.Name)-native.ipa")
if ($LASTEXITCODE -ne 0) { "[$(Get-Date -Format o)] 安装失败" | Tee-Object -FilePath $log -Append; exit 1 }

"[$(Get-Date -Format o)] 完成" | Tee-Object -FilePath $log -Append
'@ | Set-Content -LiteralPath $refresh -Encoding UTF8
}

# 配置（含密码 — 只在本机，且 gitignore 覆盖 build/）
$state = @{ MARKETING_VERSION = '1.0.0'; BUILD_NUMBER = '1' }
if (Test-Path (Join-Path $root 'VERSION')) {
    Get-Content (Join-Path $root 'VERSION') | ForEach-Object {
        if ($_ -match '^\s*([A-Z_]+)\s*=\s*(.+?)\s*$') { $state[$Matches[1]] = $Matches[2] }
    }
}
$cfg = [ordered]@{
    Profile      = (Resolve-Path $Profile).Path
    P12          = (Resolve-Path $P12).Path
    P12Password  = $P12Password
    BundleId     = $(if ($env:BUNDLE_ID) { $env:BUNDLE_ID } else { 'com.tongriyaotxt.appcore' })
    Name         = 'AppCore'
    Build        = [string]([int]$state.BUILD_NUMBER + 1)
    EveryDays    = $EveryDays
}
($cfg | ConvertTo-Json) | Set-Content -LiteralPath (Join-Path $root 'scripts\xc\refresh.json') -Encoding UTF8

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$refresh`""
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) `
    -RepetitionInterval (New-TimeSpan -Days $EveryDays)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
    -Description 'iOS 免费签名 7 天续签：重签 + 重装' | Out-Null

Write-Host "已注册计划任务：$TaskName（每 $EveryDays 天）" -ForegroundColor Green
Write-Host "  配置：scripts\xc\refresh.json"
Write-Host "  日志：build\refresh.log"
Write-Host "  立即跑一次：Start-ScheduledTask -TaskName $TaskName"
Write-Host "  删除：.\Register-RefreshTask.ps1 -Remove"

if ($RunNow) { Start-ScheduledTask -TaskName $TaskName; Write-Host '已触发一次' }
