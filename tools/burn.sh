#!/usr/bin/env bash
# keel 装机:把构建好的安装镜像写到目标磁盘
#
# 用 mkosi 的 burn 动词而不是裸 dd:它会按目标盘的容量修正 GPT
# (镜像比目标盘小的时候,备份分区表在错误的位置),并复用已构建的产物。
#
# v1.2 2.10 起**烧之前先核对版本**:mkosi burn 烧的是 mkosi.output/keel.raw(上一次构建的
# 输出,文件名里没有版本号),而发布产物在 output/keel-<版本>/ ⇒ 两者对不上就拒绝,
# 免得"拿着旧镜像烧了一台机器还不知道"。
#
# 另一条路(宿主不想装 mkosi / 目标盘拆不下来):发布目录里的 install.sh 解压写盘,
# 或者用 U 盘启动同一个镜像,在 live 环境里跑 os-install <设备>(docs/architecture.md §7.1 路径 B)。
#
# 用法:
#   sudo tools/burn.sh /dev/nvme0n1              # 核对版本 → 确认 → mkosi burn
#   tools/burn.sh --check-only                   # 只做版本核对(CI/冒烟用,不写盘)
#   sudo tools/burn.sh --force /dev/nvme0n1      # 版本不一致也烧(明确知情)
set -euo pipefail
cd "$(dirname "$0")/.."

log() { printf 'keel-burn: %s\n' "$*" >&2; }
die() { printf 'keel-burn: 错误:%s\n' "$*" >&2; exit 1; }
usage() { grep '^#   ' "$0" | sed 's/^#   //' >&2; exit 2; }

OUT=mkosi.output
# 测试/特殊布局用的覆盖点(verify.sh 会拿它们造"版本不一致"的假现场)
IMG=${KEEL_BURN_IMAGE:-$OUT/keel.raw}
VERSION_FILE=${KEEL_BURN_VERSION_FILE:-$OUT/keel.raw.version}
EFI=${KEEL_BURN_EFI:-$OUT/keel.efi}
OUT_DIR=${KEEL_BURN_OUTPUT_DIR:-output}

check_only=0; force=0; dev=""
while [ "${#}" -gt 0 ]; do
    case "$1" in
        --check-only) check_only=1 ;;
        --force) force=1 ;;
        --help|-h) usage ;;
        -*) die "不认识的选项:$1(--help 看用法)" ;;
        *) dev="$1" ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# 版本核对:镜像里的 IMAGE_VERSION(优先)vs output/ 里最新发布目录的版本
# ---------------------------------------------------------------------------
[ -e "$IMG" ] || die "找不到安装镜像 $IMG:先跑 sudo tools/build.sh"
burn_ver="$(cat "$VERSION_FILE" 2>/dev/null || true)"
[ -n "$burn_ver" ] || die "找不到 $VERSION_FILE(旧构建?):重新 sudo tools/build.sh 会写它"

# 真读一次镜像里的 IMAGE_VERSION:安装镜像的 UKI 带 .osrel 段(objcopy 抽出来就是 os-release)。
# ⚠ 认 **IMAGE_VERSION=**(mkosi 写的镜像版本),别认 VERSION_ID —— keel 的 os-release 里
# VERSION_ID 是基底发行版的版本(Debian 的 13),2026-09-28 第一次实测就差点拿它去比对。
# objcopy/keel.efi 不在时退回 sidecar —— 两条都记在日志里,别让人以为读了实际镜像。
img_ver=""
if command -v objcopy >/dev/null 2>&1 && [ -f "$EFI" ]; then
    img_ver="$(objcopy -O binary --only-section=.osrel "$EFI" /dev/stdout 2>/dev/null |
        sed -n 's/^IMAGE_VERSION=//p' | head -n1 | tr -d '\"')" || img_ver=""
    img_ver="${img_ver%$'\r'}"
fi
if [ -n "$img_ver" ]; then
    ver_src="objcopy 读 $EFI 的 .osrel"
else
    img_ver="$burn_ver"
    ver_src="sidecar $VERSION_FILE"
fi

newest="$(ls -1d "$OUT_DIR"/keel-* 2>/dev/null | sort -V | tail -n1)" || newest=""
[ -n "$newest" ] || die "$OUT_DIR/ 下没有发布产物:先跑 sudo tools/build.sh"
rel_ver="${newest##*/}"; rel_ver="${rel_ver#keel-}"

log "待烧镜像版本:$img_ver($ver_src)"
log "最新发布版本  :$rel_ver($newest)"
if [ "$img_ver" != "$rel_ver" ]; then
    if [ "$force" != 1 ]; then
        die "版本不一致:mkosi burn 烧的是 $IMG($img_ver),而 $OUT_DIR 里最新发布的是 $rel_ver。
      先 sudo tools/build.sh 重新构建,或者明确加 --force(知道自己在烧旧版)。"
    fi
    log "警告:--force:版本不一致也继续烧"
fi
if [ "$check_only" = 1 ]; then
    log "版本核对通过(--check-only,不写盘)"
    exit 0
fi

[ -n "$dev" ] || die "用法:sudo tools/burn.sh [--check-only] [--force] /dev/nvme0n1"
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
log "接下来:从这块盘 UEFI 启动。首启会自动补 /data 骨架、扩 volume、登记 NVRAM 启动项。"
log "Secure Boot 用户:先确认固件里登记了 mkosi.crt(见 docs/install.md §2.6)。"
