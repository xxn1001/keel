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
for f in ${scripts[@]+"${scripts[@]}"}; do
    if bash -n "$f" 2>/dev/null; then :; else no "bash -n 失败:$f"; fi
done
ok "bash -n 通过(${#scripts[@]} 个脚本)"
if [ "${#scripts[@]}" -gt 0 ] && have shellcheck; then
    if shellcheck -S warning "${scripts[@]}" >/tmp/keel-shellcheck.log 2>&1; then
        ok "shellcheck(-S warning)通过"
    else
        no "shellcheck 有问题:"
        grep -E '^In |\^--' /tmp/keel-shellcheck.log | head -20 | sed 's/^/      /'
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
