# shellcheck shell=bash
# keel verify 模块:initrd 冻结兜底(已查实,尚未修;v1.2 3.0 / 坑 #76/#77)
#
# 2026-09-28 实测结论(两条):
#   ① mkosi 25.3 **不读 mkosi.initrd.conf** ⇒ v1.1 的 ExtraTrees=mkosi.extra-initrd
#      从来没进过 initrd:看门狗配置与 softdog 都不在里面,而那两条「配置在不在」的断言是空断言;
#   ② 「用 mkosi --initrd 追加一个未压缩 cpio」也**不通**:实测打破 initramfs 链
#      (内核 VFS: Unable to mount root fs,正常槽都起不来)。
# 所以这一节不再假装「修好了」,而是:盯住已查实的事实、盯住没有偷偷接上会炸的写法,
# 并把准备好的补充层(mkinitrd-extra.sh + mkosi.initrd-extra/)做功能验证,给未来的修复用。

verify_initrd_watchdog() {
head1 "16. initrd 冻结兜底(已查实根因,尚未接进构建;坑 #76/#77)"

MK=tools/mkinitrd-extra.sh

if [ -x "$MK" ] &&
   grep -qF 'mkosi.initrd-extra' "$MK" &&
   grep -qF 'KEEL_INITRD_EXTRA_OUT' "$MK" &&
   grep -qF 'cpio -o -H newc' "$MK" &&
   grep -qF '回读失败' "$MK"; then
    ok "tools/mkinitrd-extra.sh 已备好:把 mkosi.initrd-extra/ 打成 newc cpio 并按内容回读(修复时的素材)"
else
    no "mkinitrd-extra.sh 缺环节(打包 / 回读 / 输出覆盖)"
fi
# 两份配置必须同值(将来注入成功时,主系统与 initrd 的看门狗行为才一致)
WD_MAIN=mkosi.extra/etc/systemd/system.conf.d/keel-watchdog.conf
WD_INITRD=mkosi.initrd-extra/etc/systemd/system.conf.d/keel-watchdog.conf
if grep -q '^RuntimeWatchdogSec=60$' "$WD_MAIN" && grep -q '^RuntimeWatchdogSec=60$' "$WD_INITRD" &&
   grep -q '^RebootWatchdogSec=' "$WD_MAIN" && grep -q '^RebootWatchdogSec=' "$WD_INITRD"; then
    ok "主镜像与 initrd 两份看门狗配置值一致(RuntimeWatchdogSec=60 + RebootWatchdogSec)"
else
    no "两份看门狗配置不一致(将来注入成功后会一头松开)"
fi
# 反向断言:修理未完成前,构建路径不许偷偷用 --initrd / mkinitrd-extra(会炸)
# 只查**真正的接线**(命令行里出现),注释里提到 --initrd 不算(那是说明为什么不能用)
wired=""
for f in tools/build.sh tools/build-container.sh tools/ota-drill-container.sh; do
    if grep -qF -- '--initrd "$OUT/keel-initrd-extra.cpio"' "$f" ||
       grep -qF -- '--initrd mkosi.output/keel-initrd-extra.cpio' "$f" ||
       grep -qF -- '&& tools/mkinitrd-extra.sh' "$f"; then
        wired="$wired $f"
    fi
done
if [ -z "$wired" ]; then
    ok "构建路径没有偷偷接上会打破 initramfs 的 --initrd(坑 #77 的现场不会重演)"
else
    no "这些构建入口又接上了 --initrd/mkinitrd-extra:$wired(实测会 VFS unable to mount root,先读坑 #77)"
fi
if grep -qF '刻意还没接进构建' tools/build.sh && grep -qF 'traps.md #77' tools/build.sh; then
    ok "build.sh 写清了「为什么刻意还没接」与坑号(后人不会以为它生效了)"
else
    no "build.sh 没说明 initrd 补充层为何没接进去 ⇒ 后人会重复踩坑"
fi
if grep -qF '不读这个文件' mkosi.initrd.conf && grep -qF 'mkinitrd-extra.sh' mkosi.initrd.conf; then
    ok "mkosi.initrd.conf 已标注「mkosi 25.3 不读它」并指向新素材(不会再被当成生效的配置)"
else
    no "mkosi.initrd.conf 还显得像生效的配置 ⇒ 后人会再信一次(坑 #76)"
fi
if grep -qF 'initrd 冻结兜底仍是已知缺口' tools/ota-drill-container.sh; then
    ok "演练改为如实打印「initrd 冻结仍是已知缺口」,没有会假绿的检查"
else
    no "演练里的 initrd 冻结检查不是「如实说明缺口」的形态"
fi

# ── 功能测试:cpio 素材本身要真的能打/能读 ──────────────────────────────────
if ! have cpio; then
    skip "没有 cpio,跳过 initrd 补充层的功能测试"
else
    it="$(tmpd)"
    if KEEL_INITRD_EXTRA_OUT="$it/x.cpio" bash "$MK" >/dev/null 2>&1 &&
       [ -s "$it/x.cpio" ] &&
       cpio -it --quiet <"$it/x.cpio" 2>/dev/null | grep -qx 'etc/systemd/system.conf.d/keel-watchdog.conf' &&
       cpio -it --quiet <"$it/x.cpio" 2>/dev/null | grep -qx 'etc/modules-load.d/keel-softdog.conf'; then
        ok "功能测试:素材 cpio 里确实有看门狗配置与 softdog 加载列表(修复时可直接用)"
    else
        no "mkinitrd-extra.sh 打出来的 cpio 里缺文件"
    fi
    if cpio -i --to-stdout 'etc/systemd/system.conf.d/keel-watchdog.conf' <"$it/x.cpio" 2>/dev/null | grep -q '^RuntimeWatchdogSec=60$' &&
       cpio -i --to-stdout 'etc/modules-load.d/keel-softdog.conf' <"$it/x.cpio" 2>/dev/null | grep -q '^softdog$'; then
        ok "功能测试:cpio 里 RuntimeWatchdogSec=60 与 softdog 内容正确"
    else
        no "cpio 里两个文件的内容不对"
    fi
    empty="$(tmpd)"; mkdir -p "$empty/etc/systemd"
    if KEEL_INITRD_EXTRA_DIR="$empty" KEEL_INITRD_EXTRA_OUT="$it/y.cpio" bash "$MK" >/dev/null 2>&1; then
        no "源目录里没有那两个文件时 mkinitrd-extra.sh 仍然成功(回读断言是空的)"
    else
        ok "源目录缺文件时 mkinitrd-extra.sh 拒绝(定向变异:required/回读断言非空)"
    fi
fi

# === PART_B_END ===

}
