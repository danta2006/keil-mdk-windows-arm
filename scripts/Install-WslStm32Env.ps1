<#
.SYNOPSIS
    Prepare a WSL2 environment able to program STM32 targets on Windows on ARM (ARM64).

.DESCRIPTION
    Imports an Ubuntu rootfs into WSL2 (bypassing `wsl --install`, which depends on
    raw.githubusercontent.com), fixes the apt sources for ARM64, installs the flashing
    tools, and verifies that the WSL kernel provides ch341 and vhci-hcd.

    Safe to re-run: an existing distribution is not re-imported, but **apt sources
    are rewritten and packages are installed again** unless you pass -SkipApt.

.PARAMETER DistroName
    Name of the WSL distribution to create. Default: Ubuntu2204

.PARAMETER InstallDir
    Where the WSL VHDX is stored. Default: C:\WSL\<DistroName>

.PARAMETER RootfsUrl
    URL of an ubuntu-base ARM64 tarball.

.PARAMETER MirrorBase
    apt mirror for ubuntu-ports. Must use http:// on a bare rootfs,
    because ca-certificates is not installed yet.

.PARAMETER Codename
    Ubuntu codename (jammy / noble / ...). If omitted it is derived from
    -RootfsUrl, so a 24.04 rootfs never ends up with jammy apt sources.

.PARAMETER SkipApt
    Do not touch /etc/apt/sources.list and do not install packages.

.EXAMPLE
    .\Install-WslStm32Env.ps1

.EXAMPLE
    .\Install-WslStm32Env.ps1 -DistroName Ubuntu2404 -InstallDir C:\WSL\Ubuntu2404 `
        -RootfsUrl "https://mirrors.tuna.tsinghua.edu.cn/ubuntu-cdimage/ubuntu-base/releases/noble/release/ubuntu-base-24.04.3-base-arm64.tar.gz"
#>
[CmdletBinding()]
param(
    [string]$DistroName = "Ubuntu2204",
    [string]$InstallDir = "",
    [string]$RootfsUrl  = "https://mirrors.tuna.tsinghua.edu.cn/ubuntu-cdimage/ubuntu-base/releases/jammy/release/ubuntu-base-22.04.5-base-arm64.tar.gz",
    [string]$MirrorBase = "http://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports",
    [string]$Codename   = "",
    [switch]$SkipApt
)

$ErrorActionPreference = "Continue"
function Say($m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Ok($m)  { Write-Host "[+] $m" -ForegroundColor Green }
function Bad($m) { Write-Host "[!] $m" -ForegroundColor Red }

# ---------------------------------------------------------------- defaults
if (-not $InstallDir) { $InstallDir = Join-Path "C:\WSL" $DistroName }

# Derive the codename from the rootfs URL unless the caller pinned it; otherwise a
# noble rootfs silently gets jammy apt sources and apt fails on every package.
if (-not $Codename) {
    foreach ($c in @("noble", "jammy", "focal", "oracular", "plucky")) {
        if ($RootfsUrl -match "/$c/") { $Codename = $c; break }
    }
}
if (-not $Codename) {
    Bad "Cannot tell the Ubuntu codename from -RootfsUrl. Pass -Codename explicitly."
    exit 1
}
Say "Distro=$DistroName  Codename=$Codename  Dir=$InstallDir"

# ---------------------------------------------------------------- architecture
# NOTE: $env:PROCESSOR_ARCHITECTURE reports the *process* architecture. Under an
# emulated x86 shell on ARM64 that reads "AMD64", which is misleading. SystemType
# reports the real OS architecture.
$sysType = ""
try { $sysType = (Get-CimInstance Win32_ComputerSystem).SystemType } catch { }
Say "Host: $sysType   (PROCESSOR_IDENTIFIER=$env:PROCESSOR_IDENTIFIER)"
if ($sysType -notlike "*ARM64*" -and $env:PROCESSOR_IDENTIFIER -notmatch "ARM") {
    Bad "This script targets Windows on ARM. On x86/x64 you do not need it - install the vendor driver instead."
    exit 1
}

# ---------------------------------------------------------------- virtualization
Say "Checking virtualization services"
foreach ($svc in @("vmcompute", "hns")) {
    $s = Get-Service $svc -ErrorAction SilentlyContinue
    if ($s) { Ok "$svc = $($s.Status)" } else { Bad "$svc not found - is Virtual Machine Platform enabled?" }
}

# ---------------------------------------------------------------- wsl present
Say "Checking WSL"
if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    Bad "wsl.exe not found. Enable 'Virtual Machine Platform' and install the WSL app first."
    exit 1
}
$wslVer = ((& wsl --version 2>$null) | Out-String) -replace "`0", ""
if ($wslVer -match "([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)") { Ok "WSL $($Matches[1])" } else { Ok "WSL present" }

# ---------------------------------------------------------------- distro exists?
Say "Looking for distribution '$DistroName'"
$existing = (& wsl --list --quiet) 2>$null | ForEach-Object { $_.Trim([char]0, ' ') } | Where-Object { $_ }
if ($existing -contains $DistroName) {
    Ok "'$DistroName' already exists - skipping import"
}
else {
    Say "Downloading rootfs: $RootfsUrl"
    $tar = Join-Path $env:TEMP "wsl-rootfs-arm64.tar.gz"
    if (-not (Test-Path $tar)) {
        $ProgressPreference = "SilentlyContinue"
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Invoke-WebRequest -Uri $RootfsUrl -OutFile $tar -UseBasicParsing -TimeoutSec 1800
        $sw.Stop()
        Ok ("Downloaded {0:N1} MB in {1:N0} s" -f ((Get-Item $tar).Length / 1MB), $sw.Elapsed.TotalSeconds)
    } else {
        Ok "Reusing existing $tar"
    }

    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    Say "Importing into $InstallDir"
    & wsl --import $DistroName $InstallDir $tar --version 2
    if ($LASTEXITCODE -ne 0) { Bad "Import failed (exit $LASTEXITCODE)"; exit 1 }
    Ok "Imported"
}

# ---------------------------------------------------------------- baseline
Say "Bringing the distribution up (first start can take ~20 s)"
& wsl -d $DistroName -e bash -c "echo ready" | Out-Null

# ---------------------------------------------------------------- apt sources
if ($SkipApt) {
    Say "-SkipApt: leaving /etc/apt/sources.list and the package set untouched"
} else {
Say "Configuring apt sources (must be http:// until ca-certificates is installed)"
$sources = @(
    "deb $MirrorBase/ $Codename main restricted universe multiverse"
    "deb $MirrorBase/ $Codename-updates main restricted universe multiverse"
    "deb $MirrorBase/ $Codename-backports main restricted universe multiverse"
    "deb $MirrorBase/ $Codename-security main restricted universe multiverse"
) -join "`n"

$tmpSrc = Join-Path $env:TEMP "sources.list"
[System.IO.File]::WriteAllText($tmpSrc, $sources + "`n", [System.Text.Encoding]::ASCII)

# translate C:\... into /mnt/c/...
$wslSrc = "/mnt/" + $tmpSrc.Substring(0,1).ToLower() + ($tmpSrc.Substring(2) -replace '\\','/')
& wsl -d $DistroName -e bash -c "cp /etc/apt/sources.list /etc/apt/sources.list.bak 2>/dev/null; cat '$wslSrc' > /etc/apt/sources.list"
Ok "sources.list written"

# ---------------------------------------------------------------- packages
Say "Installing tools (this takes a few minutes)"
# lrzsz 提供 sx/rx（XMODEM）；build-* 是重编 WSL 内核要用的
$pkgs = "ca-certificates stm32flash dfu-util picocom lrzsz usbutils kmod " +
        "build-essential git flex bison bc libssl-dev libelf-dev libncurses-dev dwarves cpio rsync"
& wsl -d $DistroName -e bash -c "export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq $pkgs 2>&1 | tail -5"
if ($LASTEXITCODE -ne 0) { Bad "Package installation failed"; exit 1 }
Ok "Tools installed"
}


# ---------------------------------------------------------------- kernel modules
Say "Verifying USB serial / USB-IP support in the WSL kernel"
$krnl = ((& wsl -d $DistroName -e uname -r) | Out-String).Trim()
Ok "kernel: $krnl"

foreach ($m in @("ch341", "vhci-hcd")) {
    $found = ((& wsl -d $DistroName -e find "/lib/modules/$krnl" -name "$m.ko" 2>$null) | Out-String).Trim()
    if ($found) { Ok ("found {0}: {1}" -f $m, ($found -split "`r?`n")[0]) }
    else        { Bad "$m.ko NOT FOUND - this WSL kernel build lacks it" }

    # modprobe lives in /sbin, which is not on the PATH used by `wsl -e`.
    & wsl -d $DistroName -e bash -c "modprobe $m" 2>$null 3>$null
    if ($LASTEXITCODE -eq 0) { Ok "modprobe $m OK" } else { Bad "modprobe $m failed (try: apt-get install -y kmod)" }
}

$loaded = ((& wsl -d $DistroName -e bash -c "lsmod | grep -E 'ch341|vhci|usbserial|usbip'" 2>$null) | Out-String).Trim()
if ($loaded) { $loaded -split "`r?`n" | ForEach-Object { Write-Host ("    " + $_) } }

# ---------------------------------------------------------------- summary
Write-Host ""
Ok "Done. Next steps:"
Write-Host "    1. Install usbipd-win (ARM64 build): https://github.com/dorssel/usbipd-win/releases"
Write-Host "    2. Plug the target in, then run as Administrator:"
Write-Host "         .\Attach-UsbDevice.ps1 -DistroName $DistroName"
Write-Host "    3. Build in Keil, then:"
Write-Host "         .\Flash-Stm32.ps1 -Hex ..\OBJ\firmware.hex -DistroName $DistroName"
Write-Host ""
