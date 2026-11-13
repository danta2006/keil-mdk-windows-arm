<#
    在 WSL 里打开开发板的串口终端（picocom，115200 8-N-1）
    支持 XMODEM 传文件：板上先敲  rx 文件名，再按 Ctrl+A Ctrl+S
#>
param([string]$Distro = "Ubuntu2204")

$sh = Join-Path $PSScriptRoot "console.sh"
Write-Host ""
Write-Host "[*] 定位 WSL 路径…" -ForegroundColor Cyan

$unix = ((& wsl -d $Distro -e wslpath -u "$sh" 2>$null) | Select-Object -First 1)
if (-not $unix) {
    Write-Host "[!] 无法访问 WSL 发行版 $Distro" -ForegroundColor Red
    Read-Host "按回车关闭"; exit 1
}

& wsl -d $Distro -e bash $unix.Trim()

Write-Host ""
Write-Host "[*] 串口已断开" -ForegroundColor Cyan
Read-Host "按回车关闭"
