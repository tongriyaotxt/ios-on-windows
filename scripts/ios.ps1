<#
.SYNOPSIS
    iOS 项目在 Windows 上的唯一入口。所有子命令都可以在这台机器上跑完，不需要 Mac。
.DESCRIPTION
    子命令：
      doctor     体检工具链（调 check-toolchain.ps1）
      bump       自增 build 号（VERSION 文件是唯一真源）
      cloud      触发云端 macOS 构建（GitHub Actions / EAS，二选一）
      nomac      零 macOS 打包：Mach-O + 签名 + .app + .ipa（无界面，见 docs/07）
      download   从最近一次成功的 workflow run 拉回 .ipa 产物
      upload     把 .ipa 传到 App Store Connect（REST buildUploads）
      status    轮询某个 build 的处理状态
      ota        生成 itms-services 安装清单 + 本地 HTTPS 服务（免 TestFlight 直接装机）
      install    用 libimobiledevice / pymobiledevice3 把 .ipa 推进已连接的 iPhone
      selftest   跑离线自检（JWT + 上传全流程 mock）
.EXAMPLE
    .\ios.ps1 doctor
    .\ios.ps1 bump
    .\ios.ps1 cloud -Target github
    .\ios.ps1 upload -Ipa .\build\AppCore.ipa
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('doctor', 'bump', 'cloud', 'download', 'upload', 'status', 'ota', 'install', 'selftest', 'nomac')]
    [string]$Command,

    [string]$Ipa,
    [string]$Target = 'github',
    [string]$AppId = $env:ASC_APP_ID,
    [string]$BundleVersion,
    [string]$Addr = '127.0.0.1',
    [int]$Port = 8443,
    [switch]$SkipPoll
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
. (Join-Path $PSScriptRoot 'lib\Bootstrap.ps1')
$versionFile = Join-Path $root 'VERSION'

function Get-VersionState {
    $state = @{ MARKETING_VERSION = '1.0.0'; BUILD_NUMBER = '1' }
    if (Test-Path $versionFile) {
        Get-Content $versionFile | ForEach-Object {
            if ($_ -match '^\s*([A-Z_]+)\s*=\s*(.+?)\s*$') { $state[$Matches[1]] = $Matches[2] }
        }
    }
    return $state
}
function Save-VersionState($state) {
    $lines = $state.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Key)=$($_.Value)" }
    Set-Content -LiteralPath $versionFile -Value $lines -Encoding ASCII
}

function Get-IpaOrDefault {
    if ($Ipa) { return (Resolve-Path -LiteralPath $Ipa).Path }
    $latest = Get-ChildItem (Join-Path $root 'build') -Filter '*.ipa' -Recurse -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest) { throw 'No .ipa found under .\build. Build one first (ios.ps1 cloud) or pass -Ipa.' }
    return $latest.FullName
}

switch ($Command) {
    'doctor' { & (Join-Path $PSScriptRoot 'check-toolchain.ps1') -Fix }

    'bump' {
        $v = Get-VersionState
        $v.BUILD_NUMBER = [string]([int]$v.BUILD_NUMBER + 1)
        Save-VersionState $v
        Write-Host "build number -> $($v.BUILD_NUMBER)  (marketing $($v.MARKETING_VERSION))" -ForegroundColor Green
        $proj = Join-Path $root 'App\project.yml'
        if (Test-Path $proj) {
            $t = Get-Content $proj -Raw
            $t = [regex]::Replace($t, 'CFBundleShortVersionString:\s*"[^"]*"', "CFBundleShortVersionString: `"$($v.MARKETING_VERSION)`"")
            $t = [regex]::Replace($t, 'CFBundleVersion:\s*"[^"]*"', "CFBundleVersion: `"$($v.BUILD_NUMBER)`"")
            Set-Content -LiteralPath $proj -Value $t -Encoding UTF8
            Write-Host 'App\project.yml 已同步' -ForegroundColor Green
        }
    }

    'cloud' {
        $v = Get-VersionState
        switch ($Target) {
            'github' {
                if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'gh not on PATH.' }
                $branch = (& git rev-parse --abbrev-ref HEAD).Trim()
                & gh workflow run ios.yml -f build_number=$v.BUILD_NUMBER -f marketing_version=$v.MARKETING_VERSION --ref $branch
                Write-Host "已触发 ios.yml（branch=$branch build=$($v.BUILD_NUMBER)）" -ForegroundColor Green
                Write-Host '取产物：.\ios.ps1 download'
            }
            'eas' {
                if (-not (Get-Command eas -ErrorAction SilentlyContinue)) { throw 'eas-cli not installed: npm i -g eas-cli' }
                & eas build --platform ios --non-interactive --profile production
            }
            'codemagic' {
                Write-Host 'Codemagic 由 git push 自动触发；或用 codemagic-cli-tools：' -ForegroundColor Yellow
                Write-Host '  pip install codemagic-cli-tools && cmapp start-build --app <id> --workflow ios-release'
            }
            default { throw "Unknown -Target '$Target' (github|eas|codemagic)" }
        }
    }

    'download' {
        if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'gh not on PATH.' }
        $runId = (& gh run list --workflow ios.yml --status success --limit 1 --json databaseId --jq '.[0].databaseId')
        if (-not $runId) { throw 'No successful ios.yml run found.' }
        New-Item -ItemType Directory -Path (Join-Path $root 'build\artifact') -Force | Out-Null
        & gh run download $runId --dir (Join-Path $root 'build\artifact')
        Get-ChildItem (Join-Path $root 'build\artifact') -Recurse -Filter '*.ipa' |
            ForEach-Object { Copy-Item $_.FullName (Join-Path $root 'build') -Force; Write-Host "ipa -> build\$($_.Name)" -ForegroundColor Green }
    }

    'upload' {
        $v = Get-VersionState
        $bv = if ($BundleVersion) { $BundleVersion } else { $v.BUILD_NUMBER }
        & (Join-Path $PSScriptRoot 'asc-upload.ps1') -Ipa (Get-IpaOrDefault) -BundleVersion $bv -AppId $AppId -SkipPoll:$SkipPoll
    }

    'status' {
        & (Join-Path $PSScriptRoot 'asc-status.ps1') -AppId $AppId -BundleVersion $BundleVersion
    }

    'ota' {
        & (Join-Path $PSScriptRoot 'make-ota-manifest.ps1') -Ipa (Get-IpaOrDefault) -BaseUrl "https://${Addr}:$Port" -OutDir (Join-Path $root 'build\ota')
        Write-Host ''
        Write-Host "1) 自签证书（一次性）：openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 365 -subj `"/CN=$Addr`"" -ForegroundColor Yellow
        Write-Host "2) 起服务：python -c `"import http.server,ssl;s=http.server.HTTPServer(('0.0.0.0',$Port),http.server.SimpleHTTPRequestHandler);c=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);c.load_cert_chain('cert.pem','key.pem');s.socket=c.wrap_socket(s.socket,server_side=True);s.serve_forever()`" " -ForegroundColor Yellow
        Write-Host "3) iPhone 浏览器打开 https://${Addr}:$Port/install.html（自签证书需先信任）" -ForegroundColor Yellow
    }

    'install' {
        $ipa = Get-IpaOrDefault
        if (Get-Command pymobiledevice3 -ErrorAction SilentlyContinue) {
            & pymobiledevice3 apps install $ipa
        } elseif (Get-Command ideviceinstaller -ErrorAction SilentlyContinue) {
            & ideviceinstaller -i $ipa
        } else {
            throw 'No device CLI found. Install pymobiledevice3 (pip install pymobiledevice3) or libimobiledevice, plus Apple Devices driver.'
        }
    }

    'nomac' {
        $v = Get-VersionState
        $bid = 'com.tongriyaotxt.helloios'
        if ($env:BUNDLE_ID) { $bid = $env:BUNDLE_ID }
        $xa = @{
            BundleId = $bid
            Name     = 'HelloIOS'
            Version  = $v.MARKETING_VERSION
            Build    = $v.BUILD_NUMBER
            OutDir   = (Join-Path $root 'build\xc')
        }
        if ($env:P12_PATH) { $xa.P12 = $env:P12_PATH; $xa.Password = $env:P12_PASSWORD }
        if ($env:TEAM_ID) { $xa.TeamId = $env:TEAM_ID }
        $hasZig = $false
        if (Get-Command zig -ErrorAction SilentlyContinue) { $hasZig = $true }
        if (-not $hasZig) { try { $null = & python -c "import ziglang" 2>&1; $hasZig = ($LASTEXITCODE -eq 0) } catch { } }
        $uiSource = Join-Path $root 'samples\UIKitApp\AppCoreUI.m'
        if ($hasZig -and (Test-Path $uiSource)) {
            # 真编译：zig 出 UIKit dylib，machogen 出可执行体，双层签名
            $native = @{
                Source   = $uiSource
                Name     = 'AppCore'
                Version  = $v.MARKETING_VERSION
                Build    = $v.BUILD_NUMBER
                OutDir   = (Join-Path $root 'build\xc')
                BundleId = $bid
            }
            if ($env:P12_PATH) { $native.P12 = $env:P12_PATH; $native.Password = $env:P12_PASSWORD }
            if ($env:TEAM_ID) { $native.TeamId = $env:TEAM_ID }
            & (Join-Path $PSScriptRoot 'xc\Build-IosAppNative.ps1') @native
            $built = Join-Path $root 'build\xc\AppCore-native.ipa'
        } else {
            & (Join-Path $PSScriptRoot 'xc\Build-IosApp.ps1') @xa
            $built = Join-Path $root 'build\xc\HelloIOS.ipa'
        }
        if ($Upload) {
            & (Join-Path $PSScriptRoot 'asc-upload.ps1') -Ipa $built -BundleVersion $v.BUILD_NUMBER -AppId $AppId
        }
    }

    'selftest' {
        & (Join-Path $PSScriptRoot 'selftest-jwt.ps1')
        & (Join-Path $root 'tools\test-upload.ps1')
    }
}
