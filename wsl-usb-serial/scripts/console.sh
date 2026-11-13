#!/bin/bash
# 打开开发板的串口终端（picocom），支持 XMODEM 发送/接收
# 由 serial-console.ps1 调用，也可以直接在 WSL 里跑： bash console.sh [串口]

BAUD="${BAUD:-115200}"
TTY="${1:-$(ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null | head -n 1)}"

missing=""
command -v picocom >/dev/null 2>&1 || missing="$missing picocom"
command -v sx      >/dev/null 2>&1 || missing="$missing lrzsz(sx/rx)"
if [ -n "$missing" ]; then
    echo "[!] 缺少工具：$missing"
    echo "    先装： sudo apt-get install -y picocom lrzsz"
    exit 2
fi

if [ -z "$TTY" ]; then
    echo "[!] 没有找到串口设备（/dev/ttyUSB* 或 /dev/ttyACM*）"
    echo "    先在 Windows 侧执行： usbipd attach --wsl --busid <BUSID>"
    echo
    echo "    WSL 当前看到的 USB 设备："
    lsusb 2>/dev/null || echo "    （lsusb 无输出）"
    exit 1
fi

echo "=============================================="
echo " 串口   : $TTY    ${BAUD} 8-N-1"
echo " 退出   : Ctrl+A 然后 X"
echo " 发文件 : 板上先执行  rx 文件名"
echo "          再按 Ctrl+A 然后 S，输入文件路径"
echo "=============================================="
echo

exec picocom -b "$BAUD" --flow n \
     --send-cmd "sx -vv" --receive-cmd "rx -vv" "$TTY"
