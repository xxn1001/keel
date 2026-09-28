# shellcheck shell=bash
# keel verify 模块:系统标识与 pcrlock(原第 1466-1499 行,逐字搬移)

verify_identity() {
# ---------------------------------------------------------------------------
head1 "8. 系统标识与 pcrlock(决策 D22 / D20)"
# ---------------------------------------------------------------------------
for kv in "Hostname=keel" "Timezone=Asia/Shanghai" "Locale=C.UTF-8"; do
    if grep -qE "^[[:space:]]*${kv}$" mkosi.conf.d/30-content.conf; then
        ok "30-content.conf 里有 $kv"
    else
        no "30-content.conf 里缺少 $kv"
    fi
done
if grep -q 'cmp -s "$R/etc/localtime"' "$FIN" && grep -q 'etc/locale.conf' "$FIN"; then
    ok "finalize 回读断言 /etc/hostname、/etc/localtime、/etc/locale.conf"
else
    no "finalize 没有回读系统标识(那三步「退出码 0」什么也证明不了)"
fi

PRESET=mkosi.extra/usr/lib/systemd/system-preset/00-keel.preset
# v1.2 起**解封**(决策 D20 写着"将来做 Secure Boot 时解封",现在兑现):
# preset 里不许再有 disable;postinst 反过来要断言"镜像里没有 mask"。
pcr_disabled=$(grep -c '^disable systemd-pcrlock' "$PRESET" || true)
if [ "$pcr_disabled" -eq 0 ]; then
    ok "preset 里没有 disable 任何 systemd-pcrlock 单元(v1.2 已解封,决策 D20)"
else
    no "preset 里还有 $pcr_disabled 条 systemd-pcrlock disable ⇒ v1.2 必须解封(决策 D20)"
fi
if grep -q 'ln -sfn /dev/null' mkosi.postinst; then
    no "postinst 还在建 /dev/null mask ⇒ v1.2 起 pcrlock 必须解封"
elif grep -q 'systemd-pcrlock 单元未被 mask' mkosi.postinst && grep -q 'pcrlock_masks' mkosi.postinst; then
    ok "postinst 反向回读断言:pcrlock 不许有 mask(解封的构建期判据)"
else
    no "postinst 没有「pcrlock 不许被 mask」的回读断言"
fi

}
