<#
.SYNOPSIS
    Open a serial monitor on a USB-serial adapter forwarded into WSL.

.DESCRIPTION
    On Windows on ARM the vendor COM-port driver cannot load, so the device never
    appears under Ports (COM/LPT) in Device Manager. After Attach-UsbDevice.ps1 the
    device is a /dev/ttyUSB* inside WSL, and picocom reads it there.

    picocom exit sequence: Ctrl+A then Ctrl+X

.PARAMETER Port
    Serial device inside WSL. Auto-detected when omitted.

.PARAMETER Baud
    Baud rate. Default 115200.

.PARAMETER DistroName
    WSL distribution. Default: Ubuntu2204

.EXAMPLE
    .\Watch-Serial.ps1

.EXAMPLE
    .\Watch-Serial.ps1 -Baud 9600
#>
[CmdletBinding()]
param(
    [string]$Port,
    [int]$Baud = 115200,
    [string]$DistroName = "Ubuntu2204"
)

function Say($m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Ok($m)  { Write-Host "[+] $m" -ForegroundColor Green }
function Bad($m) { Write-Host "[!] $m" -ForegroundColor Red }

Say "USB devices visible in WSL:"
$usb = ((& wsl -d $DistroName -e lsusb 2>$null) | Out-String).Trim()
if ($usb) { $usb -split "`r?`n" | ForEach-Object { Write-Host ("    " + $_) } }
else      { Write-Host "    (no USB devices attached)" }

if (-not $Port) {
    $detected = (& wsl -d $DistroName -e bash -c "ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null") 2>$null
    $ports = @($detected | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^/dev/tty' })
    if ($ports.Count -eq 0) {
        Bad "No serial device found in WSL."
        Write-Host "    Did you run Attach-UsbDevice.ps1 after plugging the board in?" -ForegroundColor Yellow
        exit 1
    }
    if ($ports.Count -eq 1) {
        $Port = $ports[0]
    } else {
        for ($i = 0; $i -lt $ports.Count; $i++) { Write-Host "    [$i] $($ports[$i])" }
        $sel = Read-Host "Select index (Enter = 0)"
        if ([string]::IsNullOrWhiteSpace($sel)) { $sel = 0 }
        $Port = $ports[[int]$sel]
    }
}

Ok "Opening $Port at $Baud 8N1"
Write-Host "    Exit picocom with Ctrl+A then Ctrl+X" -ForegroundColor Yellow
Write-Host ""

& wsl -d $DistroName -e picocom $Port -b $Baud

Write-Host ""
Ok "Serial monitor closed."
