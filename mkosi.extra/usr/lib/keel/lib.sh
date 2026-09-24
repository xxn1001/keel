# keel 公共 shell 库
#
# 用法:`. /usr/lib/keel/lib.sh`
# 被 /usr/lib/keel/* 与 /usr/bin/os-* 共用。
#
# 两个刻意的设计:
#   1. 不依赖 jq / python3 —— 镜像里没有它们,一切解析都用 coreutils;
#   2. 状态文件是 `key=value` 文本而不是 JSON(见 docs/architecture.md §4.2)。
#
# shellcheck shell=bash

KEEL_STATE_DIR=/Volume/keel
KEEL_CONFIG="$KEEL_STATE_DIR/config"
KEEL_STATE="$KEEL_STATE_DIR/state"
KEEL_SCHEMA_FILE="$KEEL_STATE_DIR/schema-version"
KEEL_OTA=/Volume/ota

# ESP 挂载点:**不硬编码 /efi**。
# ESP 由 systemd-gpt-auto-generator 自动挂载,挂到 /boot 还是 /efi 取决于镜像里
# 哪个目录存在(DPS 规则:/boot 存在就挂 /boot)—— 实测我们镜像里两个空目录都有,
# 它选了 /boot。所以现问 bootctl(它自己也按同样的规则找),失败再探测常见路径。
# 见 AGENTS.md 坑 #25。
keel_esp() {
    local p=
    if command -v bootctl >/dev/null 2>&1; then
        p=$(bootctl --print-esp-path 2>/dev/null) || p=
    fi
    if [ -z "$p" ] || [ ! -d "$p" ]; then
        for p in /boot /efi /boot/efi; do
            if [ -d "$p/EFI" ] || mountpoint -q "$p" 2>/dev/null; then break; fi
            p=
        done
    fi
    printf '%s' "${p:-/boot}"
}

KEEL_ESP=$(keel_esp)
KEEL_UKI_DIR="$KEEL_ESP/EFI/Linux"

keel_log() { printf 'keel: %s\n' "$*" >&2; }
keel_die() { printf 'keel: 错误:%s\n' "$*" >&2; exit 1; }

# 当前槽:只认 kernel cmdline 里的 root=PARTLABEL=root-<a|b> 这一个 token。
# 槽身份完全靠 PARTLABEL(AGENTS.md 已知的坑 #5),解析不出来就输出空。
keel_current_slot() {
    tr ' ' '\n' </proc/cmdline 2>/dev/null \
        | sed -n 's/^root=PARTLABEL=root-\([ab]\)$/\1/p' \
        | head -n1
}

keel_other_slot() {
    case "${1:-}" in
        a) printf 'b' ;;
        b) printf 'a' ;;
        *) return 1 ;;
    esac
}

# 读 /Volume/keel/config 的键;为空则输出默认值。
keel_conf() {
    local key=$1 def=${2:-} v=
    if [ -r "$KEEL_CONFIG" ]; then
        v=$(sed -n "s/^[[:space:]]*${key}=//p" "$KEEL_CONFIG" | tail -n1)
        v=${v%%#*}                                   # 去掉行尾注释
        v=$(printf '%s' "$v" | sed 's/[[:space:]]*$//')  # 去掉行尾空白
    fi
    if [ -n "$v" ]; then printf '%s' "$v"; else printf '%s' "$def"; fi
}

keel_state_get() {
    [ -r "$KEEL_STATE" ] || return 0
    sed -n "s/^[[:space:]]*$1=//p" "$KEEL_STATE" | tail -n1
}

# 原子写:先写临时文件再 rename,避免掉电留下半个状态文件。
keel_state_set() {
    local key=$1 val=${2:-} tmp
    install -d -m 0755 "$KEEL_STATE_DIR"
    tmp=$(mktemp "$KEEL_STATE_DIR/.state.XXXXXX")
    if [ -r "$KEEL_STATE" ]; then
        grep -v "^[[:space:]]*$key=" "$KEEL_STATE" >"$tmp" || true
    fi
    printf '%s=%s\n' "$key" "$val" >>"$tmp"
    chmod 0644 "$tmp"
    mv -f "$tmp" "$KEEL_STATE"
}

# 版本号 = **镜像版本**,不是发行版版本。
#
# mkosi 会把 `--image-version` 写进 /usr/lib/os-release 的 `IMAGE_VERSION=`
# (/etc/os-release 是指向它的符号链接)。而 `VERSION_ID` 在 Debian 基底上是发行版号(13)——
# 拿它当 keel 版本有两个后果(2026-09 装机后实测,见 AGENTS.md 坑 #35):
#   * os-status 显示"系统版本: 13",pending / last_result 里的版本也全是 13;
#   * os-update 靠版本号判断"要不要更新",两边恒等于 13 会让它**永远认为已经是最新**。
# 所以先读 IMAGE_VERSION,读不到(理论上不会)才退回 VERSION_ID。
keel_version() {
    local v
    v=$(sed -n 's/^IMAGE_VERSION="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' /etc/os-release | head -n1)
    if [ -z "$v" ]; then
        v=$(sed -n 's/^VERSION_ID="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' /etc/os-release | head -n1)
    fi
    printf '%s\n' "$v"
}

keel_slot_device() { printf '/dev/disk/by-partlabel/root-%s' "$1"; }
keel_uki_path() { printf '%s/keel-%s.efi' "$KEEL_UKI_DIR" "$1"; }

# 当前槽的 UKI 可能带 boot counting 后缀(keel-a+2-1.efi),取第一个匹配。
keel_find_uki() {
    ls -1 "$KEEL_UKI_DIR/keel-$1"*.efi 2>/dev/null | head -n1
}

# 需要 root 的操作统一用这个检查
keel_require_root() {
    [ "$(id -u)" = 0 ] || keel_die "需要 root 权限(试试 sudo)"
}
