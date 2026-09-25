#!/usr/bin/env bash
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
#   sudo tools/build-container.sh                  # 只构建(verify + build.sh)
#   sudo tools/build-container.sh vm               # 构建并在容器里起 QEMU(有 /dev/kvm 就自动传进去)
#   sudo tools/build-container.sh -p <密码> vm     # 同上,并给镜像里的 admin 设这个初始密码
#   sudo tools/build-container.sh --profile desktop# 叠加变体 profile(和 build.sh 一模一样)
#   sudo tools/build-container.sh shell            # 进容器手敲 mkosi,便于排错
#   sudo tools/build-container.sh vm -- --console=gui
#                                                  # -- 之后的参数原样交给 mkosi
#                                                  # (**build 与 vm 两次调用都带**:mkosi 的 vm 只读
#                                                  #  上一次 build 的 history,只给一次等于没给)
#                                                  # 注意:QEMU 自己的参数(如 `-m 4G`)不能从这里走 ——
#                                                  #  mkosi 的 `build` 不接受动词后的参数、会直接报错;
#                                                  #  要加 QEMU 参数就用 `shell` 模式手敲两条 mkosi 命令
#
#   -p / --password <密码>  给 **admin** 设初始密码(mkosi 的 `--root-password=`;
#     它在 finalize 里被搬给 admin,root 则被锁定 —— 决策 D21)。
#     不加就是没有密码 —— 正式产物默认就是"root 锁定 + 只认 SSH 公钥"(见 docs/install.md §2.5)。
#     密码只从命令行来,不落盘、不进 git:这是个公开仓库,写在 profile 里的密码等于公开的。
#     三种模式都收这个参数:`build` 时经 `KEEL_ROOT_PASSWORD` 转给 tools/build.sh,
#     `vm` 时直接拼到 mkosi 命令行上(而且**必须同时拼进 build 与 vm 两次调用**,
#     因为 `vm` 不解析配置、只读上一次 build 的 history,见 docs/traps.md 坑 #30)。
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
#   * 直接 `sudo tools/build-container.sh` 就行,不需要 `sudo bash …`:仓库脚本的 shebang
#     统一是 `#!/usr/bin/env bash`(NixOS 没有 /bin/bash 这件事在 2026-09 修掉了,见坑 #54)。
#   * **已在 NixOS 上实测**(2026-09:构建、libvirt 装机、OTA 演练都在 NixOS 宿主上跑过)。
#   * 与原生路径 tools/build.sh 的选项**必须一致**:共用选项定义在 tools/lib-build-cli.sh,
#     改一边等于改两边;能力差异只允许在 AGENTS.md 那张对照表里(容器独有:drill / shell)。
set -euo pipefail
cd "$(dirname "$0")/.."

log() { printf 'keel-container: %s\n' "$*" >&2; }
die() { printf 'keel-container: 错误:%s\n' "$*" >&2; exit 1; }
usage() {
    cat >&2 <<'EOF'
用法:sudo tools/build-container.sh [build|vm|drill|shell] [-p <密码>] [--profile <名字>]… [-- <mkosi 的额外参数>]

  build            只构建(tools/build.sh 会先跑 verify),默认动作
  vm               构建并在容器里起 QEMU(有 /dev/kvm 就自动传进去)
  drill            **OTA 演练**:构建新版本载荷 + 引导镜像,起本地 HTTP 源,在 VM 里
                   自动跑 check → fetch → stage → 重启 → 确认 → rollback → 重启(见 docs/update.md §9)
  shell            进容器手敲 mkosi,便于排错(容器独有:原生路径没有这个模式)

  共用选项(与 tools/build.sh 完全一致,定义在 tools/lib-build-cli.sh):
EOF
    keel_cli_usage_common
}

# 参数解析:共用选项(-p/--password/--profile/--vm/-h/--)走 tools/lib-build-cli.sh
# (和原生路径同一份实现,免得两边漂移),本脚本只额外多一个"模式"位置参数。
# shellcheck source=tools/lib-build-cli.sh
# shellcheck disable=SC1091
. "$(dirname "$0")/lib-build-cli.sh"

# 共用选项(-p/--password、--profile、--vm、-h、--`)走 tools/lib-build-cli.sh ——
# **和原生路径同一份实现**;本脚本只额外多一个"模式"位置参数(build|vm|drill|shell)。
# shellcheck source=tools/lib-build-cli.sh
# shellcheck disable=SC1091
. "$(dirname "$0")/lib-build-cli.sh"

keel_cli_parse "$@" || { usage; exit 2; }
[ "$KEEL_HELP" = 1 ] && { usage; exit 0; }
[ "$KEEL_PASSWORD_SET" = 1 ] && [ -z "$KEEL_PASSWORD" ] && { usage; die "-p/--password 后面是空的:要么给个密码,要么别加这个选项"; }

# 位置参数 = 模式(最多一个);`--vm` 是共用选项,在这里等价于 `vm` 模式。
MODE=build
if [ ${#KEEL_POSITIONAL[@]} -gt 1 ]; then
    usage; die "只接受一个模式参数(收到:${KEEL_POSITIONAL[*]})"
elif [ ${#KEEL_POSITIONAL[@]} -eq 1 ]; then
    MODE=${KEEL_POSITIONAL[0]}
fi
[ "$KEEL_VM" = 1 ] && MODE=vm
[ "$KEEL_DRILL" = 1 ] && MODE=drill

case "$MODE" in
    build|vm|drill|shell) ;;
    *) usage; die "模式只能是 build / vm / drill / shell(收到 '$MODE')" ;;
esac
PASSWORD=$KEEL_PASSWORD
EXTRA_MKOSI=(${KEEL_EXTRA_MKOSI[@]+"${KEEL_EXTRA_MKOSI[@]}"})
# 额外 profile(变体):合并 --profile 与 KEEL_EXTRA_PROFILES,并按**环境变量**送进容器 ——
# 容器里的 tools/build.sh 读的正是它(以前这一步漏了 ⇒ NixOS 那条路根本加不了 profile)。
EXTRA_PROFILES=$(keel_cli_extra_profiles)

ENGINE=""
for e in podman docker; do
    if command -v "$e" >/dev/null 2>&1; then ENGINE=$e; break; fi
done
[ -n "$ENGINE" ] || die "找不到 podman 或 docker。NixOS 上可以:nix-shell -p podman;或把 virtualisation.podman.enable 打开"

IMAGE=${KEEL_BUILD_IMAGE:-docker.io/library/debian:trixie}

# OTA 演练(drill 模式)用:引导镜像的版本必须**旧于**载荷版本,所以写死一个远古时间戳;
# 端口是 guest 从 10.0.2.2 访问的那个(容器内起 HTTP 服务)。
DRILL_BOOT_VERSION=${KEEL_DRILL_BOOT_VERSION:-2000.01.01.0001}
DRILL_PORT=${KEEL_DRILL_PORT:-8000}

# root 初始密码只从命令行来(不落盘、不进 git)。回显密码是**不安全**的,所以日志里只说有没有设。
#
# ROOTPW_Q 是"给容器里那个 shell 用"的、已经转义好的形式(printf %q):PAYLOAD 是一段要被
# `bash -lc` 执行的字符串,密码里若有空格/引号,直接拼进去就会碎成两个参数。
ROOTPW_Q=""
if [ -n "$PASSWORD" ]; then
    ROOTPW_Q=$(printf '%q' "--root-password=$PASSWORD")
    log "root 初始密码:已设置(只存在于本次构建,不回显、不落盘)"
else
    log "初始密码:未设置 —— admin 与 root 都没有密码(要登录请加 -p <密码>,或放 authorized_keys 用 SSH 公钥)"
fi

# EXTRA_MKOSI 是用户从 `--` 之后传给 mkosi 的额外参数,同样逐个转义后再拼进 PAYLOAD
EXTRA_Q=""
if [ ${#EXTRA_MKOSI[@]} -gt 0 ]; then
    for a in "${EXTRA_MKOSI[@]}"; do EXTRA_Q+="$(printf '%q' "$a") "; done
fi

case "$MODE" in
build) PAYLOAD='tools/build.sh' ;;   # build.sh 内部会先跑 tools/verify.sh(别跑两遍)
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
    # 就返回成功、什么都不建,随后 vm 打开的是**上一次构建的旧镜像**(真机上踩过,见坑 #23)。
    #
    # $ROOTPW_Q 在两处都出现不是重复:mkosi 的 `vm` **不解析配置文件**,它读的是
    # `.mkosi-private/history/latest.json`(上一次 build 用的配置);命令行上与 history 不同的
    # Content 段设置只会打一行 `Ignoring --root-password from the CLI`,然后照 history 走
    # ⇒ 只在 vm 那一步传密码等于没传,而且不报错。见 docs/traps.md 坑 #30。
    # 额外 profile(变体/演练)拆成 mkosi 的 --profile 参数:和原生路径 build.sh 一致。
    EXTRA_PROFILE_Q=""
    for _p in $EXTRA_PROFILES; do
        EXTRA_PROFILE_Q+="--profile $(printf '%q' "$_p") "
    done
    PAYLOAD="tools/verify.sh \
        && mkosi --profile install --profile test $EXTRA_PROFILE_Q$EXTRA_Q$ROOTPW_Q --force build \
        && mkosi --profile install --profile test $EXTRA_PROFILE_Q$EXTRA_Q$ROOTPW_Q vm"
    ;;
# 刻意**没有** ssh 模式。曾经加过 `mkosi ssh`(VSock),但:
#   1. 控制台密码登录已经可用(`-p`,见 mkosi.profiles/test.conf),进虚拟机的需求已经满足;
#   2. mkosi 25.3 的 run_ssh 会去 flock $XDG_RUNTIME_DIR/mkosi/machine,而容器里的
#      /run/mkosi 不存在 ⇒ FileNotFoundError: '/run/mkosi/machine'(实测)。
# 真机上的 SSH 是另一回事(sshd + 公钥,见 docs/install.md §2.5),不受这里影响。
drill)
    # OTA 演练的编排在 tools/ota-drill-container.sh 里(容器内运行,见那个脚本头部的说明)。
    # 这里只负责把容器起起来、把密码从环境变量带进去(KEEL_ROOT_PASSWORD 由上面的 -e 传)。
    PAYLOAD='bash tools/ota-drill-container.sh'
    ;;
shell) PAYLOAD='exec bash' ;;
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
# 详见 mkosi.conf 里那段注释和 docs/traps.md 坑 #22。
WS="$PWD/mkosi.workspace"
mkdir -p "$WS" && chmod 1777 "$WS" || die "无法创建 $WS"

ARGS=(run --rm -it --privileged -v "$PWD:/work" -v "$WS:/var/tmp" -w /work)
[ -e /dev/kvm ] && ARGS+=(--device /dev/kvm)
# root 初始密码也以环境变量传进容器:`build` 模式里跑的是 tools/build.sh,它从
# KEEL_ROOT_PASSWORD 里取(命令行参数不经过 build.sh ⇒ 只能用环境变量)。
# `vm` 模式则用它拼 mkosi 命令行(见上面的 $ROOTPW_Q);两处都设上,`shell` 模式里手敲 mkosi 也能用。
[ -n "$PASSWORD" ] && ARGS+=(-e "KEEL_ROOT_PASSWORD=$PASSWORD")
# 额外 profile 也透传:容器里的 build 模式跑的是 tools/build.sh,它从 KEEL_EXTRA_PROFILES 取。
# (2026-09 审计发现这里以前只传了密码 ⇒ NixOS 那条路上根本加不了 --profile / desktop / test。)
[ -n "$EXTRA_PROFILES" ] && ARGS+=(-e "KEEL_EXTRA_PROFILES=$EXTRA_PROFILES")
# 演练参数也传进去(容器里的 tools/ota-drill-container.sh 读它们);从宿主覆盖:
#   KEEL_DRILL_PORT=9000 sudo tools/build-container.sh drill
ARGS+=(-e "KEEL_DRILL_BOOT_VERSION=$DRILL_BOOT_VERSION" -e "KEEL_DRILL_PORT=$DRILL_PORT")
log "引擎:$ENGINE   镜像:$IMAGE   模式:$MODE${EXTRA_PROFILES:+   额外 profile:$EXTRA_PROFILES}"
[ "$(id -u)" = 0 ] || log "提示:没在用 root 跑。若报权限错误,请加 sudo(mkosi 的沙箱需要 CAP_SYS_ADMIN)"
log "产物会落在宿主机的 mkosi.output/ 与 dist/(属主是 root)"

exec "$ENGINE" "${ARGS[@]}" "$IMAGE" \
    bash -lc "$PROVISION"'
if [ -d /work/.git ]; then git config --global --add safe.directory /work 2>/dev/null || true; fi
cd /work
'"$PAYLOAD"
