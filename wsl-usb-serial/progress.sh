#!/bin/bash
# 内核编译进度条（每秒刷新，Ctrl+C 退出）
#   LOG       编译日志路径
#   TOTAL_MIN 预计总时长（分钟，8 核实测 ~51 分钟），只用于估算百分比
LOG="${LOG:-/tmp/kbuild5.log}"
TOTAL_MIN="${TOTAL_MIN:-55}"

# %W（创建时间）在部分文件系统上返回 0，回退到当前时间
START=0
if [ -f /tmp/kbuild_start ]; then
    START=$(cat /tmp/kbuild_start 2>/dev/null || echo 0)
fi
if [ "${START:-0}" -eq 0 ] 2>/dev/null; then
    START=$(stat -c %W "$LOG" 2>/dev/null || echo 0)
fi
if [ "${START:-0}" -eq 0 ] 2>/dev/null; then
    START=$(date +%s)
fi
echo "$START" > /tmp/kbuild_start 2>/dev/null || true

draw_bar() {
    local pct=$1 width=38 filled=$(( $1 * 38 / 100 )) i
    printf "["
    for ((i = 0; i < width; i++)); do
        if [ "$i" -lt "$filled" ]; then printf "#"; else printf "-"; fi
    done
    printf "] %3d%%" "$pct"
}

while true; do
    if [ ! -f "$LOG" ]; then echo "等待编译开始…"; sleep 2; continue; fi

    now=$(date +%s)
    elapsed=$(( now - START ))
    mins=$(( elapsed / 60 ))
    secs=$(( elapsed % 60 ))

    # grep -c 在没有匹配时返回 1，但仍输出 "0"；不能再 `|| echo 0`，否则会输出两行
    cc_all=$(grep -c '^  CC' "$LOG" 2>/dev/null || true)
    cc_m=$(grep -c 'CC \[M\]' "$LOG" 2>/dev/null || true)
    cc_all=${cc_all:-0}
    cc_m=${cc_m:-0}

    if grep -q 'Building modules, stage 2' "$LOG"; then
        pct=99; phase="收尾：生成模块"
    elif grep -q '^  MODPOST' "$LOG"; then
        pct=96; phase="链接模块"
    elif grep -q '^  OBJCOPY arch/arm64/boot/Image' "$LOG"; then
        pct=95; phase="内核已生成，模块收尾"
    else
        pct=$(( mins * 100 / TOTAL_MIN ))
        [ "$pct" -gt 94 ] && pct=94
        phase="编译中"
    fi

    remain=$(( TOTAL_MIN - mins ))
    [ "$remain" -lt 0 ] && remain=0

    line="$(draw_bar "$pct")  $phase  已用 ${mins}分${secs}秒  约剩 ${remain} 分  对象 ${cc_all}  模块 ${cc_m}"
    printf "\r%-120s" "$line"
    printf "%s\n" "$line" > /tmp/kbuild_progress.txt
    sleep 1
done
