<#
    把 USB 转串口（CH340 / CP210x / FTDI / PL2303）透传到 WSL

    为什么必须这样：Windows on ARM 的内核加载不了 x86/x64 的 .sys 驱动，
    所以这类设备在设备管理器里永远是红叉、永远没有 COM 口。
    把设备原样交给 WSL2，用 Linux 内核自带的驱动即可。

    用法：双击或在管理员 PowerShell 里运行
#>
param(
    [string]$BusId,
    [string]$Distro = "Ubuntu2204",
    [switch]$List
)

$ErrorActionPreference = "Continue"
function Say($m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Ok($m)  { Write-Host "[+] $m" -ForegroundColor Green }
function Bad($m) { Write-Host "[!] $m" -ForegroundColor Red }

$USBD = "C:\Program Files\usbipd-win\usbipd.exe"
if (-not (Test-Path $USBD)) {
    Bad "没装 usbipd-win，先执行： winget install --exact dorssel.usbipd-win"
    exit 1
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Say "需要管理员权限，正在申请提权（UAC 请点『是』）"
    $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($BusId) { $argLine += " -BusId $BusId" }
    if ($List)  { $argLine += " -List" }
    Start-Process -FilePath "powershell.exe" -ArgumentList $argLine -Verb RunAs
    exit
}

Write-Host ""
Say "=== 当前 USB 设备 ==="
$raw = & $USBD list 2>&1
$raw | ForEach-Object { Write-Host ("    " + $_) }
if ($List) { Read-Host "按回车关闭"; exit }

if (-not $BusId) {
    $cands = @()
    foreach ($line in $raw) {
        if ($line -match '^\s*(\d+-\d+)\s+([0-9a-fA-F]{4}):([0-9a-fA-F]{4})\s+(.+?)\s*$') {
            $b = $Matches[1]; $vid = $Matches[2].ToLower(); $desc = $Matches[4]
            if ($vid -in @('1a86','10c4','0403','067b') -or $desc -match 'CH34|Serial|UART|CP210|FT232|PL230') {
                $cands += [pscustomobject]@{ BusId = $b; Desc = $desc }
            }
        }
    }
    if ($cands.Count -eq 0) {
        Bad "没找到 USB 转串口设备（板子插好了吗？用的是数据线吗？）"
        Read-Host "按回车关闭"; exit
    }
    if ($cands.Count -eq 1) {
        $BusId = $cands[0].BusId
        Ok ("自动识别: " + $BusId + "  " + $cands[0].Desc)
    } else {
        for ($i = 0; $i -lt $cands.Count; $i++) { Write-Host ("    [$i] " + $cands[$i].BusId + "  " + $cands[$i].Desc) }
        $sel = Read-Host "选择序号（回车=0）"
        if ([string]::IsNullOrWhiteSpace($sel)) { $sel = 0 }
        $BusId = $cands[[int]$sel].BusId
    }
}

Say "绑定并透传到 WSL"
(& $USBD bind --busid $BusId 2>&1) | ForEach-Object { Write-Host ("    " + $_) }
& wsl -d $Distro -e bash -c "echo ok" 2>&1 | Out-Null
(& $USBD attach --wsl --busid $BusId --auto-attach 2>&1) | ForEach-Object { Write-Host ("    " + $_) }

foreach ($m in @('ch341','cp210x','ftdi_sio','pl2303','usbserial')) {
    & wsl -d $Distro -e bash -c "modprobe $m 2>/dev/null" 2>$null | Out-Null
}

Write-Host ""
Say "=== WSL 里看到的串口 ==="
$tty = ""
for ($i = 1; $i -le 10; $i++) {
    $tty = ((& wsl -d $Distro -e bash -c "ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null") | Out-String).Trim()
    if ($tty) { break }
    Start-Sleep -Milliseconds 700
}
if ($tty) { $tty -split "`r?`n" | ForEach-Object { Ok ("串口设备: " + $_) } }
else { Bad "透传了但没出现 /dev/ttyUSB*（拔插一次再试；或看 WSL 里 lsusb）" }

Write-Host ""
Read-Host "按回车关闭"
