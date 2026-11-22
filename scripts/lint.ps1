[CmdletBinding()]
param(
    [switch]$Fix
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
$fail = 0

Write-Host '==> Python: ruff' -ForegroundColor Cyan
& python -m ruff --version 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host '    ruff 未安装：pip install -r requirements-dev.txt' -ForegroundColor Yellow
} else {
    if ($Fix) { & python -m ruff check --fix tools tests }
    else { & python -m ruff check tools tests }
    if ($LASTEXITCODE -ne 0) { $fail++ }
}

Write-Host '==> PowerShell: PSScriptAnalyzer' -ForegroundColor Cyan
$analyzer = Get-Module -ListAvailable -Name PSScriptAnalyzer
if (-not $analyzer) {
    Write-Host '    PSScriptAnalyzer 未安装：Install-Module PSScriptAnalyzer -Scope CurrentUser' -ForegroundColor Yellow
} else {
    Import-Module PSScriptAnalyzer
    $settings = if (Test-Path '.\PSScriptAnalyzerSettings.psd1') { '.\PSScriptAnalyzerSettings.psd1' } else { $null }
    $files = Get-ChildItem -Recurse -Filter *.ps1 | Where-Object { $_.FullName -notmatch '\\build\\' }
    $issues = $files | Invoke-ScriptAnalyzer -Settings $settings
    if ($issues) {
        $issues | Group-Object Severity | ForEach-Object { Write-Host ("    {0}: {1}" -f $_.Name, $_.Count) }
        $issues | Where-Object Severity -eq 'Error' | Select-Object -First 20 |
            ForEach-Object { Write-Host ("    {0}:{1} [{2}] {3}" -f $_.ScriptName, $_.Line, $_.RuleName, $_.Message) }
        $fail++
    } else {
        Write-Host '    0 issue' -ForegroundColor Green
    }
}

Write-Host '==> 语法解析（不依赖模块）' -ForegroundColor Cyan
$parseErrors = 0
Get-ChildItem -Recurse -Filter *.ps1 | Where-Object { $_.FullName -notmatch '\\build\\' } | ForEach-Object {
    $err = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$err)
    if ($err) { $parseErrors++; Write-Host ("    {0}: {1}" -f $_.Name, $err[0].Message) -ForegroundColor Red }
}
if ($parseErrors -eq 0) { Write-Host '    全部通过' -ForegroundColor Green } else { $fail++ }

Write-Host ''
if ($fail -eq 0) { Write-Host 'LINT OK' -ForegroundColor Green; exit 0 }
Write-Host "LINT: $fail 项有问题" -ForegroundColor Red
exit 1
