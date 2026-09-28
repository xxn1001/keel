#!/usr/bin/env bash
# keel —— 把 mkosi.initrd-extra/ 打成一个小 .deb,好让 mkosi 把它**追加**进默认 initrd
#
# 为什么必须是包(2026-09-28 实测查实,坑 #77):
#   mkosi 25.3 往默认 initrd(mkosi-initrd)里放文件只有两条路 ——
#     ① `Initrds=`:**替换**而不是追加。一旦设了,`finalize_initrds()` 只返回你给的那几个文件,
#        内置 initrd 整个不进来 ⇒ UKI 里只剩我们那个几 KB 的 cpio,内核
#        `VFS: Unable to mount root fs`,连正常槽都起不来。这就是 #77 的真实根因。
#     ② `InitrdPackages=`:把包装进 initrd。唯一能"追加"的口子,于是我们造一个小包。
#   包经由 `PackageDirectories=mkosi.packages` 进 mkosi 的本地仓库(它用 tools tree 里的
#   reprepro 建索引),再由 `InitrdPackages=keel-initrd-watchdog` 装进 initrd。
#
# 为什么值得这么绕:initrd 里 PID1 冻住(实测 `[!!!!!!] Switch root target contains no usable init.`)
# 时没有任何代码会跑,**只有看门狗复位能救** —— 而这需要 initrd 里有一份
# `RuntimeWatchdogSec=`(决策 D25 / 坑 #50)。
#
# 幂等:内容没变就不重写 mkosi.packages/ 里那个文件 —— mkosi 的增量缓存键包含包文件的
# mtime,每次构建都换 mtime 会让整棵缓存失效(每次构建退化成 20–35 分钟的全量)。
#
# 用法:tools/initrd-watchdog-pkg.sh
# 环境变量(自测用):KEEL_INITRD_PKG_SRC / KEEL_INITRD_PKG_OUTDIR / KEEL_INITRD_PKG_VERSION
set -euo pipefail
cd "$(dirname "$0")/.."

SRC=${KEEL_INITRD_PKG_SRC:-mkosi.initrd-extra}
OUTDIR=${KEEL_INITRD_PKG_OUTDIR:-mkosi.packages}
NAME=keel-initrd-watchdog
BASE_VERSION=${KEEL_INITRD_PKG_VERSION:-1.0}
OUT="$OUTDIR/${NAME}_${BASE_VERSION}_all.deb"
# .deb 里的时间戳固定住:同样的输入 ⇒ 同样的字节(便于 cmp 幂等与复现)
export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-1700000000}

log() { printf "keel-initrd-pkg: %s\n" "$*" >&2; }
die() { printf "keel-initrd-pkg: 错误:%s\n" "$*" >&2; exit 1; }

command -v dpkg-deb >/dev/null 2>&1 || die "找不到 dpkg-deb(宿主需要 dpkg;Debian/Ubuntu 自带)"

# 载荷:路径就是它装进 initrd 之后的路径。少一个文件都必须在**构建期**炸,
# 否则产物看起来正常、真机上 initrd 冻住却没人复位(正是这一节要修的东西)。
FILES=(
    usr/lib/systemd/system.conf.d/keel-watchdog.conf
    usr/lib/modules-load.d/keel-watchdog.conf
    usr/lib/systemd/system/keel-initrd-timeout.service
    usr/lib/keel/initrd-timeout
)
# 单元靠**包里带的 .wants 符号链接**启用(initrd 构建不跑 preset,不能指望 [Install])
LINKS=(
    usr/lib/systemd/system/sysinit.target.wants/keel-initrd-timeout.service
    usr/lib/systemd/system/initrd-switch-root.target.wants/keel-initrd-timeout.service
)
for f in "${FILES[@]}"; do
    [ -s "$SRC/$f" ] || die "缺载荷文件:$SRC/$f(initrd 兜底是 fail-closed 的)"
done
for l in "${LINKS[@]}"; do
    [ -L "$SRC/$l" ] || die "缺启用符号链接:$SRC/$l(少了它单元根本不会启动)"
done
# 主镜像与 initrd 两份看门狗配置必须同值,否则"一头松开"(verify 也核对,这里先拦一道)
grep -q "^RuntimeWatchdogSec=60$" "$SRC/usr/lib/systemd/system.conf.d/keel-watchdog.conf" ||
    die "initrd 那份没有 RuntimeWatchdogSec=60"
grep -qx "softdog" "$SRC/usr/lib/modules-load.d/keel-watchdog.conf" ||
    die "initrd 那份 modules-load 里没有 softdog"
# 超时脚本必须真的会强制复位(sysrq 是 PID1 冻住时唯一还走得通的路径)
grep -q "^echo b >/proc/sysrq-trigger" "$SRC/usr/lib/keel/initrd-timeout" ||
    die "initrd-timeout 里没有 sysrq 强制复位 —— 那就等于没有兜底"
grep -q "^ExecStart=/usr/lib/keel/initrd-timeout$" "$SRC/usr/lib/systemd/system/keel-initrd-timeout.service" ||
    die "keel-initrd-timeout.service 没有指向 /usr/lib/keel/initrd-timeout"

work=$(mktemp -d "${TMPDIR:-/tmp}/keel-initrd-pkg.XXXXXX")
trap 'rm -rf "$work"' EXIT
root="$work/root"
mkdir -p "$root"
( cd "$SRC" && tar -cf - . ) | ( cd "$root" && tar -xf - )

# 内容摘要进版本号:包内容一变,仓库索引里那个版本也跟着变(避免同名同版不同内容)
hash=$( cd "$SRC" && find . -type f | sort | xargs sha256sum | sha256sum | cut -c1-8 )
version="${BASE_VERSION}+${hash}"

mkdir -p "$root/DEBIAN"
cat >"$root/DEBIAN/control" <<EOF
Package: $NAME
Version: $version
Architecture: all
Maintainer: keel <keel@localhost>
Section: admin
Priority: optional
Description: keel initrd-stage watchdog fallback (runtime watchdog + total timeout)
 Two drop-ins make the initrd PID1 load softdog and arm the runtime watchdog;
 a unit + script add a total timeout that force-resets the machine with sysrq if
 the initrd has not switched root in time (emergency prompt, frozen switch root).
 Required for unattended A/B rollback when the candidate slot cannot boot.
EOF

# 权限按「装进 initrd 之后该是什么」定,不看源文件在仓库里的权限位:工作区/编辑器可能
# 留下 0600,那样 initrd 里的 systemd 读不到配置(坑 #57 的形状)。
find "$root" -type f -exec chmod 0644 {} +
# /usr/lib/keel/ 下的是**可执行脚本**,不能跟着一起压成 0644
find "$root/usr/lib/keel" -type f -exec chmod 0755 {} + 2>/dev/null || true
find "$root" -type d -exec chmod 0755 {} +
find "$root" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
mkdir -p "$OUTDIR"
deb="$work/$NAME.deb"
dpkg-deb --root-owner-group --build "$root" "$deb" >/dev/null || die "dpkg-deb 打包失败"

# 回读:列出来 + 解出来逐字节比 —— 不看退出码(坑 #36 的形状)
# 第 6 字段才是路径(第 7 起是符号链接的 `-> 目标`)
listing=$(dpkg-deb -c "$deb" | awk '{print $6}' | sed 's#^\./##' | sort)
for f in "${FILES[@]}"; do
    printf "%s\n" "$listing" | grep -qx "$f" || die "回读失败:包里没有 $f"
done
for l in "${LINKS[@]}"; do
    printf "%s\n" "$listing" | grep -qx "$l" || die "回读失败:包里没有符号链接 $l"
done
extract="$work/x"
mkdir -p "$extract"
dpkg-deb -x "$deb" "$extract" || die "dpkg-deb -x 解包失败"
for f in "${FILES[@]}"; do
    cmp -s "$SRC/$f" "$extract/$f" || die "回读失败:$f 的内容与源文件不一致"
done
for l in "${LINKS[@]}"; do
    [ "$(readlink "$extract/$l")" = "$(readlink "$SRC/$l")" ] || die "回读失败:$l 的链接目标不对"
done
[ -x "$extract/usr/lib/keel/initrd-timeout" ] || die "回读失败:initrd-timeout 丢了可执行位"

if [ -f "$OUT" ] && cmp -s "$deb" "$OUT"; then
    log "包没变,保持 $OUT($version,$(stat -c %s "$OUT") B;mtime 不动 ⇒ mkosi 增量缓存可用)"
else
    install -m 0644 "$deb" "$OUT"
    log "已生成 $OUT($version,$(stat -c %s "$OUT") B;装了 ${#FILES[@]} 个文件,回读一致)"
fi
