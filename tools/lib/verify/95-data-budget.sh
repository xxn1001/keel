# shellcheck shell=bash
# keel verify 模块:/data 磁盘预算 + 更新检查(原第 1500-1667 行,逐字搬移)

verify_data_budget() {
# ---------------------------------------------------------------------------
head1 "9. /data 磁盘预算(决策 D23)"
# ---------------------------------------------------------------------------
JD=mkosi.extra/etc/systemd/journald.conf.d/keel.conf
if [ -f "$JD" ] && grep -q '^SystemMaxUse=' "$JD" && grep -q '^SystemKeepFree=' "$JD"; then
    ok "journald 有显式的 SystemMaxUse / SystemKeepFree(/data 写满会连带 /etc 写不进去)"
else
    no "缺少 $JD(或没写死上限)—— journald 默认按文件系统百分比算"
fi
if [ -f mkosi.extra/usr/lib/systemd/system/keel-nix-gc.service ] &&
   [ -f mkosi.extra/usr/lib/systemd/system/keel-nix-gc.timer ]; then
    if grep -q 'nix-collect-garbage' mkosi.extra/usr/lib/systemd/system/keel-nix-gc.service &&
       grep -q 'max-freed' mkosi.extra/usr/lib/systemd/system/keel-nix-gc.service; then
        ok "keel-nix-gc.service/timer:自带 nix GC(Debian 的 nix-setup-systemd 没有定时器)"
    else
        no "keel-nix-gc.service 里没有 nix-collect-garbage / --max-freed"
    fi
else
    no "缺少 keel-nix-gc.service 或 .timer"
fi
DG=mkosi.extra/usr/lib/keel/data-guard
if [ -f "$DG" ]; then
    if [ ! -x "$DG" ]; then
        no "$DG 没有可执行权限(systemd 会拒绝启动它)"
    elif grep -q 'WARN=' "$DG" && grep -q 'RESERVE' "$DG" && grep -q 'keel_log' "$DG"; then
        ok "keel-data-guard:阈值分级 + 交还应急空间 + 结论写进 /data/keel/data-guard.state"
    else
        no "data-guard 缺少阈值/应急空间逻辑"
    fi
else
    no "缺少 $DG"
fi
if [ -f mkosi.extra/usr/lib/systemd/system/keel-data-guard.service ] &&
   [ -f mkosi.extra/usr/lib/systemd/system/keel-data-guard.timer ]; then
    ok "keel-data-guard.service/timer 存在(启动 3 分钟后 + 每天一次)"
else
    no "缺少 keel-data-guard.service 或 .timer"
fi
if grep -q 'enable keel-data-guard.timer' "$PRESET" && grep -q 'enable keel-nix-gc.timer' "$PRESET"; then
    ok "preset 启用了两个新定时器"
else
    no "preset 没有启用 keel-data-guard.timer / keel-nix-gc.timer"
fi

# ---------------------------------------------------------------------------
# 9b. 更新**检查**(v1.1 ③):只 check + 通知,**绝不** fetch/stage
#
# 这是 roadmap §0 硬约束 1 的静态护栏:"自动更新必须排在签名之后"。光靠"记得别写"
# 不够,所以这里既断言"它调了 check",也断言"它除了 check 什么子命令都没提"。
# ---------------------------------------------------------------------------
UC=mkosi.extra/usr/lib/keel/update-check
if [ -f "$UC" ] && [ -x "$UC" ]; then
    ok "update-check 脚本存在且可执行"
else
    no "缺少可执行的 mkosi.extra/usr/lib/keel/update-check"
fi
if [ -f "$UC" ] && grep -q 'os-update check' "$UC"; then
    ok "update-check 调用的是**只读**的 os-update check"
else
    no "update-check 没有调用 os-update check"
fi
# ⚠ 反向断言:脚本里出现的**每一处** os-update 都必须是 `os-update check`。
# 换句话说:只要有人往里写了 fetch/stage(哪怕只是当成命令示例),这里就红。
if [ -f "$UC" ]; then
    n_all=$(grep -c 'os-update' "$UC" || true)
    n_chk=$(grep -c 'os-update check' "$UC" || true)
    if [ "${n_all:-0}" -gt 0 ] && [ "$n_all" = "$n_chk" ]; then
        ok "update-check 里每一处 os-update 都是 check(${n_all} 处)—— 绝不 fetch/stage"
    else
        no "update-check 里出现了非 check 的 os-update 子命令(共 ${n_all} 处,其中 check ${n_chk} 处)—— 违反硬约束 1"
    fi
fi
# 永远 exit 0:巡检失败只写结论,不该把 systemctl --failed 变成非空(keel-check 断言它为空)
if [ -f "$UC" ] && ! grep -qE '^[[:space:]]*set -e' "$UC" && grep -q '^exit 0' "$UC"; then
    ok "update-check 不用 set -e 且显式 exit 0(巡检永远成功,结论写状态文件)"
else
    no "update-check 可能非零退出 ⇒ keel-check 的「失败单元为空」会变成噪音"
fi
if grep -qE '^Type=oneshot' mkosi.extra/usr/lib/systemd/system/keel-update-check.service &&
   grep -qE '^ConditionPathIsMountPoint=/data' mkosi.extra/usr/lib/systemd/system/keel-update-check.service; then
    ok "keel-update-check.service 是 oneshot,且 /data 没挂上就不跑"
else
    no "keel-update-check.service 缺少 Type=oneshot / ConditionPathIsMountPoint=/data"
fi
if grep -qE '^OnBootSec=' mkosi.extra/usr/lib/systemd/system/keel-update-check.timer &&
   grep -qE '^OnUnitActiveSec=' mkosi.extra/usr/lib/systemd/system/keel-update-check.timer; then
    ok "keel-update-check.timer 有 OnBootSec + OnUnitActiveSec(开机先看一次,之后定期)"
else
    no "keel-update-check.timer 缺少 OnBootSec / OnUnitActiveSec"
fi
if grep -q 'enable keel-update-check.timer' "$PRESET"; then
    ok "preset 启用了 keel-update-check.timer(开箱即用)"
else
    no "preset 没有启用 keel-update-check.timer"
fi
# 状态文件的写入点与呈现点:少了任何一环,"通知"就断了
if grep -q 'keel_update_check_state' mkosi.extra/usr/lib/keel/lib.sh &&
   grep -q 'keel_update_check_state' "$UPDATE_MECH" &&
   grep -q 'update-check.state' mkosi.extra/usr/bin/os-status &&
   grep -q 'update-check.state' mkosi.extra/usr/share/keel/keel-check; then
    ok "update-check.state 链路完整:lib.sh 的 helper → os-update check 写入 → os-status/keel-check 呈现"
else
    no "update-check.state 的写入或呈现链路缺了一环"
fi
# ── 功能测试(不只是 grep):helper 在 note 为空时也必须落盘 ────────────────────
# 这一条是被真事逼出来的:helper 里原本最后一句是 `[ -n "$note" ] && printf …`,
# note 为空(= 成功路径 up-to-date / update-available)时整个 { } 组返回 1,
# 被后面的 || 兜底当成"写失败"删掉了临时文件 ⇒ **成功路径永远不写状态**,
# 而上面那些静态断言全绿。只有真跑一次才发现(v1.1 ③ 在 VM 里实测踩到)。
if [ -r mkosi.extra/usr/lib/keel/lib.sh ]; then
    ft=$(tmpd)
    if (
        # shellcheck disable=SC1091
        . mkosi.extra/usr/lib/keel/lib.sh
        KEEL_STATE_DIR="$ft/keel"
        keel_version() { printf '9.9.9\n'; }
        st="$KEEL_STATE_DIR/update-check.state"
        # 1) note 为空(成功路径)
        keel_update_check_state up-to-date "1.2.3" "" || exit 1
        [ -s "$st" ] || exit 1
        grep -q '^verdict=up-to-date$' "$st" || exit 1
        grep -q '^remote_version=1.2.3$' "$st" || exit 1
        # 2) note 非空(失败/没配源路径)也要带上 note,并且覆盖写而不是追加
        keel_update_check_state error "" "boom" || exit 1
        grep -q '^verdict=error$' "$st" || exit 1
        grep -q '^note=boom$' "$st" || exit 1
        [ "$(grep -c '^verdict=' "$st")" = 1 ] || exit 1
    ); then
        ok "keel_update_check_state 实跑:note 为空也落盘、note 非空带上、且覆盖写(状态文件不追加)"
    else
        no "keel_update_check_state 没写出状态文件 —— 检查 helper 里 { } 组的最后一句(不能用 && 结尾,note 为空时它会返回 1)"
    fi
fi
if grep -q 'RESERVE=' mkosi.extra/usr/lib/keel/firstboot && grep -q 'fallocate -l 256M' mkosi.extra/usr/lib/keel/firstboot; then
    ok "keel-firstboot 第 6 步预留 256 MiB 应急空间(小文件系统跳过)"
else
    no "keel-firstboot 里没有应急空间的创建逻辑"
fi
if grep -q 'etc.bak-\*' mkosi.extra/usr/lib/keel/mounts && grep -q 'tail -n +2' mkosi.extra/usr/lib/keel/mounts; then
    ok "os-rescue --reset-etc 的备份只留最近一份(否则每次重置都堆一份 /etc 副本)"
else
    no "mounts 里没有清理旧 etc.bak-* 的逻辑"
fi
if grep -q 'free_bytes' "$UPDATE_MECH" && grep -q 'os-update gc' "$UPDATE_MECH"; then
    ok "os-update fetch 先查 /data 空间(载荷预算:两个 erofs 根镜像 + 两个 UKI)"
else
    no "os-update fetch 没有检查 /data 可用空间"
fi
# 预算的**具体数字**也钉住:它决定"多小的 /data 还能升级",而且 ⑤ 的演练盘尺寸依赖它。
# 2026-09-26 踩过:③ 一度按"1.5–2 GiB/槽"估成 6 GiB/10 GiB,结果 20 GiB 的演练盘
# (/data 只剩 4.8 GiB)连**演练自己**都跑不起来。实测载荷是 1.1 GiB ⇒ 2 GiB / 4 GiB。
if grep -q 'need_hard=$((2 \* 1024 \* 1024 \* 1024))' "$UPDATE_MECH" &&
   grep -q 'need_warn=$((4 \* 1024 \* 1024 \* 1024))' "$UPDATE_MECH"; then
    ok "fetch 的空间预算 = 2 GiB 硬下限 / 4 GiB 警告线(实测载荷 1.1 GiB,与 ⑤ 的 20G 演练盘相容)"
else
    no "fetch 的空间预算被改过 —— 改之前先确认 20G 的演练盘(/data 约 4.8 GiB 可用)仍能 fetch(roadmap §0 ⑤)"
fi
if grep -q '自动清理旧载荷失败' "$UPDATE_MECH" && grep -q 'cmd_gc >/dev/null' "$UPDATE_MECH"; then
    ok "os-update stage 成功后自动清理旧载荷"
else
    no "os-update stage 之后没有自动清理旧载荷"
fi
if grep -q '空间看门人' mkosi.extra/usr/bin/os-status && grep -q '应急空间' mkosi.extra/usr/bin/os-status; then
    ok "os-status 报告看门人结论与应急空间状态"
else
    no "os-status 没有 /data 看门人那一节"
fi

# ---------------------------------------------------------------------------
# P2:两个状态文件的**呈现方**必须跟着产方走(不合并代码,只钉词表)
#
# `update-check.state` 与 `data-guard.state` 各有**两个呈现方**:os-status(给人看的总览)
# 与 keel-check(装机后体检)。它们各自写一份文案 —— 这是**故意的**:keel-check 必须能在
# 半坏的机器上独立跑(它连 lib.sh 读不到时都自己兜一份),合并成一个函数就等于把这个前提
# 拆掉。所以这里不合并代码,而是把"**漂移**"变成红灯:
#   * 正向:产方写的每一个 verdict,呈现方的 case 里都要有 —— 少一个,用户看到的就是
#     原始字符串或"未知"(不崩、不报错,所以没人会发现);
#   * 反向:呈现方的 case 里不许留着产方**已经不写**的标签(改名之后留下的僵尸分支)。
# 词表从**代码**里抽(产方抽 `keel_update_check_state <v>` 与 `verdict=<v>`,
# 呈现方抽它那个 case 的标签),不在这里抄一份常量 —— 抄一份就又多一个漂移点。
# ---------------------------------------------------------------------------
# case_labels <文件> <case 上的变量(带 $)> —— 打印那个 case 的标签;找不到那个 case 返回 1
case_labels() {
    local f=$1 var=$2 start
    # ⚠ 必须 -F 定长匹配:`case "$uverdict" in` 里的 `$` 在 ERE 里是**行尾锚点**,
    #   第一版用 -E 写,提取出来永远是空 ⇒ 反向检查静默失效(正是本文件要防的那种事)。
    start=$(grep -nF "case \"$var\" in" "$f" 2>/dev/null | head -n1 | cut -d: -f1)
    [ -n "$start" ] || return 1
    sed -n "${start},/^[[:space:]]*esac/p" "$f" | sed -n 's/^[[:space:]]*\([a-z][a-z-]*\)).*/\1/p'
    return 0
}
# 产方词表
uv_emit=$(grep -ohE 'keel_update_check_state [a-z][a-z-]*' "$UPDATE_MECH" \
          mkosi.extra/usr/lib/keel/update-check 2>/dev/null | awk '{print $2}' | sort -u)
gv_emit=$(sed -n 's/^[[:space:]]*verdict=\([a-z][a-z-]*\).*/\1/p' \
          mkosi.extra/usr/lib/keel/data-guard 2>/dev/null | sort -u)
uv_n=$(printf '%s\n' "$uv_emit" | grep -c . || true)
gv_n=$(printf '%s\n' "$gv_emit" | grep -c . || true)
p2_bad=""
# ① update-check:两个呈现方都要覆盖,且都不许留僵尸标签
for spec in 'mkosi.extra/usr/bin/os-status:$uverdict' 'mkosi.extra/usr/share/keel/keel-check:$uv'; do
    c=${spec%%:*}; var=${spec##*:}
    if ! labels=$(case_labels "$c" "$var"); then
        p2_bad="$p2_bad ${c##*/}(找不到 case \"$var\" in)"
        continue
    fi
    for v in $uv_emit; do
        printf '%s\n' "$labels" | grep -qx "$v" || p2_bad="$p2_bad ${c##*/}(缺 $v)"
    done
    for l in $labels; do
        printf '%s\n' "$uv_emit" | grep -qx "$l" || p2_bad="$p2_bad ${c##*/}(多出 $l)"
    done
done
# ② data-guard:os-status 有一张完整的"verdict → 文案"表;keel-check 只把原值打出来
#    (它只报告、不判断,见那边的注释)⇒ 只要求 os-status 覆盖完整。
if ! glabels=$(case_labels mkosi.extra/usr/bin/os-status '$gv'); then
    p2_bad="$p2_bad os-status(找不到 case \"\$gv\" in)"
else
    for v in $gv_emit; do
        printf '%s\n' "$glabels" | grep -qx "$v" || p2_bad="$p2_bad os-status(缺 $v)"
    done
    for l in $glabels; do
        printf '%s\n' "$gv_emit" | grep -qx "$l" || p2_bad="$p2_bad os-status(多出 $l)"
    done
fi
if [ "$uv_n" -ge 2 ] && [ "$gv_n" -ge 2 ] && [ -z "$p2_bad" ]; then
    ok "verdict 词表两侧一致:update-check ${uv_n} 个(os-status + keel-check 都覆盖)、data-guard ${gv_n} 个(os-status)"
else
    no "verdict 词表漂移了:$p2_bad(产方 update-check=${uv_n} 个 / data-guard=${gv_n} 个)"
fi

}
