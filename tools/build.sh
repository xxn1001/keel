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
# 版本号来自 mkosi.version,由第一次构建的 -B 自动 bump(docs/architecture.md §6)。
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

if [ ! -e mkosi.version ]; then
    echo 1 >mkosi.version
    log "已创建 mkosi.version = 1"
fi
VERSION_OLD=$(cat mkosi.version)

# 缓存目录先建出来:mkosi.conf 里已经显式指定了路径,这里只是保险
# (mkosi 25.x 在没有缓存目录时会拒绝 Incremental=yes)。
mkdir -p mkosi.cache mkosi.pkgcache mkosi.output

# 第一个 profile 带 -B:构建成功才把新版本号写回 mkosi.version
log "构建 install 镜像(会自动 bump 版本)"
mkosi --profile install -B build
VERSION=$(cat mkosi.version)
log "本次版本:$VERSION_OLD → $VERSION"

log "构建 slot-a 载荷"
mkosi --profile slot-a build
log "构建 slot-b 载荷"
mkosi --profile slot-b build

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
log "  先在虚拟机里试    sudo mkosi --profile install --profile test vm"
log "  发布更新          把 $D 里除 keel.raw/install.md/update.md 之外的文件放到更新源目录"
