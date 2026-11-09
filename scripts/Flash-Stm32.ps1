<#
.SYNOPSIS
    Flash an STM32 over USB from WSL (UART bootloader via stm32flash, or DFU via dfu-util).

.DESCRIPTION
    Runs the flashing tool inside WSL, where the device is a native ARM64 kernel driver
    instead of an unloadable x86/x64 Windows driver.

    UART ISP mode  : requires BOOT0 = 1, then reset. Uses stm32flash on /dev/ttyUSB*.
    DFU mode       : requires BOOT0 = 1, then reset. Uses dfu-util on the MCU's USB port.

    After flashing: set BOOT0 = 0 and reset to run the new firmware.

.PARAMETER Hex
    Path to an Intel HEX file. Selects UART ISP mode.

.PARAMETER Bin
    Path to a raw binary. Selects DFU mode (default load address 0x08000000).

.PARAMETER Port
    Serial device inside WSL, e.g. /dev/ttyUSB0. Auto-detected when omitted.

.PARAMETER Baud
    UART baud for stm32flash. Default 115200.

.PARAMETER Address
    Load address for DFU / start address for ISP. Default 0x08000000.

.PARAMETER NoReset
    Do not start the firmware after flashing.

.PARAMETER DistroName
    WSL distribution. Default: Ubuntu2204

.EXAMPLE
    .\Flash-Stm32.ps1 -Hex .\OBJ\firmware.hex

.EXAMPLE
    .\Flash-Stm32.ps1 -Bin .\OBJ\firmware.bin -Address 0x08000000
#>
[CmdletBinding(DefaultParameterSetName = "Isp")]
param(
    [Parameter(ParameterSetName = "Isp", Mandatory = $true)]
    [string]$Hex,

    [Parameter(ParameterSetName = "Dfu", Mandatory = $true)]
    [string]$Bin,

    [string]$Port,
    [int]$Baud = 115200,
    [string]$Address = "0x08000000",
    [switch]$NoReset,
    [string]$DistroName = "Ubuntu2204"
)

function Say($m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Ok($m)  { Write-Host "[+] $m" -ForegroundColor Green }
function Bad($m) { Write-Host "[!] $m" -ForegroundColor Red }

# Windows path -> /mnt/c/... for WSL
function To-WslPath([string]$win) {
    $full = (Resolve-Path -LiteralPath $win -ErrorAction Stop).Path
    return "/mnt/" + $full.Substring(0,1).ToLower() + ($full.Substring(2) -replace '\\','/')
}

# ---------------------------------------------------------------- sanity
Say "Distribution: $DistroName"
& wsl -d $DistroName -e bash -c "echo ok" | Out-Null
if ($LASTEXITCODE -ne 0) { Bad "Cannot start WSL distribution '$DistroName'"; return }

Say "USB devices visible in WSL:"
$usb = ((& wsl -d $DistroName -e lsusb 2>$null) | Out-String).Trim()
if ($usb) { $usb -split "`r?`n" | ForEach-Object { Write-Host ("    " + $_) } }
else      { Write-Host "    (no USB devices attached)" }

# ---------------------------------------------------------------- UART ISP
if ($PSCmdlet.ParameterSetName -eq "Isp") {

    $src = To-WslPath $Hex
    Say "Firmware: $Hex"

    if (-not $Port) {
        Say "Auto-detecting serial port"
        $detected = (& wsl -d $DistroName -e bash -c "ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null | head -1") 2>$null
        $Port = ($detected | Out-String).Trim()
        if (-not $Port) {
            Bad "No /dev/ttyUSB* or /dev/ttyACM* in WSL."
            Write-Host "    - Did you run Attach-UsbDevice.ps1 after plugging the board in?" -ForegroundColor Yellow
            Write-Host "    - Is BOOT0 = 1 and did you press RESET?" -ForegroundColor Yellow
            return
        }
        Ok "Using $Port"
    }

    Say "stm32flash  (BOOT0 must be 1, board just reset)"
    $go = if ($NoReset) { @() } else { @("-g", $Address) }
    & wsl -d $DistroName -e stm32flash -w $src -v @go $Port
    $code = $LASTEXITCODE
}
# ---------------------------------------------------------------- DFU
else {

    $src = To-WslPath $Bin
    Say "Firmware: $Bin"

    $dfu = (& wsl -d $DistroName -e bash -c "lsusb 2>/dev/null | grep -iE '0483:df11|STM32.*BOOTLOADER' || true") 2>$null
    if (-not (($dfu | Out-String).Trim())) {
        Bad "No STM32 DFU device in WSL (looked for 0483:df11)."
        Write-Host "    - BOOT0 = 1, then reset, then connect the MCU's own USB port" -ForegroundColor Yellow
        Write-Host "    - Re-run Attach-UsbDevice.ps1 afterwards" -ForegroundColor Yellow
        return
    }
    Ok "DFU device present"

    $spec = if ($NoReset) { $Address } else { "$Address:leave" }
    Say "dfu-util -s $spec"
    & wsl -d $DistroName -e dfu-util -a 0 -s $spec -D $src
    $code = $LASTEXITCODE
}

# ---------------------------------------------------------------- result
Write-Host ""
if ($code -eq 0) {
    Ok "Flash succeeded."
    Write-Host "    Set BOOT0 = 0 and press RESET to run the new firmware." -ForegroundColor Cyan
    Write-Host "    Then:  .\Watch-Serial.ps1 -DistroName $DistroName" -ForegroundColor Cyan
} else {
    Bad "Flash failed (exit $code)."
    Write-Host "    Common causes:" -ForegroundColor Yellow
    Write-Host "      * BOOT0 not set to 1, or RESET not pressed"
    Write-Host "      * Port busy (close picocom / any serial monitor)"
    Write-Host "      * UART too fast - try -Baud 76800"
    Write-Host "      * Device not attached - re-run Attach-UsbDevice.ps1"
}
Write-Host ""
