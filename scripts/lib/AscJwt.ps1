<#
.SYNOPSIS
    App Store Connect API 的 ES256 JWT 签发（纯 Windows，不需要 macOS / Xcode / node）。
.DESCRIPTION
    Apple 下发的 .p8 是 PKCS#8 PEM 包装的 secp256r1 私钥。Windows 上没有任何 .NET API 能直接吃它：
      - PowerShell 5.1 / .NET Framework 没有 ECDsa.ImportPkcs8PrivateKey；
      - ECDsa.ImportParameters 又强制要求 Q.X / Q.Y（只给 D 会报 "Q.X and Q.Y are required"）；
      - 自己补公钥就要做 P-256 标量乘法，纯 PowerShell 实现能跑但风险高。

    所以这里用 openssl 签（Git for Windows 自带 C:\Program Files\Git\usr\bin\openssl.exe），
    再把 openssl 的 DER 签名转成 JWT 规定的 R||S 定长 64 字节。全链路离线自检见 scripts/selftest-jwt.ps1。
.EXAMPLE
    . .\scripts\lib\AscJwt.ps1
    New-AscJwt -KeyPath .\secrets\AuthKey_ABC1234567.p8 -KeyId ABC1234567 -IssuerId 11111111-2222-3333-4444-555555555555
#>

function ConvertFrom-Base64Url([string]$S) {
    $t = $S.Replace('-', '+').Replace('_', '/')
    switch ($t.Length % 4) { 2 { $t += '==' } 3 { $t += '=' } }
    return , [Convert]::FromBase64String($t)
}

function ConvertTo-Base64Url([byte[]]$Bytes) {
    return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function ConvertTo-JsonCompact($Object) {
    return ($Object | ConvertTo-Json -Compress -Depth 8)
}

# openssl 探测：环境变量 > Git 自带 > 常见安装位 > PATH
function Get-OpenSslPath {
    $cands = @(
        $env:OPENSSL_EXE,
        'C:\Program Files\Git\usr\bin\openssl.exe',
        'C:\Program Files\Git\mingw64\bin\openssl.exe',
        'C:\Program Files\OpenSSL-Win64\bin\openssl.exe',
        'C:\Program Files\OpenSSL\bin\openssl.exe'
    )
    foreach ($c in $cands) { if ($c -and (Test-Path -LiteralPath $c)) { return (Resolve-Path -LiteralPath $c).Path } }
    $cmd = Get-Command openssl -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Read-DerLength([byte[]]$Buf, [ref]$Offset) {
    $b = $Buf[$Offset.Value]; $Offset.Value++
    if ($b -lt 0x80) { return $b }
    $n = $b -band 0x7F; $len = 0
    for ($i = 0; $i -lt $n; $i++) { $len = ($len -shl 8) -bor $Buf[$Offset.Value]; $Offset.Value++ }
    return $len
}

function Read-DerElement([byte[]]$Buf, [ref]$Offset) {
    $tag = $Buf[$Offset.Value]; $Offset.Value++
    $len = Read-DerLength $Buf $Offset
    $val = New-Object byte[] $len
    [Array]::Copy($Buf, $Offset.Value, $val, 0, $len)
    $Offset.Value += $len
    return @{ Tag = $tag; Value = $val }
}

# DER ECDSA-Sig-Value(SEQUENCE{INTEGER r, INTEGER s}) -> JWT 要的 R||S 定长 64 字节
function ConvertFrom-DerSignature([byte[]]$Der, [int]$FieldSize = 32) {
    $off = 0
    $seq = Read-DerElement $Der ([ref]$off)
    $o = 0; $buf = $seq.Value
    $r = (Read-DerElement $buf ([ref]$o)).Value
    $s = (Read-DerElement $buf ([ref]$o)).Value
    while ($r.Length -gt 1 -and $r[0] -eq 0) { $r = $r[1..($r.Length - 1)] }
    while ($s.Length -gt 1 -and $s[0] -eq 0) { $s = $s[1..($s.Length - 1)] }
    if ($r.Length -gt $FieldSize -or $s.Length -gt $FieldSize) { throw 'ECDSA signature integer wider than the curve.' }
    $out = New-Object byte[] ($FieldSize * 2)
    [Array]::Copy($r, 0, $out, ($FieldSize - $r.Length), $r.Length)
    [Array]::Copy($s, 0, $out, ($FieldSize * 2 - $s.Length), $s.Length)
    return , $out
}

function Invoke-OpenSslEcdsaSign([string]$OpenSsl, [string]$KeyPath, [byte[]]$Data) {
    $tmpIn = [IO.Path]::GetTempFileName()
    $tmpOut = [IO.Path]::GetTempFileName()
    try {
        [IO.File]::WriteAllBytes($tmpIn, $Data)
        $out = & $OpenSsl dgst -sha256 -sign $KeyPath -out $tmpOut $tmpIn 2>&1
        if ($LASTEXITCODE -ne 0) { throw "openssl failed (exit $LASTEXITCODE): $out" }
        return , [IO.File]::ReadAllBytes($tmpOut)
    } finally {
        Remove-Item -LiteralPath $tmpIn, $tmpOut -Force -ErrorAction SilentlyContinue
    }
}

<#
.SYNOPSIS  生成 App Store Connect API JWT（ES256）。
.PARAMETER KeyPath  AuthKey_XXXXXXXXXX.p8 路径。
.PARAMETER KeyId    10 位 Key ID（写进 JWT header.kid）。
.PARAMETER IssuerId Issuer ID（UUID）。
.PARAMETER TtlMinutes 有效期，Apple 硬上限 20 分钟，默认 19。
#>
function New-AscJwt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$KeyPath,
        [Parameter(Mandatory)][string]$KeyId,
        [Parameter(Mandatory)][string]$IssuerId,
        [int]$TtlMinutes = 19
    )
    if ($TtlMinutes -gt 20) { throw 'App Store Connect rejects tokens with a lifetime above 20 minutes.' }
    if (-not (Test-Path -LiteralPath $KeyPath)) { throw "API key not found: $KeyPath" }
    $openssl = Get-OpenSslPath
    if (-not $openssl) {
        throw 'openssl not found. Install Git for Windows (ships openssl) or `winget install ShiningLight.OpenSSL.Light`, or set $env:OPENSSL_EXE.'
    }

    $now = [DateTimeOffset]::UtcNow
    $header = [ordered]@{ alg = 'ES256'; kid = $KeyId; typ = 'JWT' }
    $payload = [ordered]@{
        iss = $IssuerId
        iat = $now.ToUnixTimeSeconds()
        exp = $now.AddMinutes($TtlMinutes).ToUnixTimeSeconds()
        aud = 'appstoreconnect-v1'
    }
    $h = ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes((ConvertTo-JsonCompact $header)))
    $p = ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes((ConvertTo-JsonCompact $payload)))
    $signingInput = [Text.Encoding]::ASCII.GetBytes("$h.$p")

    $der = Invoke-OpenSslEcdsaSign $openssl $KeyPath $signingInput
    $raw = ConvertFrom-DerSignature $der 32
    return "$h.$p.$(ConvertTo-Base64Url $raw)"
}
