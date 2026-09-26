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
pcr_disabled=$(grep -c '^disable systemd-pcrlock' "$PRESET" || true)
if [ "$pcr_disabled" -eq 8 ]; then
    ok "preset 里 disable 了 8 个 systemd-pcrlock 单元(7 服务 + socket)"
else
    no "preset 里 disable 的 systemd-pcrlock 条目是 $pcr_disabled 个(应为 8)"
fi
if grep -q 'ln -sfn /dev/null' mkosi.postinst && grep -q 'systemd-pcrlock.socket' mkosi.postinst; then
    # 只看 mask 循环里的条目行(注释里提到 @.service 不算)
    if grep -qE '^[[:space:]]+systemd-pcrlock@\.service[[:space:]]*\\?[[:space:]]*$' mkosi.postinst; then
        no "postinst 把 systemd-pcrlock@.service(模板)也 mask 了 —— preset-all 会为此报一条失败"
    else
        ok "postinst 把 8 个 systemd-pcrlock 单元 mask 成 /dev/null(7 服务 + socket;刻意不碰模板)"
    fi
else
    no "postinst 里缺少 systemd-pcrlock 的 mask"
fi

}
