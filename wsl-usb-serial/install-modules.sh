#!/bin/bash
# 换完内核之后，把配套的模块装进 /lib/modules 并刷新依赖
#
#   bash install-modules.sh
#
# 为什么必须做这一步：
#   自定义内核启动后，WSL 不再挂载官方那套模块，/lib/modules/<版本>/ 是空的。
#   不装模块，usbipd 依赖的 vhci_hcd 就加载不了，USB 透传直接失效。
set -euo pipefail

SRC="${SRC:-$HOME/wsl-kernel}"
KVER="$(uname -r)"

echo "当前内核: $KVER"

if [ ! -d "$SRC" ]; then
    echo "!! 找不到源码目录 $SRC（先跑 build-kernel.sh）"
    exit 1
fi

echo "== 安装模块到 /lib/modules/$KVER =="
make -C "$SRC" modules_install

echo "== 刷新模块依赖 =="
depmod -a "$KVER"

echo "== 检查关键模块 =="
for m in vhci_hcd usbip_core usbserial ch341 pl2303; do
    if modprobe "$m" 2>/dev/null; then
        echo "  $m ✓"
    else
        echo "  $m ✗"
    fi
done

echo
echo "== 当前加载的 usbip 相关模块 =="
lsmod | grep -E 'vhci|usbip' || echo "  （无）"
