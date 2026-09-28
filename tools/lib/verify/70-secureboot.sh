# shellcheck shell=bash
# keel verify 模块:Secure Boot(v1.2 1.2)
#
# v1.2 起 mkosi.conf 里 SecureBoot=yes:systemd-boot 与每个 UKI 都用**我们自己的**
# mkosi.key / mkosi.crt 签(自签 db)。这里盯四件事:
#   ① 配置真的开了(mkosi summary 里 UEFI SecureBoot: yes)+ 密钥路径可用;
#   ② 没有密钥时 build.sh 说人话地拒绝(而不是埋进 mkosi 日志);
#   ③ 私钥不进 git(.gitignore);
#   ④ pcrlock 解封的断言在 90-identity(第 8 节)里翻转 —— 这里只交叉引用一句。

verify_secureboot() {
head1 "14. Secure Boot(自签 db / UKI 签名 / pcrlock 解封)"

if grep -qE '^[[:space:]]*SecureBoot=yes' mkosi.conf &&
   grep -qE '^[[:space:]]*SecureBootAutoEnroll=yes' mkosi.conf; then
    ok "mkosi.conf 开了 SecureBoot=yes + SecureBootAutoEnroll=yes(VM 自动登记;真机看 docs/install.md)"
else
    no "mkosi.conf 没有开 SecureBoot=yes / SecureBootAutoEnroll=yes"
fi
# 功能检查:mkosi 真解析出 yes,而且密钥自动识别到仓库根目录的这一对
if have mkosi; then
    sb_sum="$(mkosi --profile install summary 2>/dev/null | grep -iE 'UEFI SecureBoot:|SecureBoot Signing Key:|SecureBoot Certificate:')"
    if printf '%s' "$sb_sum" | grep -q 'UEFI SecureBoot: yes' &&
       printf '%s' "$sb_sum" | grep -q 'mkosi.key' &&
       printf '%s' "$sb_sum" | grep -q 'mkosi.crt'; then
        ok "mkosi 解析结果:UEFI SecureBoot=yes,签名钥/证书 = 仓库根的 mkosi.key/mkosi.crt"
    else
        no "mkosi 没有解析出 SecureBoot=yes(或密钥没被自动识别):"
        printf '%s\n' "$sb_sum" | head -5 | sed 's/^/      /'
    fi
else
    skip "没有 mkosi,跳过 Secure Boot 配置的功能解析"
fi
if grep -qF 'mkosi.key' tools/build.sh && grep -qF 'sudo mkosi genkey' tools/build.sh; then
    ok "build.sh 在缺少 mkosi.key/mkosi.crt 时拒绝构建,并告诉人怎么生成"
else
    no "build.sh 没有'缺 Secure Boot 密钥就拒绝'的检查"
fi
if git check-ignore -q mkosi.key && git check-ignore -q mkosi.crt; then
    ok "mkosi.key / mkosi.crt 被 .gitignore 覆盖(私钥不进 git)"
else
    no "mkosi.key / mkosi.crt 没有被 .gitignore 覆盖"
fi
if grep -qF 'SecureBoot=yes' mkosi.conf &&
   grep -qE '^[[:space:]]*SecureBoot=yes' mkosi.conf; then
    ok "SecureBoot 设置写在 mkosi.conf 的 [Validation] 段(所有 profile 共享)"
else
    no "SecureBoot 设置不在 mkosi.conf(某个 profile 可能没签名)"
fi
# pcrlock 解封:第 8 节已翻转为"不许 disable / 不许 mask",这里只确认两处都真的翻过来了
if grep -q 'v1.2 起解封' mkosi.extra/usr/lib/systemd/system-preset/00-keel.preset &&
   grep -q 'pcrlock 单元未被 mask' mkosi.postinst; then
    ok "pcrlock 解封的两处(preset 不 disable + postinst 反查 mask)都在;断言见第 8 节"
else
    no "pcrlock 解封不完整(preset/postinst 有一处没翻)"
fi
# 演练里要真的看到"固件以 Secure Boot 模式启动了我们签的 UKI"(不然签名是自说自话)
if grep -qF '判定:Secure Boot 已启用' mkosi.extra-test/usr/lib/keel/ota-drill &&
   grep -qF '判定:Secure Boot 已启用' tools/ota-drill-container.sh; then
    ok "演练把 guest 的 Secure Boot 状态算进宿主侧关键判定(bootctl status 必须 enabled)"
else
    no "演练没有把 Secure Boot 状态算进关键判定"
fi
# 解封之后 VM 里 pcrlock 会真跑并(在没有真实 event log 时)失败:keel-check 必须区分 VM 与真机
if grep -qF '全是 systemd-pcrlock-*' mkosi.extra/usr/share/keel/keel-check &&
   grep -qF 'pcr_failed' mkosi.extra/usr/share/keel/keel-check; then
    ok "keel-check:失败单元全是 pcrlock* 且本机是 VM 时降级为警告(真机仍算失败)"
else
    no "keel-check 没有为'解封后的 pcrlock 在无测量链环境失败'做区分(会假红)"
fi

}
