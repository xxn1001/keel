#!/bin/bash
# keel 装机:把构建好的安装镜像写到目标磁盘
#
# 用 mkosi 的 burn 动词而不是裸 dd:它会按目标盘的容量修正 GPT
# (镜像比目标盘小的时候,备份分区表在错误的位置),并复用已构建的产物。
#
# 另一条路(目标盘拆不下来时)是用 U 盘启动同一个镜像,在 live 环境里跑
# `os-install <设备>`(docs/architecture.md §7.1 路径 B)。
set -euo pipefail
cd "$(dirname "$0")/.."

log() { printf 'keel-burn: %s\n' "$*" >&2; }
die() { printf 'keel-burn: 错误:%s\n' "$*" >&2; exit 1; }

dev=${1:-}
[ -n "$dev" ] || die "用法:sudo tools/burn.sh /dev/nvme0n1"
[ -b "$dev" ] || die "$dev 不是块设备"
[ "$(id -u)" = 0 ] || die "需要 root"

# 拒绝写到当前系统所在的盘上(用构建机时也防手滑)
root_src=$(findmnt -no SOURCE / 2>/dev/null || true)
if [ -n "$root_src" ]; then
    root_pk=$(lsblk -ndo PKNAME "$(readlink -f "$root_src")" 2>/dev/null | head -1 || true)
    if [ -n "$root_pk" ] && [ "$(readlink -f "$dev")" = "/dev/$root_pk" ]; then
        die "$dev 是当前系统所在的磁盘"
    fi
fi

size=$(lsblk -ndo SIZE "$dev" | head -1)
log "目标设备:$dev($size)"
log "这个设备上的所有数据都会被擦除。"
printf '确认请输入设备路径(%s):' "$dev"
read -r answer
[ "$answer" = "$dev" ] || die "输入不匹配,已取消"

command -v mkosi >/dev/null || die "没装 mkosi"
log "开始写入(mkosi burn 会按目标盘容量修正 GPT)…"
mkosi --profile install burn "$dev"
log "写入完成。"
log "接下来:从这块盘 UEFI 启动。首启会自动补 /Volume 骨架、扩 volume、登记 NVRAM 启动项。"
