# WSL2：给内核补上 PL2303

> 前提：你已经按主文档把 USB 透传跑通了。这里只解决一件事——**PL2303 的线插上没反应**。

[English](README.md)

## 症状

```bash
$ modprobe pl2303
modprobe: FATAL: Module pl2303 not found in directory /lib/modules/6.18.58.1-microsoft-standard-WSL2
```

## 三条命令

```bash
bash build-kernel.sh            # 约 50 分钟：编一个只多 PL2303 的内核 + 全套模块
```

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
wsl --shutdown
```

```bash
bash install-modules.sh         # 换完内核后必须做，否则 usbipd 会挂
bash verify.sh                  # 检查四个串口驱动 + vhci_hcd
```

`build-kernel.sh` 会按 `uname -r` 取对应的微软源码 tag，用当前 `/proc/config.gz` 当基线，只改 PL2303 那一行。

## 为什么不能只编一个 `.ko`

内核开了 `CONFIG_MODVERSIONS`，模块要和内核的 `Module.symvers` 对得上，而这个文件只有整编内核才会生成。

## 两个会踩的坑

- **不跑 `install-modules.sh`** → `vhci_hcd` 丢失 → `usbipd attach` 报 `Loading vhci_hcd failed`
- **版本号多一个 `+`** → 和 `/lib/modules` 对不上 → 模块全部加载失败（脚本里已处理）

## 回滚

删掉 `%USERPROFILE%\.wslconfig` 里 `kernel=` 一行，`wsl --shutdown`。

## 实测

Windows 11 ARM64，8 核：`make -j8 Image modules` 共 **51 分 21 秒**，4356 个模块；
换内核后 `vhci_hcd` 正常，`/dev/ttyUSB0` 出现。

## 许可

MIT
