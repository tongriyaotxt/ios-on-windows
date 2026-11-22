<#
.SYNOPSIS
    每个脚本开头的公共引导：.env 加载 + 已知路径进 PATH（只影响当前进程）。
.DESCRIPTION
    Windows 上最常见的两个「明明装了却找不到」：
      1) git / gh / flutter 装在固定位置但没进 PATH（本机实测：git 在 C:\Program Files\Git\cmd 却调不到）
      2) 凭证写在 .env 里，脚本却只认环境变量
    这里一次解决，且不修改系统环境（不写注册表、不动用户 PATH）。
.EXAMPLE
    . "$PSScriptRoot\lib\Bootstrap.ps1"
#>

$repoRoot = Split-Path -Parent $PSScriptRoot

# ---- 1. PATH 引导 ----------------------------------------------------------
foreach ($p in @(
        'C:\Program Files\Git\cmd',
        'C:\Program Files\Git\usr\bin',
        'C:\Program Files\GitHub CLI',
        'C:\Program Files\OpenSSL-Win64\bin',
        'F:\toolchains\flutter\bin'
    )) {
    if ((Test-Path -LiteralPath $p) -and ($env:PATH -notlike "*$p*")) { $env:PATH = "$p;$env:PATH" }
}

# ---- 2. .env 加载（不覆盖已存在的环境变量） --------------------------------
$envFile = Join-Path $repoRoot '.env'
if (Test-Path -LiteralPath $envFile) {
    Get-Content -LiteralPath $envFile | ForEach-Object {
        $line = $_.Trim()
        if (-not $line -or $line.StartsWith('#')) { return }
        $idx = $line.IndexOf('=')
        if ($idx -lt 1) { return }
        $k = $line.Substring(0, $idx).Trim()
        $v = $line.Substring($idx + 1).Trim().Trim('"').Trim("'")
        if (-not (Test-Path "env:$k") -or -not (Get-Item "env:$k").Value) {
            Set-Item -Path "env:$k" -Value $v
        }
    }
}

# ---- 3. 相对路径的 key 转绝对路径 ------------------------------------------
if ($env:ASC_KEY_PATH -and -not [IO.Path]::IsPathRooted($env:ASC_KEY_PATH)) {
    $candidate = Join-Path $repoRoot $env:ASC_KEY_PATH
    if (Test-Path -LiteralPath $candidate) { $env:ASC_KEY_PATH = (Resolve-Path -LiteralPath $candidate).Path }
}
if (-not $env:ASC_KEY_PATH -and $env:ASC_KEY_ID) {
    $guess = Join-Path $env:USERPROFILE ".appstoreconnect\private_keys\AuthKey_$($env:ASC_KEY_ID).p8"
    if (Test-Path -LiteralPath $guess) { $env:ASC_KEY_PATH = $guess }
}
