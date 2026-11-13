<#
    install.ps1 — 把编译好的 WSL 内核装到 Windows 侧，并让 WSL 用它

    用法：
        powershell -ExecutionPolicy Bypass -File install.ps1
        powershell -ExecutionPolicy Bypass -File install.ps1 -ImagePath D:\wsl\Image
        powershell -ExecutionPolicy Bypass -File install.ps1 -NoWrite   # 只看会改成什么

    -ImagePath 不给时，会依次找：
        \\wsl.localhost\<发行版>\root\wsl-kernel-out\Image
        \\wsl.localhost\<发行版>\root\wsl-kernel-out\bzImage
        \\wsl.localhost\<发行版>\home\<用户>\wsl-kernel-out\Image
#>
param(
    [string]$Distro = "Ubuntu2204",
    [string]$Dest   = "$env:USERPROFILE\wsl-kernel",
    [string]$ImagePath = "",
    [switch]$NoWrite
)

$cfgPath = Join-Path $env:USERPROFILE ".wslconfig"

function Say($m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Ok($m)  { Write-Host "[+] $m" -ForegroundColor Green }
function Bad($m) { Write-Host "[!] $m" -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------- 1. 找镜像
$cands = @()
if ($ImagePath) { $cands += $ImagePath }
$cands += "\\wsl.localhost\$Distro\root\wsl-kernel-out\Image"
$cands += "\\wsl.localhost\$Distro\root\wsl-kernel-out\bzImage"
$homeRoot = "\\wsl.localhost\$Distro\home"
if (Test-Path $homeRoot) {
    Get-ChildItem $homeRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $cands += (Join-Path $_.FullName "wsl-kernel-out\Image")
        $cands += (Join-Path $_.FullName "wsl-kernel-out\bzImage")
    }
}

$src = $cands | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $src) {
    Bad "没找到编译产物。先在 WSL 里跑 build-kernel.sh，或用 -ImagePath 指定镜像路径。"
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
}

[System.IO.File]::WriteAllLines($cfgPath, $out, (New-Object System.Text.UTF8Encoding($false)))
Ok ("已写入 " + $cfgPath)

Write-Host ""
Ok "下一步："
Write-Host "    1) wsl --shutdown"
Write-Host "    2) 重新进 WSL，跑  bash install-modules.sh     <-- 别漏，否则 usbipd 会挂"
Write-Host "    3) bash verify.sh"
Write-Host "    回滚：删掉 .wslconfig 里 kernel= 那一行，再 wsl --shutdown" -ForegroundColor Gray
exit 0
