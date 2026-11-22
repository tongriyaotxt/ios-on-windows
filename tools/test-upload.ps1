<#
.SYNOPSIS
    端到端验证 asc-upload.ps1：造一个假 .ipa、造一把临时 .p8、起本地 mock ASC、跑完整上传、核对结果。
.DESCRIPTION
    不联网、不碰 Apple、不消耗任何真实凭证。只在 <repo> 下留一个 build\ 目录当产物。
#>
[CmdletBinding()]
param(
    [int]$Port = 8787,
    [int]$SizeMB = 5
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function New-DerTlv([int]$Tag, [byte[]]$Value) {
    $len = $Value.Length
    if ($len -lt 0x80) { $lenBytes = [byte[]]@($len) }
    else {
        $acc = New-Object System.Collections.Generic.List[byte]
        $v = $len
        while ($v -gt 0) { $acc.Insert(0, [byte]($v -band 0xFF)); $v = $v -shr 8 }
        $lenBytes = [byte[]](@([byte](0x80 -bor $acc.Count)) + $acc.ToArray())
    }
    return [byte[]](@([byte]$Tag) + $lenBytes + $Value)
}
function Join-All([byte[][]]$Parts) {
    $acc = New-Object System.Collections.Generic.List[byte]
    foreach ($p in $Parts) { $acc.AddRange($p) }
    return , $acc.ToArray()
}

# ---- 1. 造临时密钥（结构等价于 Apple 的 AuthKey_*.p8） ---------------------
$build = Join-Path $root 'build'
$secrets = Join-Path $root 'secrets'
New-Item -ItemType Directory -Path $build, $secrets -Force | Out-Null

$ec = [System.Security.Cryptography.ECDsa]::Create([System.Security.Cryptography.ECCurve+NamedCurves]::nistP256)
$prm = $ec.ExportParameters($true)
$alg = New-DerTlv 0x30 (Join-All @([byte[]](0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01), [byte[]](0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07)))
$sec1 = New-DerTlv 0x30 (Join-All @(
            (New-DerTlv 0x02 ([byte[]](1))),
            (New-DerTlv 0x04 $prm.D),
            (New-DerTlv 0xA1 (New-DerTlv 0x03 (Join-All @([byte[]](0), [byte[]](4), $prm.Q.X, $prm.Q.Y))))))
$pkcs8 = New-DerTlv 0x30 (Join-All @((New-DerTlv 0x02 ([byte[]](0))), $alg, (New-DerTlv 0x04 $sec1)))
$keyPath = Join-Path $secrets 'AuthKey_MOCKTEST01.p8'
$b64 = [Convert]::ToBase64String($pkcs8)
[IO.File]::WriteAllText($keyPath, "-----BEGIN PRIVATE KEY-----`n$b64`n-----END PRIVATE KEY-----`n")

# ---- 2. 造假 IPA -----------------------------------------------------------
$ipa = Join-Path $build 'AppCore-mock.ipa'
$bytes = New-Object byte[] ($SizeMB * 1MB)
(New-Object Random 42).NextBytes($bytes)
[IO.File]::WriteAllBytes($ipa, $bytes)
Write-Host "[setup] key  -> $keyPath"
Write-Host "[setup] ipa  -> $ipa ($([Math]::Round((Get-Item $ipa).Length / 1MB, 2)) MB)"

# ---- 3. 起 mock ------------------------------------------------------------
$mockScript = Join-Path $root 'tools\mock-asc-server.py'
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = 'python'
$psi.Arguments = "`"$mockScript`" --port $Port --ipa `"$ipa`""
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$proc = [System.Diagnostics.Process]::Start($psi)
Start-Sleep -Milliseconds 900
if ($proc.HasExited) { throw "mock server died: $($proc.StandardError.ReadToEnd())" }
Write-Host "[setup] mock  -> http://127.0.0.1:$Port"

try {
    # ---- 4. 跑上传 ---------------------------------------------------------
    $out = & (Join-Path $root 'scripts\asc-upload.ps1') `
        -Ipa $ipa -BundleVersion '7' -AppId '1234567890' `
        -KeyPath $keyPath -KeyId 'MOCKTEST01' -IssuerId '11111111-2222-3333-4444-555555555555' `
        -ApiBase "http://127.0.0.1:$Port" -PollTimeoutMinutes 1 -ResultDir (Join-Path $build 'asc') 2>&1
    $out | ForEach-Object { Write-Host $_ }

    # ---- 5. 收 mock 结论 ---------------------------------------------------
    $proc.StandardInput.WriteLine('quit')
    $proc.StandardInput.Flush()
    $null = $proc.WaitForExit(15000)
    $report = $proc.StandardOutput.ReadToEnd()
    $report
    if ($report -notmatch '"errors": \[\]') { throw "MOCK REPORTED ERRORS — see above" }
    if ($report -notmatch '"uploaded": true') { throw 'upload was not completed' }

    # ---- 6. 校验回执 -------------------------------------------------------
    $receiptPath = Join-Path $build 'asc\upload-7.json'
    $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
    if ($receipt.buildUploadId -ne 'bu-mock-1') { throw "receipt buildUploadId mismatch: $($receipt.buildUploadId)" }
    if ($receipt.state -notin @('COMPLETE', 'VALID')) { throw "receipt state = $($receipt.state)" }
    Write-Host ''
    Write-Host 'PASS — JWT 校验通过、4 个分片按 offset 重组、sha256 一致、回执落盘。' -ForegroundColor Green
} finally {
    if (-not $proc.HasExited) { try { $proc.Kill() } catch { } }
}
