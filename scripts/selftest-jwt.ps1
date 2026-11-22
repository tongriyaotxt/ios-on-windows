<#
.SYNOPSIS
    离线自检：不联网、不碰 Apple，验证 AscJwt.ps1 的 PKCS#8 解析 + P-256 点乘 + ES256 签发是否真能用。
.DESCRIPTION
    流程：.NET 现场造一对 P-256 密钥 -> 手工拼成 PKCS#8 PEM（等价于 Apple 下发的 .p8）
          -> New-AscJwt 签发 -> 用公钥按 JWT 规则（R||S 定长 64B）验签。
    任何一步失败都会 throw，退出码非 0。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\AscJwt.ps1')

function New-DerElement([int]$Tag, [byte[]]$Value) {
    $len = $Value.Length
    $lenBytes = @()
    if ($len -lt 0x80) { $lenBytes = @([byte]$len) }
    else { $b = @(); $v = $len; while ($v -gt 0) { $b = @([byte]($v -band 0xFF)) + $b; $v = $v -shr 8 }; $lenBytes = @([byte](0x80 -bor $b.Count)) + $b }
    return [byte[]](@([byte]$Tag) + $lenBytes + $Value)
}

function Join-Bytes([byte[][]]$Parts) {
    $out = New-Object System.Collections.Generic.List[byte]
    foreach ($p in $Parts) { $out.AddRange($p) }
    return , $out.ToArray()
}

Write-Host '[1/5] generating a throwaway P-256 key pair with .NET ...'
$ec = [System.Security.Cryptography.ECDsa]::Create([System.Security.Cryptography.ECCurve+NamedCurves]::nistP256)
$prm = $ec.ExportParameters($true)

Write-Host '[2/5] assembling a PKCS#8 PEM that looks exactly like AuthKey_XXXXXXXXXX.p8 ...'
$oidEcPub   = [byte[]](0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01)   # 1.2.840.10045.2.1
$oidP256    = [byte[]](0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07) # 1.2.840.10045.3.1.7
$algId      = New-DerElement 0x30 (Join-Bytes @($oidEcPub, $oidP256))
$ver1       = New-DerElement 0x02 ([byte[]](0x01))
$dOct       = New-DerElement 0x04 $prm.D
$pubPoint   = Join-Bytes @([byte[]](0x04), $prm.Q.X, $prm.Q.Y)
$bitStr     = New-DerElement 0xA1 (New-DerElement 0x03 (Join-Bytes @([byte[]](0x00), $pubPoint)))   # [1] EXPLICIT
$inner      = New-DerElement 0x30 (Join-Bytes @($ver1, $dOct, $bitStr))     # SEC1 ECPrivateKey
$ver0       = New-DerElement 0x02 ([byte[]](0x00))
$octInner   = New-DerElement 0x04 $inner
$pkcs8      = New-DerElement 0x30 (Join-Bytes @($ver0, $algId, $octInner))
$b64        = [Convert]::ToBase64String($pkcs8)
$pem        = "-----BEGIN PRIVATE KEY-----`n" + (($b64 -split '(.{64})' | Where-Object { $_ }) -join "`n") + "`n-----END PRIVATE KEY-----`n"
$tmpDir  = Join-Path ([IO.Path]::GetTempPath()) ('ascjwt-selftest-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
$keyPath = Join-Path $tmpDir 'AuthKey_TESTSELFT.p8'
Set-Content -LiteralPath $keyPath -Value $pem -NoNewline -Encoding ascii
Write-Host "      -> $keyPath"

Write-Host '[3/5] issuing a JWT with New-AscJwt ...'
$sw = [Diagnostics.Stopwatch]::StartNew()
$jwt = New-AscJwt -KeyPath $keyPath -KeyId 'TESTSELFT1' -IssuerId '11111111-2222-3333-4444-555555555555'
$sw.Stop()
Write-Host "      -> $($jwt.Substring(0,60))... ($($sw.ElapsedMilliseconds) ms)"

Write-Host '[4/5] checking header / claims ...'
$parts = $jwt.Split('.')
if ($parts.Count -ne 3) { throw "JWT must have 3 segments, got $($parts.Count)." }
$headerJson  = [Text.Encoding]::UTF8.GetString((ConvertFrom-Base64Url $parts[0]))
$payloadJson = [Text.Encoding]::UTF8.GetString((ConvertFrom-Base64Url $parts[1]))
Write-Host "      header : $headerJson"
Write-Host "      payload: $payloadJson"
$header = $headerJson | ConvertFrom-Json
if ($header.alg -ne 'ES256') { throw "alg must be ES256, got '$($header.alg)'." }
if ($header.kid -ne 'TESTSELFT1') { throw 'kid mismatch.' }
$payload = $payloadJson | ConvertFrom-Json
if ($payload.aud -ne 'appstoreconnect-v1') { throw 'aud mismatch.' }
$ttl = [int64]$payload.exp - [int64]$payload.iat
if ($ttl -gt 1200) { throw "Token lifetime $ttl s exceeds Apple's 20 min ceiling." }

Write-Host '[5/5] verifying the signature against the public key ...'
$raw = ConvertFrom-Base64Url $parts[2]
if ($raw.Length -ne 64) { throw "ES256 signature must be 64 bytes (R||S), got $($raw.Length)." }
# 手工把 R||S 转回 DER，再用 .NET 默认接口验签（Framework 没有 P1363 格式参数）
$r = [byte[]]$raw[0..31]; $s = [byte[]]$raw[32..63]
function ConvertTo-DerInt([byte[]]$v) {
    $i = 0; while ($i -lt $v.Length - 1 -and $v[$i] -eq 0) { $i++ }
    $trim = [byte[]]$v[$i..($v.Length - 1)]
    if ($trim[0] -band 0x80) { $trim = [byte[]](@([byte]0) + $trim) }
    return New-DerElement 0x02 $trim
}
$derSig = New-DerElement 0x30 (Join-Bytes @((ConvertTo-DerInt $r), (ConvertTo-DerInt $s)))
$ok = $ec.VerifyData([Text.Encoding]::ASCII.GetBytes("$($parts[0]).$($parts[1])"), [byte[]]$raw, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
if (-not $ok) { throw 'SIGNATURE INVALID — the JWT would be rejected by App Store Connect.' }

Remove-Item -LiteralPath $tmpDir -Recurse -Force
Write-Host ''
Write-Host 'PASS — PKCS#8/PEM 解析 + ES256(openssl) 签名 + R||S 定长编码，全部离线验证通过。' -ForegroundColor Green
exit 0
