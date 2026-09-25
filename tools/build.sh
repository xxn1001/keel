#!/usr/bin/env bash
# keel 产物构建:一次跑三个 profile,组装出 dist/keel-<version>/
#
# 产物(docs/architecture.md §6):
#   dist/keel-<version>/keel.raw          安装镜像(esp + root-a + 空 root-b + volume)
#   dist/keel-<version>/slot-a.root.raw   A 槽根分区镜像(写进 /dev/disk/by-partlabel/root-a)
#   dist/keel-<version>/slot-a.uki.efi    A 槽 UKI(放到 ESP 的 EFI/Linux/keel-a.efi)
#   dist/keel-<version>/slot-b.root.raw
#   dist/keel-<version>/slot-b.uki.efi
#   dist/keel-<version>/manifest          os-update 消费的 key=value 清单(含 sha256)
#
# 这是**原生路径**(宿主本身是 mkosi 支持的发行版,例如 Debian/Ubuntu/Fedora/Arch/CachyOS)。
# 宿主不被 mkosi 支持时(NixOS 等)走适配器 tools/build-container.sh ——
# 两条路径的选项必须一致,选项本身定义在 tools/lib-build-cli.sh 里(见 AGENTS.md 那张对照表)。
#
# 用法:
#   sudo tools/build.sh                       # 构建(先跑 tools/verify.sh)
#   sudo tools/build.sh -p <密码>             # 给 admin 设一个初始密码(临时测试用)
#   sudo tools/build.sh --profile desktop     # 叠加一个变体 profile
#   sudo tools/build.sh --vm                  # 构建完直接在 QEMU 里起一遍(等价容器的 vm 模式)
#   sudo tools/build.sh -- --console=gui      # `--` 之后原样交给 mkosi
#
# 版本号来自可执行的 mkosi.version(时间戳),见 docs/architecture.md §6。
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=mkosi.output
DIST=dist

log() { printf 'keel-build: %s\n' "$*" >&2; }
die() { printf 'keel-build: 错误:%s\n' "$*" >&2; exit 1; }
usage() {
    cat >&2 <<'EOF'
用法:sudo tools/build.sh [-p <密码>] [--profile <名字>]… [--vm] [-- <mkosi 的额外参数>]

  (无)                    构建安装镜像 + A/B 载荷 → dist/keel-<版本>/
  --vm                    构建完之后用 mkosi 起一遍 QEMU(需要 /dev/kvm)
  --drill                 跑一遍完整的 OTA 演练(等价容器的 drill 模式)
EOF
    keel_cli_usage_common
}

# shellcheck source=tools/lib-build-cli.sh
# shellcheck disable=SC1091
. "$(dirname "$0")/lib-build-cli.sh"
keel_cli_parse "$@" || { usage; exit 2; }
[ "$KEEL_HELP" = 1 ] && { usage; exit 0; }
[ ${#KEEL_POSITIONAL[@]} -eq 0 ] || { usage; die "不认识的位置参数:${KEEL_POSITIONAL[*]}"; }

MODE=build
[ "$KEEL_VM" = 1 ] && MODE=vm
[ "$KEEL_DRILL" = 1 ] && MODE=drill

# 宿主判定:用 /etc/os-release,不靠"上次那台机器是什么"(见 lib-build-cli.sh 的说明)
if ! command -v mkosi >/dev/null 2>&1; then
    die "没装 mkosi。$(keel_host_hint)"
fi
[ "$(id -u)" = 0 ] || log "提示:没在用 root 跑。mkosi 的构建沙箱需要 CAP_SYS_ADMIN,报权限错误就加 sudo"

# OTA 演练走**和容器 drill 模式同一份**编排脚本(tools/ota-drill-container.sh:名字里的
# container 是历史原因,它用 cwd 定位仓库、不假设自己在容器里)。它自己会跑静态校验、
# 自己构建"旧版本引导镜像 + 新版本载荷",所以这里直接交出去,不要先做普通构建。
if [ "$MODE" = drill ]; then
    [ -f tools/ota-drill-container.sh ] || die "找不到 tools/ota-drill-container.sh(演练编排脚本)"
    log "交给 OTA 演练编排:tools/ota-drill-container.sh"
    exec bash tools/ota-drill-container.sh
fi

# 先跑静态校验,别把明显的问题带到真机构建里
if [ -x tools/verify.sh ]; then
    log "先跑静态校验(tools/verify.sh)"
    tools/verify.sh || die "静态校验没过,先修好再来构建"
fi

# 版本号来自可执行的 mkosi.version(打印时间戳),不用 -B 自动 bump:
# 那会改写一个被 git 跟踪的文件 ⇒ 工作区变脏、git pull 冲突(真机上踩过)。
VERSION=$(./mkosi.version 2>/dev/null | head -1)
[ -n "$VERSION" ] || die "mkosi.version 没有输出(它应该是一个可执行脚本,打印版本号)"
log "本次版本:$VERSION"

# 初始密码(可选,默认没有 = admin 与 root 都没有密码;给了就归 admin,root 仍锁定 —— 决策 D21)。
# 口令只从命令行/环境变量来 —— 这是公开仓库,配置里硬编码的密码等于公开的,所以**不写进 mkosi.conf**。
#   tools/build.sh -p <密码>                      ← 原生路径(推荐)
#   KEEL_ROOT_PASSWORD='...' sudo tools/build.sh  ← 环境变量,容器适配器就是用这条传进来的
# mkosi 的 `RootPassword=` 先落到 root(shadow + credstore credential),再由 mkosi.finalize
# 搬给 admin、锁掉 root、删掉那份 credential —— 和真机用仓库根目录 mkosi.rootpw 是**同一条路径**。
# 注意:带到 dist/ 里的密码只适合临时测试;正式产物请改用 authorized_keys(SSH 公钥)。
ROOTPW_ARGS=()
PASSWORD=${KEEL_PASSWORD:-${KEEL_ROOT_PASSWORD:-}}
[ "$KEEL_PASSWORD_SET" = 1 ] && [ -z "$KEEL_PASSWORD" ] && die "-p/--password 后面是空的:要么给个密码,要么别加这个选项" 
if [ -n "$PASSWORD" ]; then
    ROOTPW_ARGS=("--root-password=$PASSWORD")
    log "初始密码:已设置(只存在于本次构建,不回显、不落盘;root 仍然锁定,密码归 admin)"
    log "警告:产物里带 admin 初始密码 —— 临时测试可以,装到自己机器上的正式产物请改用 authorized_keys"
else
    log "初始密码:未设置 —— admin 与 root 都没有密码(要登录请加 -p <密码>,或放 authorized_keys 用 SSH 公钥)"
fi

# `/var/tmp` 是 tmpfs 时的提醒:mkosi 的 workspace 默认在那儿,产物与缓存就得**复制**而不是
# rename/reflink(容器适配器用 bind mount 绕过了这件事,原生路径只能提醒)。
vtt=$(findmnt -no FSTYPE /var/tmp 2>/dev/null || true)
case "$vtt" in
    tmpfs|ramfs)
        log "注意:/var/tmp 是 $vtt —— mkosi 的 workspace 落在内存盘上,收尾时产物与增量缓存都要跨设备复制(慢,且吃内存)。"
        log "      要么把 /var/tmp 放到磁盘上,要么改用容器适配器 tools/build-container.sh(它把 mkosi.workspace/ 绑到 /var/tmp)。"
        ;;
esac

# 缓存目录先建出来:mkosi.conf 里已经显式指定了路径,这里只是保险
# (mkosi 25.x 在没有缓存目录时会拒绝 Incremental=yes)。
mkdir -p mkosi.cache mkosi.pkgcache mkosi.output

# 三个 profile 显式传同一个 --image-version,保证 dist/ 目录名和镜像里的 VERSION_ID 一致。
#
# **必须带 --force。** mkosi 的 `build` 语义是"没有才建":产物路径已存在时它只打印一行
#   ‣ Output path /work/mkosi.output/keel.raw exists already. (Use --force to rebuild.)
# 然后**返回 0**,什么都不做。而版本号只写在镜像内部(文件名里没有版本号),所以少了 -f
# 就会静默复用上一次的产物 —— 你会拿着一份"版本号是新的、内容是旧的"镜像去装机(真机上
# 已经这么白测过一轮,见 docs/traps.md 坑 #23)。
# -f 只重建输出,不动增量缓存(mkosi.cache/);要连缓存一起删是 -ff,我们不用。
log "构建 install 镜像"
# 额外 profile(变体 / 演练)**只能**通过 keel_cli_extra_profiles 取:它把
# `--profile <名字>`(CLI)与 KEEL_EXTRA_PROFILES(环境变量,旧用法)合并去重。
# 演练用它把 test profile 叠进去(OTA 演练时新槽里也得有 keel-selftest / keel-ota-drill,
# 否则状态机跨不过重启)。
EXTRA_PROFILE_ARGS=()
EXTRA_PROFILES=$(keel_cli_extra_profiles)
for _p in $EXTRA_PROFILES; do
    EXTRA_PROFILE_ARGS+=(--profile "$_p")
done
[ -n "$EXTRA_PROFILES" ] && log "额外 profile:$EXTRA_PROFILES"
[ ${#KEEL_EXTRA_MKOSI[@]} -gt 0 ] && log "额外 mkosi 参数:${KEEL_EXTRA_MKOSI[*]}"

# ⚠ `--root-password=` 与额外 mkosi 参数在**两次调用里都要带**:mkosi 的 `vm` 不解析配置,
# 它读的是上一次 build 写下的 history(见 docs/traps.md 坑 #30)。
mkosi_args=(--image-version "$VERSION" --force
            ${EXTRA_PROFILE_ARGS[@]+"${EXTRA_PROFILE_ARGS[@]}"}
            ${KEEL_EXTRA_MKOSI[@]+"${KEEL_EXTRA_MKOSI[@]}"}
            ${ROOTPW_ARGS[@]+"${ROOTPW_ARGS[@]}"})
# vm 那一步和容器适配器保持一致:**不带** --image-version/--force(mkosi 的 vm 不解析配置、
# 只读上一次 build 写下的 history;带上不同的值只会收到一行 "Ignoring … from the CLI"),
# 但 profile / 额外参数 / 密码照样带 —— 与容器路径逐字对齐,免得两条路又漂开。
vm_args=(${EXTRA_PROFILE_ARGS[@]+"${EXTRA_PROFILE_ARGS[@]}"}
         ${KEEL_EXTRA_MKOSI[@]+"${KEEL_EXTRA_MKOSI[@]}"}
         ${ROOTPW_ARGS[@]+"${ROOTPW_ARGS[@]}"})

mkosi --profile install "${mkosi_args[@]}" build
log "构建 slot-a 载荷"
mkosi --profile slot-a "${mkosi_args[@]}" build
log "构建 slot-b 载荷"
mkosi --profile slot-b "${mkosi_args[@]}" build

# ---------------------------------------------------------------------------
# 组装 dist/
# ---------------------------------------------------------------------------
D="$DIST/keel-$VERSION"
rm -rf "$D"; mkdir -p "$D"

# 找文件:名字按 mkosi 的约定猜,找不到就把输出目录列出来(别让人猜)
pick() { # pick <描述> <目标名> <候选 glob...>
    local desc=$1 dst=$2; shift 2
    local f
    for f in "$@"; do
        if [ -e "$f" ]; then cp -f "$f" "$D/$dst"; log "  $desc → $dst"; return 0; fi
    done
    log "找不到 $desc,候选:$*"
    log "$OUT/ 目录里实际有:"
    ls -1 "$OUT" 2>/dev/null | sed 's/^/    /' >&2 || true
    die "缺产物:$desc"
}

pick "安装镜像"        keel.raw        "$OUT/keel.raw"
pick "A 槽根分区镜像"  slot-a.root.raw "$OUT/keel-slot-a.root-a.raw" "$OUT/keel-slot-a.root.raw"
pick "A 槽 UKI"        slot-a.uki.efi  "$OUT/keel-slot-a.efi"
pick "B 槽根分区镜像"  slot-b.root.raw "$OUT/keel-slot-b.root-b.raw" "$OUT/keel-slot-b.root.raw"
pick "B 槽 UKI"        slot-b.uki.efi  "$OUT/keel-slot-b.efi"

# ---------------------------------------------------------------------------
# manifest:os-update 消费的 key=value 清单
# ---------------------------------------------------------------------------
sha() { sha256sum "$D/$1" | cut -d' ' -f1; }
# schema 版本单一事实来源:仓库根目录的 schema-version
SCHEMA=$(cat schema-version 2>/dev/null || echo 1)

{
    echo "# keel 更新清单(os-update 消费;格式刻意是最朴素的 key=value,镜像里没有 jq)"
    echo "version=$VERSION"
    echo "image_id=keel"
    echo "created=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "schema=$SCHEMA"
    echo "migrate="
    echo "sha256_slot-a.root.raw=$(sha slot-a.root.raw)"
    echo "sha256_slot-a.uki.efi=$(sha slot-a.uki.efi)"
    echo "sha256_slot-b.root.raw=$(sha slot-b.root.raw)"
    echo "sha256_slot-b.uki.efi=$(sha slot-b.uki.efi)"
} >"$D/manifest"

( cd "$D" && sha256sum keel.raw >keel.raw.sha256 )

# 人类可读的说明顺带放进去(安装 / 更新 / 发布说明:已知限制的权威清单)
[ -f docs/install.md ] && cp -f docs/install.md "$D/install.md"
[ -f docs/update.md ] && cp -f docs/update.md "$D/update.md"
for rn in docs/release-notes*.md; do
    [ -f "$rn" ] || continue
    cp -f "$rn" "$D/${rn##*/}"
done

log "完成:$D"

# --vm:构建完直接在 QEMU 里起一遍(和容器适配器的 vm 模式对齐:同样的 profile / 密码 /
# 额外参数,而且**两次 mkosi 调用都带上** —— 原因见坑 #30)。
if [ "$MODE" = vm ]; then
    if [ ! -e /dev/kvm ]; then
        log "注意:没有 /dev/kvm,调用了 vm 但没有硬件加速;没有虚拟化环境时这一步会很慢或起不来"
    fi
    log "启动 QEMU(mkosi vm;读的是刚才那次 build 的 history)"
    mkosi --profile install "${vm_args[@]}" vm
fi

log "下一步:"
log "  装到机器上        sudo tools/burn.sh /dev/nvme0n1"
log "  先在虚拟机里试    sudo tools/build.sh --vm -p <临时密码>(原生)或 sudo tools/build-container.sh vm -p <临时密码>(容器)"
log "  或者在 libvirt 里试 dist/keel-$VERSION/keel.raw(要能登录就得先 -p 构建,或放 authorized_keys)"
log "  发布更新          把 $D 里除 keel.raw/install.md/update.md 之外的文件放到更新源目录"
