# shellcheck shell=bash
# keel verify 模块:systemd 单元语法 + shell 脚本(原第 301-357 行,逐字搬移)

verify_units() {
# ---------------------------------------------------------------------------
head1 "4. systemd 单元语法"
# ---------------------------------------------------------------------------
if ! have systemd-analyze; then
    skip "缺 systemd-analyze,跳过"
else
    for u in mkosi.extra/usr/lib/systemd/system/*.service; do
        [ -e "$u" ] || continue
        if out=$(systemd-analyze verify --man=no "$u" 2>&1); then
            ok "$(basename "$u")"
        else
            # 引用了尚未安装进宿主机的可执行文件是预期内的告警,不算失败
            real=$(printf '%s\n' "$out" | grep -viE 'is not executable|command .* not found|Failed to (create|load)|does not exist' | grep -vE '^\s*$' || true)
            if [ -z "$real" ]; then
                ok "$(basename "$u")(只有「文件还没装到宿主机」这类预期告警)"
            else
                no "$(basename "$u")"
                printf '%s\n' "$real" | head -5 | sed 's/^/      /'
            fi
        fi
    done
fi
}

verify_shell() {

# ---------------------------------------------------------------------------
head1 "5. shell 脚本"
# ---------------------------------------------------------------------------
scripts=()
while IFS= read -r f; do
    [ -n "$f" ] || continue
    if head -c 2 "$f" 2>/dev/null | grep -q '#!'; then scripts+=("$f"); fi
done < <(find mkosi.extra/usr/lib/keel mkosi.extra/usr/bin tools -type f 2>/dev/null | sort)
# ⚠ 上面那个 find 只认**有 shebang 的**脚本,而库文件按约定**不带** shebang(带了会被算成
# 脚本、把"有多少个脚本"这条基线搅乱)⇒ 它们一直漏在门外。2026-09-27 发现:
# `mkosi.extra/usr/lib/keel/lib.sh`(镜像里每个部件都 source 的运行库,还兼着 P1/P3 收进来的
# 共用机制)与 `tools/lib/verify/*.sh`(门**自己**)**从来没被 lint 过**。
# 这里把这两处显式补上(它们本来就干净,补上之后才是真的"一直干净")。
# 用 `lib*.sh` 通配:`mkosi.extra/usr/lib/keel/` 下的库都按这个约定命名(现在有 lib.sh 与
# lib-update.sh),以后再加库不用回来改这份名单。
# 只列这两处,不做通配:mkosi.extra-test / mkosi.extra-initrd 里也有脚本,但它们不是产物代码;
# 哪天真要一起 lint,把 find 的范围也扩过去,别只改这个数组。
libs=(mkosi.extra/usr/lib/keel/lib*.sh)
while IFS= read -r f; do
    [ -n "$f" ] || continue
    libs+=("$f")
done < <(find tools/lib/verify -name '*.sh' -type f 2>/dev/null | sort)
for f in ${scripts[@]+"${scripts[@]}"} ${libs[@]+"${libs[@]}"}; do
    if bash -n "$f" 2>/dev/null; then :; else no "bash -n 失败:$f"; fi
done
ok "bash -n 通过(${#scripts[@]} 个脚本 + ${#libs[@]} 个库/模块)"
if [ "$(( ${#scripts[@]} + ${#libs[@]} ))" -gt 0 ] && have shellcheck; then
    # 日志走 tmpd(=$TMPDIR 下的随机名)。**不要**改回写死的固定路径:原来的
    # keel-shellcheck.log 放在世界可写的 /tmp 下、名字又固定 ⇒ 被 root 跑过一次
    # 之后那个文件就归 root,非 root 再跑直接 "Permission denied",shellcheck 这一项
    # **假红**(2026-09 rootless 实测);而且固定名字 + 世界可写目录本来就是该躲开的
    # 攻击面(预先放个符号链接,下一次 root 跑就会去截断它指向的那个文件)。
    sc_log=$(tmpd)/shellcheck.log
    if shellcheck -S warning ${scripts[@]+"${scripts[@]}"} ${libs[@]+"${libs[@]}"} >"$sc_log" 2>&1; then
        ok "shellcheck(-S warning)通过(含 lib.sh 与 tools/lib/verify/ —— 它们没有 shebang,以前压根没进过这里)"
    else
        no "shellcheck 有问题:"
        grep -E '^In |\^--' "$sc_log" | head -20 | sed 's/^/      /'
    fi
elif ! have shellcheck; then
    skip "没装 shellcheck,跳过(建议装上)"
fi
# shebang 必须是 `#!/usr/bin/env bash`,不能是 `#!/bin/bash`(坑 #54):
# NixOS 宿主**只有 /bin/sh,没有 /bin/bash** ⇒ `sudo tools/build-container.sh` 这类
# "直接执行"的用法会在宿主上以 `bad interpreter: No such file or directory` 失败,
# 而脚本本身一点问题都没有(2026-09 在项目所有者的机器上实测撞到)。
hardcode_bash=$(grep -rl '^#!/bin/bash' mkosi.extra mkosi.extra-test mkosi.extra-initrd tools \
                mkosi.finalize mkosi.postinst 2>/dev/null | tr '\n' ' ')
if [ -z "$hardcode_bash" ]; then
    ok "脚本 shebang 都是 /usr/bin/env bash(宿主没有 /bin/bash 也能直接执行,坑 #54)"
else
    no "还有脚本写着 #!/bin/bash(NixOS 宿主上直接执行会 bad interpreter):$hardcode_bash"
fi

}
