#!/bin/bash
# keel:在不被 mkosi 支持的宿主上构建(典型场景:NixOS)
#
# ── 为什么需要这个脚本 ─────────────────────────────────────────────
# mkosi 要求**宿主本身**是它支持的发行版(它认 dnf/apt/pacman/zypper)。
# 因为它要用宿主自带的包管理器先建出一棵 tools tree —— apt、ukify、repart、qemu
# 全都在那棵树里 —— 再用那棵树去构建目标镜像(Debian)。
# NixOS 不在支持列表里,于是你会看到:
#
#   ‣ Distribution of your host can't be detected or isn't a supported target.
#     Defaulting to Distribution=custom.
#   ‣ Default tools tree requested but it is out-of-date or has not been built yet
#
# 第一行只是"镜像 Distribution 的默认值"取不到,**可以忽略**
# (我们的 mkosi.conf 已经显式写了 Distribution=debian);
# 第二行才是真正的拦路虎:建不出 tools tree,就没法把 Debian 包装进镜像。
# 这不是配置能绕过去的 —— 构建 Debian 镜像本质上需要一个 Debian 系的包管理器。
#
# ── 解法 ───────────────────────────────────────────────────────────
# 把一个受支持发行版的容器当宿主。默认用 debian:trixie:
#   - 它有 mkosi 25.3(满足我们 mkosi.conf 里的 MinimumVersion=25)
#   - 它和目标是同一个发行版,tools tree 也走同一条路径
#   - qemu/OVMF **不用装**:mkosi 建 tools tree 时会按需带上(vm 的 runtime profile)
#
# ── 用法(在仓库根目录)───────────────────────────────────────────
#   sudo tools/build-container.sh            # 只构建(verify + build.sh)
#   sudo tools/build-container.sh vm         # 构建并在容器里起 QEMU(有 /dev/kvm 就自动传进去)
#   sudo tools/build-container.sh shell      # 进容器手敲 mkosi,便于排错
#   sudo tools/build-container.sh vm -- --profile install --profile test
#                                            # -- 之后的参数原样交给 mkosi
#
#   换镜像(比如 Debian 25.3 的 mkosi 不认某个设置时):
#   KEEL_BUILD_IMAGE=docker.io/library/archlinux:latest sudo tools/build-container.sh
#
# ── 注意事项 ───────────────────────────────────────────────────────
#   * 需要 root(或 rootful 的 podman/docker):mkosi 的构建沙箱要 CAP_SYS_ADMIN。
#     因此 mkosi.output/ 里产出的文件会属于 root —— 这是正常的。
#     --privileged 同时会把宿主机的 /dev 暴露进容器,于是 repart 看得见 loop 设备;
#     mkosi 默认走 offline 模式不会碰它们(我们在 mkosi.conf 里也显式写了 RepartOffline=yes)。
#   * NixOS 上若没有容器引擎:`nix-shell -p podman` 或开 virtualisation.podman。
#   * 这个脚本**没有在 NixOS 上实测过**(开发环境里没有容器引擎)。
#     如果它在你的机器上出问题,把命令与报错贴出来即可。
set -euo pipefail
cd "$(dirname "$0")/.."

log() { printf 'keel-container: %s\n' "$*" >&2; }
die() { printf 'keel-container: 错误:%s\n' "$*" >&2; exit 1; }

MODE=${1:-build}
if [ "$MODE" = "--" ]; then MODE=build; set -- build "$@"; shift; fi
shift || true
EXTRA_MKOSI=("$@")

ENGINE=""
for e in podman docker; do
    if command -v "$e" >/dev/null 2>&1; then ENGINE=$e; break; fi
done
[ -n "$ENGINE" ] || die "找不到 podman 或 docker。NixOS 上可以:nix-shell -p podman;或把 virtualisation.podman.enable 打开"

IMAGE=${KEEL_BUILD_IMAGE:-docker.io/library/debian:trixie}

case "$MODE" in
build) PAYLOAD='tools/verify.sh && tools/build.sh' ;;
vm)
    # 必须先 build 再 vm,原因见 mkosi 源码里的那道守卫:
    #     if tools and not have_cache(tools):
    #         if (args.rerun_build_scripts or args.verb != Verb.build) and args.force == 0:
    #             die("Default tools tree requested but it is out-of-date or has not been built yet")
    # 也就是说:**只有 build 这个动作会自动把 tools tree 建出来**;
    # 用 vm 而 tools tree 还没建时,mkosi 直接拒绝(而不是顺手帮你建)。
    # 第一次会慢(tools tree + 全部软件包),之后两步都会命中缓存。
    #
    # build 那一步必须带 --force:mkosi 的 `build` 是"没有才建" —— 产物已存在时它只打印一行
    #   ‣ Output path /work/mkosi.output/keel.raw exists already. (Use --force to rebuild.)
    # 就返回成功、什么都不建。而 --profile test 是**改变了配置**的(设 root 测试密码),
    # 少了 -f 就会拿着"上一次构建的、没有登录凭据的"旧镜像去开虚拟机(真机上踩过,坑 #23)。
    # --profile test 只给 root 一个已知的测试密码(仅虚拟机用,见 mkosi.profiles/test.conf)
    EXTRA="${EXTRA_MKOSI[*]:-}"
    PAYLOAD="tools/verify.sh \
        && mkosi --profile install --profile test $EXTRA --force build \
        && mkosi --profile install --profile test $EXTRA vm"
    ;;
# 进一个**已经在跑**的虚拟机。mkosi 的 ssh 走 VSock(不经过 guest 的网络栈),
# 所以在 guest 里 systemd-networkd 还没配好网络时也能用 —— 虚拟机里那条
# "Failed to configure DHCPv4 client: Package not installed" 就是这种情况。
# 前提:
#   1. 宿主机有 /dev/vsock(没有的话下面会提示,guest 里 sshd-vsock.socket 是 listen 状态);
#   2. 虚拟机是**同一个 mkosi 状态**起来的 —— mkosi 把 VM 的 SSH 私钥和 CID 记在
#      mkosi.output/ 里(仓库内、容器之间共享 ✓),但 QEMU 进程必须还活着。
#      所以别用前台 `vm` 模式开虚拟机,用 vm-bg(它在后台容器里跑,退出终端也不死)。
ssh) PAYLOAD="mkosi --profile install --profile test ssh" ;;
# 后台起虚拟机:容器 -d 常驻,于是可以从另一个终端 build-container.sh ssh 进去
vm-bg)
    PAYLOAD="tools/verify.sh \
        && mkosi --profile install --profile test ${EXTRA_MKOSI[*]:-} --force build \
        && mkosi --profile install --profile test ${EXTRA_MKOSI[*]:-} vm --console=headless"
    ;;
shell) PAYLOAD='exec bash' ;;
*) die "用法:$0 [build|vm|vm-bg|ssh|shell] [-- mkosi 的额外参数]" ;;
esac

# 容器里的准备工作:只装 mkosi 本体与它必须的伙伴。
# 刻意用 --no-install-recommends:qemu/OVMF 由 mkosi 自己建的 tools tree 提供,
# 不必污染容器。
PROVISION='
set -e
export DEBIAN_FRONTEND=noninteractive
if ! command -v mkosi >/dev/null 2>&1; then
    echo "keel-container: 容器内安装 mkosi ..." >&2
    apt-get update -qq
    # shellcheck 也装上:tools/verify.sh 第 5 项要用它,不然那项会被跳过
    apt-get install -y -qq --no-install-recommends \
        mkosi bubblewrap ca-certificates git shellcheck
fi
'

# 把宿主机仓库里的 mkosi.workspace/ 绑到容器的 /var/tmp 上。
# mkosi 的默认 workspace 是 /var/tmp/mkosi-workspace-*(见 config.workspace_dir_or_default),而
# 容器自己的 /var/tmp 与 bind 进来的 mkosi.output/ 不是同一个文件系统 ⇒ 收尾时 rename 失败,
# 降级成"复制"(日志里一堆 "Could not rename ... falling back to copying"),增量缓存也只能复制、
# 不能 reflink/hardlink。绑过来之后 workspace、产物、缓存都在宿主机的同一个文件系统上。
#
# 为什么不用 mkosi.conf 里的 WorkspaceDirectory= 达到同样目的(曾经那么写,构建直接失败):
# mkosi 不允许 workspace 位于任何 BuildSources 之内,而 BuildSources 的默认值就是配置目录本身。
# 详见 mkosi.conf 里那段注释和 AGENTS.md 坑 #22。
WS="$PWD/mkosi.workspace"
mkdir -p "$WS" && chmod 1777 "$WS" || die "无法创建 $WS"

ARGS=(run --rm -it --privileged -v "$PWD:/work" -v "$WS:/var/tmp" -w /work)
[ -e /dev/kvm ] && ARGS+=(--device /dev/kvm)
# VSock:mkosi 的 `ssh` 走它(不经过 guest 的网络栈,所以 guest 里 DHCP 坏着也能进)
if [ -e /dev/vsock ]; then
    ARGS+=(--device /dev/vsock)
else
    log "提示:宿主机没有 /dev/vsock(加载 vhost_vsock / vmw_vsock_virtio_transport 后会有),ssh 模式可能进不去 —— 用控制台密码登录"
fi
# vm-bg:后台常驻容器(不带 --rm/-it)。QEMU 不随终端退出而死,才能从另一个终端用 ssh 模式进去。
if [ "$MODE" = vm-bg ]; then
    ARGS=(run -d --name keel-vm --privileged -v "$PWD:/work" -v "$WS:/var/tmp" -w /work)
    [ -e /dev/kvm ] && ARGS+=(--device /dev/kvm)
    [ -e /dev/vsock ] && ARGS+=(--device /dev/vsock)
fi

log "引擎:$ENGINE   镜像:$IMAGE   模式:$MODE"
[ "$(id -u)" = 0 ] || log "提示:没在用 root 跑。若报权限错误,请加 sudo(mkosi 的沙箱需要 CAP_SYS_ADMIN)"
log "产物会落在宿主机的 mkosi.output/ 与 dist/(属主是 root)"

exec "$ENGINE" "${ARGS[@]}" "$IMAGE" \
    bash -lc "$PROVISION"'
if [ -d /work/.git ]; then git config --global --add safe.directory /work 2>/dev/null || true; fi
cd /work
'"$PAYLOAD"
