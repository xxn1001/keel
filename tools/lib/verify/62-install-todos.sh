# shellcheck shell=bash
# keel verify 模块:os-install 两个 TODO 结清 + confirm_kind 功能测试 + keel_version(原第 677-739 行,逐字搬移)

verify_install_todos() {
# ---------------------------------------------------------------------------
# ④ 的两个 v1 TODO 必须在 2026-09 结清(roadmap §0 ④ / §2.7)
#
# 结清 ≠ 删掉注释:两条都要有**可检查的替代物** ——
#   ① 容量判据:读不到容量必须**拒绝**(旧写法是 `[ -n .. ] && [ -n .. ] && refuse`,
#      两个变量都空时静默放行 —— 那是坑 #36 那种"每一步都成功"的形态);
#   ② 首启边界:keel-confirm 要把"装机后的第一次启动"和"一次更新成功"在日志上分开。
# ---------------------------------------------------------------------------
if ! grep -q 'TODO(待验证):根文件系统的实际占用' mkosi.extra/usr/bin/os-install &&
   grep -q '容量核对' mkosi.extra/usr/bin/os-install &&
   grep -q '读不到当前根设备' mkosi.extra/usr/bin/os-install &&
   grep -q '读不到目标分区' mkosi.extra/usr/bin/os-install; then
    ok "os-install ① 已结清:拷整块设备 ⇒ 判据是分区容量;读不到容量**拒绝**而不是跳过检查"
else
    no "os-install 的容量判据没结清(要么 TODO 还在,要么读不到容量时仍会放行)"
fi
if ! grep -q 'TODO(待验证):keel-confirm 对' mkosi.extra/usr/bin/os-install &&
   grep -q 'first_boot=1' mkosi.extra/usr/bin/os-install &&
   grep -q 'keel_state_get first_boot' mkosi.extra/usr/lib/keel/confirm &&
   grep -q 'keel_state_set first_boot ""' mkosi.extra/usr/lib/keel/confirm &&
   grep -q '首次启动' mkosi.extra/usr/lib/keel/confirm &&
   grep -q 'firstboot:58' mkosi.extra/usr/lib/keel/confirm; then
    ok "os-install ② 已结清:显式 first_boot 标记区分「装机后首次启动」与「更新成功」,用完即清(不靠 running_slot 是否为空 —— firstboot 会先把它填上)"
else
    no "首启边界没结清:os-install 写 first_boot、confirm 读+清 first_boot 要成对,且不能用 running_slot 判"
fi
# 功能测试:confirm_kind 的判据必须是**一次性标记**,不是"running_slot 恰好为空"。
# 后者被 keel-firstboot 先填上,永远为假 —— 那正是本仓库坑 #65 的现场。
ft3=$(tmpd)
sed -n '/^confirm_kind()/,/^}/p' mkosi.extra/usr/lib/keel/confirm >"$ft3/fn.sh"
if [ -s "$ft3/fn.sh" ] && (
    # shellcheck disable=SC1091
    . mkosi.extra/usr/lib/keel/lib.sh
    KEEL_STATE_DIR="$ft3/keel"
    KEEL_STATE="$KEEL_STATE_DIR/state"
    install -d -m 0755 "$KEEL_STATE_DIR"
    # shellcheck disable=SC1090
    . "$ft3/fn.sh"
    # ① 有 first_boot=1 → 首次启动
    printf 'running_slot=a\nfirst_boot=1\n' >"$KEEL_STATE"
    [ "$(confirm_kind)" = first-boot ] || exit 1
    # ② 没有 first_boot(而且 running_slot **已经有值**)→ 更新成功
    printf 'running_slot=a\nlast_result=success\n' >"$KEEL_STATE"
    [ "$(confirm_kind)" = update ] || exit 1
    # ③ first_boot 存在但不是 1 → 更新成功(别把空值当成 true)
    printf 'first_boot=\n' >"$KEEL_STATE"
    [ "$(confirm_kind)" = update ] || exit 1
    exit 0
); then
    ok "confirm_kind 实跑:first_boot=1 → 首次启动;没有它(哪怕 running_slot 已填)→ 更新"
else
    no "confirm_kind 判据不对 —— 可能又用回了「running_slot 为空」(坑 #65)"
fi

# keel 的"系统版本"必须来自 /usr/lib/os-release 的 IMAGE_VERSION(mkosi 写的),
# **不能**用 Debian 的 VERSION_ID —— 那会让版本显示成 "13",而且 os-update 的版本比较
# 会恒等 ⇒ 永远认为"已经是最新"(坑 #35)。
if sed -n '/^keel_version()/,/^}/p' mkosi.extra/usr/lib/keel/lib.sh | grep -q 'IMAGE_VERSION'; then
    ok "keel_version 读 IMAGE_VERSION(不是 Debian 的 VERSION_ID,坑 #35)"
else
    no "keel_version 没读 IMAGE_VERSION —— 版本会显示成 13、os-update 的版本比较也会失效(坑 #35)"
fi

}
