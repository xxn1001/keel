# shellcheck shell=bash
# keel verify 模块:OTA 更新 manifest 协议(os-update ↔ tools/build.sh ↔ tools/ota-drill-container.sh)
#
# 更新"线上协议"其实只有一份:更新源目录里的固定文件名(ARTIFACTS)与 manifest 的
# `sha256_<name>=` 行。os-update 拿 ARTIFACTS 里的名字去下载/校验,build.sh 从固定
# 清单 echo 出 sha256 行。两侧都是普通 shell 代码:改名、加第五个产物、只改一边的
# `sha256_` 前缀,都能让更新在 fetch/stage 阶段才炸,而 tools/verify.sh 以前一条都不查。
# 这里把「名字集合 / 数量 / 真实消费点 / key 前缀 / 演练坏槽目标」钉死。
#
# 只做纯文本提取(grep/sed/tr/sort),不依赖 jq / python;不引用绝对行号,避免一动就脆。

verify_manifest_protocol() {
head1 "10. OTA manifest 协议(os-update ↔ build.sh)"
mp_update=mkosi.extra/usr/bin/os-update
mp_build=tools/build.sh
mp_drill=tools/ota-drill-container.sh

# ── 提取两侧的产物名集合(排序后冻结成字符串,比较与顺序无关)──────────────────
# os-update:`readonly ARTIFACTS=(a b c d)` → 每行一个名字
mp_u_arts=$(grep -m1 '^readonly ARTIFACTS=(' "$mp_update" 2>/dev/null \
    | sed 's/^[^(]*(//; s/).*$//' | tr ' ' '\n' | sed '/^[[:space:]]*$/d' | sort)
# build.sh:`echo "sha256_<name>=$(…)"` → 只取 <name>
mp_b_arts=$(grep -oE 'echo "sha256_[^=]+=' "$mp_build" 2>/dev/null \
    | sed 's/^echo "sha256_//; s/=$//' | sort)
mp_u_n=$(printf '%s\n' "$mp_u_arts" | grep -c . || true)
mp_b_n=$(printf '%s\n' "$mp_b_arts" | grep -c . || true)

# (a) 两侧名字集合相等 —— 谁单方面改了产物名,这里就是红,并把两份清单都打出来
if [ -n "$mp_u_arts" ] && [ "$mp_u_arts" = "$mp_b_arts" ]; then
    ok "产物名集合两侧一致(${mp_u_n} 个:$(printf '%s' "$mp_u_arts" | tr '\n' ' '))"
else
    no "产物名集合漂移:os-update 的 ARTIFACTS 与 build.sh 的 sha256_<name>= 行对不上(改协议必须两边一起改)"
    printf '      os-update ARTIFACTS(%s):\n' "$mp_u_n"
    printf '%s\n' "$mp_u_arts" | sed 's/^/        /'
    printf '      build.sh  manifest(%s):\n' "$mp_b_n"
    printf '%s\n' "$mp_b_arts" | sed 's/^/        /'
fi

# (b) 数量恰为 4 —— 否则把数组清空后 (a) 的集合相等会退化成"空 == 空"的假绿
if [ "$mp_u_n" = 4 ] && [ "$mp_b_n" = 4 ]; then
    ok "两侧都恰好 4 个产物(清空数组/漏一个都会在这里红)"
else
    no "产物数量不是 4:os-update=${mp_u_n} 个,build.sh=${mp_b_n} 个(校验点注释也写死 sha256 全部匹配 4 个)"
fi

# (c) os-update 真的在下载/校验循环里消费这个数组(定义了却没人用 = 协议断言是空的)
#     真实消费点:for a in "${ARTIFACTS[@]}" → fetch_one "$a" / manifest_get … "sha256_$a"
mp_use=$(grep -cF '"${ARTIFACTS[@]}"' "$mp_update" 2>/dev/null || true)
if [ "${mp_use:-0}" -ge 1 ]; then
    ok "os-update 的下载/校验循环引用了 \"\${ARTIFACTS[@]}\"(${mp_use} 处;校验点用 manifest_get … \"sha256_\$a\")"
else
    no "os-update 没有引用 \"\${ARTIFACTS[@]}\":数组定义了却没人消费,上面两条断言失去意义"
fi

# (d) manifest key 前缀两侧必须是同一个字面量 sha256_(os-update 用 "sha256_$a" 去查)
mp_prefix_u=$(grep -oE '"sha256_[$]a"' "$mp_update" 2>/dev/null | sed 's/"//g; s/[$]a$//' | sort -u)
mp_prefix_b=$(grep -oE 'echo "sha256_[^=]+=' "$mp_build" 2>/dev/null | sed -n 's/^echo "\(sha256_\)[^=]*=.*/\1/p' | sort -u)
if [ "$mp_prefix_u" = "sha256_" ] && [ "$mp_prefix_b" = "sha256_" ]; then
    ok "manifest key 前缀两侧一致:os-update 查 \"sha256_\$a\",build.sh 写 \"sha256_<name>=\"(同为字面量 sha256_)"
else
    no "manifest key 前缀不一致:os-update 侧='${mp_prefix_u:-<无>}' build.sh 侧='${mp_prefix_b:-<无>}'(必须同为 sha256_)"
fi

# (e) 演练的坏槽载荷 key 必须落在 ARTIFACTS 里 —— 否则改名后演练会打到一个不存在的产物
if grep -qF 'sha256_slot-$BAD_SLOT.root.raw' "$mp_drill"; then
    mp_missing=""
    for mp_s in a b; do
        grep -qxF "slot-${mp_s}.root.raw" <<<"$mp_u_arts" || mp_missing="${mp_missing} slot-${mp_s}.root.raw"
    done
    if [ -z "$mp_missing" ]; then
        ok "ota-drill-container.sh 的坏槽载荷 slot-\$BAD_SLOT.root.raw(a/b)都在 ARTIFACTS 里 —— 改名后演练不会指向空气"
    else
        no "ota-drill-container.sh 的坏槽载荷${mp_missing} 不在 os-update 的 ARTIFACTS 里(演练会打到一个已改名的产物)"
    fi
else
    no "ota-drill-container.sh 里找不到 sha256_slot-\$BAD_SLOT.root.raw:坏载荷的 manifest key 构造点没了"
fi

}
