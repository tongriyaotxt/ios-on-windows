<#
.SYNOPSIS
    零 macOS 全链路自测：生成 Mach-O → 签名（ad-hoc + 真证书 CMS）→ 组 .app → 打 .ipa → OTA 清单 → 模拟上传。
.DESCRIPTION
    不联网、不碰 Apple、不需要任何 macOS。跑完你会得到：
      build\xc\HelloIOS.ipa          ad-hoc 签名
      build\xc\HelloIOSCms.ipa       证书 CMS 签名（自签测试证书）
      build\xc\ota\manifest.plist    itms-services 安装清单
      build\xc\asc\upload-3.json     上传回执（对本地 mock）
.EXAMPLE
    .\tools\test-nomac-build.ps1
#>
[CmdletBinding()]
param(
    [int]$MockPort = 8790,
    [string]$BundleId = 'com.tongriyaotxt.helloios'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
$env:PYTHONIOENCODING = 'utf-8'
$py = 'python'
$fail = 0
function Step([string]$t) { Write-Host "`n== $t" -ForegroundColor Cyan }
function Ok([string]$t) { Write-Host "   PASS  $t" -ForegroundColor Green }
function Bad([string]$t) { Write-Host "   FAIL  $t" -ForegroundColor Red; $script:fail++ }

# ---------------------------------------------------------------- 0. 准备
Step '0/6 准备：测试证书 + entitlements'
New-Item -ItemType Directory -Path .\secrets, .\build\xc -Force | Out-Null
$p12 = '.\secrets\test-dist.p12'
if (-not (Test-Path $p12)) {
    & $py -c @"
import datetime, sys
from cryptography import x509
from cryptography.x509.oid import NameOID
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.serialization import pkcs12
from cryptography.hazmat.primitives.asymmetric import ec
key = ec.generate_private_key(ec.SECP256R1())
name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'AppCore Distribution (TEST ONLY)')])
now = datetime.datetime.now(datetime.timezone.utc)
cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
        .public_key(key.public_key()).serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(days=1))
        .not_valid_after(now + datetime.timedelta(days=365))
        .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
        .sign(key, hashes.SHA256()))
open('secrets/test-dist.p12','wb').write(
    pkcs12.serialize_key_and_certificates(b'appcore-test', key, cert, None,
        serialization.BestAvailableEncryption(b'testpass')))
"@
    if ($LASTEXITCODE -eq 0) { Ok "生成测试证书 $p12" } else { Bad '生成测试证书' }
} else { Ok "复用 $p12" }

$entPath = '.\build\xc\ent.plist'
[IO.File]::WriteAllText((Join-Path $root $entPath),
    '{"get-task-allow": true, "application-identifier": "ABCDE12345.' + $BundleId + '"}',
    [Text.ASCIIEncoding]::new())

# ---------------------------------------------------------------- 1. ad-hoc
Step '1/6 ad-hoc 构建'
& powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\xc\Build-IosApp.ps1 `
    -BundleId $BundleId -Name HelloIOS -Version 1.0.0 -Build 3 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0 -and (Test-Path .\build\xc\HelloIOS.ipa)) { Ok 'IPA 生成' } else { Bad 'IPA 生成' }

Step '2/6 校验 Mach-O 与签名'
& $py .\tools\codesign_lite.py verify --binary .\build\xc\HelloIOS\HelloIOS.app\HelloIOS 2>&1 | Select-Object -Last 1
if ($LASTEXITCODE -eq 0) { Ok '签名自校验 VALID' } else { Bad '签名自校验' }

Step '3/6 校验 IPA 结构'
$check = & $py -c @"
import sys, zipfile, plistlib
z = zipfile.ZipFile(r'build/xc/HelloIOS.ipa')
n = z.namelist()
assert all('\\' not in x for x in n), 'entry 里有反斜杠'
assert all(x.startswith('Payload/HelloIOS.app/') for x in n), 'Payload 前缀不对'
info = plistlib.loads(z.read('Payload/HelloIOS.app/Info.plist'))
assert info['CFBundleIdentifier'] == '$BundleId'
assert info['CFBundleExecutable'] == 'HelloIOS'
print('ok')
"@
if ($check -eq 'ok') { Ok 'Payload/ 前缀 + 正斜杠 + Info.plist 可解析' } else { Bad "IPA 结构: $check" }

# ---------------------------------------------------------------- 2. CMS
Step '4/6 证书 CMS 构建（真 PKCS#7）'
& powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\xc\Build-IosApp.ps1 `
    -BundleId $BundleId -Name HelloIOSCms -Version 1.0.1 -Build 4 `
    -P12 $p12 -Password testpass -TeamId ABCDE12345 -Entitlements $entPath 2>&1 | Out-Null
if (Test-Path .\build\xc\HelloIOSCms.ipa) { Ok 'CMS 版 IPA 生成' } else { Bad 'CMS 版 IPA' }
& $py .\tools\codesign_lite.py verify --binary .\build\xc\HelloIOSCms\HelloIOSCms.app\HelloIOSCms 2>&1 |
    Select-String -Pattern 'cms:|nSpecial|RESULT' | ForEach-Object { "   $($_.Line.Trim())" }
$cmsOut = & $py .\tools\codesign_lite.py verify --binary .\build\xc\HelloIOSCms\HelloIOSCms.app\HelloIOSCms 2>&1 | Out-String
if ($cmsOut -match 'cms: present' -and $cmsOut -match 'RESULT: VALID') { Ok 'CMS 存在且页哈希一致' } else { Bad 'CMS 校验' }

# ---------------------------------------------------------------- 3. OTA
Step '5/6 OTA 清单'
& powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\make-ota-manifest.ps1 `
    -Ipa .\build\xc\HelloIOS.ipa -BaseUrl 'https://192.168.2.2:8443' -OutDir .\build\xc\ota 2>&1 | Out-Null
if (Test-Path .\build\xc\ota\manifest.plist) {
    $mf = Get-Content .\build\xc\ota\manifest.plist -Raw
    if ($mf -match [regex]::Escape($BundleId) -and $mf -match 'software-package') { Ok 'manifest.plist 含 bundle id 与包地址' }
    else { Bad 'manifest.plist 内容' }
} else { Bad 'manifest.plist 生成' }

# ---------------------------------------------------------------- 4. 上传
Step "6/6 模拟上传（mock ASC :$MockPort）"
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $py
$psi.Arguments = "tools\mock-asc-server.py --port $MockPort --ipa build\xc\HelloIOS.ipa"
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$proc = [System.Diagnostics.Process]::Start($psi)
Start-Sleep -Milliseconds 900
try {
    & powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\asc-upload.ps1 `
        -Ipa .\build\xc\HelloIOS.ipa -BundleVersion 3 -AppId 1 `
        -KeyPath .\secrets\AuthKey_MOCKTEST01.p8 -KeyId MOCKTEST01 `
        -IssuerId '11111111-2222-3333-4444-555555555555' `
        -ApiBase "http://127.0.0.1:$MockPort" -SkipPoll -ResultDir .\build\xc\asc 2>&1 | Out-Null
    $proc.StandardInput.WriteLine('quit'); $proc.StandardInput.Flush()
    $null = $proc.WaitForExit(15000)
    $report = $proc.StandardOutput.ReadToEnd()
    $report
    if ($report -match '"uploaded": true' -and $report -match '"errors": \[\]') { Ok 'mock 端重组哈希一致、上传完成' }
    else { Bad 'mock 上传' }
} finally {
    if (-not $proc.HasExited) { try { $proc.Kill() } catch { } }
}

Step '7/7 zig 原生构建（真编译 UIKit dylib）'
$zigOk = $true
try { $null = & python -c "import ziglang" 2>&1 } catch { $zigOk = $false }
if (Get-Command zig -ErrorAction SilentlyContinue) { $zigOk = $true }
if ($zigOk) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\xc\Build-IosAppNative.ps1 `
        -Source .\samples\UIKitApp\AppCoreUI.m -Name AppCore -Build 5 2>&1 | Out-Null
    if (Test-Path .\build\xc\AppCore-native.ipa) { Ok 'zig 编出 UIKit dylib 并打成 ipa' } else { Bad 'zig 原生构建' }
    $chk = & $py -c @"
import sys, zipfile, struct
z = zipfile.ZipFile(r'build/xc/AppCore-native.ipa')
n = z.namelist()
assert 'Payload/AppCore.app/Frameworks/AppCore.dylib' in n, n
d = z.read('Payload/AppCore.app/Frameworks/AppCore.dylib')
ncmds, = struct.unpack_from('<I', d, 16); off=32; deps=[]; sig=False; plat=None
for _ in range(ncmds):
    cmd, cs = struct.unpack_from('<II', d, off)
    if cmd == 0xC:
        o = struct.unpack_from('<I', d, off+8)[0]; deps.append(d[off+o:off+cs].split(b'\0')[0].decode())
    if cmd == 0x1D: sig = True
    if cmd == 0x32: plat = struct.unpack_from('<I', d, off+8)[0]
    off += cs
assert plat == 2, plat
assert sig, 'dylib 未签名'
assert any('UIKit' in x for x in deps), deps
print('ok')
"@
    if ($chk -eq 'ok') { Ok 'dylib 依赖 UIKit 且已签名（iOS 平台）' } else { Bad "dylib 检查: $chk" }
} else { Write-Host '   SKIP  zig 未安装（pip install ziglang 后可跑这一步）' -ForegroundColor Yellow }

Step '8/8 上架前静态校验 + SDK 解包器自测'
$verOut = & $py .\tools\verify-ipa.py .\build\xc\AppCore-native.ipa 2>&1 | Out-String
if ($verOut -match '0 失败') { Ok 'verify-ipa: 0 失败（图标/Mach-O/依赖/签名全过）' }
else { Bad "verify-ipa: $((($verOut -split "`n" | Select-String 'FAIL' | Select-Object -First 2) -join ' / '))" }
& $py .\tools\test-xip.py 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) { Ok 'xip-extract: xar→pbzx→cpio 三层往返一致' } else { Bad 'xip 解包器' }

Step '9/9 真机启动审计'
$audit = & $py .\tools\audit-device.py .\build\xc\AppCore-native.ipa 2>&1 | Out-String
$audit -split "`n" | Where-Object { $_ -match '^\[(FATAL|HIGH)' } | ForEach-Object { "   $($_.Trim())" }
if ($audit -match '缺 LC_LOAD_DYLINKER|缺 LC_MAIN|特殊槽只有 0|CFBundleSupportedPlatforms|特殊槽只有') {
    Bad '审计里还有可修复的结构问题（见上）'
} else {
    Ok '结构类问题已清零；剩余项都是凭证/设备相关'
}

Step '10/10 模拟执行（不用真机验启动链路）'
$simOut = & $py .\tools\sim-ios.py .\build\xc\AppCore.work\AppCore.app 2>&1 | Out-String
$simOut -split "`n" | Where-Object { $_ -match '^\s+\[(PASS|FAIL|SKIP)\]' } | ForEach-Object { "   $($_.Trim())" }
if ($simOut -match 'PASS —— App 的启动链路') { Ok '模拟器跑通启动链路（constructor → UIApplicationMain → 界面调用）' }
else { Bad '模拟执行失败（见上）' }

Write-Host ''
if ($fail -eq 0) {
    Write-Host 'PASS —— 全链路零 macOS：Mach-O 生成 / 签名(ad-hoc+CMS) / .app / .ipa / OTA / 上传' -ForegroundColor Green
    exit 0
} else {
    Write-Host "FAIL —— $fail 项未通过" -ForegroundColor Red
    exit 1
}
