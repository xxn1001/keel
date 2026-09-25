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

KEEL_STATE_DIR=/data/keel
KEEL_CONFIG="$KEEL_STATE_DIR/config"
KEEL_STATE="$KEEL_STATE_DIR/state"
KEEL_SCHEMA_FILE="$KEEL_STATE_DIR/schema-version"
KEEL_OTA=/data/ota

keel_log() { printf 'keel: %s\n' "$*" >&2; }
keel_die() { printf 'keel: 错误:%s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 按 GPT 分区名找分区设备 —— **不依赖 udev**
#
# 内核在 /sys/class/block/*/uevent 里直接给出 GPT 分区名(PARTNAME=),这是分区名的
# 权威来源;`lsblk` 的 PARTLABEL 列来自 udev 的数据库,刚写完分区表时可能还是空的
# (AGENTS.md 坑 #33)。blkid 只作为兜底:它直接读文件系统超级块,同样不需要 udev。
#
# 为什么放在 lib.sh:keel-mounts(挂 /data 与 ESP)和 os-install / os-rescue 都要用
# 同一套查找逻辑 —— 一份实现,一个坑只踩一次。
# ---------------------------------------------------------------------------
keel_part_dev() {
    local want=$1 p dev
    [ -n "$want" ] || return 1
    for p in /sys/class/block/*; do
        [ -r "$p/uevent" ] || continue
        if grep -qx "PARTNAME=$want" "$p/uevent" 2>/dev/null; then
            printf '/dev/%s' "${p##*/}"
            return 0
        fi
    done
    if command -v blkid >/dev/null 2>&1; then
        dev=$(blkid -o device -t "LABEL=$want" 2>/dev/null | head -n1) || dev=
        if [ -n "$dev" ]; then printf '%s' "$dev"; return 0; fi
    fi
    return 1
}

# ---------------------------------------------------------------------------
# ESP(EFI 系统分区)
#
# ⚠ 这里曾经是坑 #36 的源头:以前直接拿 `bootctl --print-esp-path` 的输出当路径用,
# 而 bootctl **只是在按 gpt-auto 的规则猜**(镜像里 /boot 目录存在就报 /boot),
# 它**不检查那个路径是不是真的挂载点**。装机后的系统上 ESP 压根没挂上,于是所有
# `$KEEL_UKI_DIR` 操作都落在一个空目录里,而且每一步都"成功"
# ⇒ os-update 写不进 UKI、bootctl set-preferred 切不了槽、keel-confirm 确认不了槽。
#
# 现在只有两个可信来源:
#   ① 挂载表里有我们的 ESP(源设备就是 PARTNAME=esp 的那个分区)—— keel-mounts 挂的;
#   ② bootctl 报的路径**确实是挂载点**。
# 都不成立时 keel_esp() 输出空 —— 调用方必须自己决定"报错还是自救",不许静默继续。
# ---------------------------------------------------------------------------
KEEL_ESP_MOUNT=/boot          # 我们自己挂 ESP 的位置(见 keel_esp_mount)

# 已经在哪挂着?按"源设备 == PARTNAME=esp 的分区"匹配,不看路径。
keel_esp_mountpoint() {
    local want real t s
    want=$(keel_part_dev esp 2>/dev/null) || return 1
    real=$(readlink -f "$want" 2>/dev/null) || return 1
    [ -n "$real" ] || return 1
    while read -r t s; do
        [ -n "$t" ] || continue
        case "$s" in /dev/*) ;; *) continue ;; esac
        if [ "$(readlink -f "$s" 2>/dev/null)" = "$real" ]; then
            printf '%s' "$t"
            return 0
        fi
    done < <(findmnt -rn -t vfat -o TARGET,SOURCE 2>/dev/null)
    return 1
}

# 确保 ESP 挂上了,输出它的挂载点。已经挂着就原样返回(绝不重复挂:同一块 vfat
# 挂两次没有好处,只有风险)。挂不上返回 1。
keel_esp_mount() {
    local dir=$KEEL_ESP_MOUNT dev
    if keel_esp_mountpoint; then return 0; fi
    dev=$(keel_part_dev esp 2>/dev/null) || return 1
    install -d -m 0755 "$dir" 2>/dev/null || return 1
    # 必须 rw:boot counting / `bootctl set-preferred` / os-update 写新 UKI 都要写它。
    # 选项对齐 systemd 给 ESP 用的默认值(fmask=0133,dmask=0022)。
    mount -t vfat -o rw,fmask=0133,dmask=0022 "$dev" "$dir" 2>/dev/null || return 1
    printf '%s' "$dir"
}

keel_esp() {
    local p=
    p=$(keel_esp_mountpoint 2>/dev/null) || p=
    if [ -z "$p" ] && command -v bootctl >/dev/null 2>&1; then
        # bootctl 只是参考:它给的路径必须真的是个挂载点才算数(坑 #36)
        local q; q=$(bootctl --print-esp-path 2>/dev/null) || q=
        if [ -n "$q" ] && mountpoint -q "$q" 2>/dev/null; then p=$q; fi
    fi
    printf '%s' "$p"
}

KEEL_ESP=$(keel_esp)
# ESP 没挂上时 KEEL_ESP 是空的 —— 单独给一个变量,好让"只想报告状态"的地方
# (os-status)和"必须写 ESP"的地方(os-update)用不同的话术。
KEEL_ESP_MOUNTED=no
[ -n "$KEEL_ESP" ] && KEEL_ESP_MOUNTED=yes
# 没挂上时 KEEL_UKI_DIR 指向"本该挂的那里"(仅用于打印/报错,绝不拿它去读写)。
KEEL_UKI_DIR="${KEEL_ESP:-$KEEL_ESP_MOUNT}/EFI/Linux"

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

# 读 /data/keel/config 的键;为空则输出默认值。
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
