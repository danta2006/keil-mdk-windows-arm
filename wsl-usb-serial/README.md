# WSL2: adding PL2303 support to the kernel

> Assumes the USB passthrough from the main document already works.
> This directory fixes exactly one thing: **a PL2303 adapter shows up but no `/dev/ttyUSB0` appears**.

[中文](README.zh-CN.md)

## Symptom

```bash
$ modprobe pl2303
modprobe: FATAL: Module pl2303 not found in directory /lib/modules/6.18.58.1-microsoft-standard-WSL2
```

## Three steps

```bash
bash build-kernel.sh            # ~50 min: build a kernel with PL2303 + the full module set
```

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
wsl --shutdown
```

```bash
bash install-modules.sh         # required after switching, or usbipd breaks
bash verify.sh                  # checks the four serial drivers + vhci_hcd
```

`build-kernel.sh` picks the Microsoft source tag matching `uname -r`, uses the running
`/proc/config.gz` as baseline, and changes only the PL2303 line.

## Why a standalone `.ko` cannot work

The kernel is built with `CONFIG_MODVERSIONS`; modules must match the kernel's
`Module.symvers`, which only exists after a full kernel build.

## Two pitfalls

- **Skipping `install-modules.sh`** → `vhci_hcd` goes missing → `usbipd attach` fails with
  `Loading vhci_hcd failed`
- **A trailing `+` in the version string** → does not match `/lib/modules` → every module
  fails to load (handled by the script)

## Rollback

Remove the `kernel=` line from `%USERPROFILE%\.wslconfig`, then `wsl --shutdown`.

## Measured

Windows 11 ARM64, 8 cores: `make -j8 Image modules` took **51 min 21 s**, 4356 modules.
After switching, `vhci_hcd` loads and `/dev/ttyUSB0` appears.

## License

MIT
