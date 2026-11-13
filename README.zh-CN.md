# 在 Windows on ARM（ARM64）上使用 Keil MDK

**用 Windows on ARM 笔记本*编译*并且*烧录* STM32 —— 以及为什么厂商驱动永远装不上。**

[English](README.md)

---

## 一句话总结

| 任务 | Windows ARM64 上能做吗 | 原因 |
|---|---|---|
| 安装并运行 Keil MDK（µVision） | ✅ | x86 用户态程序，靠模拟运行 |
| 编辑 / 编译 / 链接 / 生成 `.hex` | ✅ | 整条工具链都是用户态 |
| 用 ST-Link / ULINK / J-Link 烧录 | ❌ | 需要**内核态**驱动 |
| 用板载 USB 转串口（CH340/CP210x）烧录 | ❌ | 同上 |
| 用 STM32 内置 USB DFU 烧录 | ❌ | 仍需内核态 WinUSB / ST DFU 驱动 |
| **用 WSL2 + usbipd 烧录** | ✅ | 驱动活在 **Linux** 内核里 |

思路：让 Keil 只干它能干的（编译），把设备 I/O 交给 WSL2，通过 USB/IP 透传。Linux 内核是原生 ARM64 构建，串口驱动本来就带——Windows 侧一个驱动都不用装。

---

## 1. 问题现象

在 Windows on ARM 机器（骁龙 / 微软 SQ 系列）上，Keil MDK 能正常安装、正常编译。一旦要点下载固件：

- µVision 的 *Load* 按钮没反应，或提示 target DLL 缺失/已取消
- `Cannot Load Flash Programming Algorithm`
- CH340/CP210x 永远不出现 COM 口（顶多是个带黄色感叹号的未知设备）
- ST-Link Utility 报找不到探针

这不是 Keil 的 bug，也不是"用管理员身份重装驱动"能解决的。

## 2. 为什么注定不行：用户态 vs 内核态

Windows on ARM **不是**在硬件层模拟 x86，而是在**用户态**模拟：

- **x86（32 位）**程序 —— Windows 10 起支持（CHPE）
- **x64** 程序 —— Windows 11 起支持（Prism）

两者都是翻译*用户态*代码页、转发 Win32/NT 调用。**内核里根本没有 x86/x64 指令解释器**。内核态代码必须是真正的、原生编译的、已签名的 ARM64 二进制。

所有调试探针和 USB 转串口芯片提供的都是**内核态** `.sys`，而这些二进制是 x86 或 x64。Windows 在 ARM64 上不会加载它们——也**没有东西能模拟它们**。

同样地，基于 `WinUSB` 的"免驱"方案也没用：即便号称免驱，设备仍需被**绑定**到某个驱动，而构造这个绑定需要一个 `.sys` 与原生架构匹配的 INF。

### 2.1 自己动手验证

读取每个二进制的 PE `Machine` 字段：

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

在 Surface Pro X（Microsoft SQ2，Windows 11 build 26200，Keil 5.24 / MDK-ARM **Lite**）上的实测：

| 二进制 | 类型 | 架构 | 能否加载 |
|---|---|---|---|
| `UV4.exe` | 用户态 | x86 (i386) | ✅ 靠模拟正常运行 |
| `armcc.exe`、`armclang.exe` | 用户态 | x86 (i386) | ✅ |
| `CH341SER.SYS`（WCH 官方驱动） | 内核态 | x86 (i386) | ❌ |
| `CH341S64.SYS`（WCH 官方驱动） | 内核态 | x64 (AMD64) | ❌ |
| `libusbK.sys`（ST DFU 驱动包里的） | 内核态 | x64 (AMD64) | ❌ |

再全盘交叉验证一次：

```powershell
$nonArm = Get-ChildItem C:\Windows\System32\drivers -Filter *.sys |
    ForEach-Object { [pscustomobject]@{ Name=$_.Name; Arch=(Get-PEArch $_.FullName) } } |
    Where-Object { $_.Arch -notlike 'ARM64*' }
```

测试机上 **352 个驱动里 349 个是 ARM64**。剩下 3 个是历史软件残留的 x64 文件，其中只有一个还注册了服务，且状态是 `Stopped`——它们根本跑不起来。

### 2.2 INF 也说了同一件事

WCH CH340 安装包的 `CH341SER.INF` 里只有：

```
[WinChipHead.NTamd64]
```

**没有 `NTarm64` 段。** 在 ARM64 上这个驱动包没有任何适用的安装路径——安装程序会"看起来成功"，然后什么都没改变。

网上常见的那套 STM32 DFU 驱动包，目录里也只提供 `amd64/` 和 `x86/`。

## 3. 其他方案为什么也不行

| 方案 | 结论 |
|---|---|
| 硬装 x86/x64 驱动 | ❌ Windows 直接拒绝，内核架构必须匹配 |
| x86 虚拟机（VirtualBox / VMware） | ❌ ARM64 宿主不支持 x86 guest |
| QEMU 全系统模拟 x86 | ⚠️ 能开机，但 USB 透传基本不可用 |
| Chrome/Edge 的 WebUSB DFU 刷写工具 | ⚠️ **前提**是 DFU 设备已绑定 WinUSB——而这正是缺失的那个驱动 |
| ST-Link / ULINK / J-Link | ❌ 厂商工具不支持 ARM 笔记本 |
| **WSL2 + usbipd-win** | ✅ 推荐 |

关键在于：**usbipd-win 工作在 USB 总线层面**。它把设备绑定，然后把原始 USB 流量转发给 WSL 虚拟机。它**不要求**该设备在 Windows 侧有可用驱动——于是"缺驱动"这个死结自然就解开了。

## 4. 架构

```
┌──────────────────────────── Windows 11 ARM64 ─────────────────────────────┐
│                                                                           │
│   ┌────────────────┐        ┌──────────────────────────────────────────┐  │
│   │  Keil µVision  │        │  但厂商驱动装不上（x86/x64 内核态）        │  │
│   │  (x86，模拟运行) │        │  ✗ ST-Link / ULINK / CH340 INF            │  │
│   │  编辑 + 编译     │       └──────────────────────────────────────────┘  │
│   └───────┬────────┘                                                      │
│           │ 产出 Template.hex                                             │
│           ▼                                                               │
│   ┌────────────────┐    原始 USB 流量      ┌───────────────────────────┐  │
│   │ usbipd-win     │ ───────────────────▶  │  WSL2 虚拟机（ARM64 Linux）│  │
│   │ (ARM64, USB/IP)│                       │   ch341.ko   （内核自带）  │  │
│   │ 总线层绑定      │                       │   vhci-hcd.ko（内核自带）  │  │
│   └───────┬────────┘                       │        ▼                   │  │
│           │                                │   /dev/ttyUSB0             │  │
│           │                                │   stm32flash / dfu-util    │  │
│           │                                │   picocom                  │  │
│           │                                └───────────────────────────┘  │
└───────────┼────────────────────────────────────────────────────────────────┘
            │
            ▼
       STM32 目标板（ISP / DFU 都需要 BOOT0=1）
```

## 5. 安装步骤

### 5.1 前置条件

- Windows 11 ARM64（x64 模拟需要 11；x86 模拟 Win10 就有）
- 已开启虚拟化 —— 检查 `Get-Service vmcompute` 为 `Running`
- 已装好 Keil MDK 且能编译

### 5.2 绕过发行版列表安装 WSL2

`wsl --install -d Ubuntu` 依赖 `raw.githubusercontent.com`。该域名被阻断时会直接失败：

```
Wsl/WININET_E_CONNECTION_RESET
```

变通办法：直接导入发行版 rootfs。`ubuntu-base` 的 ARM64 包只有约 26 MB：

```powershell
# 用国内镜像。注意：ARM64 的包在 ubuntu-ports 里，不是 ubuntu。
$url = "https://mirrors.tuna.tsinghua.edu.cn/ubuntu-cdimage/ubuntu-base/releases/jammy/release/ubuntu-base-22.04.5-base-arm64.tar.gz"
Invoke-WebRequest $url -OutFile "$env:TEMP\rootfs.tar.gz"

wsl --import Ubuntu2204 C:\WSL\Ubuntu2204 "$env:TEMP\rootfs.tar.gz" --version 2
wsl --list --verbose          # VERSION 应为 2
```

> 国际链路慢的时候别用 `aka.ms/wslubuntu2204`——它可能被限速到几十 KB/s。base rootfs 只有 26 MB，而那个约 600 MB。

### 5.3 修复精简 rootfs 里的 apt

`ubuntu-base` 不带 `ca-certificates`，所以 **https** 源会报：

```
Certificate verification failed: The certificate is NOT trusted.
```

先用 **http** 引导，再补证书：

```bash
# /etc/apt/sources.list —— 注意是 ubuntu-ports，ARM64 必须用这个
deb http://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports/ jammy main restricted universe multiverse
deb http://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports/ jammy-updates main restricted universe multiverse
deb http://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports/ jammy-security main restricted universe multiverse
```

```bash
apt-get update
apt-get install -y ca-certificates      # 之后 https 就正常了
apt-get install -y stm32flash dfu-util picocom usbutils kmod
```

### 5.4 确认内核已经自带所需模块

WSL2 内核是原生 ARM64 构建，包含 USB 串口和 USB/IP 支持：

```bash
uname -r                     # 例如 6.18.54.1-microsoft-standard-WSL2
find /lib/modules/$(uname -r) -name 'ch341*'
find /lib/modules/$(uname -r) -name 'vhci-hcd*'
modprobe ch341 && echo ch341 OK
modprobe vhci-hcd && echo vhci ok
lsmod | grep -E 'ch341|vhci'
```

预期输出：

```
ch341.ko        kernel/drivers/usb/serial/ch341.ko
vhci-hcd.ko     kernel/drivers/usb/usbip/vhci-hcd.ko
ch341                  20480  0
usbserial              53248  1 ch341
vhci_hcd               45056  0
usbip_core             32768  1 vhci_hcd
```

**这就是整套方案的核心**：`ch341` 是*原生 ARM64* 内核模块，Windows 侧完全不需要驱动。

### 5.5 安装 usbipd-win（必须 ARM64 版）

`usbipd-win` 提供 `arm64.msi`，从 releases 页下载：

```
https://github.com/dorssel/usbipd-win/releases
```

```powershell
msiexec /i usbipd-win_5.3.0_arm64.msi
Get-Service usbipd            # Status: Running
```

> 一定要用 **arm64** 那个资产。x64 的 MSI 能装上，但服务加载不了驱动。

### 5.6 绑定并透传设备

插上目标板，然后**用管理员 PowerShell**：

```powershell
usbipd list
# BUSID  VID:PID    DEVICE
# 2-1    1a86:7523  USB-SERIAL CH340（ARM64 上不会出现 COM 口）

usbipd bind   --busid 2-1
usbipd attach --wsl --busid 2-1
```

然后在 WSL 里确认：

```bash
lsusb
# Bus 001 Device 002: ID 1a86:7523 QinHeng Electronics CH340 serial converter
ls /dev/ttyUSB0
```

`bind` 是持久的，但 **`attach` 不会跨拔插或 WSL 重启存活**。加上 `--auto-attach` 让 usbipd 自动重挂：

```powershell
usbipd attach --wsl --busid 2-1 --auto-attach
```

不加这个参数的话，VM 一重启设备就悄悄丢了，症状是"刚才还好好的，现在 `/dev/ttyUSB0` 不见了"——重新 `attach` 一次即可（或者干脆一开始就带上这个参数）。

## 6. 日常流程

```
改代码 → Keil 按 F7 编译 → 跑烧录脚本 → BOOT0=0 按 RESET → picocom 看输出
```

因为没有在线调试器，**串口打印就是你唯一的调试手段**，记得先准备好一个小 `printf`。

在 SQ2 上一个中等规模 StdPeriph 工程的实测：全量编译约 30 秒，增量 5~10 秒，烧写 7 KB 固件约 2~3 秒。

```powershell
# 编译并抓日志；返回码 0=无错无警告 1=有警告 2=有错误
& "C:\Keil_v5\UV4\UV4.exe" -b .\USER\Template.uvprojx -j0 -o build.log
```

```bash
# 串口 ISP 烧录（BOOT0=1 后复位）
stm32flash -w /mnt/c/path/to/Template.hex -v -g 0x08000000 /dev/ttyUSB0

# 或走 MCU 自己的 USB DFU（BOOT0=1）
dfu-util -a 0 -s 0x08000000:leave -D /mnt/c/path/to/Template.bin

# 串口终端
picocom /dev/ttyUSB0 -b 115200     # 退出：Ctrl+A 然后 Ctrl+X
```

### 6.1 图形界面

`scripts/FlashAssistant.ps1` 把同一套流程包进一个窗口，适合不想敲命令的时候：

```powershell
.\scripts\FlashAssistant.ps1
```

| 控件 | 作用 |
|---|---|
| **Refresh** | 重新读取 usbipd 状态和 WSL 里的 tty |
| **Attach (admin)** | 自己申请提权，然后 `bind` + `attach --auto-attach` |
| **Browse…**（工程） | 选任意 `.uvprojx`；路径记在 `%APPDATA%\keil-arm64-flash\settings.json` |
| **固件下拉框** | 列出工程输出目录里所有 `.hex`，外加最近用过的 12 个；字段可编辑，任意路径都能粘进去 |
| **Browse…**（固件） | 从任意位置选 `.hex` / `.bin` |
| **Rescan** | 在外部编译之后重新扫描输出目录 |
| **Follow build** | 勾上：编译后自动选用本次产物。不勾：编译不动你的选择 |
| **Build & Flash** | 跑 `UV4 -b` 再烧录（用哪个固件取决于 *Follow build*） |
| **Flash only** | 不重新编译 |
| **Serial monitor** | 另开一个控制台窗口跑 `picocom` |
| **Open output dir** | 打开放着 `.hex` 的目录 |

手动选过固件之后，**Follow build 会自动取消勾选**，这样后续编译不会悄悄把文件换掉——日志里会写明保留了哪个文件、新产物在哪。选择结果和勾选状态都会跨次启动保留。

两个值得一提的行为：

- **烧录前的 BOOT0 体检。** 写入之前先监听串口 2 秒。如果目标程序还在跑，说明
  BOOT0 没拨，`stm32flash` 必然报 `Failed to init device`——它会先停下来告诉你该挪哪个
  跳线帽，而不是白跑一次注定失败的烧录。
- **没有任何硬编码。** 它不绑死某个工程，指向你自己的 `.uvprojx` 就行。

纯 PowerShell 5.1 + WinForms，不用编译、没有额外依赖。带 `-SelfTest` 参数时会构建界面、
打印诊断信息后退出，可以拿来做冒烟检查。

## 7. 踩坑目录

下面这些都是搭建过程中真实撞到的，而且大多数报错信息都具有误导性。

### 7.1 Keil：启动文件报 `A1067E` + `A1023E`

```
startup_stm32f40_41xxx.s: Error: A1067E: Output file specified as '..\CORE\startup.s',
  but it has already been specified as '.\objects\startup.o'
startup_stm32f40_41xxx.s: error: A1023E: File "__UVISION_VERSION SETA 524" could not be opened
```

这两句话里没有任何线索指向真实原因。真正的问题是**器件包版本不匹配**：工程里写的器件名在已安装的 DFP 中不存在，µVision 解析器件失败，于是生成了一条畸形的汇编命令行（`--pd` 被错当成位置参数）。

器件名在**不同 DFP 版本之间是不稳定的**，同一颗芯片可能叫：

| DFP 版本 | 包里的器件名 |
|---|---|
| 1.0.8 | `STM32F407ZE` |
| 2.11.0 | `STM32F407ZETx` |
| 2.13.0 | `STM32F407ZE` |

修法：打开 **Options for Target → Device**，重新选一次器件，让工程记录一个在已装包里真实存在的名字；同时确认 `.uvprojx` 里的 `PackID` 对应已安装版本。手工核对：

```powershell
Select-String -Path "$env:LOCALAPPDATA\Arm\Packs\Keil\STM32F4xx_DFP\*\*.pdsc" -Pattern 'Dname="(STM32F407[A-Z0-9]*)"' -AllMatches |
  ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
```

### 7.2 Keil：`L6047U` 镜像过大

```
Fatal error: L6047U: The size of this image (40356 bytes) exceeds the maximum allowed
  for this version of the linker
```

这是 **MDK-ARM Lite** 的 32 KB（代码 + RO 数据）上限。看一眼实际用量：

```
Program Size: Code=6712 RO-data=424 RW-data=44 ZI-data=1636
```

Code + RO + RW 约 7.2 KB。Lite 跑小工程没问题，一旦塞字库、文件系统或 GUI 就会顶到天花板。

### 7.3 Keil：换了器件型号后 `Flash Download failed`

**只改器件名是不够的**——烧录算法和 ROM 大小是**单独存储**的：

```xml
<FlashDriverDll>UL2CM3(... -FF0STM32F4xx_1024 -FS08000000 -FL0100000
                        -FP0($$Device:STM32F407ZG$Flash\STM32F4xx_1024.FLM))</FlashDriverDll>
<Cpu>IROM(0x08000000,0x100000) ...</Cpu>
```

对 512 KB 的芯片必须改成 `STM32F4xx_512` / `-FL080000` / `IROM(0x08000000,0x80000)`。`<RegisterFile>`、`<SFDFile>` 以及 `.uvoptx` 里对应的 `<Name>` 也要一起改。不匹配的后果：要么下载失败，要么往不存在的地址写。

### 7.4 USB-C：能给手机充电、但接上毫无反应的 A 转 C 线

A 转 C 线的 **C 头里有一个 5.1 kΩ 下拉电阻（Rd，接在 CC 脚）**。USB-C 主机口必须先检测到这个电阻，才会打开 VBUS。

而充电宝的 **USB-A** 口是无脑输出 5 V 的，**根本不看 CC**。所以：

> "用充电宝能给手机充电" ⇒ 只证明了 VBUS/GND 通，**完全不能证明 CC 电阻存在**。

典型症状：同一根线插 USB-A 口（任何台式机）一切正常，插 USB-C 口**毫无反应**。两个有效的判断方法：

- 把 C 头插到 **USB-C 充电器**（它会检查 CC）。设备能上电 ⇒ 线没问题，问题在主机端。
- 用 **USB-C 转 USB-A 母 转接头** + 普通 A 公对公 线：转接头造出一个真·USB-A 主机口，永远输出 5 V，彻底绕开 CC 这个变量。

### 7.5 STM32 串口 ISP：无法自动复位

串口 bootloader 一般靠翻转 DTR/RTS 进入。很多板子上这两个脚在 USB 转串口芯片那里是**悬空**的，于是**任何工具都无法把 MCU 复位进 bootloader**。在 FlyMcu 里必须勾选"不使用 RTS/DTR"，然后手动进 bootloader：

1. `BOOT0 = 1`，按 RESET
2. 烧录
3. `BOOT0 = 0`，再按 RESET

### 7.6 PowerShell：脚本报"缺少右 `}`"

Windows PowerShell 5.1 会把**没有 BOM 的 `.ps1` 当作 ANSI/GBK** 解码。多字节字符随之错位，末尾多出来的一个前导字节可能把后面的 ASCII 引号"吃掉"——于是一个看起来完全正确的文件报出莫名的语法错误。

所有含非 ASCII 字符的 `.ps1` 一律存成 **UTF-8 with BOM**（或改用 PowerShell 7，它默认 UTF-8）。校验：

```powershell
[System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$err)
```

### 7.7 Windows 侧始终看不到设备

正常现象。用 usbipd 时，设备在设备管理器里可能显示为未知设备，或者根本不出现。要看的是 **WSL 侧**：

```powershell
"C:\Program Files\usbipd-win\usbipd.exe" list
wsl -d Ubuntu2204 -e lsusb
```

如果 `usbipd list` 能看到设备但 `lsusb` 是空的，说明 `attach` 没执行（或者 VM 重启过了，需要重新 attach）。

### 7.8 已 attach、`lsusb` 也能看到，但没有 `/dev/ttyUSB*`

在 WSL 内核更新后遇到过（6.18.54.1 → 6.18.58.1）。设备确实透传进来了，但串口驱动没加载，所以没有驱动绑定它：

```
$ lsusb
Bus 001 Device 002: ID 1a86:7523 QinHeng Electronics CH340 serial converter

$ ls /dev/ttyUSB*
(无 tty)
```

先确认驱动真的没绑定，再去查别的：

```bash
ls -l /sys/bus/usb/devices/1-1/driver
# -> .../usb/drivers/usb      只有通用 usb 驱动，ch341 没绑上
```

修复——手动加载：

```bash
uname -r                 # 必须能在 /lib/modules 下找到同名目录
modprobe ch341
dmesg | tail -3
# ch341-uart converter now attached to ttyUSB0
```

这里有两个坑：

- `wsl -d <发行版> -e modprobe ch341` 会报 `execvpe(modprobe) failed`，因为 `-e` 不走登录 shell，`/sbin` 不在 PATH 里。要用 shell 包一层：`wsl -d <发行版> -e bash -c "modprobe ch341"`。
- 内核升级后 `/lib/modules` 里可能新旧两套目录并存，`modprobe` 只认 `uname -r` 对应的那套；如果那个目录根本不存在，重跑环境安装脚本。

## 8. 验证状态

下列各项均已在真实硬件上确认。

| 步骤 | 状态 |
|---|---|
| Keil 5.24（x86）在 ARM64 上安装、编译、链接、产出 `.hex` | ✅ 已验证 |
| 各厂商驱动的 PE 架构（也就是根因） | ✅ 已验证 |
| 不用 `wsl --install`，直接导入 WSL 3.0.3.0 + Ubuntu 22.04 ARM64 | ✅ 已验证 |
| `ch341.ko` / `vhci-hcd.ko` 存在且可加载 | ✅ 已验证 |
| `usbipd-win` arm64 版安装、服务运行 | ✅ 已验证 |
| CH340 经 usbipd 透传、`ch341` 绑定、生成 `/dev/ttyUSB0` | ✅ 已验证 |
| `stm32flash` 通过该串口写入并校验 | ✅ 已验证 |
| 从 WSL 读回串口输出 | ✅ 已验证 |

实际运行记录（STM32F407ZET6，20 KB HEX，走 STM32 串口 bootloader）：

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

在 Keil 里编译，在 WSL 里烧录，在 WSL 里读串口。Windows 侧自始至终没有装过任何厂商驱动。

## 9. 适用范围与限制

- **没有在线调试。** 断点/变量监视需要探针驱动，ST-Link 和 ULINK 在这里都用不了。靠串口输出来调试。
- **CMSIS-DAP 探针可能可用。** CMSIS-DAP 是 HID/WinUSB 类设备，部分探针在 ARM64 上无需厂商驱动即可枚举。本文未验证，但那是通往真正断点调试最有希望的一条路。
- **模拟运行更慢。** 编译会比原生 x86 稍慢一些。
- **本文不授予任何 Keil/ARM/ST 授权。** 请勿再分发厂商安装包或器件包，给出官方链接即可。

## 10. 延伸：PL2303 串口

CH340 / CP210x / FTDI 插上就能用，**PL2303 不行**：微软的 WSL2 内核没编这个驱动，
也没法单独补模块，只能重编一次内核。

完整做法和踩坑记录在 **[wsl-usb-serial/](wsl-usb-serial/README.zh-CN.md)**（约 50 分钟，含一键脚本、编译进度条和验证命令）。

## 11. 许可

文档与脚本：**MIT**（见 [LICENSE](LICENSE)）。

本仓库**不包含**任何厂商二进制文件、安装包或器件包。各第三方工具的官方获取渠道
与商标声明见 [NOTICE](NOTICE)。
