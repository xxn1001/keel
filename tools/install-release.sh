#!/usr/bin/env bash
# keel 发布包安装器(v1:解压写盘)
#
# 它随发布目录一起分发(output/keel-<版本>/install.sh),按脚本所在目录找 keel.img.zst。
#
# 用法:
#   sudo ./install.sh /dev/nvme0n1          # 写整块盘(擦除!先确认设备)
#   sudo ./install.sh /dev/sdX --yes        # 跳过确认
#        ./install.sh --to keel-out.raw     # 写成一个镜像文件(测试/喂 VM;不需要 root)
#   --force 允许覆盖已存在的 --to 目标;--help 看用法
#
# 依赖:**宿主**只要有 zstd + dd + lsblk/blockdev(util-linux)。**不需要 mkosi** ——
# 这是发布包收紧(v1.2 2.10)之后的第一条安装路径;第二条是 tools/burn.sh(mkosi burn,
# 会按目标盘容量修 GPT,适合构建机上直接烧)。
#
# 目标盘比镜像大时:GPT 备份表还在镜像末尾的位置(主表可用);首启的 systemd-repart +
# keel-firstboot 会把分区/文件系统扩到整盘,和 os-install 之后的行为一致。
#
# Secure Boot:v1.2 的 UKI 是自签的(见 docs/install.md §2.6)。固件里没登记 mkosi.crt 时,
# 要么先关掉 Secure Boot 完成首装,要么先登记证书。
set -euo pipefail

SELF_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
IMG="$SELF_DIR/keel.img.zst"
SIZE_FILE="$SELF_DIR/keel.img.zst.size"

log() { printf 'keel-install: %s\n' "$*" >&2; }
die() { printf 'keel-install: 错误:%s\n' "$*" >&2; exit 1; }
usage() {
    grep '^#   ' "$0" | sed 's/^#   //' >&2
    exit 2
}

target=""; to=""; yes=0; force=0
while [ "${#}" -gt 0 ]; do
    case "$1" in
        --yes|-y) yes=1 ;;
        --force|-f) force=1 ;;
        --to) shift; to="${1:-}" ;;
        --help|-h) usage ;;
        -*) die "不认识的选项:$1(--help 看用法)" ;;
        *) target="$1" ;;
    esac
    shift
done

if [ -z "$to" ] && [ -z "$target" ]; then die "用法:install.sh <设备> [--yes] 或 install.sh --to <文件>"; fi
if [ -n "$to" ] && [ -n "$target" ]; then die "--to 与设备只能给一个"; fi

[ -s "$IMG" ] || die "找不到 $IMG(install.sh 必须和 keel.img.zst 放在一起)"
command -v zstd >/dev/null 2>&1 || die "宿主没有 zstd(keel 镜像里也没有;装一个:apt install zstd)"

raw_size="$(cat "$SIZE_FILE" 2>/dev/null || true)"
case "$raw_size" in ''|*[!0-9]*) die "缺少/损坏 $SIZE_FILE(里面应该是解压后的字节数)" ;; esac
log "镜像:$(basename "$IMG")(压缩 $(du -h "$IMG" | cut -f1) / 解压 $((raw_size / 1048576)) MiB)"

if [ -n "$to" ]; then
    if [ -e "$to" ] && [ "$force" != 1 ]; then
        die "$to 已存在(要覆盖加 --force)"
    fi
    tmp="${to}.tmp.$$"
    rm -f "$tmp"
    if ! zstd -dc "$IMG" >"$tmp"; then rm -f "$tmp"; die "解压失败"; fi
    actual=$(stat -c %s "$tmp")
    if [ "$actual" != "$raw_size" ]; then rm -f "$tmp"; die "解压后大小不对(期望 $raw_size,实际 $actual)"; fi
    mv -f "$tmp" "$to"
    log "完成:$to($actual 字节)"
    exit 0
fi

[ "$(id -u)" = 0 ] || die "写块设备需要 root"
[ -b "$target" ] || die "$target 不是块设备"
[ "$(lsblk -ndo TYPE "$target" 2>/dev/null | head -1)" = disk ] || die "$target 不是整块盘(请给 /dev/sdX,不要给分区)"

# 目标盘上有挂载点就拒绝(顺带覆盖"当前系统根所在盘")
if lsblk -nlo MOUNTPOINT "$target" 2>/dev/null | grep -q '[^[:space:]]'; then
    die "$target 上有已挂载的分区,拒绝写入(先 umount)"
fi
root_src="$(findmnt -no SOURCE / 2>/dev/null || true)"
if [ -n "$root_src" ]; then
    root_pk="$(lsblk -ndo PKNAME "$(readlink -f "$root_src")" 2>/dev/null | head -1 || true)"
    if [ -n "$root_pk" ] && [ "$(readlink -f "$target")" = "/dev/$root_pk" ]; then
        die "$target 是当前系统所在的盘"
    fi
fi

dev_bytes="$(blockdev --getsize64 "$target" 2>/dev/null || echo 0)"
[ "$dev_bytes" -ge "$raw_size" ] || die "目标盘 $target 只有 $((dev_bytes / 1048576)) MiB,装不了解压后 $((raw_size / 1048576)) MiB 的镜像"

log "目标盘:$target($(lsblk -ndo SIZE "$target" | head -1))"
log "这个盘上的数据会被**全部擦除**。"
if [ "$yes" != 1 ]; then
    printf '确认请输入设备路径(%s):' "$target"
    read -r answer
    [ "$answer" = "$target" ] || die "输入不匹配,已取消"
fi

log "写盘中(zstd -dc | dd)…"
zstd -dc "$IMG" | dd of="$target" bs=4M conv=fsync status=progress
sync
log "写入完成。"
log "接下来:从这块盘 UEFI 启动。Secure Boot 用户先看 docs/install.md §2.6(登记 mkosi.crt)。"
