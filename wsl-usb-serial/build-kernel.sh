#!/bin/bash
# 编译一个"多一个 PL2303 驱动"的 WSL2 内核，连完整模块树一起编
#
#   用法： bash build-kernel.sh
#   说明： 约 40~50 分钟，全程本机原生编译（ARM64 / x86_64 都行）
#
set -euo pipefail

KVER="$(uname -r)"                    # 例：6.18.58.1-microsoft-standard-WSL2
TAG="linux-msft-wsl-${KVER%%-*}"      # 例：linux-msft-wsl-6.18.58.1
ARCH="$(uname -m)"
SRC="${SRC:-$HOME/wsl-kernel}"
OUT="${OUT:-$HOME/wsl-kernel-out}"

# 依赖预检：ubuntu-base 这类精简 rootfs 里没有编译工具
missing=""
for c in gcc make git bc flex bison; do
    command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
done
if [ -n "$missing" ]; then
    echo "缺少编译依赖:$missing"
    echo "  sudo apt-get update && sudo apt-get install -y \\"
    echo "      build-essential git flex bison bc libssl-dev libelf-dev \\"
    echo "      libncurses-dev dwarves cpio rsync kmod"
    exit 1
fi
echo "=================================================="
echo " 当前 WSL 内核 : $KVER"
echo " 对应源码 tag  : $TAG"
echo " 主机架构      : $ARCH"
echo "=================================================="

# ---------------------------------------------------------------- 源码
if [ ! -d "$SRC/.git" ] && [ ! -d "$SRC/.git_off" ]; then
    echo "[1/5] 克隆内核源码（约 2 GB，只取这一个 tag）…"
    git clone --depth 1 --branch "$TAG" \
        https://github.com/microsoft/WSL2-Linux-Kernel.git "$SRC"
else
    echo "[1/5] 已有源码目录，跳过克隆"
fi
cd "$SRC"

# 版本号后面会多一个 "+"，那样就和 /lib/modules/ 对不上，把 .git 挪开
if [ -d .git ]; then
    mv .git .git_off
    echo "      已把 .git 移开，保证版本号和官方一致"
fi

# ---------------------------------------------------------------- 配置
echo "[2/5] 用当前运行内核的配置做基线，只打开 PL2303"
cp -f /proc/config.gz config.gz
gunzip -f config.gz
mv -f config .config

sed -i 's/^# CONFIG_USB_SERIAL_PL2303 is not set/CONFIG_USB_SERIAL_PL2303=m/' .config
make olddefconfig >/dev/null

if ! grep -q '^CONFIG_USB_SERIAL_PL2303=m' .config; then
    echo "!! 配置没有生效"
    exit 1
fi
echo "      CONFIG_USB_SERIAL_PL2303=m  ✓"
echo "      版本号： $(make kernelrelease 2>/dev/null | tail -n 1)"

# ---------------------------------------------------------------- 编译
echo "[3/5] 编译内核镜像 + 全部模块（8 核约 51 分钟，需要 15-20 GB 空闲磁盘）"
time make -j"$(nproc)" Image modules

# ---------------------------------------------------------------- 导出
echo "[4/5] 导出镜像"
mkdir -p "$OUT"
if [ "$ARCH" = "aarch64" ]; then
    cp -v arch/arm64/boot/Image "$OUT/Image"
else
    cp -v arch/x86/boot/bzImage "$OUT/bzImage"
fi

echo "[5/5] 模块先留在源码树里，等换完内核再用 install-modules.sh 安装"
du -sh "$OUT"/*

echo
echo "完成。接着在 Windows 侧执行： powershell -ExecutionPolicy Bypass -File install.ps1"
