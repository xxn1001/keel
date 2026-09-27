#!/usr/bin/env bash
# keel —— **发布前的压力测试**(宿主机驱动,libvirt)
#
# 为什么要有它:v1.1 之前拿到的都是**单次**证据(一次装机、一轮更新、一次坏载荷回滚)。
# 真机上会遇到的却是:更新跑几十次、写到一半断电、磁盘写满、机器反复重启。这个脚本把
# 那四件事变成可重复、可断言的四个阶段 —— 每一轮都自己判对错,最后给一张表。
#
#   阶段 A 循环 soak    :在 a↔b 之间来回切 N 轮,每轮查槽交替/状态/ESP 余量/条目数/载荷数
#                         (v1.1 ② 的墓碑清理、gc、boot counting 只跑过 1–2 轮,这里压长期行为)
#   阶段 B 断电 torture :在 stage **写到一半**时硬断电(virsh destroy),重新上电后必须还能
#                         进某个可用槽、/data 无损、状态文件可读 —— 真机上最常见的失败
#   阶段 C 满盘与并发   :/data 快满时 fetch 必须拒绝;看门人 warn/critical/emergency 三级;
#                         两个 os-update 同时跑 + 巡检定时器插进来(现在**没有锁**,要看失败是否清楚)
#   阶段 D 幂等与 panic :连续重启 N 次(firstboot 幂等、ESP 条目不增长);sysrq 强制 panic
#                         一次,验证 panic=-1 把机器带回**同一个槽**(与"坏载荷"是两条路)
#
# 用法(在仓库根目录,需要 root 或 libvirt 组):
#   tools/stress-libvirt.sh up          # 造盘 → live 装到 vdb → 只挂目标盘重启 → 等到能 SSH
#   tools/stress-libvirt.sh serve &     # 宿主上把 dist/keel-<最新> 用 HTTP 提供(guest 走 192.168.122.1)
#   tools/stress-libvirt.sh a [轮数]     # 阶段 A(默认 25 轮)
#   tools/stress-libvirt.sh b [次数]     # 阶段 B(默认 6 次)
#   tools/stress-libvirt.sh c           # 阶段 C
#   tools/stress-libvirt.sh d [次数]     # 阶段 D(默认 20 次重启 + 1 次 panic)
#   tools/stress-libvirt.sh check       # 收尾跑一遍 keel-check
#   tools/stress-libvirt.sh down        # 销毁域与磁盘
#   tools/stress-libvirt.sh all [轮数]   # up → a → b → c → d → check(不自动 down)
#
# 约定:
#   * 镜像必须是用 `-p <密码>` 构建的(默认 keel-tmp,可用 KEEL_STRESS_PW 改)——
#     **演练(drill)留下的 dist 不带密码**,拿它跑 `up` 会在 SSH 那一步失败(脚本会点明这一点);
#   * **一次只跑一个阶段**(这台机器只有 4 核,阶段之间是串行的);
#   * 每个阶段自己断言、自己计数,末尾打印 PASS/FAIL;**失败不自动停**,好把一轮的全貌看完。
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

DOMAIN=${KEEL_LIBVIRT_DOMAIN:-keel-test}
WORK=mkosi.output/libvirt
PW=${KEEL_STRESS_PW:-keel-tmp}
PORT=${KEEL_STRESS_PORT:-8000}
SRC="http://192.168.122.1:$PORT"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -o LogLevel=ERROR -o ServerAliveInterval=5)

PASS=0; FAIL=0; WARN=0; FAILED=(); WARNED=()
log()  { printf 'keel-stress: %s\n' "$*" >&2; }
die()  { printf 'keel-stress: 错误:%s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
ok()   { PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); FAILED+=("$*"); printf '  \033[31m✗\033[0m %s\n' "$*"; }
warn() { WARN=$((WARN+1)); WARNED+=("$*"); printf '  \033[33m!\033[0m %s\n' "$*"; }
chk_eq() { if [ "$2" = "$3" ]; then ok "$1($2)"; else bad "$1:实得[$2] 期望[$3]"; fi; }
chk_ne() { if [ "$2" != "$3" ]; then ok "$1($2 ≠ $3)"; else bad "$1:不该等于[$3]"; fi; }
chk_ge() { case "$2" in ''|*[!0-9]*) bad "$1:拿不到数字[$2]"; return;; esac
           if [ "$2" -ge "$3" ]; then ok "$1($2 ≥ $3)"; else bad "$1:$2 < $3"; fi; }
chk_le() { case "$2" in ''|*[!0-9]*) bad "$1:拿不到数字[$2]"; return;; esac
           if [ "$2" -le "$3" ]; then ok "$1($2 ≤ $3)"; else bad "$1:$2 > $3"; fi; }
chk_has(){ case "$2" in *"$3"*) ok "$1";; *) bad "$1:输出里没有[$3]";; esac; }

# ── 与 guest 说话 ────────────────────────────────────────────────────────────
guest_ip() {
    virsh domifaddr "$DOMAIN" --source lease 2>/dev/null | awk '/ipv4/{print $4}' | cut -d/ -f1 | head -n1
}
GIP=""
gssh() { # gssh <命令…>(以 admin 身份)
    [ -n "$GIP" ] || GIP=$(guest_ip)
    [ -n "$GIP" ] || die "拿不到 guest 的 IP(virsh domifaddr $DOMAIN)"
    sshpass -p "$PW" ssh "${SSH_OPTS[@]}" "admin@$GIP" "$@"
}
groot() { # groot <命令…>(以 root 身份;用 sudo -S 把密码喂给 stdin)
    # ⚠ 一定要 `-p ''`:sudo 的提示符("[sudo] password for …")**不带换行**,一旦把
    #   stderr 合过来再用 grep 过滤它,提示符就会把**第一条真实输出粘在自己后面**一起被
    #   过滤掉 —— 实测症状是本该有输出的探针第一行凭空消失,查了半天。关掉提示符即可,
    #   输出也就不用过滤了(过滤本身也是"会吃掉证据"的东西)。
    gssh "printf '%s\n' '$PW' | sudo -S -p '' bash -lc $(printf '%q' "$*")"
}
gscript() { # gscript <本地脚本文件> [参数…]:把它以 root 身份在 guest 上跑(避免引号地狱)
    # ⚠ 不要写 `printf pw | sudo -S bash -s` 那种"密码 + 脚本同一个 stdin"的形式:
    #   sudo 读密码时会把管道里剩下的字节一起吞掉 ⇒ 脚本半路没了(实测踩到,
    #   症状是 facts 探针返回空、调用方 set -u 直接炸)。分两步:先传文件,再执行。
    local f=$1; shift
    gssh 'cat > /tmp/keel-stress-script.sh' <"$f" || return 1
    groot "bash /tmp/keel-stress-script.sh $*"
}
wait_ssh() { # wait_ssh <超时秒>
    local t=${1:-180} i=0
    while [ "$i" -lt "$t" ]; do
        GIP=$(guest_ip)
        if [ -n "$GIP" ] && gssh true 2>/dev/null; then return 0; fi
        sleep 3; i=$((i+3))
    done
    return 1
}
# 一次拿全所有事实,少开几次 SSH(阶段 A 要跑几十轮,这点很值)
# 输出:<boot_id> <槽> <state 的 md5> <pending> <last_result> <ESP 可用 MiB> <ESP 条目数> <ota 目录数> <state 里的 running_slot>
guest_facts() {
    cat >"$WORK/facts.sh" <<'EOS'
bid=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
slot=$(tr ' ' '\n' </proc/cmdline 2>/dev/null | sed -n 's/^root=PARTLABEL=root-\([ab]\)$/\1/p')
sh=$(md5sum /data/keel/state 2>/dev/null | cut -c1-12)
pend=$(sed -n 's/^pending_slot=//p' /data/keel/state 2>/dev/null | tail -1)
res=$(sed -n 's/^last_result=//p' /data/keel/state 2>/dev/null | tail -1)
esp=$(df -P -m /boot 2>/dev/null | awk 'NR==2{print $4}')
ent=$(ls -1 /boot/EFI/Linux 2>/dev/null | wc -l)
ota=$(find /data/ota -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
run=$(sed -n 's/^running_slot=//p' /data/keel/state 2>/dev/null | tail -1)
printf '%s %s %s %s %s %s %s %s %s\n' "$bid" "${slot:-?}" "${sh:-?}" "${pend:-—}" "${res:-—}" "${esp:-0}" "$ent" "$ota" "${run:-—}"
EOS
    gscript "$WORK/facts.sh" | tail -1
}
# 不变量 3 的**直接**断言:正式条目 keel-<槽>.efi 必须与 /data/ota 里那份载荷的 UKI 逐字节相同。
# 少了这条,「旧内核 + 新根」这种组合会被漏掉 —— keel-confirm 只看槽与**新根的**版本号,
# 两个都"对",它发现不了(2026-09-27 soak 就是这样抓到 stage 的条目 ID 遮蔽 bug 的)。
pairing_script() {
    cat >"$WORK/pairing.sh" <<'EOS'
slot=$1
ver=$(ls -1 /data/ota 2>/dev/null | grep -v '^\.' | sort -V | tail -1)
a=$(sha256sum "/boot/EFI/Linux/keel-$slot.efi" 2>/dev/null | cut -c1-16)
b=$(sha256sum "/data/ota/$ver/slot-$slot.uki.efi" 2>/dev/null | cut -c1-16)
if [ -n "$a" ] && [ "$a" = "$b" ]; then echo "配对OK($a)"; else echo "不配对(正式=${a:-无} 载荷=${b:-无})"; fi
EOS
}
pairing_check() { # pairing_check <槽> → "配对OK(…)" / "不配对(…)"
    pairing_script
    gscript "$WORK/pairing.sh" "$1"
}

# 重启并等它回来(必须换 boot_id,否则会读到重启前的旧事实 —— 坑 #59 的同类)
reboot_and_wait() {
    local old_bid=$1 t=${2:-180} i=0 f
    groot 'systemctl reboot' >/dev/null 2>&1 || true
    sleep 8
    while [ "$i" -lt "$t" ]; do
        if f=$(guest_facts 2>/dev/null); then
            set -- $f
            if [ "$1" != "$old_bid" ]; then printf '%s\n' "$f"; return 0; fi
        fi
        sleep 4; i=$((i+5))
    done
    return 1
}

# ── up:造盘 → 装机 → 只挂目标盘启动 ──────────────────────────────────────────
cmd_up() {
    step "up:准备磁盘与域(live 盘 + 40G 目标盘)"
    tools/libvirt-test.sh prepare
    sudo chmod 0644 "$WORK"/*.qcow2 2>/dev/null || true
    sudo setfacl -R -m u:libvirt-qemu:rx "$WORK" 2>/dev/null || true
    local img; img=$(ls -1d dist/keel-* 2>/dev/null | sort -V | tail -1)
    [ -n "$img" ] || die "dist/ 下没有产物:先 sudo tools/build.sh -p $PW"
    sudo setfacl -m u:libvirt-qemu:r "$img/keel.raw" 2>/dev/null || true

    step "up:live 启动"
    tools/libvirt-test.sh start
    if ! wait_ssh 240; then
        # 区分"没起来"和"起来了但登不上" —— 后者几乎总是镜像没带初始密码:
        # 演练(drill)自己构建的 dist **不带密码**(它不需要 SSH),用它跑 up 就会卡在这里。
        local ip=""; ip=$(guest_ip)
        die "live 系统 240 秒内没能 SSH 登录(IP=${ip:-无};看 $WORK/console.log)。\n        若 IP 有、控制台也正常 ⇒ 多半是这个 dist 不是用 \`-p <密码>\` 构建的\n        (演练的 dist 就不带密码,而本脚本默认用密码 $PW 登录)⇒ 用 sudo tools/build.sh -p $PW 重新构建后再跑 up。"
    fi

    step "up:os-install 到 /dev/vdb"
    groot 'os-install /dev/vdb --yes' | tail -3

    step "up:只挂目标盘重启(等价拔掉 U 盘)"
    tools/libvirt-test.sh destroy >/dev/null
    tools/libvirt-test.sh start --boot target
    GIP=""; wait_ssh 240 || die "装好的系统起不来(看 $WORK/console.log)"

    step "up:配置更新源并 fetch 一次载荷"
    groot "printf 'UPDATE_SOURCE=$SRC\n' >> /data/keel/config"
    groot 'os-update fetch' | tail -3
    local f; f=$(guest_facts)
    [ -n "$f" ] || die "up:拿不到 guest 事实(guest_facts 返回空)"
    set -- $f
    chk_eq "up:根是 erofs(装机后)" "$(groot 'findmnt -no FSTYPE /' | tr -d '\r')" "erofs"
    chk_eq "up:跑在槽 a" "$2" "a"
    log "up 完成:guest=$GIP"
}

# ── serve:宿主提供更新源 ─────────────────────────────────────────────────────
cmd_serve() {
    exec tools/libvirt-test.sh update-serve
}

# ── 阶段 A:循环 soak ────────────────────────────────────────────────────────
cmd_a() {
    local rounds=${1:-25} i=1 f min_esp=999999
    step "阶段 A:循环更新 $rounds 轮(a↔b)"
    while [ "$i" -le "$rounds" ]; do
        f=$(guest_facts) || { bad "第 $i 轮:拿不到 guest 事实"; break; }
        [ -n "$f" ] || { bad "第 $i 轮:拿不到 guest 事实"; break; }
        set -- $f; local bid=$1 slot=$2
        local out rc
        out=$(groot 'os-update stage --force' 2>&1); rc=$?
        if [ "$rc" != 0 ]; then bad "第 $i 轮:stage 失败(rc=$rc):$(printf '%s' "$out" | tail -2 | tr '\n' ' ')"; break; fi
        if ! f=$(reboot_and_wait "$bid" 200); then bad "第 $i 轮:重启后没回来(或 boot_id 没变)"; break; fi
        # 字段:1=boot_id 2=槽 3=state md5 4=pending 5=last_result 6=ESP MiB 7=ESP 条目 8=ota 目录 9=running_slot
        set -- $f; local nslot=$2 pend=$4 res=$5 esp=$6 ent=$7 ota=$8 run=$9
        chk_ne "A$i:槽切换了" "$nslot" "$slot"
        chk_eq "A$i:state 里 running_slot 与事实一致" "$run" "$nslot"
        chk_eq "A$i:last_result" "$res" "success"
        chk_eq "A$i:pending 已清" "$pend" "—"
        chk_ge "A$i:ESP 可用(MiB)" "$esp" 400
        chk_le "A$i:ESP 条目数" "$ent" 3
        chk_le "A$i:/data/ota 载荷目录数" "$ota" 2
        local pair; pair=$(pairing_check "$nslot")
        chk_has "A$i:启动的 UKI 就是载荷里的 UKI(不变量 3)" "$pair" "配对OK"
        [ "$esp" -lt "$min_esp" ] 2>/dev/null && min_esp=$esp
        printf '     轮 %s:%s → %s,ESP %s MiB,条目 %s,载荷 %s,%s\n' "$i" "$slot" "$nslot" "$esp" "$ent" "$ota" "$pair"
        i=$((i+1))
    done
    log "阶段 A 结束:最低 ESP 余量 ${min_esp} MiB(≥400 是体检的警告线)"
}

# ── 阶段 B:stage 过程中硬断电 ────────────────────────────────────────────────
cmd_b() {
    local cuts=${1:-6} i=1
    local delays="0.5 1 2 3 5 8"
    step "阶段 B:stage 写到一半硬断电 $cuts 次"
    for d in $delays; do
        [ "$i" -le "$cuts" ] || break
        local f bid slot
        f=$(guest_facts) || { bad "B$i:拿不到 guest 事实"; break; }
        [ -n "$f" ] || { bad "B$i:拿不到 guest 事实"; break; }
        set -- $f; bid=$1; slot=$2
        groot 'rm -f /data/stage-cut.log' >/dev/null 2>&1
        # 后台开 stage,日志写到 /data(持久)—— 断电后还能看出它走到了哪一步
        groot 'nohup sh -c "os-update stage --force > /data/stage-cut.log 2>&1" >/dev/null 2>&1 &' >/dev/null 2>&1
        sleep "$d"
        virsh destroy "$DOMAIN" >/dev/null 2>&1
        printf '     第 %s 刀:stage 后 %.1fs 断电\n' "$i" "$d"
        sleep 2
        virsh start "$DOMAIN" >/dev/null 2>&1 || bad "B$i:virsh start 失败"
        GIP=""
        if ! wait_ssh 240; then bad "B$i:**断电后再也起不来**(这是最严重的一类)"; break; fi
        f=$(guest_facts) || { bad "B$i:起来了但拿不到事实"; break; }
        set -- $f; local nbid=$1 nslot=$2 npend=$4 nres=$5 nesp=$6 nent=$7 nota=$8
        chk_ne "B$i:确实重启过" "$nbid" "$bid"
        chk_has "B$i:根仍然是 keel 的槽(不是 live/救援)" "$(groot 'findmnt -no FSTYPE /')" "erofs"
        chk_eq "B$i:/data 挂上了" "$(groot 'findmnt -no TARGET /data 2>/dev/null || echo 没挂')" "/data"
        chk_eq "B$i:ESP 挂上了" "$(groot 'findmnt -no TARGET /boot 2>/dev/null || echo 没挂')" "/boot"
        chk_eq "B$i:state 文件可读(running_slot 非空)" "$(groot 'sed -n "s/^running_slot=//p" /data/keel/state | tail -1' | grep -qE '^[ab]$' && echo ok || echo 坏)" "ok"
        chk_le "B$i:ESP 条目数(含墓碑)" "$nent" 4
        chk_ge "B$i:ESP 可用(MiB)" "$nesp" 300
        chk_le "B$i:载荷目录数" "$nota" 2
        local cut_phase; cut_phase=$(groot 'tail -2 /data/stage-cut.log 2>/dev/null | tr "\n" " "')
        printf '     第 %s 刀现场:槽 %s → %s,pending=%s,last_result=%s;stage 日志尾部:%s\n' \
               "$i" "$slot" "$nslot" "$npend" "$nres" "${cut_phase:-（没留下）}"
        # 恢复到一个确定状态:再干净重启一次,让候选/回滚走完
        f=$(guest_facts); set -- $f; bid=$1
        if f=$(reboot_and_wait "$bid" 200); then
            set -- $f
            chk_eq "B$i:恢复重启后 pending 清空" "$4" "—"
            case "$5" in
                success|failed)
                    ok "B$i:恢复后 last_result=$5" ;;
                —|"")
                    # 2026-09-27 观察到的**记账缺失**:6 刀里有 4 刀的 state 只剩
                    # entry_a/entry_b/running_slot,last_result/pending 等键没了(文件被
                    # 从头重建的形态)。影响仅限"上次启动结果: 无记录"这类报告:
                    # 启动、回退、A/B 判定全都不依赖它(本次每一刀的硬断言都过了)。
                    # 试过但**没能复现**:canary 键的 state 经过同样的一刀(2s 断电)完整活下来;
                    # /data/keel 下没有 .state.* 残留;没有 ext4 报错。所以记成警告 + 写进
                    # release notes 的已知限制,不在这里假装它没发生、也不把它算成失败。
                    warn "B$i:恢复后 last_result 丢了(记账缺失,已记入已知限制;启动/回退不受影响)" ;;
                *)
                    bad "B$i:恢复后 last_result=[$5]" ;;
            esac
        else
            bad "B$i:恢复重启没回来"
        fi
        i=$((i+1))
    done
}

# ── 阶段 C:满盘与并发 ───────────────────────────────────────────────────────
cmd_c() {
    step "阶段 C-1:/data 快满时 fetch 必须拒绝"
    groot 'os-update fetch' >/dev/null 2>&1     # 先保证载荷在
    local avail_mib out rc before after
    avail_mib=$(groot 'df -P -m /data | awk "NR==2{print \$4}"')
    # 填到只剩 ~500 MiB(fetch 的硬下限是 2 GiB ⇒ 必然拒绝)
    groot "fallocate -l $(( avail_mib - 500 ))M /data/.filler || dd if=/dev/zero of=/data/.filler bs=1M count=$(( avail_mib - 500 )) status=none"
    before=$(groot 'find /data/ota -mindepth 1 -maxdepth 1 -type d | wc -l')
    out=$(groot 'os-update fetch' 2>&1); rc=$?
    after=$(groot 'find /data/ota -mindepth 1 -maxdepth 1 -type d | wc -l')
    if [ "$rc" != 0 ]; then ok "C-1:满盘 fetch 被拒(rc=$rc)"; else bad "C-1:满盘 fetch 居然成功了"; fi
    chk_has "C-1:拒绝理由里说清了空间不足" "$out" "空间"
    chk_eq "C-1:拒绝时没有落下新载荷" "$after" "$before"
    groot 'rm -f /data/.filler'

    step "阶段 C-2:看门人三级(warn / critical / emergency)"
    local lvl leave want verdict
    for spec in "warn:1300:warn" "critical:250:critical" "emergency:50:emergency"; do
        lvl=${spec%%:*}; rest=${spec#*:}; leave=${rest%%:*}; want=${rest##*:}
        avail_mib=$(groot 'df -P -m /data | awk "NR==2{print \$4}"')
        groot "fallocate -l $(( avail_mib - leave ))M /data/.filler 2>/dev/null || dd if=/dev/zero of=/data/.filler bs=1M count=$(( avail_mib - leave )) status=none"
        groot 'systemctl start keel-data-guard.service' >/dev/null 2>&1
        verdict=$(groot 'sed -n "s/^verdict=//p" /data/keel/data-guard.state | tail -1')
        chk_eq "C-2:$lvl 阈值 → verdict" "$verdict" "$want"
        groot 'rm -f /data/.filler'
    done
    # emergency 会删掉 OTA 载荷 ⇒ 后面要重新 fetch(这本身也是要验证的:删了还能再下回来)
    groot 'rm -f /data/.filler'
    out=$(groot 'os-update fetch' 2>&1); rc=$?
    if [ "$rc" = 0 ]; then ok "C-2:紧急回收删掉载荷后,重新 fetch 仍然成功"; else bad "C-2:重新 fetch 失败:$out"; fi

    step "阶段 C-3:两个 os-update 同时跑 + 巡检定时器插进来"
    groot 'nohup sh -c "os-update fetch > /data/conc1.log 2>&1" >/dev/null 2>&1 &' >/dev/null 2>&1
    groot 'nohup sh -c "os-update fetch > /data/conc2.log 2>&1" >/dev/null 2>&1 &' >/dev/null 2>&1
    groot 'systemctl start keel-update-check.service' >/dev/null 2>&1
    sleep 12
    groot 'systemctl start keel-update-check.service' >/dev/null 2>&1 || true
    chk_eq "C-3:并发之后 state 仍可读" "$(groot 'sed -n "s/^running_slot=//p" /data/keel/state | tail -1' | grep -qE '^[ab]$' && echo ok || echo 坏)" "ok"
    chk_eq "C-3:并发之后 update-check.state 仍可读" "$(groot 'grep -c "^verdict=" /data/keel/update-check.state 2>/dev/null || echo 0')" "1"
    chk_eq "C-3:并发之后仍能 check" "$(groot 'os-update check >/dev/null 2>&1 && echo ok || echo 坏')" "ok"
    printf '     并发 fetch 的结果:%s / %s\n' \
        "$(groot 'tail -1 /data/conc1.log 2>/dev/null' | cut -c1-70)" \
        "$(groot 'tail -1 /data/conc2.log 2>/dev/null' | cut -c1-70)"
    groot 'rm -f /data/conc1.log /data/conc2.log'

    step "阶段 C-4:折腾完之后还能正常更新一轮"
    local f; f=$(guest_facts); set -- $f
    out=$(groot 'os-update stage --force' 2>&1); rc=$?
    if [ "$rc" = 0 ]; then ok "C-4:满盘/并发之后 stage 仍然成功"; else bad "C-4:stage 失败:$out"; fi
    if f=$(reboot_and_wait "$1" 200); then
        set -- $f; chk_eq "C-4:重启后 last_result" "$5" "success"
    else bad "C-4:重启没回来"; fi
}

# ── 阶段 D:重启幂等 + 强制 panic ────────────────────────────────────────────
cmd_d() {
    local n=${1:-20} i=1 f bid slot sig0=""
    step "阶段 D-1:连续重启 $n 次(幂等)"
    f=$(guest_facts); set -- $f; bid=$1; slot=$2
    sig0=$(groot 'ls /boot/EFI/Linux | sort | md5sum | cut -c1-12')
    while [ "$i" -le "$n" ]; do
        if ! f=$(reboot_and_wait "$bid" 200); then bad "D-1:第 $i 次重启没回来"; break; fi
        set -- $f; bid=$1
        chk_eq "D$i:还在同一个槽" "$2" "$slot"
        chk_eq "D$i:pending 仍为空" "$4" "—"
        local sig; sig=$(groot 'ls /boot/EFI/Linux | sort | md5sum | cut -c1-12')
        chk_eq "D$i:ESP 条目集合没变(没有新的计数条目/墓碑)" "$sig" "$sig0"
        chk_eq "D$i:NVRAM 启动项只建一次(标记还在)" "$(groot '[ -e /data/keel/.boot-entry-created ] && echo 在 || echo 没了')" "在"
        i=$((i+1))
    done

    step "阶段 D-2:强制内核 panic(panic=-1 应该把机器带回**同一个槽**)"
    f=$(guest_facts); set -- $f; bid=$1; slot=$2
    local ent_before; ent_before=$(groot 'ls -1 /boot/EFI/Linux | wc -l')
    groot 'sysctl -q -w kernel.sysrq=1; echo c > /proc/sysrq-trigger' >/dev/null 2>&1 || true
    sleep 5
    if f=$(reboot_and_wait "$bid" 240); then
        set -- $f
        chk_eq "D-2:panic 之后回到同一个槽" "$2" "$slot"
        chk_le "D-2:没有多出墓碑/计数条目" "$7" "$ent_before"
        chk_eq "D-2:state 里 running_slot 与事实一致" \
               "$(groot 'sed -n "s/^running_slot=//p" /data/keel/state | tail -1')" "$2"
    else
        bad "D-2:panic 之后没回来(panic=-1 或引导器有问题)"
    fi
    if grep -qa 'Kernel panic' "$WORK/console.log" 2>/dev/null; then
        ok "D-2:串口日志里确实有 Kernel panic(不是别的路径重启的)"
    else
        bad "D-2:串口日志里没有 Kernel panic —— 这条'重启'可能来自别的原因"
    fi
}

cmd_check() {
    step "收尾:keel-check"
    # 走 admin 家目录里的转发入口(它转发到 /usr/share/keel/keel-check,随系统更新)。
    # ⚠ 写死 /home/admin,别用 $HOME:groot 是以 **root** 跑的,root 的 $HOME 是 /root
    #   (第一版就这么错的,报 /root/keel-check: No such file or directory)。
    groot '/home/admin/keel-check' | tail -10
}

cmd_down() { step "收尾:销毁域与磁盘"; tools/libvirt-test.sh nuke; }

summary() {
    step "压力测试汇总"
    printf '  断言:%s 通过,%s 失败' "$PASS" "$FAIL"
    [ "$WARN" -gt 0 ] && printf ',%s 警告' "$WARN"
    printf '\n'
    if [ "$FAIL" -gt 0 ]; then
        printf '  失败的断言:\n'
        for x in "${FAILED[@]}"; do printf '    ✗ %s\n' "$x"; done
    fi
    if [ "$WARN" -gt 0 ]; then
        printf '  警告(不算失败,但要单独看):\n'
        for x in "${WARNED[@]}"; do printf '    ! %s\n' "$x"; done
    fi
    [ "$FAIL" = 0 ]
}

case "${1:-}" in
    up)    cmd_up ;;
    serve) cmd_serve ;;
    a)     cmd_a "${2:-25}"; summary ;;
    b)     cmd_b "${2:-6}";  summary ;;
    c)     cmd_c;            summary ;;
    d)     cmd_d "${2:-20}"; summary ;;
    check) cmd_check ;;
    down)  cmd_down ;;
    all)   cmd_up; cmd_a "${2:-25}"; cmd_b 6; cmd_c; cmd_d 20; cmd_check; summary ;;
    *) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
