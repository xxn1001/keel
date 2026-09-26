#!/usr/bin/env bash
# keel OTA 演练:编排脚本(容器路径与原生路径**共用同一份**)
#
#   容器路径:sudo tools/build-container.sh drill   (构建容器里以 root 运行,cwd = 仓库挂载点)
#   原生路径:sudo tools/build.sh --drill          (FHS 宿主上直接跑;两条路走的是这个文件)
#
# 名字里的 "container" 是历史原因(它最早只在容器里跑过)。脚本内部不依赖"自己在容器里":
# 只有一处前提 —— **HTTP 源必须和 qemu 在同一个网络命名空间**(guest 访问的 10.0.2.2 是
# QEMU 用户态网络的网关)。容器路径下 qemu 在容器里,所以源也起在容器里;原生路径下
# qemu 就在本机,源起在本机即可。两种情况都是"谁跑 qemu,谁起源",脚本用 cwd 定位仓库。
#
# 它负责:
#   1. 静态校验
#   2. tools/build.sh → 新版本载荷 dist/keel-<时间戳>/
#   3. 用**显式更旧的版本号**构建引导镜像(否则 os-update check 会说"已经是最新")
#   4. 把安装镜像放大到 $KEEL_DRILL_IMAGE_SIZE(默认 24G,见下面 step 4 的说明;
#      live 镜像自己的 /data 只有 1 GiB,不够放载荷)
#   5. 起本地 HTTP 源(见下面"为什么必须在容器里起")
#   6. 起 VM:guest 里的 keel-ota-drill.service 会自己跑完 check/fetch/stage/重启/确认/回滚
#
# 可调的环境变量(不设就用默认值):
#   KEEL_DRILL_IMAGE_SIZE    安装镜像放大到多大(整数 GiB,默认 24G;下限 20G)
#   KEEL_DRILL_BOOT_VERSION  引导镜像的版本号(默认 2000.01.01.0001,必须旧于载荷)
#   KEEL_DRILL_PORT          本地 HTTP 源端口(默认 8000)
#   KEEL_DRILL_VM_TIMEOUT    VM 超时秒数(默认 1500)
#   KEEL_DRILL_BAD_SLOT      做坏载荷的目标槽(默认 b)
#   KEEL_DRILL_SABOTAGE      坏法:userspace(默认)/ initrd
#   KEEL_ROOT_PASSWORD       给 admin 的初始密码(经 mkosi --root-password)
#
# 为什么要拆成独立脚本:整个流程要塞进 `bash -lc "…"` 的话,引号要套三层
# (容器 → PAYLOAD → mkosi),第一次跑就栽在"容器里没有 curl"这种小地方,
# 而独立脚本里可以正常写、正常报错。
#
# 为什么 HTTP 源必须起在容器里:guest 访问的 10.0.2.2 是 QEMU 用户态网络的"网关",
# SLIRP 实际是让 **qemu 进程**去连它自己网络命名空间里的地址 —— qemu 跑在容器里,
# 所以服务也必须在容器里;宿主机上起的服务它够不着。
set -euo pipefail
cd "$(dirname "$0")/.."
REPO=$PWD   # 容器里是 /work,原生宿主上是仓库目录 —— 脚本内部一律用它定位

DRILL_BOOT_VERSION=${KEEL_DRILL_BOOT_VERSION:-2000.01.01.0001}
DRILL_PORT=${KEEL_DRILL_PORT:-8000}
DRILL_VM_TIMEOUT=${KEEL_DRILL_VM_TIMEOUT:-1500}
# 安装镜像放大到多大。v1 时代硬编码 40G —— 那时一份载荷 13 GiB,必须留足;
# erofs 之后一份载荷只有 ~1.1 GiB(实测),40G 是纯粹的浪费(guest 真写真占、
# 演练 qcow2 跟着长)。默认 24G 仍然很宽松,**下限 20G**(见 step 4 的算式:
# 布局 13 GiB + 基础 /data 占用 ~2.2 GiB + 两份载荷 ~2.2 GiB + 每次 fetch 的 2 GiB 余量)。
DRILL_IMAGE_SIZE=${KEEL_DRILL_IMAGE_SIZE:-24G}
DRILL_IMAGE_MIN_G=20
ROOTPW_ARGS=()
[ -n "${KEEL_ROOT_PASSWORD:-}" ] && ROOTPW_ARGS=("--root-password=$KEEL_ROOT_PASSWORD")

# 尺寸参数解析 + 下限检查。抽成函数是为了能**单独测**(tools/verify.sh 会把它原样抽出来
# 跑几个用例,而不是只用 grep 看字符串在不在):返回解析出的整数 GiB;不合法或低于下限返回非 0。
drill_image_gib() {
    local s=$1 n
    case "$s" in *G) n=${s%G} ;; *) return 1 ;; esac
    case "$n" in ''|*[!0-9]*) return 1 ;; esac
    [ "$n" -ge "$DRILL_IMAGE_MIN_G" ] || return 1
    printf '%s' "$n"
}

step() { printf '\n== %s ==\n' "$*"; }

step "1/7 静态校验"
tools/verify.sh

step "2/7 构建新版本载荷(tools/build.sh)"
# KEEL_EXTRA_PROFILES=test:**新槽里也必须有没有自检/状态机**,否则重启到新槽之后
# 状态机就断了(第一次演练就栽在这里:新槽是生产载荷,里面没有 keel-ota-drill,
# 于是 p1/p2 永远不会跑,VM 就停在 login 提示符上)。
env KEEL_EXTRA_PROFILES=test tools/build.sh
DRILL_PAYLOAD=$(ls -1d dist/keel-* 2>/dev/null | sort -V | tail -n1) || DRILL_PAYLOAD=""
[ -n "$DRILL_PAYLOAD" ] || { echo "错误:dist/ 下没有载荷目录" >&2; exit 1; }
echo "   载荷目录:$DRILL_PAYLOAD(版本 $(sed -n 's/^version=//p' "$DRILL_PAYLOAD/manifest" | head -n1))"

step "3/7 构建引导镜像(版本 $DRILL_BOOT_VERSION,必须旧于载荷)"
mkosi --profile install --profile test --image-version="$DRILL_BOOT_VERSION" \
      "${ROOTPW_ARGS[@]+"${ROOTPW_ARGS[@]}"}" --force build

step "4/7 把安装镜像放大到 $DRILL_IMAGE_SIZE(首启的 repart + resize2fs 会把 data 扩到整盘)"
if ! img_g=$(drill_image_gib "$DRILL_IMAGE_SIZE"); then
    echo "   错误:KEEL_DRILL_IMAGE_SIZE 不合法:'$DRILL_IMAGE_SIZE'(只接受整数 GiB,例如 20G / 24G)," >&2
    echo "         或者小于下限 ${DRILL_IMAGE_MIN_G}G。下限怎么来的(2026-09-26 被真事教育过):" >&2
    echo "           esp 1 + root-a 6 + root-b 6 = 13 GiB,剩下的全给 /data;" >&2
    echo "           首启后 /data 本身要占 ~2.2 GiB,演练要放**两份** erofs 载荷(各 ~1.1 GiB)," >&2
    echo "           而 os-update fetch 自己有 2 GiB 的可用空间硬下限 ⇒ 20 GiB 是实测能跑通的最小值。" >&2
    echo "         (想要更小,得先改布局常量或 fetch 的预算 —— 都不是这个变量能解决的。)" >&2
    exit 1
fi
# 用解析出来的值(而不是原始字符串)去 truncate:顺带把 `024G` 这类写法归一化。
truncate -s "${img_g}G" mkosi.output/keel.raw
ls -l mkosi.output/keel.raw | awk '{ print "   keel.raw = " $5 " 字节" }'

step "5/7 起本地 HTTP 源(guest 会访问 http://10.0.2.2:$DRILL_PORT/good)"
rm -rf /tmp/drill-serve
mkdir -p /tmp/drill-serve
ln -sfn "$REPO/$DRILL_PAYLOAD" /tmp/drill-serve/good
( cd /tmp/drill-serve && nohup python3 -m http.server "$DRILL_PORT" --bind 0.0.0.0 >/tmp/drill-http.log 2>&1 & )
sleep 2
# 用 python3 探测(容器里**没有 curl** —— 第一次就栽在这:mkosi 不依赖它)
python3 - "$DRILL_PORT" <<'PY'
import sys, urllib.request
port = sys.argv[1]
url = f"http://127.0.0.1:{port}/good/manifest"
try:
    with urllib.request.urlopen(url, timeout=5) as r:
        body = r.read()
    print(f"   本地源就绪:{url} → HTTP {r.status},{len(body)} 字节")
except Exception as e:  # noqa: BLE001
    print(f"   错误:本地源探测失败:{e}", file=sys.stderr)
    sys.exit(1)
PY

step "6/7 准备**坏载荷**(让某个槽真的起不来,验自动回滚)"
# 思路:坏载荷 = 好载荷的"镜像",只把**目标槽的根镜像**换成一个起不来的文件系统:
# 删掉 PID1(/usr/lib/systemd/systemd)与内核的 init 兜底(/bin/sh → dash、bash)
# ⇒ 内核找不到任何 init ⇒ panic ⇒ cmdline 里的 panic=-1 立即重启(决策 D24)
# ⇒ 下次启动回到持久默认(旧槽),keel-confirm 于是能判定"更新失败已回滚"。
#
# 演练里"目标槽"总是**另一个槽**:p2 阶段跑在槽 a 上,所以要用 slot-b 的产物。
# 大的根镜像用 cp --reflink(不行就普通复制);其余文件用符号链接,省 ~4 GiB 的拷贝。
BAD_SLOT=${KEEL_DRILL_BAD_SLOT:-b}
# 破坏方式(2026-09 实测两种,决策 D25 / 坑 #50):
#   userspace(默认)= 把根里的 default.target 换成**悬空符号链接** ⇒ 根里的 systemd 起来后
#       找不到默认目标 ⇒ 启动失败/进 emergency(挂住)⇒ **主系统的运行时看门狗**(已实测生效:
#       RuntimeWatchdogUSec=1min + /dev/watchdog0)到点复位 ⇒ 自动回退。这条链路 v1 能验证。
#   initrd = 删掉 PID1 与 init 兜底 ⇒ initrd 在 switch-root 时判"没有可用的 init"并**冻结**
#       (不 panic、不重启)。实测:机器挂住 650+ 秒没有被复位 ⇒ **v1 覆盖不到这种情况**
#       (initrd 里的看门狗没生效:配置没进去?还是没有 /dev/watchdog?待查,见 docs/roadmap.md 3.0)。
# 两种文件系统的**实现**不同(v1.1):erofs 走"解包 → 改树 → 重打包"(fsck.erofs/mkfs.erofs),
# ext4 走 debugfs 就地改;脚本按超级块魔数自己选,见下面 fs_kind()。
SABOTAGE=${KEEL_DRILL_SABOTAGE:-userspace}
rm -rf /tmp/drill-serve/bad
mkdir -p /tmp/drill-serve/bad
for f in "$REPO/$DRILL_PAYLOAD"/*; do
    b=$(basename "$f")
    [ "$b" = "manifest" ] && continue
    [ "$b" = "slot-$BAD_SLOT.root.raw" ] && continue
    ln -sfn "$f" "/tmp/drill-serve/bad/$b"
done
cp --reflink=auto --sparse=always "$REPO/$DRILL_PAYLOAD/slot-$BAD_SLOT.root.raw" \
   "/tmp/drill-serve/bad/slot-$BAD_SLOT.root.raw"
BAD_IMG=/tmp/drill-serve/bad/slot-$BAD_SLOT.root.raw

# ── 坏槽构造必须按**文件系统**选工具(v1.1:槽根已从 ext4 换成 erofs)────────────
# 认文件系统:erofs 的超级块在 offset 1024,小端魔数 0xE0F5E1E2(字节 e2 e1 f5 e0);
# ext4 的主超级块也在 1024,但它的魔数 0xEF53 在超级块内偏移 0x38(= 文件偏移 1080)。
# 认不出来就**明确失败** —— 猜错的代价是"产出一个根本没坏的载荷,回滚演练变假绿",
# 比直接失败坏得多(debugfs 打不开 erofs 也返回 0,坑 #47)。
fs_kind() {
    local magic
    magic=$(od -An -tx1 -j 1024 -N 4 "$1" 2>/dev/null | tr -d ' \n' || true)
    [ "$magic" = "e2e1f5e0" ] && { printf 'erofs'; return 0; }
    magic=$(od -An -tx1 -j 1080 -N 2 "$1" 2>/dev/null | tr -d ' \n' || true)
    [ "$magic" = "53ef" ] && { printf 'ext4'; return 0; }
    printf 'unknown'
}

# 缺什么装什么(容器路径下这些工具不一定在;做法与原来只装 e2fsprogs 一致)
install_if_missing() {
    command -v "$1" >/dev/null 2>&1 && return 0
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends "$2" >/dev/null 2>&1 || true
    command -v "$1" >/dev/null 2>&1
}

# ── ext4 路线:debugfs 就地改(历史路径,老载荷仍然走它)──────────────────────
sabotage_ext4() {
    install_if_missing debugfs e2fsprogs ||
        { echo "   错误:装不上 e2fsprogs(debugfs)" >&2; exit 1; }
    if [ "$SABOTAGE" = initrd ]; then
        for target in /usr/lib/systemd/systemd /usr/bin/dash /usr/bin/bash; do
            # 注意:**不要**只看 debugfs 的退出码 —— 它干什么都返回 0(坑 #47 实测)
            debugfs -w -R "rm $target" "$BAD_IMG" >/dev/null 2>&1 || true
        done
        # 回读确认真的删掉了:判据只能是**输出文本**(`File not found by ext2_lookup`),
        # 因为 `debugfs -R "stat …"` 对不存在的路径同样返回 0(实测)。
        for target in /usr/lib/systemd/systemd /usr/bin/dash /usr/bin/bash; do
            if debugfs -R "stat $target" "$BAD_IMG" 2>&1 | grep -q 'File not found'; then
                echo "   已确认删掉:$target"
            else
                echo "   错误:坏载荷里 $target 还在(或 debugfs 读不出来)⇒ 演练没有意义" >&2
                debugfs -R "stat $target" "$BAD_IMG" 2>&1 | tail -2 >&2
                exit 1
            fi
        done
    else
        # userspace:把 default.target 换成悬空符号链接(先删再建,保证内容是我们写的)
        debugfs -w -R "rm /etc/systemd/system/default.target" "$BAD_IMG" >/dev/null 2>&1 || true
        debugfs -w -R "symlink /etc/systemd/system/default.target /nonexistent-keel.target" "$BAD_IMG" >/dev/null 2>&1 || true
        # 回读:符号链接的目标必须是 /nonexistent-keel.target(同样只看输出,不看退出码)
        if debugfs -R "stat /etc/systemd/system/default.target" "$BAD_IMG" 2>&1 |
            grep -q 'nonexistent-keel.target'; then
            echo "   已确认:default.target -> /nonexistent-keel.target(用户态起不来)"
        else
            echo "   错误:坏载荷的 default.target 没换成悬空链接" >&2
            debugfs -R "stat /etc/systemd/system/default.target" "$BAD_IMG" 2>&1 | tail -3 >&2
            exit 1
        fi
    fi
}

# ── erofs 路线:解包 → 改树 → 重打包(2026-09 实测)────────────────────────────
# 为什么这么绕:erofs 是只读压缩镜像,没有 debugfs 那样的"就地改"工具。
# 这条路线**只用 erofs-utils,不需要 mount / loop**,所以容器路径也能跑(坑 #17 的教训:
# 别让校验/演练依赖 loop 设备)。
#
# 实测数据(2026-09-26,载荷 401 MiB):
#   fsck.erofs --extract  2.6 s,解出 440 MiB 的树;mkfs.erofs 重打包 0.5 s;
#   重打包后大小与原件相同(420,880,384 B),blkid 仍报 erofs,能正常挂载。
# 保真度:`fsck.erofs --extract` 对 root **保留 owner 与权限(含 setuid)** ——
#   实测解出来的 /usr/bin/sudo 是 -rwsr-xr-x。(早期笔记说"会丢 setuid"是错的:
#   那次是我自己在解包后又 chown,而 chown 本来就会清 setuid。)
#   xattr 默认不搬;坏载荷不需要文件能力(security.capability),所以刻意不加 --xattrs。
sabotage_erofs() {
    install_if_missing fsck.erofs erofs-utils ||
        { echo "   错误:装不上 erofs-utils(fsck.erofs / mkfs.erofs)" >&2; exit 1; }
    install_if_missing mkfs.erofs erofs-utils ||
        { echo "   错误:装不上 erofs-utils(mkfs.erofs)" >&2; exit 1; }

    local work tree check
    work=$(mktemp -d "${TMPDIR:-/tmp}/drill-erofs.XXXXXX")
    tree="$work/root"
    check="$work/check"
    mkdir -p "$tree"

    echo "   解包 erofs(不用 mount/loop)→ $tree"
    fsck.erofs --extract="$tree" "$BAD_IMG" >/dev/null 2>&1 ||
        { echo "   错误:fsck.erofs --extract 失败" >&2; rm -rf "$work"; exit 1; }

    if [ "$SABOTAGE" = initrd ]; then
        for t in usr/lib/systemd/systemd usr/bin/dash usr/bin/bash; do
            rm -f "$tree/$t"
            [ -e "$tree/$t" ] && { echo "   错误:$t 没删掉" >&2; rm -rf "$work"; exit 1; }
            echo "   已确认删掉:/$t"
        done
    else
        rm -f "$tree/etc/systemd/system/default.target"
        ln -s /nonexistent-keel.target "$tree/etc/systemd/system/default.target"
        if [ "$(readlink "$tree/etc/systemd/system/default.target")" = "/nonexistent-keel.target" ]; then
            echo "   已确认:default.target -> /nonexistent-keel.target(用户态起不来)"
        else
            echo "   错误:default.target 没换成悬空链接" >&2; rm -rf "$work"; exit 1
        fi
    fi

    echo "   重打包 mkfs.erofs"
    mkfs.erofs "$BAD_IMG" "$tree" >/dev/null 2>&1 ||
        { echo "   错误:mkfs.erofs 重打包失败" >&2; rm -rf "$work"; exit 1; }

    # 回读:重新解包**产物镜像**,确认破坏真的落在镜像里(而不是只落在临时树上)。
    mkdir -p "$check"
    fsck.erofs --extract="$check" "$BAD_IMG" >/dev/null 2>&1 ||
        { echo "   错误:坏镜像解不开(重打包坏了)⇒ 演练没有意义" >&2; rm -rf "$work"; exit 1; }
    if [ "$SABOTAGE" = initrd ]; then
        for t in usr/lib/systemd/systemd usr/bin/dash usr/bin/bash; do
            [ -e "$check/$t" ] && { echo "   错误:坏镜像里 $t 还在" >&2; rm -rf "$work"; exit 1; }
        done
        echo "   回读确认:坏镜像里 PID1 与 init 兜底都已不存在"
    else
        [ "$(readlink "$check/etc/systemd/system/default.target")" = "/nonexistent-keel.target" ] ||
            { echo "   错误:坏镜像里的 default.target 不是悬空链接" >&2; rm -rf "$work"; exit 1; }
        echo "   回读确认:坏镜像里 default.target -> /nonexistent-keel.target"
    fi
    rm -rf "$work"
}

FS_KIND="$(fs_kind "$BAD_IMG")"
echo "   槽载荷的文件系统:$FS_KIND"
case "$FS_KIND" in
erofs) sabotage_erofs ;;
ext4)  sabotage_ext4 ;;
*)
    echo "   错误:认不出槽载荷的文件系统(既不是 erofs 也不是 ext4)⇒ 拒绝猜。" >&2
    echo "        猜错会产出一个'根本没坏'的载荷,回滚演练就成了假绿。看上面 fs_kind 的判据。" >&2
    exit 1
    ;;
esac
echo "   已把 slot-$BAD_SLOT.root.raw 做成起不来的(破坏方式:$SABOTAGE,回读已确认)"
# manifest:版本比好载荷再高一档(否则 stage 会说"不比当前新"),并把被改过的那个产物的
# sha256 换成新值 —— 其余行为原样复制(其余产物是符号链接,内容没变)
GOOD_VER=$(sed -n 's/^version=//p' "$REPO/$DRILL_PAYLOAD/manifest" | head -n1)
BAD_SHA=$(sha256sum "$BAD_IMG" | cut -d' ' -f1)
sed -e "s/^version=.*/version=${GOOD_VER}.bad/" \
    -e "s|^sha256_slot-$BAD_SLOT.root.raw=.*|sha256_slot-$BAD_SLOT.root.raw=$BAD_SHA|" \
    "$REPO/$DRILL_PAYLOAD/manifest" >/tmp/drill-serve/bad/manifest
echo "   坏载荷版本:${GOOD_VER}.bad(slot-$BAD_SLOT.root.raw 的 sha256 已更新)"

# 再做一个"声明了 /data 迁移"的载荷:它的产物都是符号链接(内容没变),只是 manifest 里
# `migrate=` 非空。v1 没有迁移执行器 ⇒ os-update fetch **必须拒绝**它(这一项也在演练里验)。
rm -rf /tmp/drill-serve/mig
mkdir -p /tmp/drill-serve/mig
for f in "$REPO/$DRILL_PAYLOAD"/*; do
    b=$(basename "$f")
    [ "$b" = "manifest" ] && continue
    ln -sfn "$f" "/tmp/drill-serve/mig/$b"
done
sed -e "s/^version=.*/version=${GOOD_VER}.mig/" \
    -e 's/^migrate=.*/migrate=mkdir:\/data\/keel\/migtest:0755/' \
    "$REPO/$DRILL_PAYLOAD/manifest" >/tmp/drill-serve/mig/manifest
echo "   迁移载荷版本:${GOOD_VER}.mig(manifest 里 migrate=mkdir:/data/keel/migtest:0755)"

# 额外的一次"回读确认":看门狗配置**必须真的进了 initrd**(否则坏槽冻结时没人复位,
# 演练会卡死在黑屏 —— 坑 #50 的现场)。这里直接从 UKI 里抽 .initrd 出来查文件名。
if command -v objcopy >/dev/null 2>&1 || apt-get install -y -qq --no-install-recommends binutils >/dev/null 2>&1; then
    if objcopy -O binary --only-section=.initrd "$REPO/mkosi.output/keel.efi" /tmp/keel-initrd.bin 2>/dev/null &&
       [ -s /tmp/keel-initrd.bin ]; then
        if command -v zstd >/dev/null 2>&1 || apt-get install -y -qq --no-install-recommends zstd >/dev/null 2>&1; then :; fi
        if zstd -d -c /tmp/keel-initrd.bin >/tmp/keel-initrd.cpio 2>/dev/null ||
           cp /tmp/keel-initrd.bin /tmp/keel-initrd.cpio; then :; fi
        if command -v cpio >/dev/null 2>&1 || apt-get install -y -qq --no-install-recommends cpio >/dev/null 2>&1; then :; fi
        if cpio -t < /tmp/keel-initrd.cpio 2>/dev/null | grep -q 'keel-watchdog'; then
            echo "   initrd 里确认有 keel-watchdog.conf(冻结时看门狗能复位)"
        else
            echo "   警告:在 initrd 里没找到 keel-watchdog.conf —— 坏槽冻结时不会被复位,演练可能卡死" >&2
        fi
    else
        echo "   警告:抽不出 .initrd(跳过这项检查)" >&2
    fi
fi

step "7/7 起 VM(演练状态机自己跑;p3 结束时会 poweroff,所以这次 VM 会自己退出)"
set +e
timeout "$DRILL_VM_TIMEOUT" mkosi --profile install --profile test \
    "${ROOTPW_ARGS[@]+"${ROOTPW_ARGS[@]}"}" vm
rc=$?
set -e
if [ "$rc" = 124 ]; then
    echo "   注意:VM 到了 ${DRILL_VM_TIMEOUT}s 超时上限被结束 —— 演练可能卡在某个阶段,"
    echo "         把上面控制台输出里最后一段 keel-ota-drill[...] 的内容发出来。"
else
    echo "   VM 退出码:$rc(0 = 演练跑到 p2 并自己 poweroff)"
fi
