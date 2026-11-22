<#
.SYNOPSIS
    从 macOS 客户机里把 IPA 拉回 Windows（QEMU hostfwd 把客户机 8000 映到本机 127.0.0.1:8000）。
.DESCRIPTION
    客户机里跑 `macos-build.sh` 后会 `python3 -m http.server 8000`；本脚本列出目录、下载最新 .ipa，
    然后可以直接链到 asc-upload.ps1。
.EXAMPLE
    .\Get-Artifact.ps1 -BundleVersion 42
    .\Get-Artifact.ps1 -Url http://127.0.0.1:8000 -Upload
#>
[CmdletBinding()]
param(
    [string]$Url = 'http://127.0.0.1:8000',
    [string]$OutDir = '.\build',
    [string]$BundleVersion,
    [switch]$Upload
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not (Test-Path $root)) { $root = (Get-Location).Path }

Write-Host "==> 探测 $Url" -ForegroundColor Cyan
try {
    $index = Invoke-WebRequest -Uri "$Url/" -UseBasicParsing -TimeoutSec 10
} catch {
    throw "连不上 $Url —— 确认客户机里 http.server 已启动，且 QEMU 带 -netdev user,hostfwd=tcp::8000-:8000。($($_.Exception.Message))"
}

$links = [regex]::Matches($index.Content, 'href="(?<n>[^"]+\.ipa)"') | ForEach-Object { $_.Groups['n'].Value }
if (-not $links) { throw "服务在跑，但根目录没有 .ipa。客户机里是否已经 xcodebuild -exportArchive 成功？" }

$latest = $links | Sort-Object -Descending | Select-Object -First 1
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$dest = Join-Path $OutDir $latest

Write-Host "==> 下载 $latest" -ForegroundColor Cyan
Invoke-WebRequest -Uri "$Url/$latest" -OutFile $dest -UseBasicParsing
$size = [Math]::Round((Get-Item $dest).Length / 1MB, 2)
Write-Host "    -> $dest ($size MB)" -ForegroundColor Green

if ($Upload) {
    if (-not $BundleVersion) { throw '-Upload 需要 -BundleVersion（与客户机里 CURRENT_PROJECT_VERSION 一致）' }
    & (Join-Path $root 'scripts\asc-upload.ps1') -Ipa $dest -BundleVersion $BundleVersion
} else {
    Write-Host ''
    Write-Host "下一步：.\scripts\asc-upload.ps1 -Ipa `"$dest`" -BundleVersion <n>" -ForegroundColor Yellow
}
