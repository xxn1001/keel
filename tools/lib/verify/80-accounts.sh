# shellcheck shell=bash
# keel verify 模块:账号模型 + 假镜像树实跑 finalize(原第 1307-1465 行,逐字搬移)

verify_accounts() {
head1 "7. 账号模型(决策 D21:admin 是唯一交互账号,root 锁定)"
# ---------------------------------------------------------------------------
if grep -qE '^[[:space:]]*sudo$' mkosi.conf.d/20-packages.conf; then
    ok "包清单里有 sudo(admin 唯一的提权途径)"
else
    no "包清单里没有 sudo ⇒ 装完机 admin 无法提权(Debian 上 sudo 不是 Essential)"
fi
if grep -qE '^[[:space:]]*tzdata$' mkosi.conf.d/20-packages.conf; then
    ok "包清单里有 tzdata(时区名字靠 /usr/share/zoneinfo 解析)"
else
    no "包清单里没有 tzdata ⇒ Timezone=Asia/Shanghai 会静默落回 UTC"
fi

SYSUSERS=mkosi.extra/usr/lib/sysusers.d/keel.conf
if [ -f "$SYSUSERS" ] && grep -qE '^u[[:space:]]+admin[[:space:]]+1000' "$SYSUSERS"; then
    ok "sysusers.d 里建了 admin(uid 1000,家目录 /home/admin)"
else
    no "缺少 $SYSUSERS 或里面没有 u admin 1000"
fi
if [ -f "$SYSUSERS" ] && grep -qE '^m[[:space:]]+admin[[:space:]]+sudo' "$SYSUSERS"; then
    ok "admin 被加进 sudo 组(sysusers 会顺带建这个组)"
else
    no "sysusers 里没有 m admin sudo"
fi
# 用真的 systemd-sysusers 在假根上跑一遍,确认文件语法有效、结果符合预期
if have systemd-sysusers; then
    d=$(tmpd); mkdir -p "$d/etc" "$d/usr/lib/sysusers.d"
    : >"$d/etc/passwd"; : >"$d/etc/group"; : >"$d/etc/shadow"; : >"$d/etc/gshadow"
    cp "$SYSUSERS" "$d/usr/lib/sysusers.d/" 2>/dev/null || true
    if systemd-sysusers --root="$d" >/dev/null 2>&1 &&
       grep -qE '^admin:x:1000:1000:' "$d/etc/passwd" &&
       grep -qE '^sudo:x:[0-9]+:admin$' "$d/etc/group"; then
        ok "systemd-sysusers 实跑:admin(1000:1000)+ sudo 组 + 成员关系都对"
    else
        no "systemd-sysusers 实跑结果不对(见 $SYSUSERS)"
        sed 's/^/      /' "$d/etc/passwd" "$d/etc/group" 2>/dev/null | head -6
    fi
else
    skip "没有 systemd-sysusers,跳过实跑(只做了文本断言)"
fi

SUDOERS=mkosi.extra/etc/sudoers.d/10-keel-admin
if [ -f "$SUDOERS" ] && grep -qE '^admin[[:space:]]+ALL=' "$SUDOERS"; then
    if grep -qE '^[^#]*NOPASSWD' "$SUDOERS"; then
        no "$SUDOERS 里有 NOPASSWD —— 项目所有者拍板的是「sudo 需要密码」"
    else
        ok "sudoers.d/10-keel-admin:admin 需要密码(明确不用 NOPASSWD)"
    fi
else
    no "缺少 $SUDOERS 或里面没有 admin 的规则"
fi
if grep -q 'chmod 0440 "$R/etc/sudoers.d/10-keel-admin"' mkosi.postinst; then
    ok "postinst 把 sudoers 文件设成 0440(git 存不了这个权限位)"
else
    no "postinst 没有把 sudoers 文件设成 0440(sudo 会因权限报错)"
fi

SSHD_DROPIN=mkosi.extra/etc/ssh/sshd_config.d/10-keel.conf
if [ -f "$SSHD_DROPIN" ] && grep -qE '^PermitRootLogin[[:space:]]+no' "$SSHD_DROPIN"; then
    ok "sshd drop-in:PermitRootLogin no(root 锁定 + SSH 也明确关掉)"
else
    no "缺少 $SSHD_DROPIN 或里面没有 PermitRootLogin no"
fi
if grep -q 'sshd_config.d/\*\.conf' mkosi.postinst &&
   grep -q 'Include /etc/ssh/sshd_config.d' mkosi.postinst; then
    ok "postinst 检查(并在缺失时补到最前面)sshd_config 的 Include 行"
else
    no "postinst 没有检查 sshd_config 的 Include 行 ⇒ drop-in 可能整个不生效"
fi

FIN=mkosi.finalize
if grep -q 'SKEL/home/admin/.ssh/authorized_keys' "$FIN"; then
    ok "authorized_keys 放进 /data 骨架的 home/admin/.ssh(不再是 root)"
else
    no "finalize 没把 authorized_keys 放到 admin 家目录"
fi
if grep -q 'SKEL/home/root/.ssh' "$FIN"; then
    no "finalize 里还有往 root 家目录放密钥的残留"
else
    ok "骨架里不再给 root 放任何登录凭据"
fi
if grep -q 'admin" { \$2=h }' "$FIN" && grep -q 'root"  { \$2="!" }' "$FIN"; then
    ok "finalize 把初始密码从 root 搬给 admin,并把 root 锁成 '!'"
else
    no "finalize 里缺少「搬密码 + 锁 root」的 awk 逻辑"
fi
if grep -q 'rm -f "$R/usr/lib/credstore/passwd.hashed-password.root"' "$FIN"; then
    ok "finalize 删掉了 credstore 里的 root 密码 credential(否则 systemd-firstboot 会把 root 又解开)"
else
    no "finalize 没有删 credstore 里的 root 密码 credential"
fi
if grep -q 'id -u admin' mkosi.extra/usr/bin/os-status && grep -q '登录账号' mkosi.extra/usr/bin/os-status; then
    ok "os-status 报告登录账号(admin 是否存在 / 有没有密码 / root 是否锁定)"
else
    no "os-status 没有登录账号那一节"
fi

# 假镜像树实跑 finalize:账号搬运 + 系统标识断言必须真的有效(不是只写了代码)
#
# 两棵树只差一个 hostname,别的地方都补全 —— 否则"finalize 失败了"可能根本不是因为
# hostname(第一版就是这样:树里缺 data-skeleton 目录,它在写 keel-check 转发时就死了,
# 于是"标识断言生效"那条检查**假通过**,而真正的 bug 是坑 #53)。
fake_tree() { # fake_tree <root> <hostname>
    local r=$1 hn=$2
    mkdir -p "$r/etc" "$r/var/log/journal" "$r/usr/lib/credstore" "$r/usr/share/zoneinfo/Asia"
    printf 'root:x:0:0:root:/root:/bin/bash\nadmin:x:1000:1000:Keel Admin:/home/admin:/bin/bash\n' >"$r/etc/passwd"
    printf 'root:x:0:\nadmin:x:1000:\n' >"$r/etc/group"
    printf 'root:$6$FAKE$HASH:19000:0:99999:7:::\nadmin:!*:20721::::::\n' >"$r/etc/shadow"
    echo cred >"$r/usr/lib/credstore/passwd.hashed-password.root"
    printf '%s\n' "$hn" >"$r/etc/hostname"
    echo "LANG=C.UTF-8" >"$r/etc/locale.conf"
    echo tzdata >"$r/usr/share/zoneinfo/Asia/Shanghai"
    ln -s /usr/share/zoneinfo/Asia/Shanghai "$r/etc/localtime"
}
FIN_R=$(tmpd); FIN_S=$(tmpd)
fake_tree "$FIN_R" keel
echo "ssh-ed25519 AAAAfake keel@verify" >"$FIN_S/authorized_keys"
echo 1 >"$FIN_S/schema-version"
if [ "$(id -u)" != 0 ]; then
    # 这条要真的跑 finalize,而 finalize 会给 admin 家目录 chown(镜像里的 uid 1000)。
    # 非 root 跑必然 EPERM ⇒ 以前它会在 NixOS 宿主上以"账号逻辑有问题"的面目失败,
    # 那是**环境**问题不是代码问题(坑 #52 的同一个形状:判据自己要说真话)。
    skip "非 root:跳过「假镜像树实跑 finalize」(它要 chown admin;用 sudo 或进构建容器跑完整版)"
elif BUILDROOT="$FIN_R" SRCDIR="$FIN_S" bash "$FIN" >/dev/null 2>&1; then
    if grep -q '^admin:\$6\$FAKE\$HASH:' "$FIN_R/etc/shadow" &&
       grep -q '^root:!:' "$FIN_R/etc/shadow" &&
       [ ! -e "$FIN_R/usr/lib/credstore/passwd.hashed-password.root" ] &&
       [ -f "$FIN_R/usr/share/keel/data-skeleton/home/admin/.ssh/authorized_keys" ] &&
       [ "$(readlink "$FIN_R/var")" = /data/var ] &&
       [ -d "$FIN_R/nix" ] && [ ! -L "$FIN_R/nix" ]; then
        ok "假镜像树实跑 finalize:密码搬到 admin、root 锁定、credential 删除、骨架就位、/var 是链接而 /nix 是真目录"
    else
        no "finalize 实跑后状态不对"
        grep -E '^(root|admin):' "$FIN_R/etc/shadow" | sed 's/^/      /'
        ls -l "$FIN_R/usr/share/keel/data-skeleton/home/admin/.ssh/" 2>/dev/null | sed 's/^/      /'
    fi
else
    no "finalize 在假镜像树上直接失败了(账号/标识逻辑有问题)"
fi

# 反向:标识不对时必须让构建失败,而不是"退出码 0"。
# 判据要**对准失败原因**:只看"退出码非 0"的话,finalize 因为任何别的理由失败
# (例如非 root 跑不了 chown)都会让这条检查假通过 —— 断言必须抓到那句话。
# 这棵树**故意不给 authorized_keys**(SRCDIR 里只有 schema-version):顺带覆盖
# "仓库里没有 authorized_keys 时构建也必须能走完"这一条(坑 #53)。
FIN_R2=$(tmpd); FIN_S2=$(tmpd)
fake_tree "$FIN_R2" localhost
echo 1 >"$FIN_S2/schema-version"
if [ "$(id -u)" != 0 ]; then
    skip "非 root:跳过「标识不对时构建必须失败」的实跑(同一个 chown 限制)"
elif BUILDROOT="$FIN_R2" SRCDIR="$FIN_S2" bash "$FIN" >"$FIN_R2/out" 2>&1; then
    no "finalize 在 /etc/hostname 是 localhost 时仍然成功了 ⇒ 标识断言没生效"
elif grep -q 'hostname' "$FIN_R2/out"; then
    ok "finalize 在系统标识不对时会让构建失败(hostname 断言真的在跑)"
else
    no "finalize 失败了,但原因不是标识断言(⇒ 这条检查证明不了标识断言在跑):"
    head -5 "$FIN_R2/out" | sed 's/^/      /'
fi

}
