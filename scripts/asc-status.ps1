<#
.SYNOPSIS
    查询某个 build 在 App Store Connect 的处理状态（纯 REST，Windows 可直接跑）。
.EXAMPLE
    .\asc-status.ps1 -AppId 6471234567 -BundleVersion 42
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$AppId,
    [Parameter(Mandatory)][string]$BundleVersion,
    [string]$KeyPath = $env:ASC_KEY_PATH,
    [string]$KeyId = $env:ASC_KEY_ID,
    [string]$IssuerId = $env:ASC_ISSUER_ID,
    [string]$ApiBase = 'https://api.appstoreconnect.apple.com'
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
. (Join-Path $PSScriptRoot 'lib\Bootstrap.ps1')
. (Join-Path $PSScriptRoot 'lib\AscJwt.ps1')

$jwt = New-AscJwt -KeyPath $KeyPath -KeyId $KeyId -IssuerId $IssuerId
$headers = @{ Authorization = "Bearer $jwt"; Accept = 'application/json' }
$q = "/v1/builds?filter[app]=$AppId&filter[version]=$BundleVersion" +
     '&fields[builds]=version,processingState,uploadedDate,expirationDate,expired&sort=-uploadedDate&limit=10'

$resp = Invoke-RestMethod -Uri "$ApiBase$q" -Method Get -Headers $headers
if (-not $resp.data -or $resp.data.Count -eq 0) {
    Write-Host "No build found for app=$AppId version=$BundleVersion" -ForegroundColor Yellow
    exit 1
}
$resp.data | ForEach-Object {
    [pscustomobject]@{
        id              = $_.id
        version         = $_.attributes.version
        processingState = $_.attributes.processingState
        uploadedDate    = $_.attributes.uploadedDate
        expired         = $_.attributes.expired
    }
} | Format-Table -AutoSize
