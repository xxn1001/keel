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
# (docs/traps.md 坑 #33)。blkid 只作为兜底:它直接读文件系统超级块,同样不需要 udev。
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
# ⇒ os-update 写不进 UKI、bootctl 切不了槽、keel-confirm 确认不了槽。
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
    # 必须 rw:boot counting / `bootctl set-oneshot` / os-update 写新 UKI 都要写它。
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

# ---------------------------------------------------------------------------
# 确保 ESP 已经挂上,并把三个全局变量**就地**更新成"挂好之后"的值:
#     KEEL_ESP / KEEL_UKI_DIR / KEEL_ESP_MOUNTED
#
# ⚠⚠ 必须当**普通命令**调用(如 `keel_esp_ensure die '…' '…'`),
#      绝不允许写进 `$( )` 或管道 —— 那会在子 shell 里执行:挂载会成功,
#      但调用方看到的 KEEL_ESP / KEEL_UKI_DIR / KEEL_ESP_MOUNTED 仍是旧值,
#      后续所有 UKI 操作又落回空目录里(坑 #36 那种"每一步都成功、结果全落空")。
#
# 已经挂着时原样返回 0,绝不重复挂(理由见 keel_esp_mount)。
# 成功新挂上时打印 "<mounted-log-prefix> <挂载点>"。
# 为什么日志前缀由调用方给:三处调用点的文案本来就不同(逐字保留,别在重构里改口径)。
#
# 参数:
#   $1 die|soft            die = 挂不上就 keel_die "$3";soft = 挂不上返回 1
#   $2 mounted-log-prefix  成功挂上时日志里挂载点前面的那句
#   $3 die-msg             die 模式下的报错原文
# ---------------------------------------------------------------------------
keel_esp_ensure() {
    local mode=${1:-die} log_prefix=${2:-} die_msg=${3:-} mnt
    if [ "$KEEL_ESP_MOUNTED" = yes ]; then
        return 0
    fi
    if mnt=$(keel_esp_mount); then
        KEEL_ESP=$mnt
        KEEL_UKI_DIR="$mnt/EFI/Linux"
        KEEL_ESP_MOUNTED=yes
        keel_log "$log_prefix $mnt"
        return 0
    fi
    case "$mode" in
        soft) return 1 ;;
        *) keel_die "$die_msg" ;;
    esac
}

# 当前槽:只认 kernel cmdline 里的 root=PARTLABEL=root-<a|b> 这一个 token。
# 槽身份完全靠 PARTLABEL(docs/traps.md 坑 #5),解析不出来就输出空。
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

# cmdline 里有没有某个**完整的 token**(第二个参数是给人做测试用的 cmdline 文件)。
#
# 为什么要有这个函数,而不是到处 `grep 'flag' /proc/cmdline`:
#   * /proc/cmdline 是**一整个行** —— `grep '^flag'` 锚的是整行开头,所以除了第一个 token,
#     别的永远匹配不上。我们就这么在体检脚本里把一台好机器判成了硬失败(坑 #52)。
#   * 光去掉 `^` 也不够:子串匹配既会误命中(`root=PARTLABEL=root-a` 会匹配
#     `foo=root=PARTLABEL=root-a`),又说不清"我要的是这个 token"。
# 所以:按空白切成 token,整行比较(`-x`);`-e` 负责吃掉以 `-` 开头的 token。
keel_cmdline_has() {
    local tok=$1 file=${2:-/proc/cmdline}
    [ -n "$tok" ] || return 1
    tr -s '[:space:]' '\n' <"$file" 2>/dev/null | grep -qx -e "$tok"
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

# ---------------------------------------------------------------------------
# /data 文件系统的字节数(决策 D23:fetch 的预算、firstboot 的应急空间、
# data-guard 的分级、os-status / keel-check 的报告都靠它)。
#
# 用法:keel_data_fs_bytes <size|used|avail> [...]
#   按参数顺序输出字段(空格分隔),来自**同一个 df 快照**;读不到 /data 时
#   **什么都不输出**(不是输出一行空字段),由调用方自己决定当 0 还是当"未知"。
#   这样 `$(keel_data_fs_bytes avail)` 拿到空串、`read … < <(keel_data_fs_bytes …)`
#   拿到 EOF,与各处原来的内联 df 逐字一致。
#
# 为什么读不到也不报错/不 die:调用方里既有 `set -e`(os-update / firstboot)也有
#   `set -uo pipefail`(data-guard / keel-check),而"读不到"是预期内的事;
#   返回值恒为 0,`set -e` 的调用方不会在赋值处意外退出。
# 不做 cd,不碰任何全局。
# ---------------------------------------------------------------------------
keel_data_fs_bytes() {
    local want out size used avail v first=1
    for want in "$@"; do
        case "$want" in
            size|used|avail) ;;
            *) return 2 ;;
        esac
    done
    out=$(df -P -B1 /data 2>/dev/null | awk 'NR==2{print $2, $3, $4}') || out=""
    [ -n "$out" ] || return 0
    size=""; used=""; avail=""
    read -r size used avail <<<"$out" 2>/dev/null || true
    out=""
    for want in "$@"; do
        case "$want" in
            size)  v=$size ;;
            used)  v=$used ;;
            avail) v=$avail ;;
        esac
        if [ "$first" = 1 ]; then out=$v; first=0; else out="$out $v"; fi
    done
    printf '%s\n' "$out"
}

# "更新检查"的结论(v1.1 ③)。写进独立的状态文件,由 os-status / keel-check 呈现。
#
# 为什么要独立文件而不是塞进 /data/keel/state:那份 state 是**启动语义**的
# (pending / running_slot / last_result),由 keel-confirm 写;而"有没有新版本"
# 是**巡检结论**,由定时器每次覆盖。两者生命周期完全不同,混在一起会互相踩。
#
# verdict 取值(调用方约定,os-status 按它措辞):
#   update-available  源上有比本机更新的版本
#   up-to-date        源上与本机相同(或更旧)
#   source-older      源上的版本比本机旧(八成是源指错了目录)
#   no-source         /data/keel/config 里没有 UPDATE_SOURCE=
#   error             连不上源 / manifest 读不懂(巡检失败,不是系统故障)
#
# best-effort:任何一步失败都**不抛**(它不该让调用者变红;data-guard 的规矩同理)。
keel_update_check_state() {
    local verdict=$1 remote=${2:-} note=${3:-} cur="" tmp=""
    install -d -m 0755 "$KEEL_STATE_DIR" 2>/dev/null || return 0
    cur="$(keel_version 2>/dev/null)" || cur=""
    tmp="$(mktemp "$KEEL_STATE_DIR/.updchk.XXXXXX" 2>/dev/null)" || return 0
    # ⚠ 最后一句必须是**恒为 0** 的命令:这里曾经写成 `[ -n "$note" ] && printf …`,
    # note 为空(= 成功路径 update-available/up-to-date)时整个 { } 组返回 1,
    # 被下面的 || 兜底当成"写失败"把临时文件删掉 ⇒ **成功路径永远不落盘**。
    # 静态校验看不出来,只有真跑一次才发现(v1.1 ③ 在 VM 里实测踩到)。
    # 所以用 if(条件为假时返回 0),不要用 `&&` 结尾。
    {
        printf 'checked_at=%s\n' "$(date +%s)"
        printf 'verdict=%s\n' "$verdict"
        printf 'current_version=%s\n' "$cur"
        printf 'remote_version=%s\n' "$remote"
        if [ -n "$note" ]; then printf 'note=%s\n' "$note"; fi
    } >"$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
    chmod 0644 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$KEEL_STATE_DIR/update-check.state" 2>/dev/null || rm -f "$tmp"
    return 0
}

# 版本号 = **镜像版本**,不是发行版版本。
#
# mkosi 会把 `--image-version` 写进 /usr/lib/os-release 的 `IMAGE_VERSION=`
# (/etc/os-release 是指向它的符号链接)。而 `VERSION_ID` 在 Debian 基底上是发行版号(13)——
# 拿它当 keel 版本有两个后果(2026-09 装机后实测,见 docs/traps.md 坑 #35):
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

# /etc/machine-id(或指定文件)是不是有效的 32 位十六进制 ID —— 这份正则只在 lib.sh 里
# 留一处,别让 mounts / os-status 各写一份(坑 #29:ID 无效 ⇒
# networkd 的 DUID 拿到 -ENOPKG ⇒ DHCP/IPv6/DNSSEC 一起静默失效)。
# 读不到、内容不是恰好一行 32 位十六进制都返回非 0。
keel_machine_id_valid() {
    local f=${1:-/etc/machine-id}
    [ -r "$f" ] && grep -qxE '[0-9a-f]{32}' "$f" 2>/dev/null
}

# /etc/shadow 里某个账号的密码字段(第 2 列)。账号不存在、文件读不到都输出空串 ——
# 调用方(os-status / keel-check / selftest)全部按"未知"处理。
# 不用 getent:系统半坏时它未必可用,而这里只需要一个字段。
keel_shadow_field() {
    local user=$1 file=${2:-/etc/shadow} v=""
    if [ -r "$file" ]; then
        v=$(awk -F: -v u="$user" '$1==u{print $2}' "$file" 2>/dev/null) || v=""
    fi
    printf '%s\n' "$v"
}

keel_slot_device() { printf '/dev/disk/by-partlabel/root-%s' "$1"; }
keel_uki_path() { printf '%s/keel-%s.efi' "$KEEL_UKI_DIR" "$1"; }

# ---------------------------------------------------------------------------
# 槽切换用哪两个 bootctl 动词(坑 #43,2026-09 演练实测)
#
# 原设计用的是 `bootctl set-preferred <条目>`(它的语义正好是我们要的:像 set-default,
# 但**感知 boot assessment**,会跳过 tries-left 已经归零的条目)。问题是:
# **Debian trixie 的 systemd 257 里没有这个动词** —— VM 实测报
#     Unknown command verb 'set-preferred'.
# (systemd 261 的 man 与二进制里它才有;也就是说这行代码从写下来那天起就没生效过,
#  而"没生效"被 `if ! bootctl ...; then` 当成普通失败报了出来,是这次演练才让它现形。)
#
# 现在用 257 就有的两个动词:
#   * 候选槽(试一次)= `set-oneshot` —— 引导器用完就删掉那个 EFI 变量 ⇒
#     这一次起不来(panic、initrd 失败、systemd 没起来),下次启动自动回到持久默认(旧槽)。
#     代价:只有**一次**机会,不是文档里写的"连续三次"。三次的语义要等基底 systemd
#     提供 set-preferred(≥261)才能用,已记进 docs/roadmap.md。
#   * 已经确认好的槽 = `set-default` —— 持久默认。
# keel-confirm 在启动成功后用 keel_boot_default 把新槽固化下来。
# ---------------------------------------------------------------------------
keel_boot_candidate() { bootctl set-oneshot "$1"; }
keel_boot_default() { bootctl set-default "$1"; }

# 当前槽的 UKI 可能带 boot counting 后缀(keel-a+2-1.efi),取第一个匹配。
keel_find_uki() {
    ls -1 "$KEEL_UKI_DIR/keel-$1"*.efi 2>/dev/null | head -n1
}

# 需要 root 的操作统一用这个检查。
# ⚠ 消息与原先 os-update / os-install / os-rescue 里各自那份 need_root() **逐字一致**
#   (那三份完全相同,是操作者实际看到的那句);keel_require_root 此前没有调用点,
#   它带的旧文案不再对外输出,所以在这里对齐成真实可见的那句。
keel_require_root() {
    [ "$(id -u)" = 0 ] || keel_die "需要 root 权限,请用 sudo 重新执行"
}
