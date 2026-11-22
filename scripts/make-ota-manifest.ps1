<#
.SYNOPSIS
    生成 itms-services OTA 安装清单（不经过 TestFlight，浏览器点一下就装）。
.DESCRIPTION
    iOS 允许从 HTTPS 直接安装 ad-hoc / enterprise 签名的 IPA，靠的是一个 manifest.plist：
        <key>items[0].assets[0].url</key> = IPA 的 https 直链
        <key>items[0].metadata.bundle-identifier</key> / bundle-version / title
    本脚本从 IPA 里读出 Info.plist 的这几个值（IPA 就是 zip，直接解），不需要 Mac。
    生成的目录里同时有 install.html，iPhone Safari 打开即装。
.NOTES
    前置：IPA 必须用「带目标设备 UDID 的 ad-hoc profile」或 enterprise 证书签名，
    否则装上去会提示 "无法安装"。TestFlight 分发的包不适用此流程。
.EXAMPLE
    .\make-ota-manifest.ps1 -Ipa .\build\AppCore.ipa -BaseUrl https://192.168.2.2:8443
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Ipa,
    [Parameter(Mandatory)][string]$BaseUrl,          # 例：https://192.168.2.2:8443（必须 https）
    [string]$OutDir = '.\build\ota',
    [string]$Title
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$ipaPath = (Resolve-Path -LiteralPath $Ipa).Path
if ($BaseUrl -notmatch '^https://') { throw 'iOS 只接受 https 的 manifest 与 ipa 直链（http 会被系统拒绝）。' }
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

# ---- 从 IPA 里读 Info.plist ------------------------------------------------
$zip = [IO.Compression.ZipFile]::OpenRead($ipaPath)
try {
    $entry = $zip.Entries | Where-Object { $_.FullName -match '^Payload[/\\\\][^/\\\\]+\.app[/\\\\]Info\.plist$' } | Select-Object -First 1
    if (-not $entry) { throw 'Info.plist not found inside Payload/*.app — is this a real .ipa?' }
    $ms = New-Object IO.MemoryStream
    $entry.Open().CopyTo($ms)
    $ms.Position = 0
    $xml = [Text.Encoding]::UTF8.GetString($ms.ToArray())
} finally { $zip.Dispose() }

function Get-PlistValue([string]$Xml, [string]$Key) {
    $m = [regex]::Match($Xml, "<key>$([regex]::Escape($Key))</key>\s*<string>([^<]*)</string>")
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

$bundleId = Get-PlistValue $xml 'CFBundleIdentifier'
$bundleVersion = Get-PlistValue $xml 'CFBundleVersion'
$shortVersion = Get-PlistValue $xml 'CFBundleShortVersionString'
$displayName = Get-PlistValue $xml 'CFBundleDisplayName'
if (-not $displayName) { $displayName = Get-PlistValue $xml 'CFBundleName' }
if (-not $Title) { $Title = $displayName }
if (-not $bundleId -or -not $bundleVersion) { throw "Could not read CFBundleIdentifier / CFBundleVersion from Info.plist." }

$ipaName = [IO.Path]::GetFileName($ipaPath)
Copy-Item -LiteralPath $ipaPath -Destination (Join-Path $OutDir $ipaName) -Force
$ipaUrl = "$($BaseUrl.TrimEnd('/'))/$ipaName"

# ---- manifest.plist --------------------------------------------------------
$manifest = @"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>items</key>
    <array>
        <dict>
            <key>assets</key>
            <array>
                <dict>
                    <key>kind</key>
                    <string>software-package</string>
                    <key>url</key>
                    <string>$ipaUrl</string>
                </dict>
            </array>
            <key>metadata</key>
            <dict>
                <key>bundle-identifier</key>
                <string>$bundleId</string>
                <key>bundle-version</key>
                <string>$bundleVersion</string>
                <key>kind</key>
                <string>software</string>
                <key>title</key>
                <string>$Title</string>
            </dict>
        </dict>
    </array>
</dict>
</plist>
"@
Set-Content -LiteralPath (Join-Path $OutDir 'manifest.plist') -Value $manifest -Encoding UTF8

# ---- install.html ---------------------------------------------------------
$manifestUrl = "$($BaseUrl.TrimEnd('/'))/manifest.plist"
$html = @"
<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Install $Title</title>
<style>body{font:16px/1.5 -apple-system,sans-serif;margin:0;padding:32px;background:#0b0b0d;color:#eee;text-align:center}
a.btn{display:inline-block;margin-top:24px;padding:16px 28px;border-radius:14px;background:#0a84ff;color:#fff;text-decoration:none;font-weight:600}
code{color:#9be15d;font-size:13px;word-break:break-all}</style>
<h1>$Title</h1>
<p>$shortVersion ($bundleVersion)</p>
<p><code>$bundleId</code></p>
<a class="btn" href="itms-services://?action=download-manifest&url=$manifestUrl">安装到这台 iPhone</a>
<p style="margin-top:32px;color:#888;font-size:13px">需要该设备 UDID 已加入描述文件（ad-hoc），或使用企业证书签名。</p>
"@
Set-Content -LiteralPath (Join-Path $OutDir 'install.html') -Value $html -Encoding UTF8

Write-Host "manifest -> $(Join-Path $OutDir 'manifest.plist')" -ForegroundColor Green
Write-Host "page     -> $(Join-Path $OutDir 'install.html')" -ForegroundColor Green
Write-Host "ipa url  -> $ipaUrl"
Write-Host ""
Write-Host "iPhone 上用 Safari 打开：$($BaseUrl.TrimEnd('/'))/install.html" -ForegroundColor Cyan
