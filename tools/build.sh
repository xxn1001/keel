#!/bin/bash
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
# 版本号来自可执行的 mkosi.version(时间戳),见 docs/architecture.md §6。
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=mkosi.output
DIST=dist

log() { printf 'keel-build: %s\n' "$*" >&2; }
die() { printf 'keel-build: 错误:%s\n' "$*" >&2; exit 1; }

command -v mkosi >/dev/null || die "没装 mkosi"

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
# 口令只从环境变量来 —— 这是公开仓库,配置里硬编码的密码等于公开的,所以**不写进 mkosi.conf**。
# 由 tools/build-container.sh 的 `-p/--password` 转成 KEEL_ROOT_PASSWORD 传进来,也可以自己:
#     KEEL_ROOT_PASSWORD='...' sudo tools/build.sh
# mkosi 的 `RootPassword=` 先落到 root(shadow + credstore credential),再由 mkosi.finalize
# 搬给 admin、锁掉 root、删掉那份 credential —— 和真机用仓库根目录 mkosi.rootpw 是**同一条路径**。
# 注意:带到 dist/ 里的密码只适合临时测试;正式产物请改用 authorized_keys(SSH 公钥)。
ROOTPW_ARGS=()
if [ -n "${KEEL_ROOT_PASSWORD:-}" ]; then
    ROOTPW_ARGS=("--root-password=$KEEL_ROOT_PASSWORD")
    log "警告:产物里带 admin 初始密码 —— 临时测试可以,装到自己机器上的正式产物请改用 authorized_keys"
fi

# 缓存目录先建出来:mkosi.conf 里已经显式指定了路径,这里只是保险
# (mkosi 25.x 在没有缓存目录时会拒绝 Incremental=yes)。
mkdir -p mkosi.cache mkosi.pkgcache mkosi.output

# 三个 profile 显式传同一个 --image-version,保证 dist/ 目录名和镜像里的 VERSION_ID 一致。
#
# **必须带 --force。** mkosi 的 `build` 语义是"没有才建":产物路径已存在时它只打印一行
#   ‣ Output path /work/mkosi.output/keel.raw exists already. (Use --force to rebuild.)
# 然后**返回 0**,什么都不做。而版本号只写在镜像内部(文件名里没有版本号),所以少了 -f
# 就会静默复用上一次的产物 —— 你会拿着一份"版本号是新的、内容是旧的"镜像去装机(真机上
# 已经这么白测过一轮,见 AGENTS.md 坑 #23)。
# -f 只重建输出,不动增量缓存(mkosi.cache/);要连缓存一起删是 -ff,我们不用。
log "构建 install 镜像"
mkosi --profile install --image-version "$VERSION" --force "${ROOTPW_ARGS[@]}" build
log "构建 slot-a 载荷"
mkosi --profile slot-a --image-version "$VERSION" --force "${ROOTPW_ARGS[@]}" build
log "构建 slot-b 载荷"
mkosi --profile slot-b --image-version "$VERSION" --force "${ROOTPW_ARGS[@]}" build

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

# 人类可读的安装说明顺带放进去
[ -f docs/install.md ] && cp -f docs/install.md "$D/install.md"
[ -f docs/update.md ] && cp -f docs/update.md "$D/update.md"

log "完成:$D"
log "下一步:"
log "  装到机器上        sudo tools/burn.sh /dev/nvme0n1"
log "  先在虚拟机里试    sudo tools/build-container.sh -p <临时密码> vm(控制台 admin / 该密码,root 锁定)"
log "  或者在 libvirt 里试 dist/keel-$VERSION/keel.raw(要能登录就得先 -p 构建,或放 authorized_keys)"
log "  发布更新          把 $D 里除 keel.raw/install.md/update.md 之外的文件放到更新源目录"
