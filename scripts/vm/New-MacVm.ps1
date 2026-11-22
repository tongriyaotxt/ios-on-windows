<#
.SYNOPSIS
    在 Windows 上创建并启动一台 macOS 虚拟机（QEMU + WHPX + OpenCore）—— 不碰任何 Mac 硬件。
.DESCRIPTION
    这是「编译这一环也不需要 Mac 设备」的路线：macOS 作为客户机跑在这台 PC 上，Xcode 装在客户机里，
    Windows 只负责托管虚拟机和后续的签名/上传/装机（那三步本仓库已经能在 Windows 原生完成）。

    脚本做四件事：
      1. 体检：VT-x/AMD-V、QEMU、OVMF、OpenCore 引导盘、目标磁盘
      2. 建盘：qemu-img 创建 macos.qcow2（预分配元数据，不写满）
      3. 组命令：把 QEMU 参数拼好（-DryRun 只打印，便于你先核对）
      4. 启动：-Launch 时才真正拉起虚拟机

    装完 macOS 之后要做的事在 docs\06-ZERO-MAC-VM.md，一条不用背：
      App 编译 → IPA → http 服务（hostfwd 8000）→ Windows 侧 Get-Artifact.ps1 拉回
      → asc-upload.ps1 直传 App Store Connect
.PARAMETER OpenCoreDisk
    OpenCore 引导盘（OSX-KVM 发布的 OpenCore.qcow2，或自己用 OpenCorePkg 生成）。GitHub 直连不通时，
    先在本机把文件准备好再传路径进来。
.PARAMETER OvmfDir
    含 edk2-x86_64-code.fd / edk2-i386-vars.fd 的目录。QEMU for Windows 一般自带在 <qemu>\share 下。
.EXAMPLE
    .\New-MacVm.ps1 -OpenCoreDisk F:\vm\OpenCore.qcow2 -DryRun
.EXAMPLE
    .\New-MacVm.ps1 -OpenCoreDisk F:\vm\OpenCore.qcow2 -Launch -RamMB 16384 -Cpu 8 -DiskGB 96
#>
[CmdletBinding()]
param(
    [string]$VmDir = 'F:\vm\macos',
    [Parameter(Mandatory)][string]$OpenCoreDisk,
    [string]$OvmfDir,
    [int]$DiskGB = 96,
    [int]$RamMB = 16384,
    [int]$Cpu = 8,
    [string]$CpuModel = 'host',
    [int]$SshPort = 2222,
    [int]$HttpPort = 8000,
    [switch]$PassthroughIphone,
    [switch]$DryRun,
    [switch]$Launch
)

$ErrorActionPreference = 'Stop'
$ok = $true
function Check([string]$Name, [bool]$Pass, [string]$Detail, [string]$FixHint) {
    $tag = if ($Pass) { 'OK     ' } else { 'MISSING' }
    $color = if ($Pass) { 'Green' } else { 'Red' }
    Write-Host ("  [{0}] {1,-18} {2}" -f $tag, $Name, $Detail) -ForegroundColor $color
    if (-not $Pass -and $FixHint) { Write-Host ("           -> {0}" -f $FixHint) -ForegroundColor Yellow }
    if (-not $Pass) { $script:ok = $false }
    # 不返回值，避免 True/False 漏到 stdout
}

Write-Host "`n[1/4] 环境体检" -ForegroundColor Cyan

$virt = (Get-CimInstance Win32_Processor | Select-Object -First 1)
$vtEnabled = $true
try { $vtEnabled = [bool]$virt.VirtualizationFirmwareEnabled } catch { }
$hyperv = (Get-CimInstance Win32_ComputerSystem).HypervisorPresent
Check 'CPU 虚拟化' ($vtEnabled -or $hyperv) "VirtualizationFirmwareEnabled=$vtEnabled HypervisorPresent=$hyperv" 'BIOS 里打开 VT-x/AMD-V（本机已开：HypervisorPresent=True）'

$qemu = Get-Command qemu-system-x86_64 -ErrorAction SilentlyContinue
Check 'QEMU' ([bool]$qemu) $(if ($qemu) { $qemu.Source } else { 'not found' }) 'winget install SoftwareFreedomConservancy.QEMU'

$qemuImg = Get-Command qemu-img -ErrorAction SilentlyContinue
Check 'qemu-img' ([bool]$qemuImg) $(if ($qemuImg) { $qemuImg.Source } else { 'not found' }) '随 QEMU 一起安装'

Check 'OpenCore 引导盘' (Test-Path -LiteralPath $OpenCoreDisk) $OpenCoreDisk '准备 OpenCore.qcow2（OSX-KVM 发布物）后传 -OpenCoreDisk'

if (-not $OvmfDir) {
    $cands = @('C:\Program Files\qemu\share', 'F:\vm\ovmf')
    if ($qemu) {
        $cands = @((Join-Path (Split-Path (Split-Path $qemu.Source -Parent) -Parent) 'share')) + $cands
    }
    $cands = $cands | Where-Object { $_ -and (Test-Path $_) }
    foreach ($c in $cands) {
        if (Test-Path (Join-Path $c 'edk2-x86_64-code.fd')) { $OvmfDir = $c; break }
    }
}
$ovmfCode = if ($OvmfDir) { Join-Path $OvmfDir 'edk2-x86_64-code.fd' } else { $null }
$ovmfVarsSrc = if ($OvmfDir) { Join-Path $OvmfDir 'edk2-i386-vars.fd' } else { $null }
Check 'OVMF (UEFI 固件)' ([bool]($ovmfCode -and ([bool]$ovmfCode -and (Test-Path -LiteralPath $ovmfCode)))) "$ovmfCode" 'QEMU 安装目录的 share\ 下应有 edk2-x86_64-code.fd'

if (-not $ok -and -not $DryRun) { throw '前提不满足，先补齐上面标红项（加 -DryRun 可只看计划）。' }

Write-Host "`n[2/4] 准备磁盘" -ForegroundColor Cyan
New-Item -ItemType Directory -Path $VmDir -Force | Out-Null
$macDisk = Join-Path $VmDir 'macos.qcow2'
$varsCopy = Join-Path $VmDir 'edk2-vars.fd'
$ocDisk = Join-Path $VmDir 'OpenCore.qcow2'

if (-not (Test-Path $macDisk)) {
    if ($DryRun -or -not $qemuImg) {
        Write-Host "  (dry) qemu-img create -f qcow2 -o preallocation=metadata `"$macDisk`" ${DiskGB}G"
    } else {
        & $qemuImg create -f qcow2 -o preallocation=metadata $macDisk "${DiskGB}G"
        Write-Host "  已创建 $macDisk (${DiskGB}G, 稀疏)" -ForegroundColor Green
    }
} else {
    Write-Host "  复用已有磁盘 $macDisk ($([Math]::Round((Get-Item $macDisk).Length / 1GB, 1)) GB 已分配)" -ForegroundColor Green
}
if ((Test-Path -LiteralPath $OpenCoreDisk) -and -not (Test-Path $ocDisk)) {
    Copy-Item -LiteralPath $OpenCoreDisk -Destination $ocDisk -Force
    Write-Host "  已复制 OpenCore 引导盘 -> $ocDisk" -ForegroundColor Green
}
if ($ovmfVarsSrc -and (Test-Path $ovmfVarsSrc) -and -not (Test-Path $varsCopy)) {
    Copy-Item -LiteralPath $ovmfVarsSrc -Destination $varsCopy -Force
    Write-Host "  已复制 UEFI 变量盘 -> $varsCopy" -ForegroundColor Green
}

Write-Host "`n[3/4] 组装 QEMU 命令" -ForegroundColor Cyan
$args = @(
    '-machine', 'q35,accel=whpx,kernel-irqchip=on',
    '-cpu', $CpuModel,
    '-smp', "$Cpu",
    '-m', "$RamMB",
    '-rtc', 'base=localtime,clock=host',
    '-drive', "if=pflash,format=raw,readonly=on,file=$ovmfCode",
    '-drive', "if=pflash,format=raw,file=$varsCopy",
    # OpenCore 必须在 SATA 2，macOS 安装盘在 SATA 3
    '-drive', "id=OpenCore,if=none,format=qcow2,file=$ocDisk",
    '-device', 'ide-hd,bus=sata.2,drive=OpenCore',
    '-drive', "id=MacHDD,if=none,format=qcow2,file=$macDisk",
    '-device', 'ide-hd,bus=sata.3,drive=MacHDD',
    # 用户态网络 + 端口转发：Windows 侧可以直接 http://127.0.0.1:8000 取 IPA、ssh -p 2222 进客户机
    '-netdev', "user,id=net0,hostfwd=tcp::$SshPort-:22,hostfwd=tcp::$HttpPort-:8000",
    '-device', 'virtio-net-pci,netdev=net0',
    '-device', 'qemu-xhci,id=xhci',
    '-device', 'usb-kbd',
    '-device', 'usb-tablet',
    '-vga', 'std',
    '-display', 'sdl',
    '-boot', 'order=c'
)
if ($PassthroughIphone) {
    # iPhone 直通给客户机（插上就能被 macOS 认到）；不稳定时优先走 OTA/TestFlight
    $args += @('-device', 'usb-host,vendorid=0x05ac,productid=0x12a8,bus=xhci.0')
}
$cmdLine = "& `"$($qemu.Source)`" " + (($args | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) -join ' ')
Write-Host $cmdLine -ForegroundColor DarkGray

Write-Host "`n[4/4] 启动" -ForegroundColor Cyan
if ($DryRun) {
    Write-Host '  (dry-run) 上面这条命令就是全部；去掉 -DryRun 并加 -Launch 才会真的启动。' -ForegroundColor Yellow
    Write-Host "`n首次启动后的步骤见 docs\06-ZERO-MAC-VM.md。要点："
    Write-Host '  1) 进 UEFI/OpenCore → 选 macOS Base System → 磁盘工具抹掉 macos.qcow2（APFS）→ 安装'
    Write-Host '  2) 装好后：系统设置 → 共享 → 打开「远程登录」（ssh 用）'
    Write-Host '  3) 装 Xcode Command Line Tools + Xcode（客户机内 App Store 或 .xip）'
    Write-Host '  4) 客户机内跑 bash scripts/vm/macos-build.sh，然后 Windows 侧 .\scripts\vm\Get-Artifact.ps1'
    exit 0
}
if (-not $Launch) {
    Write-Host '  未加 -Launch，只做准备。确认命令无误后重跑并加 -Launch。' -ForegroundColor Yellow
    exit 0
}
if (-not $qemu) { throw 'QEMU 不在 PATH。' }
& $qemu.Source @args
