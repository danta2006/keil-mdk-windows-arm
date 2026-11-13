#!/bin/bash
# 检查当前 WSL 内核的串口支持情况
# 用法： bash verify.sh
set -u

echo "== 内核版本 =="
uname -r

echo
echo "== 内核配置里的 USB 串口驱动 =="
CFG=""
if [ -r /proc/config.gz ]; then
    CFG="$(zcat /proc/config.gz)"
    echo "$CFG" | grep -E '^CONFIG_USB_SERIAL(=|_CH341|_CP210X|_FTDI_SIO|_PL2303)' || echo "（没有相关配置）"
else
    echo "（没有 /proc/config.gz，跳过）"
fi

echo
echo "== 驱动是否注册（内置驱动开机就会打印） =="
for name in ch341 cp210x ftdi_sio pl2303; do
    if echo "$CFG" | grep -q "^CONFIG_USB_SERIAL_$(echo "$name" | tr 'a-z' 'A-Z')=y"; then
        if dmesg 2>/dev/null | grep -qi "$name"; then
            echo "  $name ✓ 编进内核且已注册"
        else
            echo "  $name ✓ 编进内核（插上线后才会出现在日志里）"
        fi
    else
        echo "  $name ✗ 不支持"
    fi
done

echo
echo "== 当前串口设备 =="
ls -l /dev/ttyUSB* /dev/ttyACM* 2>/dev/null || echo "  （还没有设备：先插线，再 usbipd attach）"
