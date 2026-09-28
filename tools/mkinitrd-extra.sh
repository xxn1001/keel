#!/usr/bin/env bash
# keel:initrd 补充层(cpio)—— v1.2 3.0
#
# 背景(2026-09-28 拆 UKI 实测):mkosi 25.3 **根本不读仓库里的 mkosi.initrd.conf**
# (源码里没有这个文件名;默认 initrd 是用内置的 --include=mkosi-initrd 构的)。
# 于是那个文件里写的 ExtraTrees=mkosi.extra-initrd 从来没生效:initrd 里既没有
# RuntimeWatchdogSec,也没有 softdog ⇒ 坏槽在 initrd 阶段冻结时永远没人复位(坑 #50),
# 而 tools/verify.sh 那两条"看配置在不在"的断言一直是**空断言**(见坑 #76)。
#
# 能工作的机制是 mkosi 的 Initrds= / --initrd:把用户 cpio 原样拼进 UKI 的 .initrd。
# 本脚本把 mkosi.initrd-extra/ 打成 newc cpio;build.sh 用 --initrd 传给 mkosi,
# 并在生成后**回读**两个文件确实在 cpio 里(不是只看目录里有)。
#
# 用法:tools/mkinitrd-extra.sh
# 环境变量(自测用):KEEL_INITRD_EXTRA_DIR(默认 mkosi.initrd-extra)
#                   KEEL_INITRD_EXTRA_OUT(默认 mkosi.output/keel-initrd-extra.cpio)
set -euo pipefail
cd "$(dirname "$0")/.."

SRC=${KEEL_INITRD_EXTRA_DIR:-mkosi.initrd-extra}
OUT=${KEEL_INITRD_EXTRA_OUT:-mkosi.output/keel-initrd-extra.cpio}

log() { printf 'keel-initrd-extra: %s\n' "$*" >&2; }
die() { printf 'keel-initrd-extra: 错误:%s\n' "$*" >&2; exit 1; }

[ -d "$SRC" ] || die "找不到补充层目录:$SRC"
command -v cpio >/dev/null 2>&1 || die "需要 cpio(GNU cpio;宿主或容器里装一个)"
required="etc/systemd/system.conf.d/keel-watchdog.conf etc/modules-load.d/keel-softdog.conf"
for f in $required; do
    [ -s "$SRC/$f" ] || die "补充层里缺少 $SRC/$f"
done

mkdir -p "$(dirname "$OUT")"
tmp="${OUT}.tmp.$$"
rm -f "$tmp"
# 用固定顺序打包(可复现;cpio 的 inode 顺序会进档案头,但不影响内核解包)
( cd "$SRC" && find . -mindepth 1 -printf '%P\n' | LC_ALL=C sort | cpio -o -H newc --quiet ) >"$tmp" ||
    { rm -f "$tmp"; die "cpio 打包失败"; }
[ -s "$tmp" ] || { rm -f "$tmp"; die "cpio 是空的"; }

# 回读:按**内容**确认两个文件在档案里(不是相信 find/cpio 的退出码)
listing="$(cpio -it --quiet <"$tmp" 2>/dev/null)" || { rm -f "$tmp"; die "读不回 cpio 清单"; }
for f in $required; do
    if ! printf '%s\n' "$listing" | grep -qx "$f" && ! printf '%s\n' "$listing" | grep -qx "./$f"; then
        rm -f "$tmp"
        die "回读失败:cpio 里没有 $f"
    fi
done
mv -f "$tmp" "$OUT"
log "已生成 $OUT($(stat -c %s "$OUT") 字节;含 $(printf '%s' "$required" | wc -w) 个文件)"
