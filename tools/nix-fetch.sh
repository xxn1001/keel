#!/usr/bin/env bash
# keel:上游 nix 的取用(v1.2 B1,决策 D29)
#
# 为什么不用 Debian 的 nix-bin:trixie 的 2.26.3 已 EOL,Debian 在 security-tracker
# 上标了 4 条 "no DSA"(不打算在 trixie 修),其中三条 root 级;换更新的 Debian 包这条路
# 实测解不开(sid 要 libcurl >= 8.20,见 docs/traps.md #72)。
# 所以 v1.2 起:nix 由**上游官方二进制 tarball**供给,版本 + sha256 钉死在本文件里。
#
# 落地链路(与 docs/decisions.md D29、docs/roadmap.md 1.5 一致):
#   fetch  → 下载/校验 tarball(缓存在 mkosi.pkgcache/)→ 解进**数据骨架**
#            mkosi.extra/usr/share/keel/data-skeleton/nix/(这个目录在 .gitignore 里)
#   运行时 → keel-nix-sync 把骨架里 /data/nix 还没有的 store path 加性同步过去,
#            并把 profile 重指到本槽的 nix(v1.2 起版本跟着槽走,回滚也跟着回)
#
# 用法:
#   tools/nix-fetch.sh fetch           # 构建前必须跑(下载+校验+解包到骨架)
#   tools/nix-fetch.sh verify          # 只校验缓存里的 tarball(不下载)
#   tools/nix-fetch.sh unpack <tar.xz> # **不校验哈希**,只解包;只给 tools/verify.sh 自测用
#                                      # (要 KEEL_NIX_UNVERIFIED=1;构建请用 fetch)
#   tools/nix-fetch.sh path            # 打印缓存路径
#
# 环境变量(离线构建/自测用):
#   KEEL_NIX_CACHE   缓存目录(默认 mkosi.pkgcache)
#   KEEL_NIX_STAGE   骨架里的落地目录(默认 mkosi.extra/usr/share/keel/data-skeleton/nix)
set -euo pipefail
cd "$(dirname "$0")/.."

readonly NIX_VERSION=2.35.2
readonly NIX_ARCH=x86_64-linux
readonly NIX_SHA256=0c3960a9792331a22081c3c7a5d8465db9b17c50b3acdf18587fa4c6f2cb1158
readonly NIX_URL="https://releases.nixos.org/nix/nix-${NIX_VERSION}/nix-${NIX_VERSION}-${NIX_ARCH}.tar.xz"
CACHE_DIR=${KEEL_NIX_CACHE:-mkosi.pkgcache}
STAGE_DIR=${KEEL_NIX_STAGE:-mkosi.extra/usr/share/keel/data-skeleton/nix}
TARBALL="$CACHE_DIR/nix-${NIX_VERSION}-${NIX_ARCH}.tar.xz"
TOP="nix-${NIX_VERSION}-${NIX_ARCH}"

log() { printf 'keel-nix-fetch: %s\n' "$*" >&2; }
die() { printf 'keel-nix-fetch: 错误:%s\n' "$*" >&2; exit 1; }

# 校验是**唯一**入口:fetch/stage 都先过这里(stage 的调用方保证它已校验过,
# 自测除外 —— 自测用的是假 tarball,见 tools/lib/verify/69-nix-upstream.sh)。
check_tarball() {
    local tar="${1:-}" actual
    [ -s "$tar" ] || die "找不到 tarball:$tar"
    actual="$(sha256sum "$tar" | cut -d' ' -f1)"
    [ "$actual" = "$NIX_SHA256" ] || die "tarball 哈希不匹配:$tar
  期望 $NIX_SHA256
  实际 $actual
  上游文件被换过?别绕过校验:确认 $NIX_URL 之后更新本文件里的哈希(并重新构建)。"
    log "哈希匹配:$tar"
}

unpack() {
    local tar="${1:-}" tmp nixname
    [ -s "$tar" ] || die "找不到 tarball:$tar"
    command -v tar >/dev/null 2>&1 || die "宿主没有 tar"
    tmp="$(mktemp -d "${TMPDIR:-/var/tmp}/keel-nix.XXXXXX")"
    if ! tar -xJf "$tar" -C "$tmp"; then
        rm -rf "$tmp"
        die "解包失败:$tar(需要 tar 的 xz 支持)"
    fi
    if [ ! -d "$tmp/$TOP/store" ]; then
        rm -rf "$tmp"
        die "tarball 布局不是预期的 $TOP/store/"
    fi
    rm -rf "$STAGE_DIR"
    install -d -m 0755 "$STAGE_DIR/store" "$STAGE_DIR/var/nix/profiles"
    cp -a "$tmp/$TOP/store/." "$STAGE_DIR/store/" || { rm -rf "$tmp"; die "拷贝 store 失败"; }
    install -m 0644 "$tmp/$TOP/.reginfo" "$STAGE_DIR/var/nix/reginfo"
    rm -rf "$tmp"
    nixname="$(cd "$STAGE_DIR/store" && ls -d -- *-nix-"$NIX_VERSION" 2>/dev/null | head -n1)" || true
    [ -n "$nixname" ] || die "解出来的 store 里没有 *-nix-$NIX_VERSION"
    [ -x "$STAGE_DIR/store/$nixname/bin/nix-store" ] || die "$nixname 里没有 bin/nix-store"
    [ -x "$STAGE_DIR/store/$nixname/bin/nix-daemon" ] || die "$nixname 里没有 bin/nix-daemon"
    # profile 指向本槽的 nix 包。上游 installer 会跑 nix-env -i 生成 profile generation;
    # 这里不需要那层语义:profile 只是"稳定的二进制目录",运行时 keel-nix-sync 会把它
    # 重指到同一个目标。
    ln -sfn "/nix/store/$nixname" "$STAGE_DIR/var/nix/profiles/default"
    log "已把上游 nix $NIX_VERSION 解进骨架:$STAGE_DIR(store 路径 $nixname)"
}

cmd_fetch() {
    mkdir -p "$CACHE_DIR"
    if [ ! -s "$TARBALL" ]; then
        log "下载 $NIX_URL"
        curl -fL --retry 3 -C - -o "$TARBALL.part" "$NIX_URL" ||
            die "下载失败:$NIX_URL(也可以手动放到 $TARBALL)"
        mv -f "$TARBALL.part" "$TARBALL"
    else
        log "用缓存:$TARBALL"
    fi
    check_tarball "$TARBALL"
    unpack "$TARBALL"
}

cmd_verify() {
    check_tarball "$TARBALL"
}

cmd_unpack() {
    [ "${KEEL_NIX_UNVERIFIED:-0}" = 1 ] ||
        die "unpack 不做哈希校验,只给 tools/verify.sh 自测用(要 KEEL_NIX_UNVERIFIED=1)。构建请用 fetch。"
    unpack "${1:-}"
}

case "${1:-}" in
    fetch)  cmd_fetch ;;
    verify) cmd_verify ;;
    unpack) shift; cmd_unpack "${1:-}" ;;
    path)   printf '%s\n' "$TARBALL" ;;
    -h|--help|help|"")
        sed -n 's/^#   tools\/nix-fetch\.sh /  tools\/nix-fetch.sh /p' "$0" >&2
        printf '用法:tools/nix-fetch.sh <fetch|verify|unpack <tar.xz>|path>\n' >&2
        exit 2
        ;;
    *) die "不认识的子命令:'${1}'(见 -h)" ;;
esac
