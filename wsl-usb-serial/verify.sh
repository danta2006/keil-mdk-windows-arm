#!/bin/bash
# 检查当前 WSL 内核的 USB 串口 / USB-IP 支持
# 用法： bash verify.sh
set -u

KVER="$(uname -r)"
echo "== 内核版本 =="; echo "$KVER"

CFG=""
if [ -r /proc/config.gz ]; then
    CFG="$(zcat /proc/config.gz)"
elif [ -r "/boot/config-$KVER" ]; then
    CFG="$(cat "/boot/config-$KVER")"
fi

echo; echo "== 内核配置 =="
if [ -n "$CFG" ]; then
    echo "$CFG" | grep -E '^CONFIG_(USB_SERIAL|USBIP)' || echo "（没有相关配置）"
else
    echo "（读不到内核配置：既无 /proc/config.gz，也无 /boot/config-$KVER）"
fi

echo; echo "== USB 串口驱动（y=built-in, m=模块） =="
for name in ch341 cp210x ftdi_sio pl2303; do
    key="CONFIG_USB_SERIAL_$(echo "$name" | tr 'a-z' 'A-Z')"
    if ! echo "$CFG" | grep -qE "^$key=(y|m)$"; then
        echo "  $name ✗ 未启用（$key 未设置）"; continue
    fi
    if echo "$CFG" | grep -qE "^$key=y$"; then
        echo "  $name ✓ built-in"
    elif lsmod | grep -q "^$name"; then
        echo "  $name ✓ 模块已加载"
    else
        echo "  $name ✓ 模块可用（modprobe $name）"
    fi
done

echo; echo "== USB/IP 虚拟主机控制器 =="
if lsmod | grep -qE '^vhci_hcd'; then
    echo "  vhci_hcd ✓ 已加载"
elif echo "$CFG" | grep -qE '^CONFIG_USBIP_VHCI_HCD=(y|m)$'; then
    echo "  vhci_hcd ✓ 已编译但未加载（modprobe vhci-hcd）"
else
    echo "  vhci_hcd ✗ 未启用（usbipd attach 会失败）"
fi

echo; echo "== 当前串口设备 =="
ls -l /dev/ttyUSB* /dev/ttyACM* 2>/dev/null || echo "  （还没有设备：先插线，再 usbipd attach）"
