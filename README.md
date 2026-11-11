# Keil MDK on Windows on ARM (ARM64)

**Using Keil MDK to build *and flash* STM32 firmware from a Windows-on-ARM laptop — and why the vendor drivers will never install.**

[中文说明](README.zh-CN.md)

---

## TL;DR

| Task | Works on Windows ARM64? | Why |
|---|---|---|
| Install & run Keil MDK (µVision) | ✅ | x86 user-mode app, runs under emulation |
| Edit / compile / link / produce `.hex` | ✅ | whole toolchain is user-mode |
| Flash via ST-Link / ULINK / J-Link | ❌ | needs a **kernel-mode** driver |
| Flash via on-board USB-serial (CH340/CP210x) | ❌ | same reason |
| Flash via STM32 built-in USB DFU | ❌ | still needs a kernel-mode WinUSB/ST DFU driver |
| **Flash via WSL2 + usbipd** | ✅ | driver lives in the **Linux** kernel |

The workaround: keep Keil doing what it can (compile), and move the device I/O into WSL2 through USB/IP. The Linux kernel is a native ARM64 build and already ships the serial drivers — Windows never needs to load one.

---

## 1. The problem

On a Windows-on-ARM machine (Snapdragon / Microsoft SQ series), Keil MDK installs and compiles normally. The moment you try to download firmware, it fails:

- µVision's *Load* button does nothing, or reports a missing/cancelled target DLL
- `Cannot Load Flash Programming Algorithm`
- CH340/CP210x adapters never appear as a COM port (an "Unknown device" with a yellow mark at best)
- ST-Link Utility reports no probe

This is not a Keil bug, and it is not fixable by reinstalling drivers "as administrator".

## 2. Why it can never work: user-mode vs kernel-mode

Windows on ARM does **not** emulate x86 at the hardware level. It emulates it in **user mode**:

- **x86 (32-bit)** apps — emulated since Windows 10 (CHPE)
- **x64** apps — emulated on Windows 11 (Prism)

Both work by translating *user-mode* code pages and thunking Win32/NT calls. There is **no x86/x64 instruction interpreter in the kernel**. Kernel-mode code must be a real, natively-compiled, signed ARM64 binary.

Every debugging probe and USB-serial adapter ships a **kernel-mode** `.sys`. Those binaries are x86 or x64. Windows will not load them on ARM64 — and there is nothing to emulate them with.

The same applies to `WinUSB`-based tools: even a "driverless" solution still needs the device to be **bound** to a driver, and building that binding requires an INF whose `.sys` matches the native architecture.

### 2.1 Verify it yourself

Read the PE `Machine` field of each binary:

```powershell
function Get-PEArch($path) {
    $b = [System.IO.File]::ReadAllBytes($path)
    $lfanew = [BitConverter]::ToInt32($b, 0x3C)
    switch ([BitConverter]::ToUInt16($b, $lfanew + 4)) {
        0x14c   { "x86 (i386)" }
        0x8664  { "x64 (AMD64)" }
        0xAA64  { "ARM64" }
        default { "other" }
    }
}
```

Measured on a Surface Pro X (Microsoft SQ2, Windows 11 26200, Keil 5.24 / MDK-ARM **Lite**):

| Binary | Kind | Machine | Loads? |
|---|---|---|---|
| `UV4.exe` | user-mode | x86 (i386) | ✅ runs under emulation |
| `armcc.exe`, `armclang.exe` | user-mode | x86 (i386) | ✅ |
| `CH341SER.SYS` (WCH vendor driver) | kernel-mode | x86 (i386) | ❌ |
| `CH341S64.SYS` (WCH vendor driver) | kernel-mode | x64 (AMD64) | ❌ |
| `libusbK.sys` (from ST's DFU driver pack) | kernel-mode | x64 (AMD64) | ❌ |

Cross-check the whole system:

```powershell
$nonArm = Get-ChildItem C:\Windows\System32\drivers -Filter *.sys |
    ForEach-Object { [pscustomobject]@{ Name=$_.Name; Arch=(Get-PEArch $_.FullName) } } |
    Where-Object { $_.Arch -notlike 'ARM64*' }
```

On the test machine: **349 of 352** drivers are ARM64. The 3 leftovers are stale x64 files from previous software; only one has a registered service, and it sits in `Stopped`. They cannot run.

### 2.2 The INF tells you the same story

The WCH CH340 installer's `CH341SER.INF` contains only:

```
[WinChipHead.NTamd64]
```

No `NTarm64` section. On ARM64 the driver package has no applicable install path — the installer will appear to succeed and change nothing.

The DFU driver pack commonly recommended for web-based STM32 flashing tools ships `amd64/` and `x86/` subdirectories only.

## 3. What about the alternatives?

| Approach | Verdict |
|---|---|
| Install the x86/x64 driver anyway | ❌ Windows refuses; kernel architecture must match |
| x86 VM (VirtualBox / VMware) | ❌ no x86 guest support on ARM64 hosts |
| QEMU full-system x86 | ⚠️ boots, but USB passthrough is impractical |
| WebUSB DFU flasher in Chrome/Edge | ⚠️ works **only if** the DFU device is already bound to WinUSB — which needs the missing driver |
| ST-Link / ULINK / J-Link | ❌ vendor tools are not supported on ARM laptops |
| **WSL2 + usbipd-win** | ✅ recommended |

The key insight: **usbipd-win operates at the USB bus level.** It binds a device and forwards raw USB traffic to the WSL VM. It does **not** require the device to have a working Windows driver, so the missing-driver problem disappears entirely.

## 4. Architecture

```
┌──────────────────────────── Windows 11 ARM64 ─────────────────────────────┐
│                                                                           │
│   ┌────────────────┐        ┌──────────────────────────────────────────┐  │
│   │  Keil µVision  │        │  ... but not the vendor driver (x86/x64) │  │
│   │  (x86, emulated)│       │  ✗ ST-Link / ULINK / CH340 INF            │  │
│   │  edit + compile │       └──────────────────────────────────────────┘  │
│   └───────┬────────┘                                                      │
│           │ produces Template.hex                                         │
│           ▼                                                               │
│   ┌────────────────┐    raw USB traffic    ┌───────────────────────────┐  │
│   │ usbipd-win     │ ───────────────────▶  │  WSL2 VM (ARM64 Linux)     │  │
│   │ (ARM64, USB/IP)│                       │   ch341.ko  (built-in)     │  │
│   │ bus-level bind │                       │   vhci-hcd.ko (built-in)   │  │
│   └───────┬────────┘                       │        ▼                   │  │
│           │                                │   /dev/ttyUSB0             │  │
│           │                                │   stm32flash / dfu-util    │  │
│           │                                │   picocom                  │  │
│           │                                └───────────────────────────┘  │
└───────────┼────────────────────────────────────────────────────────────────┘
            │
            ▼
       STM32 target (BOOT0=1 for ISP / DFU)
```

## 5. Setup

### 5.1 Prerequisites

- Windows 11 on ARM64 (x64 emulation needs 11; x86 emulation exists on 10)
- Virtualization enabled — check `Get-Service vmcompute` is `Running`
- Keil MDK installed and compiling

### 5.2 Install WSL2 without the distro list

`wsl --install -d Ubuntu` depends on `raw.githubusercontent.com`. In networks where that host is blocked you get:

```
Wsl/WININET_E_CONNECTION_RESET
```

Workaround — import a distro rootfs directly. An `ubuntu-base` ARM64 tarball is only ~26 MB:

```powershell
# Grab a local mirror. Note: ARM64 packages live in ubuntu-ports, not ubuntu.
$url = "https://mirrors.tuna.tsinghua.edu.cn/ubuntu-cdimage/ubuntu-base/releases/jammy/release/ubuntu-base-22.04.5-base-arm64.tar.gz"
Invoke-WebRequest $url -OutFile "$env:TEMP\rootfs.tar.gz"

wsl --import Ubuntu2204 C:\WSL\Ubuntu2204 "$env:TEMP\rootfs.tar.gz" --version 2
wsl --list --verbose          # expect VERSION = 2
```

> Avoid `aka.ms/wslubuntu2204` on slow international links — it can be throttled to a few tens of KB/s. The base rootfs is 26 MB instead of ~600 MB.

### 5.3 Fix apt inside a minimal rootfs

`ubuntu-base` ships without `ca-certificates`, so **https** mirrors fail with:

```
Certificate verification failed: The certificate is NOT trusted.
```

Bootstrap over **http** first, then upgrade:

```bash
# /etc/apt/sources.list  — note ubuntu-ports, required on ARM64
deb http://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports/ jammy main restricted universe multiverse
deb http://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports/ jammy-updates main restricted universe multiverse
deb http://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports/ jammy-security main restricted universe multiverse
```

```bash
apt-get update
apt-get install -y ca-certificates      # now https works
apt-get install -y stm32flash dfu-util picocom usbutils kmod
```

### 5.4 Confirm the kernel already has what you need

The WSL2 kernel is a native ARM64 build and includes USB serial and USB/IP support:

```bash
uname -r                     # e.g. 6.18.54.1-microsoft-standard-WSL2
find /lib/modules/$(uname -r) -name 'ch341*'
find /lib/modules/$(uname -r) -name 'vhci-hcd*'
modprobe ch341 && echo ch341 OK
modprobe vhci-hcd && echo vhci ok
lsmod | grep -E 'ch341|vhci'
```

Expected:

```
ch341.ko        kernel/drivers/usb/serial/ch341.ko
vhci-hcd.ko     kernel/drivers/usb/usbip/vhci-hcd.ko
ch341                  20480  0
usbserial              53248  1 ch341
vhci_hcd               45056  0
usbip_core             32768  1 vhci_hcd
```

**This is the whole point**: `ch341` is a *native ARM64* kernel module. The Windows side needs no driver at all.

### 5.5 Install usbipd-win (ARM64 build)

`usbipd-win` publishes an `arm64.msi`. Get it from the releases page:

```
https://github.com/dorssel/usbipd-win/releases
```

```powershell
msiexec /i usbipd-win_5.3.0_arm64.msi
Get-Service usbipd            # Status: Running
```

> Use the **arm64** asset. The x64 MSI will install but the service cannot load its driver.

### 5.6 Attach the device

Plug the target in, then **from an elevated PowerShell**:

```powershell
usbipd list
# BUSID  VID:PID    DEVICE
# 2-1    1a86:7523  USB-SERIAL CH340 (COM-less on ARM64)   Not shared

usbipd bind   --busid 2-1
usbipd attach --wsl --busid 2-1
```

Then inside WSL:

```bash
lsusb
# Bus 001 Device 002: ID 1a86:7523 QinHeng Electronics CH340 serial converter
ls /dev/ttyUSB0
```

`bind` is persistent, but **`attach` does not survive a re-plug or a WSL restart**. Add `--auto-attach` so usbipd re-attaches on its own:

```powershell
usbipd attach --wsl --busid 2-1 --auto-attach
```

Without that flag a restarted VM silently loses the device, and you get "it worked a minute ago, now `/dev/ttyUSB0` is gone" — re-run `attach` (or just use the flag once).

## 6. Daily workflow

```
edit  →  Keil F7 (build)  →  flash script  →  BOOT0=0, RESET  →  picocom
```

Because you have no in-circuit debugger, **serial logging is your only debugger.** Budget for a small `printf`.

Typical cycle with `UV4 -b` on a mid-size StdPeriph project on an SQ2: full rebuild ~30 s, incremental ~5–10 s, flash of a 7 KB image ~2–3 s.

```powershell
# build and capture the log; exit codes: 0 = clean, 1 = warnings, 2 = errors
& "C:\Keil_v5\UV4\UV4.exe" -b .\USER\Template.uvprojx -j0 -o build.log
```

```bash
# flash over UART ISP  (BOOT0 = 1, then reset)
stm32flash -w /mnt/c/path/to/Template.hex -v -g 0x08000000 /dev/ttyUSB0

# or over the MCU's own USB DFU (BOOT0 = 1)
dfu-util -a 0 -s 0x08000000:leave -D /mnt/c/path/to/Template.bin

# serial console
picocom /dev/ttyUSB0 -b 115200     # exit: Ctrl+A, Ctrl+X
```

### 6.1 Graphical assistant

`scripts/FlashAssistant.ps1` puts the same cycle in a window, for when you would rather click than type:

```powershell
.\scripts\FlashAssistant.ps1
```

| Control | Action |
|---|---|
| **Refresh** | re-read the usbipd state and the WSL tty |
| **Attach (admin)** | self-elevates, then `bind` + `attach --auto-attach` |
| **Browse…** (project) | pick any `.uvprojx`; the path is remembered in `%APPDATA%\keil-arm64-flash\settings.json` |
| **Build & Flash** | run `UV4 -b`, take the newest `.hex` from the output folder, flash it |
| **Flash only** | skip the build |
| **Serial monitor** | open `picocom` on the tty in its own console window |
| **Open output dir** | reveal the folder holding the `.hex` |

Two behaviours worth knowing:

- **Pre-flight BOOT0 check.** Before writing, it listens on the port for 2 seconds.
  If the target application is still running, BOOT0 is not set and `stm32flash` would
  fail with `Failed to init device` — so it stops and tells you which jumper to move
  instead of burning an attempt on a guaranteed failure.
- **Nothing is hard-coded.** It is not tied to any particular project; point it at your
  own `.uvprojx`.

Plain PowerShell 5.1 + WinForms — no compilation, no extra dependencies. `-SelfTest`
builds the form, prints diagnostics and exits, which is handy as a smoke check.

## 7. Troubleshooting catalogue

These are the failures actually hit while building this setup. Most of them produce misleading error text.

### 7.1 Keil: `A1067E` + `A1023E` on the startup file

```
startup_stm32f40_41xxx.s: Error: A1067E: Output file specified as '..\CORE\startup.s',
  but it has already been specified as '.\objects\startup.o'
startup_stm32f40_41xxx.s: error: A1023E: File "__UVISION_VERSION SETA 524" could not be opened
```

Nothing about this message points at the real cause. It is a **device pack mismatch**: the project names a device that the installed Device Family Pack does not contain, so µVision fails to resolve the device and emits a malformed assembler command line (`--pd` mangled into a positional input file).

Device names are **not stable across DFP versions**. For the same silicon you will find:

| DFP version | Device name in the pack |
|---|---|
| 1.0.8 | `STM32F407ZE` |
| 2.11.0 | `STM32F407ZETx` |
| 2.13.0 | `STM32F407ZE` |

Fix: open **Options for Target → Device**, re-select the part so the project records a device that actually exists in an installed pack, and make sure `PackID` in the `.uvprojx` matches an installed version. Verifying by hand:

```powershell
Select-String -Path "$env:LOCALAPPDATA\Arm\Packs\Keil\STM32F4xx_DFP\*\*.pdsc" -Pattern 'Dname="(STM32F407[A-Z0-9]*)"' -AllMatches |
  ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
```

### 7.2 Keil: `L6047U` — image too large

```
Fatal error: L6047U: The size of this image (40356 bytes) exceeds the maximum allowed
  for this version of the linker
```

That is **MDK-ARM Lite**, capped at 32 KB of code + RO data. Check what you actually have:

```
Program Size: Code=6712 RO-data=424 RW-data=44 ZI-data=1636
```

Code + RO + RW ≈ 7.2 KB here. Lite is fine for small projects; the cap only bites once you pull in fonts, filesystems or a GUI.

### 7.3 Keil: `Flash Download failed` after changing the part

Changing only the device name is not enough — the **flash algorithm and ROM size are stored separately** in the project:

```xml
<FlashDriverDll>UL2CM3(... -FF0STM32F4xx_1024 -FS08000000 -FL0100000
                        -FP0($$Device:STM32F407ZG$Flash\STM32F4xx_1024.FLM))</FlashDriverDll>
<Cpu>IROM(0x08000000,0x100000) ...</Cpu>
```

For a 512 KB part this must become `STM32F4xx_512` / `-FL080000` / `IROM(0x08000000,0x80000)`. Same for `<RegisterFile>` and `<SFDFile>`, and for the matching `<Name>` entries in the `.uvoptx`. A mismatch either fails to download or writes to addresses that do not exist.

### 7.4 USB-C: an A-to-C cable that charges but does nothing

An A-to-C cable presents a **5.1 kΩ pull-down (Rd) on CC** in its C plug. A USB-C host port enables VBUS only after sensing that resistor.

A power bank's **USB-A** port always outputs 5 V and never looks at CC. So:

> "it charges my phone from a power bank" ⇒ **only** VBUS/GND are proven. It says nothing about CC.

Symptom: the same cable works on a USB-A port (any desktop PC) but produces *nothing at all* on a USB-C port. Two useful tests:

- Plug the C end into a **USB-C charger** (which does check CC). Device powers ⇒ cable is fine, host is the problem.
- Use a **USB-C to USB-A female adapter** plus a plain A-to-A cable: the adapter creates a real USB-A host port that always supplies 5 V, removing CC from the equation entirely.

### 7.5 STM32 UART ISP: no auto-reset

Serial bootloaders are normally entered by toggling DTR/RTS. On many boards those pins are left floating at the USB-UART chip, so **no tool can reset the MCU into the bootloader**. In FlyMcu you must tick *"don't use RTS/DTR"* and enter the bootloader by hand:

1. `BOOT0 = 1`, press RESET
2. flash
3. `BOOT0 = 0`, press RESET again

### 7.6 PowerShell: scripts fail with "missing closing '}'"

Windows PowerShell 5.1 decodes a `.ps1` without a BOM as **ANSI/GBK**. Multi-byte characters then misalign, and a trailing lead byte can swallow the following ASCII quote — producing a bogus syntax error in a file that looks correct.

Save every non-ASCII `.ps1` as **UTF-8 with BOM** (or run PowerShell 7, which defaults to UTF-8). Verify:

```powershell
[System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$err)
```

### 7.7 The device never appears on the Windows side

Expected. With usbipd the device may show up as an unknown device, or not at all, in Device Manager. What matters is the **WSL** view:

```powershell
"C:\Program Files\usbipd-win\usbipd.exe" list
wsl -d Ubuntu2204 -e lsusb
```

If `usbipd list` shows the device but `lsusb` is empty, `attach` did not run (or the VM was restarted — re-attach).

### 7.8 Attached, visible in `lsusb`, but no `/dev/ttyUSB*`

Observed after a WSL kernel update (6.18.54.1 → 6.18.58.1). The device is forwarded correctly but the serial driver was never loaded, so nothing binds to it:

```
$ lsusb
Bus 001 Device 002: ID 1a86:7523 QinHeng Electronics CH340 serial converter

$ ls /dev/ttyUSB*
(no tty)
```

Confirm the driver really is absent before chasing anything else:

```bash
ls -l /sys/bus/usb/devices/1-1/driver
# -> .../usb/drivers/usb      (generic only; ch341 is NOT bound)
```

Fix — load it manually:

```bash
uname -r                 # must match a directory under /lib/modules
modprobe ch341
dmesg | tail -3
# ch341-uart converter now attached to ttyUSB0
```

Two traps here:

- `wsl -d <distro> -e modprobe ch341` fails with `execvpe(modprobe) failed` because `-e` does not use a login shell and `/sbin` is not on the PATH. Run it through a shell: `wsl -d <distro> -e bash -c "modprobe ch341"`.
- After a kernel bump, `/lib/modules` may contain both the old and the new tree. `modprobe` picks the one matching `uname -r`; if that directory is missing entirely, re-run the environment installer.

## 8. Validation status

Everything below was confirmed on real hardware.

| Step | Status |
|---|---|
| Keil 5.24 (x86) installs, compiles, links, emits `.hex` on ARM64 | ✅ verified |
| PE machine types of the vendor drivers (the root cause) | ✅ verified |
| WSL 3.0.3.0 + Ubuntu 22.04 ARM64 import without `wsl --install` | ✅ verified |
| `ch341.ko` / `vhci-hcd.ko` present and loadable | ✅ verified |
| `usbipd-win` arm64 build installs, service runs | ✅ verified |
| CH340 attached via usbipd, `ch341` bound, `/dev/ttyUSB0` created | ✅ verified |
| `stm32flash` writes + verifies over that tty | ✅ verified |
| Serial console read back through WSL | ✅ verified |

Actual run (STM32F407ZET6, 20 KB HEX, STM32 UART bootloader):

```
Interface serial_posix: 57600 8E1
Device ID    : 0x0413 (STM32F40xxx/41xxx)
Flash        : Up to 1024KiB (size first sector: 1x16384)
...
Wrote and verified address 0x08001c0c (100.00%) Done.
Starting execution at address 0x08000000... done.
```

```
$ stty -F /dev/ttyUSB0 115200 cs8 -cstopb -parenb raw -echo
$ timeout 8 cat /dev/ttyUSB0
uptime = 13 s
uptime = 14 s
```

Build in Keil, flash from WSL, read the console from WSL. No vendor driver was ever installed on Windows.

## 9. Scope and limitations

- **No in-circuit debugging.** Breakpoints/watchpoints require a probe driver; neither ST-Link nor ULINK works here. Debug with serial output.
- **A CMSIS-DAP probe may work.** CMSIS-DAP is HID/WinUSB-class; some probes enumerate on ARM64 without a vendor driver. Untested here, but it is the most promising route to real breakpoints.
- **Emulation is slower.** Expect compiles a little slower than on native x86.
- **This document does not grant any Keil/ARM/ST license.** Do not redistribute vendor installers or device packs; link to the official pages instead.

## 10. License

Text and scripts: **MIT** (see [LICENSE](LICENSE)).

No vendor binaries, installers or device packs are distributed here. See
[NOTICE](NOTICE) for where each third-party tool must be obtained from and the
trademark attributions.
