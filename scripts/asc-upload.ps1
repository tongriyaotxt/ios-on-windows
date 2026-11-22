<#
.SYNOPSIS
    从 Windows 把 .ipa 传进 App Store Connect —— 不需要 macOS、不需要 Xcode、不需要 Transporter。
.DESCRIPTION
    WWDC25 之后 App Store Connect REST API 自己就能收二进制（POST /v1/buildUploads），
    所以「上传」这一步彻底脱离 macOS。本脚本实现完整四步：

      1. POST /v1/buildUploads            建一个上传会话，拿到 buildUploadId
      2. POST /v1/buildUploadFiles        声明文件名/大小，拿回 uploadOperations[]（预签名分片 URL）
      3. PUT  <每个分片 URL>              按 offset/length 切片上传，逐片校验
      4. PATCH /v1/buildUploads/{id}      uploaded=true，交回 Apple 处理
      5. GET  /v1/builds?...              轮询 processingState 到 VALID / INVALID / FAILED

    鉴权只用 App Store Connect API Key（.p8 + Key ID + Issuer ID），JWT 见 lib\AscJwt.ps1。
.EXAMPLE
    .\asc-upload.ps1 -Ipa .\build\AppCore.ipa -BundleVersion 42 -AppId 6471234567
.EXAMPLE
    # 对着本地 mock 跑通流程（不发真包）
    .\asc-upload.ps1 -Ipa .\test.ipa -BundleVersion 1 -AppId 1 -ApiBase http://127.0.0.1:8787
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Ipa,
    [Parameter(Mandatory)][string]$BundleVersion,          # CFBundleVersion，必须比上一版大
    [string]$Platform = 'IOS',
    [string]$AppId,                                        # 数字 App ID，仅轮询用；不填就跳过轮询
    [string]$KeyPath = $env:ASC_KEY_PATH,
    [string]$KeyId = $env:ASC_KEY_ID,
    [string]$IssuerId = $env:ASC_ISSUER_ID,
    [string]$ApiBase = 'https://api.appstoreconnect.apple.com',
    [int]$ChunkRetry = 3,
    [int]$PollTimeoutMinutes = 45,
    [switch]$SkipPoll,
    [switch]$SkipVerify,                                   # 不校验 Apple 回的 chunk 覆盖度
    [string]$ResultDir = (Join-Path $PSScriptRoot '..\build\asc')
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
. (Join-Path $PSScriptRoot 'lib\Bootstrap.ps1')
. (Join-Path $PSScriptRoot 'lib\AscJwt.ps1')

# ---------- 小工具 ----------------------------------------------------------
function Write-Step([string]$Text) { Write-Host "==> $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text) { Write-Host "    $Text" -ForegroundColor Green }

function Get-AscHeaders {
    $jwt = New-AscJwt -KeyPath $KeyPath -KeyId $KeyId -IssuerId $IssuerId
    return @{ Authorization = "Bearer $jwt"; Accept = 'application/json' }
}

function Invoke-AscJson {
    param(
        [string]$Method,
        [string]$Path,
        $Body,
        [hashtable]$Headers
    )
    $uri = "$ApiBase$Path"
    $params = @{
        Uri         = $uri
        Method      = $Method
        Headers     = $Headers
        ErrorAction = 'Stop'
    }
    if ($null -ne $Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 12 -Compress)
        $params.ContentType = 'application/json'
    }
    try {
        return Invoke-RestMethod @params
    } catch {
        $resp = $_.Exception.Response
        if ($resp) {
            $reader = New-Object IO.StreamReader($resp.GetResponseStream())
            $payload = $reader.ReadToEnd()
            throw "ASC $Method $Path failed [$([int]$resp.StatusCode)]: $payload"
        }
        throw
    }
}

function Invoke-PutChunk {
    param([string]$Url, [hashtable]$RequestHeaders, [byte[]]$Bytes)
    $lastErr = $null
    for ($attempt = 1; $attempt -le $ChunkRetry; $attempt++) {
        try {
            $h = @{}
            foreach ($k in $RequestHeaders.Keys) { $h[$k] = $RequestHeaders[$k] }
            $null = Invoke-WebRequest -Uri $Url -Method Put -Headers $h -Body $Bytes `
                -ContentType 'application/octet-stream' -UseBasicParsing -TimeoutSec 600
            return
        } catch {
            $lastErr = $_
            Start-Sleep -Seconds ([Math]::Pow(2, $attempt))
        }
    }
    throw "Chunk upload failed after $ChunkRetry attempts: $($lastErr.Exception.Message)"
}

# ---------- 前置检查 --------------------------------------------------------
if (-not (Test-Path -LiteralPath $Ipa)) { throw "IPA not found: $Ipa" }
foreach ($pair in @(@('KeyPath', $KeyPath), @('KeyId', $KeyId), @('IssuerId', $IssuerId))) {
    if (-not $pair[1]) { throw "Missing $($pair[0]). Set it via parameter or `$env:ASC_* / .env." }
}
$ipaItem = Get-Item -LiteralPath $Ipa
if ($ipaItem.Extension -ne '.ipa') { Write-Warning "File extension is '$($ipaItem.Extension)', not .ipa — continuing anyway." }
$fileSize = $ipaItem.Length
New-Item -ItemType Directory -Path $ResultDir -Force | Out-Null

Write-Step "IPA: $($ipaItem.Name)  $([Math]::Round($fileSize / 1MB, 2)) MB  build=$BundleVersion"
$headers = Get-AscHeaders
Write-Ok 'JWT issued'

# ---------- 1. 建上传会话 ---------------------------------------------------
Write-Step 'POST /v1/buildUploads'
$createBody = @{
    data = @{
        type       = 'buildUploads'
        attributes = @{ bundleVersion = $BundleVersion; platform = $Platform }
    }
}
$created = Invoke-AscJson -Method Post -Path '/v1/buildUploads' -Body $createBody -Headers $headers
$buildUploadId = $created.data.id
if (-not $buildUploadId) { throw "Unexpected response from /v1/buildUploads: $($created | ConvertTo-Json -Depth 8)" }
Write-Ok "buildUploadId = $buildUploadId  state=$($created.data.attributes.state)"

# ---------- 2. 声明文件，拿分片清单 -----------------------------------------
Write-Step 'POST /v1/buildUploadFiles'
$fileBody = @{
    data = @{
        type          = 'buildUploadFiles'
        attributes    = @{ fileName = $ipaItem.Name; fileSize = $fileSize; assetType = 'BUILD' }
        relationships = @{
            buildUpload = @{ data = @{ id = $buildUploadId; type = 'buildUploads' } }
        }
    }
}
$fileResp = Invoke-AscJson -Method Post -Path '/v1/buildUploadFiles' -Body $fileBody -Headers $headers
$ops = $fileResp.data.attributes.uploadOperations
if (-not $ops) { throw "No uploadOperations returned: $($fileResp | ConvertTo-Json -Depth 8)" }
Write-Ok "$($ops.Count) chunk(s) authorized"

# ---------- 3. 分片上传 -----------------------------------------------------
Write-Step 'PUT chunks'
$stream = [IO.File]::OpenRead($ipaItem.FullName)
try {
    $buf = New-Object byte[] (1024 * 1024 * 8)
    $done = 0
    $covered = 0
    foreach ($op in $ops) {
        $offset = [int64]$op.offset
        $length = [int64]$op.length
        $chunk = New-Object byte[] $length
        $null = $stream.Seek($offset, 'Begin')
        $read = 0
        while ($read -lt $length) {
            $n = $stream.Read($chunk, $read, [int]($length - $read))
            if ($n -le 0) { throw "Unexpected EOF while reading chunk at offset $offset." }
            $read += $n
        }
        $rh = @{}
        foreach ($hdr in $op.requestHeaders) { $rh[$hdr.name] = $hdr.value }
        Invoke-PutChunk -Url $op.url -RequestHeaders $rh -Bytes $chunk
        $done += $length
        $covered += $length
        $pct = if ($fileSize -gt 0) { [Math]::Round(100 * $done / $fileSize) } else { 100 }
        Write-Host ("    [$pct%] offset={0,12} len={1,-9} {2}" -f $offset, $length, $op.method)
    }
} finally { $stream.Dispose() }

if (-not $SkipVerify -and $covered -ne $fileSize) {
    throw "Chunk coverage mismatch: authorized $covered bytes of $fileSize. Refusing to mark uploaded."
}

# ---------- 4. 交给 Apple ---------------------------------------------------
Write-Step "PATCH /v1/buildUploads/$buildUploadId"
$patchBody = @{
    data = @{
        type       = 'buildUploads'
        id         = $buildUploadId
        attributes = @{ uploaded = $true }
    }
}
$patched = Invoke-AscJson -Method Patch -Path "/v1/buildUploads/$buildUploadId" -Body $patchBody -Headers $headers
Write-Ok "state = $($patched.data.attributes.state)"

$summary = [ordered]@{
    ipa           = $ipaItem.FullName
    sizeBytes     = $fileSize
    bundleVersion = $BundleVersion
    platform      = $Platform
    buildUploadId = $buildUploadId
    state         = $patched.data.attributes.state
    uploadedAt    = (Get-Date).ToString('o')
}
$summaryPath = Join-Path $ResultDir "upload-$BundleVersion.json"
($summary | ConvertTo-Json) | Set-Content -LiteralPath $summaryPath -Encoding UTF8
Write-Ok "receipt -> $summaryPath"

# ---------- 5. 轮询处理状态 -------------------------------------------------
if ($SkipPoll -or -not $AppId) {
    Write-Host ''
    Write-Host 'Done. Poll later with: .\scripts\asc-status.ps1 -AppId <id> -BundleVersion <n>' -ForegroundColor Yellow
    return
}

Write-Step "GET /v1/builds  (app=$AppId version=$BundleVersion)"
$deadline = (Get-Date).AddMinutes($PollTimeoutMinutes)
$state = 'PROCESSING'
while ((Get-Date) -lt $deadline) {
    $q = "/v1/builds?filter[app]=$AppId&filter[version]=$BundleVersion" +
         '&fields[builds]=version,processingState,uploadedDate,expirationDate&sort=-uploadedDate&limit=5'
    $builds = Invoke-AscJson -Method Get -Path $q -Headers $headers
    if ($builds.data -and $builds.data.Count -gt 0) {
        $state = $builds.data[0].attributes.processingState
        if ($state -ne 'PROCESSING') { break }
    }
    Start-Sleep -Seconds 45
}
switch ($state) {
    'VALID' { Write-Host "    build is VALID -> usable in TestFlight" -ForegroundColor Green }
    'PROCESSING' { Write-Host '    still PROCESSING at timeout; check App Store Connect later' -ForegroundColor Yellow }
    default { Write-Host "    processingState = $state" -ForegroundColor Red }
}
$summary.state = $state
($summary | ConvertTo-Json) | Set-Content -LiteralPath $summaryPath -Encoding UTF8
if ($state -in @('INVALID', 'FAILED')) { exit 2 }
