<#
.SYNOPSIS
    Bind a USB device and attach it to a WSL2 distribution (requires Administrator).

.DESCRIPTION
    usbipd-win forwards raw USB traffic to the WSL VM, so the device does NOT need a
    working Windows driver. This is what makes USB serial adapters and debug probes
    usable on Windows on ARM, where no x86/x64 kernel driver can be loaded.

    Run with -List to just enumerate devices.

.PARAMETER BusId
    Device BUSID from the list (e.g. 2-1). If omitted you are prompted.

.PARAMETER DistroName
    Target WSL distribution. Default: Ubuntu2204

.PARAMETER List
    Only list devices, then exit.

.EXAMPLE
    .\Attach-UsbDevice.ps1 -List

.EXAMPLE
    .\Attach-UsbDevice.ps1 -BusId 2-1
#>
[CmdletBinding()]
param(
    [string]$BusId,
    [string]$DistroName = "Ubuntu2204",
    [switch]$List
)

function Say($m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Ok($m)  { Write-Host "[+] $m" -ForegroundColor Green }
function Bad($m) { Write-Host "[!] $m" -ForegroundColor Red }

$usbipd = "C:\Program Files\usbipd-win\usbipd.exe"
if (-not (Test-Path $usbipd)) { $usbipd = (Get-Command usbipd.exe -ErrorAction SilentlyContinue).Source }
if (-not $usbipd) {
    Bad "usbipd not found. Install the ARM64 build from https://github.com/dorssel/usbipd-win/releases"
    exit 1
}

Say "Devices:"
& $usbipd list
if ($List) { exit 0 }

if (-not $BusId) { $BusId = (Read-Host "Enter BUSID to attach (e.g. 2-1)").Trim() }
if (-not $BusId) { Bad "No BUSID given"; exit 1 }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

Say "bind $BusId"
if ($isAdmin) {
    & $usbipd bind --busid $BusId
    if ($LASTEXITCODE -ne 0) { Write-Host "    (bind may already be in place - continuing)" -ForegroundColor Yellow }
} else {
    Bad "bind needs Administrator. Re-run this script from an elevated prompt."
    Write-Host "    usbipd bind --busid $BusId" -ForegroundColor Yellow
    exit 1
}

Say "Waking distribution '$DistroName'"
& wsl -d $DistroName -e bash -c "echo ok" | Out-Null

Say "attach $BusId -> $DistroName"
& $usbipd attach --wsl --busid $BusId --auto-attach
if ($LASTEXITCODE -ne 0) {
    Bad "attach failed. Is the distribution running?  wsl -d $DistroName -e true"
    exit 1
}
Ok "Attached"

Start-Sleep -Seconds 2
Say "What WSL sees:"
& wsl -d $DistroName -e bash -c "lsusb 2>/dev/null; echo '--- serial devices ---'; ls -l /dev/ttyUSB* /dev/ttyACM* 2>/dev/null || echo '    (none)'"

Write-Host ""
Write-Host "    NOTE: attach does not survive unplugging or a VM restart. Re-run this script."
Write-Host ""
exit 0
