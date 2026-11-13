<#
    install.ps1 — 把编译好的 WSL 内核装到 Windows 侧，并让 WSL 用它

    做三件事：
      1. 从 WSL 里把 Image 复制到一个纯英文路径（默认 C:\Users\<你>\wsl-kernel\）
      2. 备份 %USERPROFILE%\.wslconfig
      3. 在 [wsl2] 段里写入 kernel= 指向这个 Image

    用法：
        powershell -ExecutionPolicy Bypass -File install.ps1
        powershell -ExecutionPolicy Bypass -File install.ps1 -NoWrite   # 只看会改成什么
#>
param(
    [string]$Distro   = "Ubuntu2204",
    [string]$Dest     = "$env:USERPROFILE\wsl-kernel",
    [switch]$NoWrite
)

$ErrorActionPreference = "Stop"
$cfgPath = Join-Path $env:USERPROFILE ".wslconfig"

function Say($m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Ok($m)  { Write-Host "[+] $m" -ForegroundColor Green }
function Bad($m) { Write-Host "[!] $m" -ForegroundColor Red }

# ---------------------------------------------------------------- 1. 取 Image
$srcCandidates = @(
    "\\wsl.localhost\$Distro\root\wsl-kernel-out\Image",
    "\\wsl.localhost\$Distro\root\wsl-kernel-out\bzImage"
)
$src = $srcCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $src) {
    Bad "WSL 里没找到编译产物（/root/wsl-kernel-out/Image）"
    Write-Host "    先在 WSL 里跑： bash build-kernel.sh" -ForegroundColor Yellow
    exit 1
}

New-Item -ItemType Directory -Force -Path $Dest | Out-Null
$destFile = Join-Path $Dest (Split-Path $src -Leaf)
Say ("复制 " + $src + "  ->  " + $destFile)
Copy-Item $src $destFile -Force
Ok ("Image 大小: " + [math]::Round((Get-Item $destFile).Length / 1MB, 1) + " MB")

# ---------------------------------------------------------------- 2. 备份配置
if (Test-Path $cfgPath) {
    $bak = "$cfgPath.bak-" + (Get-Date -Format "yyyyMMdd-HHmmss")
    Copy-Item $cfgPath $bak -Force
    Ok ("已备份原配置: " + $bak)
} else {
    New-Item -ItemType File -Path $cfgPath -Force | Out-Null
}

# ---------------------------------------------------------------- 3. 写 kernel=
$kernelLine = "kernel=" + ($destFile -replace '\\', '\\')
$lines = @(Get-Content $cfgPath -Encoding UTF8)

$inWsl2 = $false
$done   = $false
$out    = New-Object System.Collections.Generic.List[string]

foreach ($line in $lines) {
    $t = $line.Trim()
    if ($t -match '^\[(.+)\]$') {
        if ($done -and $inWsl2) { }          # 后面还有别的段，不再管
        $inWsl2 = ($Matches[1].Trim().ToLower() -eq 'wsl2')
        $out.Add($line)
        if ($inWsl2 -and -not $done) {
            $out.Add($kernelLine)
            $done = $true
        }
        continue
    }
    if ($inWsl2 -and $t -match '^kernel\s*=') { continue }   # 去掉旧的 kernel=
    $out.Add($line)
}
if (-not $done) {
    if ($out.Count -gt 0) { $out.Add("") }
    $out.Add("[wsl2]")
    $out.Add($kernelLine)
}

Say "新的 .wslconfig："
$out | ForEach-Object { Write-Host ("    " + $_) }

if ($NoWrite) {
    Write-Host ""
    Ok "（-NoWrite 模式，没有真正写入）"
    exit 0
}

[System.IO.File]::WriteAllLines($cfgPath, $out, (New-Object System.Text.UTF8Encoding($false)))
Ok ("已写入 " + $cfgPath)

Write-Host ""
Ok "下一步：在 PowerShell 里执行  wsl --shutdown ，然后重新打开 WSL"
Write-Host "    进去后跑  bash verify.sh  应该看到 CONFIG_USB_SERIAL_PL2303=y" -ForegroundColor Gray
Write-Host "    想还原：删掉 .wslconfig 里 kernel= 那一行，再 wsl --shutdown" -ForegroundColor Gray
