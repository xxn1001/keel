# shellcheck shell=bash
# keel verify 模块:演练镜像尺寸 / ESP 余量 / clean-esp / migrate / 看门狗(原第 1002-1122 行,逐字搬移)

verify_esp_clean_watchdog() {
# v1.1 ⑤:演练的镜像尺寸**可配**(别再硬编码 40G)+ 太小要**明确拒绝**。
# 一条 `truncate -s 40G` 写死会让"磁盘最紧"这条约束永远松不下来;
# 而尺寸改小又是最容易写错的地方(小于布局 14 GiB 就会在 guest 里炸),所以下限要自己拦。
if grep -q 'KEEL_DRILL_IMAGE_SIZE' tools/ota-drill-container.sh &&
   grep -qE '^DRILL_IMAGE_SIZE=\$\{KEEL_DRILL_IMAGE_SIZE:-' tools/ota-drill-container.sh &&
   ! grep -qE 'truncate -s +40G' tools/ota-drill-container.sh &&
   grep -q 'DRILL_IMAGE_MIN_G' tools/ota-drill-container.sh &&
   grep -qF 'truncate -s "${img_g}G"' tools/ota-drill-container.sh; then
    ok "演练镜像尺寸可配(KEEL_DRILL_IMAGE_SIZE,默认 24G)+ 低于下限明确拒绝,不再硬编码 40G"
else
    no "演练镜像尺寸没做成可配(或还硬编码 40G / 没有下限检查)—— 见 roadmap §0 ⑤"
fi
# 功能测试(不只 grep):把 drill_image_gib 原样抽出来,跑合法值与各种坏值。
# 这条守住的是"改小到装不下"这个最容易犯的错(布局 14 GiB 是硬底)。
ft2=$(tmpd)
sed -n '/^drill_image_gib()/,/^}/p' tools/ota-drill-container.sh >"$ft2/fn.sh"
if [ -s "$ft2/fn.sh" ] && (
    # export 是给 shellcheck 看的(SC2034):这个值由下面 source 进来的函数读,
    # 它看不见跨文件的引用,会误报"未使用"。
    export DRILL_IMAGE_MIN_G=20
    # shellcheck disable=SC1090
    . "$ft2/fn.sh"
    [ "$(drill_image_gib 24G)" = 24 ] || exit 1
    [ "$(drill_image_gib 20G)" = 20 ] || exit 1
    drill_image_gib 19G  && exit 1
    drill_image_gib 4G   && exit 1
    drill_image_gib 24   && exit 1
    drill_image_gib abcG && exit 1
    drill_image_gib ""   && exit 1
    exit 0
); then
    ok "drill_image_gib 实跑:24G/20G 通过;19G/4G/24/abcG/空 一律拒绝"
else
    no "drill_image_gib 的格式/下限检查不对(要么放行了装不下的尺寸,要么把合法尺寸也拒了)"
fi

# v1.1 ②:ESP 余量 —— 写 UKI 之前必须先问 ESP 空间(和 /data 的空间检查同一个道理,
# 不变量 10;而 ESP 写不下时会留下半个 UKI 而根分区已经写好了 ⇒ 违反不变量 3)。
if grep -q 'ESP \*\*空间\*\*也要在写根分区之前确认' mkosi.extra/usr/bin/os-update &&
   grep -q 'os-rescue --clean-esp' mkosi.extra/usr/bin/os-update; then
    ok "os-update stage 在动分区之前检查 ESP 空间,并指向 os-rescue --clean-esp"
else
    no "os-update stage 没有 ESP 空间前置检查 ⇒ ESP 满时会写半个 UKI 而根已更新(内核与根不配对)"
fi
# v1.1 ②:清掉**所有**槽的 .failed/.bad 墓碑(不只目标槽)
if grep -q 'keel-\*.efi.failed' mkosi.extra/usr/bin/os-update; then
    ok "os-update stage 顺手清掉所有槽的 .failed/.bad 墓碑(ESP 空间自愈)"
else
    no "os-update stage 只清目标槽的残留 ⇒ 别槽的 .failed 会一直占着 ESP 空间"
fi
# v1.1 ②:os-rescue --clean-esp 这个显式入口(usage + 分派 + 实现)
if grep -q -- '--clean-esp' mkosi.extra/usr/bin/os-rescue &&
   grep -q 'do_clean_esp' mkosi.extra/usr/bin/os-rescue &&
   grep -q 'clean-esp) do_clean_esp' mkosi.extra/usr/bin/os-rescue &&
   grep -q 'pending' mkosi.extra/usr/bin/os-rescue; then
    ok "os-rescue --clean-esp:清墓碑与被取代的计数条目,且**跳过 pending 槽**(不取消待确认的更新)"
else
    no "os-rescue 缺少 --clean-esp(pending 槽不被误删的判据也要在)"
fi
# keel-check 要指向清理入口,不能只报"有 N 个 .failed"
if grep -q 'os-rescue --clean-esp' mkosi.extra/usr/share/keel/keel-check; then
    ok "keel-check 发现 .failed / ESP 空间紧张时给出 os-rescue --clean-esp"
else
    no "keel-check 只报告 .failed 却不告诉人怎么清"
fi

# v1 不支持 /data 迁移:带 migrate= 的载荷必须在 fetch 阶段被拒(而不是装上)
if grep -q 'migrate=' mkosi.extra/usr/bin/os-update &&
   grep -q '还没有迁移执行器' mkosi.extra/usr/bin/os-update; then
    ok "os-update fetch 会拒绝声明了 /data 迁移的载荷(v1 没有迁移执行器,拒绝好过假装迁移过)"
else
    no "os-update 没有拒绝带 migrate= 的载荷 ⇒ 可能装上一个要求迁移的版本(回滚后旧系统读不懂 /data)"
fi
if grep -q 'migrate=mkdir' tools/ota-drill-container.sh &&
   grep -q 'SRC_MIG' mkosi.extra-test/usr/lib/keel/ota-drill; then
    ok "演练会造一个带 migrate= 的载荷并验证它被拒绝"
else
    no "演练没有覆盖「带迁移的载荷被拒绝」这一项"
fi

# 运行时看门狗(决策 D25 / 坑 #50):主镜像与 initrd 各一份,且两边的值必须一致
WD_MAIN=mkosi.extra/etc/systemd/system.conf.d/keel-watchdog.conf
WD_INITRD=mkosi.extra-initrd/etc/systemd/system.conf.d/keel-watchdog.conf
if [ -f "$WD_MAIN" ] && [ -f "$WD_INITRD" ] &&
   grep -q '^RuntimeWatchdogSec=60' "$WD_MAIN" &&
   grep -q '^RuntimeWatchdogSec=60' "$WD_INITRD"; then
    if grep -q '^RebootWatchdogSec=' "$WD_MAIN" && grep -q '^RebootWatchdogSec=' "$WD_INITRD"; then
        ok "运行时看门狗配置在主镜像与 initrd 里都有,两边 RuntimeWatchdogSec 一致(坑 #50)"
    else
        no "看门狗配置缺 RebootWatchdogSec"
    fi
else
    no "缺少看门狗配置(或两边不一致)⇒ initrd 冻结时机器会一直挂着,自动回退不会发生(坑 #50)"
fi
if grep -qE '^ExtraTrees=mkosi\.extra-initrd$' mkosi.initrd.conf; then
    ok "mkosi.initrd.conf 把 mkosi.extra-initrd 挂进 initrd(initrd 不读主镜像的 /etc)"
else
    no "mkosi.initrd.conf 里没有 ExtraTrees=mkosi.extra-initrd ⇒ initrd 拿不到看门狗配置"
fi
if grep -q '^softdog$' mkosi.extra/etc/modules-load.d/keel-watchdog.conf; then
    ok "没有硬件看门狗的设备上会加载 softdog 兜底"
else
    no "没有加载 softdog ⇒ 部分真机上 RuntimeWatchdogSec 只会打一条警告"
fi

# 启动失败看门狗(决策 D26):没到 boot-complete ⇒ 自动重启;三类失败各一道兜底
BF=mkosi.extra/usr/lib/systemd/system/keel-boot-failed-reboot.service
if [ -f "$BF" ] && grep -q '^WantedBy=emergency.target rescue.target$' "$BF" &&
   [ -x mkosi.extra/usr/lib/keel/boot-failed-reboot ] &&
   grep -q '^enable keel-boot-failed-reboot.service$' \
        mkosi.extra/usr/lib/systemd/system-preset/00-keel.preset; then
    if grep -q '/run/keel/boot-complete' mkosi.extra/usr/lib/keel/confirm &&
       grep -q 'systemctl stop keel-boot-failed-reboot' mkosi.extra/usr/lib/keel/boot-failed-reboot; then
        ok "启动失败看门狗:emergency/rescue 时 60 秒后自动回退,且告诉人怎么取消(决策 D26)"
    else
        no "启动失败看门狗缺「boot-complete 标记」或「取消方式」提示"
    fi
else
    no "缺少 keel-boot-failed-reboot(emergency 那类失败会停在提示符前,自动回滚不成立)"
fi

}
