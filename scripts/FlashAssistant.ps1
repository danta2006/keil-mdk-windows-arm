<#
.SYNOPSIS
    Graphical front-end for building and flashing STM32 firmware on Windows on ARM.

.DESCRIPTION
    A small WinForms window that wraps the same approach used by the command-line
    scripts: Keil MDK compiles (x86 code runs under emulation), usbipd forwards the
    USB device into WSL2, and stm32flash / dfu-util do the actual writing from there.
    No vendor kernel driver is ever installed on Windows.

    The window shows the device state, lets you pick a Keil project, and runs the
    build + flash cycle with a live log. Before flashing it probes the serial port:
    if the target application is still running, BOOT0 is not set and the flash would
    fail with "Failed to init device", so it stops and tells you instead.

    Requires:
      * Keil MDK installed (default C:\Keil_v5, override with -Uv4)
      * usbipd-win ARM64 build, service running
      * a WSL2 distribution prepared with stm32flash (see Install-WslStm32Env.ps1)

.PARAMETER Project
    Path to a Keil .uvprojx. Remembered between runs when omitted.

.PARAMETER Hex
    Path to a .hex to flash. Remembered between runs when omitted.

.PARAMETER DistroName
    WSL distribution to use. Default: Ubuntu2204

.PARAMETER Uv4
    Path to UV4.exe. Default: C:\Keil_v5\UV4\UV4.exe

.PARAMETER AttachOnly
    Internal: bind + attach the device and exit. Used for self-elevation.

.PARAMETER BusId
    Device BUSID for -AttachOnly (e.g. 2-1). Auto-detected when omitted.

.PARAMETER SelfTest
    Build the form, print diagnostics, and exit without showing it.

.EXAMPLE
    .\FlashAssistant.ps1

.EXAMPLE
    .\FlashAssistant.ps1 -Project C:\work\firmware\USER\app.uvprojx
#>
[CmdletBinding()]
param(
    [string]$Project,
    [string]$Hex,
    [string]$DistroName = "Ubuntu2204",
    [string]$Uv4 = "C:\Keil_v5\UV4\UV4.exe",
    [switch]$AttachOnly,
    [string]$BusId,
    [switch]$SelfTest
)

$ErrorActionPreference = "Continue"

$USBD   = "C:\Program Files\usbipd-win\usbipd.exe"
# UV4 lives in <keil>\UV4\UV4.exe ; the compiler is in <keil>\ARM\ARMCC\bin
$KEIL_ROOT = Split-Path (Split-Path $Uv4 -Parent) -Parent
$FROMELF = Join-Path $KEIL_ROOT "ARM\ARMCC\bin\fromelf.exe"
$SETTINGS_DIR = Join-Path $env:APPDATA "keil-arm64-flash"
$SETTINGS_FILE = Join-Path $SETTINGS_DIR "settings.json"
$BUILD_LOG = Join-Path $env:TEMP "keil_arm64_build.log"

function Say($m, $c = "Gray") { Write-Host $m -ForegroundColor $c }

# ----------------------------------------------------------------- settings
function Load-Settings {
    if (Test-Path $SETTINGS_FILE) {
        try {
            $s = Get-Content $SETTINGS_FILE -Raw | ConvertFrom-Json
            # migrate / fill defaults
            if ($null -eq $s.Recent) { $s | Add-Member -NotePropertyName Recent -NotePropertyValue @() -Force }
            if ($null -eq $s.Follow) { $s | Add-Member -NotePropertyName Follow -NotePropertyValue $true -Force }
            return $s
        } catch {}
    }
    return [pscustomobject]@{ Project = ""; Hex = ""; Distro = "Ubuntu2204"; Recent = @(); Follow = $true }
}

function Save-Settings($s) {
    if (-not (Test-Path $SETTINGS_DIR)) { New-Item -ItemType Directory -Path $SETTINGS_DIR -Force | Out-Null }
    try { $s | ConvertTo-Json -Depth 4 | Set-Content $SETTINGS_FILE -Encoding UTF8 } catch {}
}

function To-WslPath([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return "" }
    $full = $p
    try { $full = (Resolve-Path -LiteralPath $p -ErrorAction Stop).Path } catch {}
    return "/mnt/" + $full.Substring(0,1).ToLower() + ($full.Substring(2) -replace '\\','/')
}

function Run-Cmd {
    param([string]$File, [string[]]$ArgList, [int]$TimeoutSec = 0, [scriptblock]$OnTick)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $File
    $psi.Arguments = ($ArgList | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    try { $p = [System.Diagnostics.Process]::Start($psi) } catch { return @{ Code = -1; Out = $_.Exception.Message } }

    # Start draining both pipes before waiting: reading them only after the child
    # exits deadlocks as soon as it fills the 4 KB pipe buffer (Keil logs do).
    $soTask = $p.StandardOutput.ReadToEndAsync()
    $seTask = $p.StandardError.ReadToEndAsync()

    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not $p.HasExited) {
        if ($OnTick) { & $OnTick } elseif ($null -ne $script:app) { [System.Windows.Forms.Application]::DoEvents() }
        Start-Sleep -Milliseconds 40
        if ($TimeoutSec -gt 0 -and $sw.Elapsed.TotalSeconds -gt $TimeoutSec) { try { $p.Kill() } catch {}; break }
    }
    $o = ""; $e = ""
    try { [void]$p.WaitForExit(5000) } catch {}
    try { $o = $soTask.Result } catch {}
    try { $e = $seTask.Result } catch {}
    $code = -1
    try { $code = $p.ExitCode } catch {}
    return @{ Code = $code; Out = ($o + $e) }
}

function Wsl-Cmd([string]$Command) {
    $r = Run-Cmd "wsl.exe" @("-d", $DistroName, "-e", "bash", "-c", $Command) 60
    return ([string]$r.Out).Trim()
}

function Get-UsbInfo {
    # Only USB-serial style adapters count. Matching "the first device in the list"
    # picks up the camera / touchpad / Bluetooth radio on many laptops - those have
    # lower BUSIDs and appear first - and then bind the wrong device into WSL.
    if (-not (Test-Path $USBD)) { return [pscustomobject]@{ Found = $false; State = "usbipd not installed"; BusId = ""; Id = ""; Candidates = @() } }
    $r = Run-Cmd $USBD @("list") 30
    $cands = @()
    foreach ($line in ([string]$r.Out -split "`r?`n")) {
        if ($line -notmatch '^\s*(\d+-\d+)\s+([0-9a-fA-F]{4}):([0-9a-fA-F]{4})\s+(.+?)\s*$') { continue }
        $busid = $Matches[1]
        $vid   = $Matches[2].ToLower()
        $pidn  = $Matches[3].ToLower()
        $desc  = $Matches[4].Trim()
        $state = "Unknown"
        if ($desc -match '(Not shared|Shared|Attached)') { $state = $Matches[1] }
        if ($vid -notin @('1a86','10c4','0403','067b') -and
            $desc -notmatch 'CH34|Serial|UART|CP210|FT232|PL230') { continue }
        $cands += [pscustomobject]@{
            BusId = $busid
            Id    = "$vid`:$pidn"
            Desc  = ($desc -replace '\s*(Not shared|Shared|Attached)\s*$', '').Trim()
            State = $state
        }
    }
    $script:UsbCandidates = $cands
    if ($cands.Count -eq 0) {
        return [pscustomobject]@{ Found = $false; State = "no USB serial device"; BusId = ""; Id = ""; Candidates = @() }
    }
    $pick = $cands[0]
    if ($cands.Count -gt 1) {
        # Prefer the adapter used last time instead of silently taking the first one.
        $saved = ""
        if ($null -ne $script:settings) { $saved = [string]$script:settings.LastBusId }
        $hit = $cands | Where-Object { $_.BusId -eq $saved } | Select-Object -First 1
        if ($hit) { $pick = $hit }
    }
    return [pscustomobject]@{ Found = $true; State = $pick.State; BusId = $pick.BusId; Id = $pick.Id; Candidates = $cands }
}

function Ensure-Tty([int]$Retries = 1) {
    for ($i = 1; $i -le $Retries; $i++) {
        Run-Cmd "wsl.exe" @("-d", $DistroName, "-e", "bash", "-c", "modprobe ch341") 20 | Out-Null
        $t = Wsl-Cmd "ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null | head -1"
        if ($t) { return $t }
        Start-Sleep -Milliseconds 600
    }
    return ""
}

function Test-AppRunning([string]$tty) {
    $r = Run-Cmd "wsl.exe" @("-d", $DistroName, "-e", "bash", "-c", "stty -F $tty 115200 raw -echo 2>/dev/null; timeout 2 cat $tty") 30
    return (([string]$r.Out).Trim().Length -gt 0)
}

# ----------------------------------------------------------------- attach-only mode
if ($AttachOnly) {
    Say "Attach helper (elevated)" Cyan
    if (-not $BusId) {
        $info = Get-UsbInfo
        if (-not $info.Found) { Say "No USB serial device found." Red; exit 1 }
        if ($info.Candidates.Count -gt 1) {
            $saved = ""
            if ($null -ne $script:settings) { $saved = [string]$script:settings.LastBusId }
            $hit = $null
            if ($saved) { $hit = $info.Candidates | Where-Object { $_.BusId -eq $saved } | Select-Object -First 1 }
            if ($hit) {
                Say ("Several candidates; using the last one used: {0}  {1}" -f $hit.BusId, $hit.Desc) Yellow
                $BusId = $hit.BusId
            } else {
                Say "Several USB-serial devices found - pass -BusId explicitly:" Red
                $info.Candidates | ForEach-Object { Say ("  {0}  {1}  {2}  [{3}]" -f $_.BusId, $_.Id, $_.Desc, $_.State) }
                exit 1
            }
        } else {
            $BusId = $info.BusId
        }
    }
    Say "BUSID: $BusId"
    Run-Cmd $USBD @("bind", "--busid", $BusId) 30 | Out-Null
    Run-Cmd "wsl.exe" @("-d", $DistroName, "-e", "bash", "-c", "echo ok") 30 | Out-Null
    $r = Run-Cmd $USBD @("attach", "--wsl", "--busid", $BusId, "--auto-attach") 40
    Say ([string]$r.Out)
    if ($r.Code -eq 0) {
        Say "Attached." Green
        if ($null -ne $script:settings) { $script:settings.LastBusId = $BusId; Save-Settings $script:settings }
    } else { Say "attach failed (exit $($r.Code))" Red }
    Start-Sleep -Milliseconds 800
    exit $r.Code
}

# ----------------------------------------------------------------- gui
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:app        = $null
$script:busy       = $false
$script:settings   = Load-Settings
if ($Project) { $script:settings.Project = $Project }
if ($Hex)     { $script:settings.Hex = $Hex }

$form = New-Object System.Windows.Forms.Form
$form.Text = "STM32 Flash Assistant  (Windows on ARM)"
$form.Size = New-Object System.Drawing.Size(820, 640)
$form.StartPosition = "CenterScreen"
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$form.MinimumSize = New-Object System.Drawing.Size(700, 520)

$lblState = New-Object System.Windows.Forms.Label
$lblState.Text = "Checking device..."
$lblState.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$lblState.AutoSize = $true
$lblState.Location = New-Object System.Drawing.Point(14, 12)

$lblDetail = New-Object System.Windows.Forms.Label
$lblDetail.Text = ""
$lblDetail.AutoSize = $true
$lblDetail.ForeColor = [System.Drawing.Color]::DimGray
$lblDetail.Location = New-Object System.Drawing.Point(14, 36)

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = "Refresh"
$btnRefresh.Size = New-Object System.Drawing.Size(90, 28)
$btnRefresh.Location = New-Object System.Drawing.Point(600, 12)
$btnRefresh.Anchor = "Top,Right"

$btnAttach = New-Object System.Windows.Forms.Button
$btnAttach.Text = "Attach (admin)"
$btnAttach.Size = New-Object System.Drawing.Size(110, 28)
$btnAttach.Location = New-Object System.Drawing.Point(696, 12)
$btnAttach.Anchor = "Top,Right"
$btnAttach.Enabled = $false

$gbProject = New-Object System.Windows.Forms.GroupBox
$gbProject.Text = "Keil project"
$gbProject.Location = New-Object System.Drawing.Point(12, 62)
$gbProject.Size = New-Object System.Drawing.Size(790, 62)
$gbProject.Anchor = "Top,Left,Right"

$txtProject = New-Object System.Windows.Forms.TextBox
$txtProject.Location = New-Object System.Drawing.Point(12, 24)
$txtProject.Size = New-Object System.Drawing.Size(660, 24)
$txtProject.Text = $script:settings.Project

$btnBrowseProj = New-Object System.Windows.Forms.Button
$btnBrowseProj.Text = "Browse..."
$btnBrowseProj.Location = New-Object System.Drawing.Point(680, 23)
$btnBrowseProj.Size = New-Object System.Drawing.Size(96, 26)

$gbProject.Controls.AddRange(@($txtProject, $btnBrowseProj))

$gbHex = New-Object System.Windows.Forms.GroupBox
$gbHex.Text = "Firmware (.hex)"
$gbHex.Location = New-Object System.Drawing.Point(12, 130)
$gbHex.Size = New-Object System.Drawing.Size(790, 62)
$gbHex.Anchor = "Top,Left,Right"

$cmbHex = New-Object System.Windows.Forms.ComboBox
$cmbHex.Location = New-Object System.Drawing.Point(12, 24)
$cmbHex.Size = New-Object System.Drawing.Size(520, 24)
$cmbHex.DropDownStyle = "DropDown"          # editable, and a pick list
$cmbHex.AutoCompleteMode = "SuggestAppend"
$cmbHex.AutoCompleteSource = "ListItems"
$cmbHex.Text = $script:settings.Hex

$btnBrowseHex = New-Object System.Windows.Forms.Button
$btnBrowseHex.Text = "Browse..."
$btnBrowseHex.Location = New-Object System.Drawing.Point(540, 23)
$btnBrowseHex.Size = New-Object System.Drawing.Size(84, 26)

$btnRescanHex = New-Object System.Windows.Forms.Button
$btnRescanHex.Text = "Rescan"
$btnRescanHex.Location = New-Object System.Drawing.Point(630, 23)
$btnRescanHex.Size = New-Object System.Drawing.Size(84, 26)

$chkFollow = New-Object System.Windows.Forms.CheckBox
$chkFollow.Text = "Follow build"
$chkFollow.Checked = $true
$chkFollow.Location = New-Object System.Drawing.Point(724, 26)
$chkFollow.Size = New-Object System.Drawing.Size(100, 22)

$gbHex.Controls.AddRange(@($cmbHex, $btnBrowseHex, $btnRescanHex, $chkFollow))

$btnBuildFlash = New-Object System.Windows.Forms.Button
$btnBuildFlash.Text = "Build && Flash"
$btnBuildFlash.Location = New-Object System.Drawing.Point(12, 202)
$btnBuildFlash.Size = New-Object System.Drawing.Size(150, 38)
$btnBuildFlash.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
$btnBuildFlash.ForeColor = [System.Drawing.Color]::White
$btnBuildFlash.FlatStyle = "Flat"

$btnFlashOnly = New-Object System.Windows.Forms.Button
$btnFlashOnly.Text = "Flash only"
$btnFlashOnly.Location = New-Object System.Drawing.Point(172, 202)
$btnFlashOnly.Size = New-Object System.Drawing.Size(110, 38)

$btnSerial = New-Object System.Windows.Forms.Button
$btnSerial.Text = "Serial monitor"
$btnSerial.Location = New-Object System.Drawing.Point(292, 202)
$btnSerial.Size = New-Object System.Drawing.Size(120, 38)

$btnOpenDir = New-Object System.Windows.Forms.Button
$btnOpenDir.Text = "Open output dir"
$btnOpenDir.Location = New-Object System.Drawing.Point(422, 202)
$btnOpenDir.Size = New-Object System.Drawing.Size(120, 38)

$lblHint = New-Object System.Windows.Forms.Label
$lblHint.Text = "BOOT0 = 1 + press RESET before flashing    |    BOOT0 = 0 + RESET after"
$lblHint.ForeColor = [System.Drawing.Color]::FromArgb(150, 90, 20)
$lblHint.AutoSize = $true
$lblHint.Location = New-Object System.Drawing.Point(556, 214)
$lblHint.Anchor = "Top,Right"

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.ReadOnly = $true
$txtLog.Location = New-Object System.Drawing.Point(12, 250)
$txtLog.Size = New-Object System.Drawing.Size(780, 336)
$txtLog.Anchor = "Top,Bottom,Left,Right"
$txtLog.Font = New-Object System.Drawing.Font("Consolas", 9)
$txtLog.BackColor = [System.Drawing.Color]::FromArgb(28, 28, 32)
$txtLog.ForeColor = [System.Drawing.Color]::FromArgb(215, 215, 220)

$form.Controls.AddRange(@($lblState, $lblDetail, $btnRefresh, $btnAttach,
                          $gbProject, $gbHex, $btnBuildFlash, $btnFlashOnly,
                          $btnSerial, $btnOpenDir, $lblHint, $txtLog))

# ----------------------------------------------------------------- firmware list
$script:suppress = $false

function Set-HexValue([string]$v, [switch]$UserPicked) {
    $script:suppress = $true
    $cmbHex.Text = $v
    $script:suppress = $false
    if ($UserPicked) {
        # an explicit pick means "do not overwrite this on build"
        $chkFollow.Checked = $false
        Add-RecentHex $v
        Save-CurrentSettings
    }
}

function Add-RecentHex([string]$v) {
    if (-not $v) { return }
    $list = @($script:settings.Recent)
    if ($list -notcontains $v) { $list = @($v) + $list }
    $script:settings.Recent = @($list | Select-Object -First 12)
}

function Save-CurrentSettings {
    $script:settings.Hex    = $cmbHex.Text.Trim()
    $script:settings.Follow = [bool]$chkFollow.Checked
    Save-Settings $script:settings
}

# output folder(s) for the currently selected project
function Get-OutputDirs {
    $dirs = @()
    $p = $txtProject.Text.Trim()
    if ($p) {
        $base = Split-Path $p -Parent
        $dirs += (Join-Path $base "..\OBJ")
        $dirs += (Join-Path $base "OBJ")
        $dirs += (Join-Path $base "Objects")
    }
    return $dirs | Where-Object { Test-Path $_ } | ForEach-Object { (Resolve-Path $_).Path } | Select-Object -Unique
}

function Refresh-HexList {
    $cur = $cmbHex.Text.Trim()
    $items = New-Object System.Collections.ArrayList

    # 1) every .hex in the project output folder, newest first
    foreach ($d in (Get-OutputDirs)) {
        Get-ChildItem $d -Filter *.hex -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            ForEach-Object { if ($items -notcontains $_.FullName) { [void]$items.Add($_.FullName) } }
    }
    # 2) recently used
    foreach ($r in @($script:settings.Recent)) {
        if ($r -and $items -notcontains $r) { [void]$items.Add($r) }
    }

    $script:suppress = $true
    $cmbHex.Items.Clear()
    foreach ($i in $items) { [void]$cmbHex.Items.Add($i) }
    if ($cur) { $cmbHex.Text = $cur }
    elseif ($items.Count -gt 0) { $cmbHex.Text = $items[0] }
    $script:suppress = $false
}

function Log([string]$t, [string]$lvl = "info") {
    $p = switch ($lvl) { "ok" { "[+]" } "err" { "[!]" } "warn" { "[*]" } default { "   " } }
    $txtLog.AppendText(((Get-Date).ToString("HH:mm:ss")) + " $p $t`r`n")
    $txtLog.SelectionStart = $txtLog.TextLength
    $txtLog.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

function Set-State([string]$text, $color, [string]$detail) {
    $lblState.Text = $text
    $lblState.ForeColor = $color
    $lblDetail.Text = $detail
}

function Update-Status([int]$retries = 1) {
    $info = Get-UsbInfo
    $tty = ""
    if ($info.Found -and $info.State -eq "Attached") { $tty = Ensure-Tty $retries }

    if ($tty) {
        Set-State "Device ready: $tty" ([System.Drawing.Color]::FromArgb(0,140,60)) `
                  "$($info.Id)  BUSID=$($info.BusId)  attached   -   ready to flash"
        $btnAttach.Enabled = $false
        $btnBuildFlash.Enabled = $true
        $btnFlashOnly.Enabled = $true
        $btnSerial.Enabled = $true
        return
    }
    if (-not $info.Found) {
        Set-State "No USB serial device" ([System.Drawing.Color]::FromArgb(190,40,40)) `
                  "check: board powered, using its UART/USB port, and the cable carries data"
        $btnAttach.Enabled = $false
        $btnBuildFlash.Enabled = $false
        $btnFlashOnly.Enabled = $false
        $btnSerial.Enabled = $false
        return
    }
    Set-State "Device found, not attached to WSL   [$($info.State)]" ([System.Drawing.Color]::FromArgb(200,130,0)) `
              "click Attach (admin) and confirm the UAC prompt"
    $btnAttach.Enabled = $true
    $btnBuildFlash.Enabled = $false
    $btnFlashOnly.Enabled = $false
    $btnSerial.Enabled = $false
}

function Do-Build {
    $proj = $txtProject.Text.Trim()
    if (-not $proj) { Log "Pick a .uvprojx first." "err"; return $false }
    if (-not (Test-Path $proj)) { Log "Project not found: $proj" "err"; return $false }
    if (-not (Test-Path $Uv4)) { Log "UV4.exe not found: $Uv4  (use -Uv4)" "err"; return $false }

    Log "Building $([System.IO.Path]::GetFileName($proj)) ..."
    if (Test-Path $BUILD_LOG) { Remove-Item $BUILD_LOG -Force -ErrorAction SilentlyContinue }
    $r = Run-Cmd $Uv4 @("-b", $proj, "-j0", "-o", $BUILD_LOG) 0

    if (Test-Path $BUILD_LOG) {
        foreach ($line in (Get-Content $BUILD_LOG)) {
            if ($line -match "Program Size|error|Error\(s\)|warning\(s\)") { Log ("  " + $line.Trim()) }
        }
    }
    if ($r.Code -ge 2) { Log "Build failed (exit $($r.Code))" "err"; return $false }

    $projDir = Split-Path $proj -Parent
    $cand = @()
    # Keil writes to OBJ\ by default, but "Objects" is used by some templates.
    foreach ($d in @((Join-Path $projDir "..\OBJ"), (Join-Path $projDir "OBJ"),
                     (Join-Path $projDir "..\Objects"), (Join-Path $projDir "Objects"))) {
        if (Test-Path $d) { $cand += (Get-ChildItem $d -Filter *.hex -ErrorAction SilentlyContinue) }
    }
    $hexFound = $cand | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($hexFound) {
        Log ("Build OK, HEX: " + $hexFound.FullName + "  (" + [math]::Round($hexFound.Length/1KB,1) + " KB)") "ok"
        Add-RecentHex $hexFound.FullName
        Refresh-HexList

        if ($chkFollow.Checked) {
            Set-HexValue $hexFound.FullName
            Log "  using this build output" "ok"
        } elseif ($cmbHex.Text.Trim() -ne $hexFound.FullName) {
            Log ("  build output is " + $hexFound.FullName) "warn"
            Log ("  keeping your selection: " + (Split-Path $cmbHex.Text.Trim() -Leaf) +
                 "   (tick 'Follow build' to use the new output)") "warn"
        } else {
            Set-HexValue $hexFound.FullName
        }
        return $true
    }
    Log "Build finished but no .hex found - is 'Create HEX File' enabled in Options for Target?" "err"
    return $false
}

function Do-Flash {
    $hexFile = $cmbHex.Text.Trim()
    if (-not $hexFile) { Log "Pick a .hex firmware first." "err"; return }
    if (-not (Test-Path $hexFile)) { Log "Firmware not found: $hexFile" "err"; return }
    if ([System.IO.Path]::GetExtension($hexFile) -ne ".hex") {
        Log ("stm32flash only accepts Intel HEX; this is " + [System.IO.Path]::GetExtension($hexFile)) "err"
        Log "  re-export as .hex in Keil (Options for Target -> Output -> Create HEX File)" "warn"
        return
    }
    Save-CurrentSettings

    $tty = Ensure-Tty 6
    if (-not $tty) {
        Log "No /dev/ttyUSB* inside WSL." "err"
        Log "  run Attach (admin) first, or check the board is plugged in" "warn"
        Update-Status
        return
    }

    Log "Checking whether the target is still running..."
    if (Test-AppRunning $tty) {
        Log "The application is still running - BOOT0 is still 0, flashing will fail." "err"
        Log "  1) set BOOT0 = 1" "warn"
        Log "  2) press RESET on the board" "warn"
        Log "  3) click Flash only again" "warn"
        Log "  (the bootloader is silent; no serial output means you got it)" "warn"
        return
    }
    Log "Serial silent - target looks like it is in the bootloader" "ok"

    Log "Flashing $([System.IO.Path]::GetFileName($hexFile)) to $tty ..."
    $r = Run-Cmd "wsl.exe" @("-d", $DistroName, "-e", "stm32flash",
                             "-w", (To-WslPath $hexFile), "-v", "-g", "0x08000000", $tty) 400
    foreach ($line in ([string]$r.Out -split "`r?`n")) {
        if ($line -match "Device ID|Flash\s+:|Wrote|Done|Starting|Failed|Error") { Log ("  " + $line.Trim()) }
    }
    if ($r.Code -eq 0) {
        Log "Flash complete. Set BOOT0 = 0 and press RESET." "ok"
    } else {
        Log "Flash failed (exit $($r.Code))" "err"
        Log "  BOOT0 not set / RESET not pressed / port busy / try a lower baud" "warn"
    }
}

# ----------------------------------------------------------------- events
$btnRefresh.Add_Click({ if (-not $script:busy) { Log "Refreshing..."; Update-Status 3 } })

$btnAttach.Add_Click({
    $script:busy = $true
    try {
        Log "Requesting elevation - confirm the UAC prompt..."
        Start-Process -FilePath "powershell.exe" `
            -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-File",$PSCommandPath,
                            "-AttachOnly","-DistroName",$DistroName) -Verb RunAs
        Log "Elevated helper launched. Waiting..." "warn"
        for ($i = 0; $i -lt 12; $i++) {
            Start-Sleep -Milliseconds 1000
            [System.Windows.Forms.Application]::DoEvents()
            Update-Status 1
            if ($lblState.Text -like "Device ready*") { Log "Attached." "ok"; return }
        }
        Log "Still not attached - click Refresh in a moment." "warn"
    } catch {
        Log "Elevation cancelled: $($_.Exception.Message)" "err"
    } finally { $script:busy = $false }
})

$btnBrowseProj.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = "Keil project (*.uvprojx)|*.uvprojx|All files (*.*)|*.*"
    if ($dlg.ShowDialog() -eq "OK") {
        $txtProject.Text = $dlg.FileName
        $script:settings.Project = $dlg.FileName
        Save-Settings $script:settings
        Refresh-HexList          # the output folder changed
    }
})

$btnBrowseHex.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = "Firmware (*.hex)|*.hex|All files (*.*)|*.*"
    $dirs = @(Get-OutputDirs)
    if ($dirs.Count -gt 0) { $dlg.InitialDirectory = $dirs[0] }
    elseif ($Hex) { $dlg.InitialDirectory = (Split-Path $Hex -Parent) }
    if ($dlg.ShowDialog() -eq "OK") {
        Set-HexValue $dlg.FileName -UserPicked
        Refresh-HexList
        Set-HexValue $dlg.FileName
        Log ("Selected firmware: " + (Split-Path $dlg.FileName -Leaf)) "ok"
    }
})

$btnRescanHex.Add_Click({
    Refresh-HexList
    Log ("Firmware list refreshed: " + $cmbHex.Items.Count + " .hex file(s) - use the drop-down to switch") "ok"
})

$chkFollow.Add_CheckedChanged({
    if ($script:suppress) { return }
    if ($chkFollow.Checked) { Log "'Follow build' ON - after a build the new output is selected" "ok" }
    else { Log "'Follow build' OFF - a build will not change your selection" "warn" }
    Save-CurrentSettings
})

$cmbHex.Add_SelectionChangeCommitted({
    if ($script:suppress) { return }
    $chkFollow.Checked = $false
    Add-RecentHex $cmbHex.Text.Trim()
    Save-CurrentSettings
    Log ("Switched firmware to: " + (Split-Path $cmbHex.Text.Trim() -Leaf)) "ok"
})

$btnOpenDir.Add_Click({
    $h = $cmbHex.Text.Trim()
    if ($h) { $d = Split-Path $h -Parent; if (Test-Path $d) { Start-Process explorer.exe $d; return } }
    $p = $txtProject.Text.Trim()
    if ($p) { $d = Split-Path $p -Parent; if (Test-Path $d) { Start-Process explorer.exe $d } }
})

$btnSerial.Add_Click({
    $tty = Ensure-Tty 3
    if (-not $tty) { Log "No serial device in WSL." "err"; return }
    Log "Opening serial monitor on $tty ..."
    Start-Process -FilePath "wsl.exe" -ArgumentList @("-d", $DistroName, "-e", "picocom", $tty, "-b", "115200")
})

$btnBuildFlash.Add_Click({
    if ($script:busy) { return }
    $script:busy = $true
    try { if (Do-Build) { Do-Flash } } finally { $script:busy = $false }
})

$btnFlashOnly.Add_Click({
    if ($script:busy) { return }
    $script:busy = $true
    try { Do-Flash } finally { $script:busy = $false }
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 7000
$timer.Add_Tick({
    # Only poll while there is something to poll for: this used to spawn a wsl +
    # modprobe round trip every 7 s even when the device was already attached.
    if (-not $script:busy -and $lblState.Text -notlike "Device ready*") { Update-Status 1 }
})

$form.Add_Shown({
    $script:app = $form
    # restore previous selection
    $chkFollow.Checked = if ($null -ne $script:settings.Follow) { [bool]$script:settings.Follow } else { $true }
    Refresh-HexList
    if ($script:settings.Hex) { Set-HexValue $script:settings.Hex }

    Log "STM32 Flash Assistant"
    Log "  Keil  : $Uv4"
    Log "  WSL   : $DistroName"
    Log "  usbipd: $USBD"
    Log ("  firmware: " + $cmbHex.Text + "   (" + $cmbHex.Items.Count + " available, use the drop-down to switch)")
    Log ""
    Update-Status 3
    $timer.Start()
})

$form.Add_FormClosing({
    $timer.Stop()
    Save-CurrentSettings
})

# ----------------------------------------------------------------- self test
if ($SelfTest) {
    $chkFollow.Checked = if ($null -ne $script:settings.Follow) { [bool]$script:settings.Follow } else { $true }
    Refresh-HexList
    Write-Host "SelfTest: form constructed OK"
    Write-Host ("  Size            : " + $form.Size)
    Write-Host ("  Controls        : " + $form.Controls.Count)
    Write-Host ("  Distro          : " + $DistroName)
    Write-Host ("  UV4 exists      : " + (Test-Path $Uv4))
    Write-Host ("  usbipd exists   : " + (Test-Path $USBD))
    Write-Host ("  FromELF exists  : " + (Test-Path $FROMELF))
    Write-Host ("  Settings file   : " + $SETTINGS_FILE)
    Write-Host ("  USB state       : " + (Get-UsbInfo).State)
    Write-Host ("  Project setting : " + $script:settings.Project)
    Write-Host ("  Hex setting     : " + $script:settings.Hex)
    Write-Host ("  Hex items       : " + $cmbHex.Items.Count)
    Write-Host ("  Hex selected    : " + $cmbHex.Text)
    Write-Host ("  Follow build    : " + $chkFollow.Checked)
    $form.Dispose()
    exit 0
}

[void]$form.ShowDialog()
$form.Dispose()
