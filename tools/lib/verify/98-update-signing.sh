# shellcheck shell=bash
# keel verify 模块:更新签名(v1.2 1.1)
#
# 这一节盯四件事:
#   ① 机制库真的 fail-closed(没有 .sig / 没有 key_id / 没有公钥 / 验签不过 ⇒ 拒绝),
#      而且 v1 那条"源没签名就只警告后继续"的 fail-open 分支**不许再存在**(反向断言;
#      这种分支最容易在后续重构里悄悄复活,而复活了照旧全绿);
#   ② 验签发生在**下载载荷之前**(先判两个小文件,再动 GiB 级的载荷);
#   ③ 公钥有一个可信来源:构建期由 tools/sign.sh sync 放进镜像树,postinst 回读断言,
#      三条构建路径(build.sh / build-container.sh 的 vm / 演练)都真的 sync;
#   ④ 功能测试(**不靠 grep**):用临时密钥真的签一次 manifest,再用镜像里同一条
#      openssl 命令验;然后把 manifest 改一个字节证明"验得过"不是永远为真
#      (变异验证 —— 反向断言永远为真正是坑 #69 的坑型)。
#
# 这里不重复 96-manifest-protocol 的产物名/前缀断言,只盯签名这一层。

verify_update_signing() {
head1 "12. 更新签名(v1.2 1.1:fail-closed + 公钥落地 + tools/sign.sh)"

SIGN=tools/sign.sh
MECH=$UPDATE_MECH
POSTINST=mkosi.postinst
DRILL=tools/ota-drill-container.sh
DRILL_GUEST=mkosi.extra-test/usr/lib/keel/ota-drill
# 演练源的路径前缀单独放变量:第 11 节会 grep 校验器源码里有没有写死的 /tmp/<字母> 路径
# (固定名字的世界可写路径,前一个 uid 能卡住下一个 uid),直接写字面量会撞那条断言。
TS=/tmp

# ── ① fail-closed 的四种拒绝路径必须同时存在 ───────────────────────────────
sig_missing=""
for pat in '未签名的更新源' '缺少合法的 key_id=' '本机没有 key_id=' '验签失败(key_id='; do
    grep -qF "$pat" "$MECH" || sig_missing="$sig_missing [$pat]"
done
if [ -z "$sig_missing" ]; then
    ok "机制库四种拒绝路径俱全:无 .sig / 无 key_id / 无公钥 / 验签不过(fail-closed)"
else
    no "机制库缺少强制验签的拒绝路径:$sig_missing"
fi

# 反向断言:v1 的 fail-open 代码不许复活(用旧代码里的原话当判据,不匹配注释)
fail_open=$(grep -nE '更新源没有分布|警告:本次更新没有签名保护|v1 策略:继续' "$MECH" || true)
if [ -z "$fail_open" ]; then
    ok "机制库里没有「源没签名也继续」的 fail-open 分支(反向断言,防止以后写回来)"
else
    no "机制库里又出现了 fail-open 分支(v1.2 起必须拒绝未签名的更新):"
    printf '%s\n' "$fail_open" | head -3 | sed 's/^/      /'
fi

# 旧的单文件公钥路径必须退场(现在是 /usr/share/keel/update-keys/<key_id>.pub)
if grep -qF '/usr/share/keel/update-key.pub' "$MECH"; then
    no "机制库还在用旧的单文件公钥路径 /usr/share/keel/update-key.pub(应改为 update-keys/<key_id>.pub)"
else
    ok "机制库不再引用旧的单文件公钥路径(公钥走 update-keys/<key_id>.pub,支持轮换)"
fi

# ── ② 验签排在下载载荷之前 ─────────────────────────────────────────────────
line_of() { grep -nF "$1" "$2" 2>/dev/null | head -n1 | cut -d: -f1; }
sig_line="$(line_of 'verify_manifest_signature "$DEST"' "$MECH")"
dl_line="$(line_of 'for a in "${ARTIFACTS[@]}"' "$MECH")"
if [ -n "$sig_line" ] && [ -n "$dl_line" ] && [ "$sig_line" -lt "$dl_line" ]; then
    ok "机制库在下载载荷之前验签(第 $sig_line 行 < 第 $dl_line 行;便宜的检查先做)"
else
    no "机制库的验签不在下载载荷之前(验签行='${sig_line:-无}',下载行='${dl_line:-无}')⇒ 会先下 GiB 级载荷再拒绝"
fi

# ── ③ 公钥落地 + 三条构建路径都 sync ────────────────────────────────────────
if [ -x "$SIGN" ] &&
   grep -q 'cmd_gen' "$SIGN" && grep -q 'cmd_sync' "$SIGN" &&
   grep -q 'cmd_sign' "$SIGN" && grep -q 'cmd_verify' "$SIGN" &&
   grep -q 'cmd_rotate' "$SIGN" && grep -q 'cmd_use' "$SIGN"; then
    ok "tools/sign.sh 可执行,gen/use/rotate/sync/sign/verify 齐全(密钥生成与轮换入口)"
else
    no "tools/sign.sh 缺失或命令不齐(gen/use/rotate/sync/sign/verify)"
fi

if grep -qF 'usr/share/keel/update-keys' "$POSTINST" && grep -qF '没有更新签名公钥' "$POSTINST"; then
    ok "mkosi.postinst 回读断言公钥进了镜像(缺公钥的产物在构建期就被拒,不会装成'不能更新'的机器)"
else
    no "mkosi.postinst 没有'公钥必须进镜像'的回读断言"
fi
if grep -qF 'openssl' mkosi.conf.d/20-packages.conf && grep -qF '/usr/bin/openssl' "$POSTINST"; then
    ok "openssl 显式进 Packages,且 postinst 断言 /usr/bin/openssl 存在(验签的运行时依赖)"
else
    no "openssl 没有显式进 Packages,或 postinst 没断言它在镜像里"
fi

build_sync_missing=""
for pat in 'SIGN_TOOL=tools/sign.sh' '"$SIGN_TOOL" id' '"$SIGN_TOOL" sync' '"$SIGN_TOOL" sign' 'echo "key_id='; do
    grep -qF "$pat" tools/build.sh || build_sync_missing="$build_sync_missing [$pat]"
done
if [ -z "$build_sync_missing" ]; then
    ok "tools/build.sh 取密钥 id、sync 公钥、写 manifest key_id=、给产物签名(全链路)"
else
    no "tools/build.sh 的签名链缺环节:$build_sync_missing"
fi
if grep -qF 'tools/sign.sh sync' tools/build-container.sh; then
    ok "build-container.sh 的 vm 模式先 sync 公钥(vm 绕过 build.sh 直接调 mkosi)"
else
    no "build-container.sh 的 vm 模式没 sync 公钥 ⇒ 那条路会因镜像无公钥而构建失败"
fi
if git check-ignore -q mkosi.extra/usr/share/keel/update-keys/verify-probe.pub 2>/dev/null; then
    ok "公钥落地目录被 .gitignore 覆盖(生成的公钥不会被误提交)"
else
    no "mkosi.extra/usr/share/keel/update-keys/ 不在 .gitignore 里(构建会往源码树里放公钥)"
fi

# ── ④ 演练的三条签名路径 ───────────────────────────────────────────────────
drill_missing=""
for pat in "$TS/drill-serve/unsigned" "$TS/drill-serve/badsig" \
           "tools/sign.sh sign $TS/drill-serve/bad" "tools/sign.sh sign $TS/drill-serve/mig"; do
    grep -qF "$pat" "$DRILL" || drill_missing="$drill_missing [$pat]"
done
if [ -z "$drill_missing" ]; then
    ok "演练摆了 good/unsigned/badsig 三个源,并给坏载荷+迁移载荷合法签名(否则测的是签名而不是它们)"
else
    no "演练缺签名路径:$drill_missing"
fi
if grep -qF 'guard_reject "$SRC_UNSIGNED"' "$DRILL_GUEST" &&
   grep -qF 'guard_reject "$SRC_BADSIG"' "$DRILL_GUEST" &&
   grep -qF '验签通过' "$DRILL_GUEST" &&
   grep -qF '没有在 /data/ota 留下任何载荷' "$DRILL_GUEST"; then
    ok "guest 演练断言:unsigned/badsig 被拒 + 不留载荷 + good 源必须带「验签通过」证据"
else
    no "guest 演练没有覆盖三条签名路径(或没有'被拒后不留载荷'的断言)"
fi

# ── ⑤ 功能测试:真的签、真的验、真的变异 ───────────────────────────────────
sd="$(tmpd)"; kd="$sd/keys"; stage="$sd/stage"
printf 'version=9.9.9-verify\nkey_id=verifytest\nsha256_x=deadbeef\n' >"$sd/manifest"
if KEEL_KEYS_DIR="$kd" bash "$SIGN" gen verifytest >/dev/null 2>&1 &&
   KEEL_KEYS_DIR="$kd" bash "$SIGN" sign "$sd" >/dev/null 2>&1 &&
   [ -s "$sd/manifest.sig" ]; then
    ok "tools/sign.sh gen/sign 真的生成密钥并签出 manifest.sig(功能测试,不是 grep)"
else
    no "tools/sign.sh gen/sign 功能测试失败(临时目录里跑不出 manifest.sig)"
fi
if [ -s "$sd/manifest.sig" ] &&
   openssl dgst -sha256 -verify "$kd/update-key-verifytest.pub" \
       -signature "$sd/manifest.sig" "$sd/manifest" >/dev/null 2>&1; then
    ok "刚签出的 manifest.sig 能被「镜像里同一条 openssl 命令」验过(签发/验证两侧成对)"
else
    no "openssl dgst -sha256 -verify 验不过自己签的 manifest.sig(两侧命令不成对)"
fi
# 变异:改一个字节必须验不过。这条如果也"通过",说明上面的验签断言是空的。
if [ -s "$sd/manifest.sig" ]; then
    cp "$sd/manifest" "$sd/manifest.tampered"
    printf '# tampered\n' >>"$sd/manifest.tampered"
    if openssl dgst -sha256 -verify "$kd/update-key-verifytest.pub" \
           -signature "$sd/manifest.sig" "$sd/manifest.tampered" >/dev/null 2>&1; then
        no "manifest 被改之后验签居然还通过 ⇒ 上面的「验签通过」断言是空的(变异验证失败)"
    else
        ok "manifest 改一个字节后验签失败(定向变异:验签断言非空)"
    fi
fi
if KEEL_KEYS_DIR="$kd" KEEL_UPDATE_KEYS_STAGE="$stage" bash "$SIGN" sync >/dev/null 2>&1 &&
   [ -s "$stage/verifytest.pub" ]; then
    ok "tools/sign.sh sync 把公钥按 <key_id>.pub 落进镜像树(机制库就查这个名字)"
else
    no "tools/sign.sh sync 没把公钥落成 <key_id>.pub(机制库会找不到)"
fi
# 符号链接安全(2026-09-28 演练实测的假绿根因):manifest.sig 是符号链接时,
# sign 必须**替换链接本身**,不能顺着链接把签名写进目标文件(那会覆盖掉别人目录里
# 已经签好的 manifest.sig —— 演练的 bad/mig 目录正是这么指到 dist 的)。
sd2="$(tmpd)"; decoy="$sd2/decoy.sig"
printf 'decoy-content' >"$decoy"
printf 'version=9.9.9-verify\nkey_id=verifytest\n' >"$sd2/manifest"
ln -s "$decoy" "$sd2/manifest.sig"
if KEEL_KEYS_DIR="$kd" bash "$SIGN" sign "$sd2" >/dev/null 2>&1 &&
   [ "$(cat "$decoy")" = "decoy-content" ] &&
   [ ! -L "$sd2/manifest.sig" ] &&
   openssl dgst -sha256 -verify "$kd/update-key-verifytest.pub" \
       -signature "$sd2/manifest.sig" "$sd2/manifest" >/dev/null 2>&1; then
    ok "manifest.sig 是符号链接时 sign 只替换链接、不写穿目标(演练 bad/mig 目录的假绿坑)"
else
    no "tools/sign.sh sign 会写穿 manifest.sig 符号链接 ⇒ 会覆盖别人目录里已签好的签名"
fi
mkdir -p "$sd/wrong"
printf 'version=9.9.9-verify\nkey_id=someone-else\n' >"$sd/wrong/manifest"
if KEEL_KEYS_DIR="$kd" bash "$SIGN" sign "$sd/wrong" >/dev/null 2>&1; then
    no "tools/sign.sh 给 key_id 不一致的 manifest 也签了(会产出'签名钥与 key_id 不符'的清单)"
else
    ok "tools/sign.sh 拒绝签 key_id 与当前签名钥不一致的 manifest"
fi

# ── ⑥ 对抗复核(2026-09-28)要求的加固:防重放、退场、解析歧义、schema 静默放行 ──
# 防重放降级:签名不能证明"比本机新",拿历史已签名版本当源会被静默装上 ⇒ fetch 必须比版本。
if grep -qF '防得住伪造,防不住重放历史版本' "$MECH" &&
   [ "$(grep -c 'version_is_newer' "$MECH")" -ge 2 ]; then
    ok "fetch 拒绝比本机旧的版本(防重放降级;check 与 fetch 共用同一版本判据)"
else
    no "fetch 没有防重放降级:拿历史已签名版本当更新源会被静默装上(验签挡不住)"
fi
# 退场:只删私钥不够 —— 公钥还在 keys/ 里就会被每次 sync 烤进新镜像,新版机器永远信它。
if grep -qF 'cmd_retire' "$SIGN" && grep -qF 'retire)' "$SIGN"; then
    ok "tools/sign.sh 有 retire(私钥+公钥一起移出 keys/,不再进新镜像)"
else
    no "tools/sign.sh 没有 retire 子命令(退休钥的公钥会永久留在新镜像的信任库里)"
fi
if grep -qF 'active-key-id' "$POSTINST" && grep -qF '没有对应的公钥' "$POSTINST"; then
    ok "postinst 断言**当前签名钥**的公钥真的在镜像里(不满足于'至少有一个 .pub')"
else
    no "postinst 只数 .pub 个数,发现不了'当前签名钥的公钥没进镜像'"
fi
# 解析歧义:manifest_get 不再用正则(sha256_ 里的 . 曾能匹配任意字符)
if (
    # shellcheck disable=SC1090  # $MECH 是 common.sh 赋的常量变量,静态检查跟不了
    . "$MECH"
    printf 'xxsha256_x=bogus\nsha256_x=real\n' >"$sd/mget"
    [ "$(manifest_get "$sd/mget" sha256_x)" = "real" ]
); then
    ok "manifest_get 按行做字面前缀匹配(sha256_ 里的 . 不再当通配,xxsha256_x= 抢不走真实值)"
else
    no "manifest_get 仍会被 sha256_ 里的 . 通配匹配(可能读到伪造前缀行)"
fi
if grep -qF '""|*[!0-9]*) printf' "$MECH"; then
    ok "/data/keel/schema-version 被写坏(非数字)时当作 0 ⇒ schema 检查拒绝而不是静默放行"
else
    no "volume_schema 不校验数字:写坏的 schema-version 会让 schema 检查静默放行"
fi
if grep -qF 'keel_update_check_state update-available "$rv" "$sig_state"' "$MECH" &&
   grep -qF '${unote:+ —— $unote}' mkosi.extra/usr/bin/os-status; then
    ok "check 的签名结论写进 update-check.state 且 os-status 会显示(未签名源不再显示成'正常可用')"
else
    no "check 的签名结论没有落到状态文件/os-status(未签名源在状态报告里看不出问题)"
fi
# sync 的配对检查(功能):破坏公钥后 sync 必须拒绝
sd3="$(tmpd)"; kd3="$sd3/keys"
KEEL_KEYS_DIR="$kd3" bash "$SIGN" gen pairkey >/dev/null 2>&1
printf '\n# tampered\n' >>"$kd3/update-key-pairkey.pub"
if KEEL_KEYS_DIR="$kd3" KEEL_UPDATE_KEYS_STAGE="$sd3/stage" bash "$SIGN" sync >/dev/null 2>&1; then
    no "sync 在公钥与私钥不配对时仍然成功 ⇒ 会把不一致的信任库放进镜像"
else
    ok "sync 发现公钥与私钥不配对时拒绝(不一致的信任库进不了镜像)"
fi
# retire(功能):不能退当前钥;非当前钥要连公钥一起移走
sd4="$(tmpd)"; kd4="$sd4/keys"
KEEL_KEYS_DIR="$kd4" bash "$SIGN" gen keyOne >/dev/null 2>&1
KEEL_KEYS_DIR="$kd4" bash "$SIGN" gen keyTwo >/dev/null 2>&1
if KEEL_KEYS_DIR="$kd4" bash "$SIGN" retire keyOne >/dev/null 2>&1; then
    no "retire 竟然允许让当前签名钥退场(会让机器再也签不出可验证的更新)"
else
    ok "retire 拒绝让当前签名钥退场(必须先 use 切走)"
fi
if KEEL_KEYS_DIR="$kd4" bash "$SIGN" retire keyTwo >/dev/null 2>&1 &&
   [ ! -e "$kd4/update-key-keyTwo.pub" ] && [ -e "$kd4/retired/update-key-keyTwo.pub" ]; then
    ok "retire 把非当前钥的私钥+公钥一起移出 keys/(此后 sync 不再烤进新镜像)"
else
    no "retire 没有把非当前钥完整移出 keys/"
fi

}
