# shellcheck shell=bash
# keel verify 模块:构建标志与两条构建路径对等(原第 455-585 行,逐字搬移)

verify_build_flags() {
# mkosi 不允许 workspace 位于任何 BuildSources 之内,而 BuildSources= 的默认值就是配置目录本身。
# 真机表现(坑 #22):
#   ‣ The workspace directory (/work/mkosi.workspace) cannot be a subdirectory of any source
#     directory (/work)
# 连 `mkosi vm` 都跑不起来。所以仓库里不能设 WorkspaceDirectory=;要"同文件系统"就用
# tools/build-container.sh 里那个把 mkosi.workspace 绑到 /var/tmp 的做法。
if grep -qE '^[[:space:]]*WorkspaceDirectory=' mkosi.conf; then
    no "mkosi.conf 里设了 WorkspaceDirectory= —— 指向仓库内会触发 mkosi 的 source 目录校验(坑 #22)"
else
    ok "mkosi.conf 没有设 WorkspaceDirectory=(不会触发 source 目录校验)"
fi

# mkosi 的 `build` 是"没有才建":产物已存在时它只打印一行 info 就返回 0,静默复用旧镜像(坑 #23)。
# 所以构建脚本里的每一次构建都必须带 --force。
# 断言刻意不依赖 `--force` 的位置与写法:先挑出所有构建行,再看其中有几行含 --force。
# 2026-09 起三次构建共用同一个参数数组(mkosi_args),所以断言改成:
#   ① 数组定义里有 --force;② 三次构建都通过那个数组调用、没有绕开它的裸 mkosi build。
n_build=$(grep -cE '^[[:space:]]*mkosi .*\$\{mkosi_args\[@\]\}.* build$' tools/build.sh)
if grep -qE '^mkosi_args=\(.*--force' tools/build.sh &&
   grep -qE '^[[:space:]]*mkosi_args=\(--image-version' tools/build.sh; then
    force_ok=1
else
    force_ok=0
fi
stray_build=$(grep -cE '^[[:space:]]*mkosi .* build$' tools/build.sh || true)
if [ "$n_build" -ge 3 ] && [ "$force_ok" = 1 ] && [ "$stray_build" = "$n_build" ]; then
    ok "tools/build.sh 的 $n_build 次构建都走带 --force 的 mkosi_args(不会静默复用旧产物,坑 #23)"
else
    no "tools/build.sh 的构建没有全部带上 --force(共用数组=$force_ok,构建行=$n_build,裸 build 行=$stray_build;坑 #23)"
fi

if grep -q -- '--force build' tools/build-container.sh; then
    ok "tools/build-container.sh 的 build 步骤带 --force"
else
    no "tools/build-container.sh 的 build 步骤没带 --force(不 -f 就会拿上一次构建的旧镜像开虚拟机,坑 #23)"
fi

if grep -q -- '-v "$WS:/var/tmp"' tools/build-container.sh; then
    ok "build-container.sh 把 mkosi.workspace 绑到容器的 /var/tmp(产物与缓存不跨设备)"
else
    warn "build-container.sh 没有把 mkosi.workspace 绑到 /var/tmp —— 构建仍会成功,但收尾会退化成复制 14 GiB"
fi

# root 密码 / 自动登录都**不许硬编码在仓库里**:这是公开仓库,写进配置的密码等于公开的;
# 而 `Autologin=yes` 在本镜像里会变成"登录成功但 shell 秒退"的死循环(坑 #26;根因是缺 /bin/login,
# 见坑 #28)。密码只从命令行来:tools/build-container.sh -p <密码> → mkosi 的 `--root-password=`。
if grep -rnE '^[[:space:]]*(RootPassword|Autologin)=' mkosi.conf mkosi.conf.d mkosi.profiles 2>/dev/null | grep -q .; then
    no "配置里硬编码了 RootPassword=/Autologin=(密码必须由命令行传入,坑 #26):"
    grep -rnE '^[[:space:]]*(RootPassword|Autologin)=' mkosi.conf mkosi.conf.d mkosi.profiles 2>/dev/null | head -3 | sed 's/^/      /'
else
    ok "配置里没有硬编码的 RootPassword=/Autologin=(密码只从命令行来,坑 #26)"
fi

# mkosi 的 `vm` 不解析配置文件,它读上一次 build 的 history(.mkosi-private/history/latest.json);
# 与 history 不同的 Content 段 CLI 设置只会打一行 `Ignoring --root-password from the CLI`,然后照
# history 走 ⇒ 密码必须**同时**传给 build 与 vm 两次调用,只在 vm 那步传等于没传(且不报错,坑 #30)。
if grep -qE '\$ROOTPW_Q +--force build' tools/build-container.sh \
   && grep -qE '\$ROOTPW_Q +vm' tools/build-container.sh; then
    ok "build-container.sh 把 --root-password 同时传给 build 与 vm(坑 #30:vm 用 history 里的配置)"
else
    no "build-container.sh 只在一次调用里传 --root-password:vm 那步会从 history 读配置,把 CLI 上的密码忽略掉(坑 #30)"
fi

# ---------------------------------------------------------------------------
# 两条构建路径的**对等性**(2026-09 审计:以前 build.sh 完全不解析参数、容器漏传 profile,
# 两条路各写各的 ⇒ 必然漂移。现在共用 tools/lib-build-cli.sh,并且这一组断言盯着它)。
# ---------------------------------------------------------------------------
LIB=tools/lib-build-cli.sh
if [ -f "$LIB" ] && grep -q 'lib-build-cli.sh' tools/build.sh && grep -q 'lib-build-cli.sh' tools/build-container.sh; then
    ok "两条构建路径共用同一份参数解析($LIB)"
else
    no "build.sh 与 build-container.sh 没有共用参数解析 ⇒ 选项会各自漂移(新增选项请加进 $LIB)"
fi
missopt=""
for opt in --password --profile --vm --drill; do
    grep -q -- "$opt" "$LIB" || missopt="$missopt $opt"
done
if [ -z "$missopt" ]; then
    ok "共用选项齐全(--password / --profile / --vm / --drill)"
else
    no "共用解析器缺选项:$missopt"
fi
# 功能性检查:不是 grep 猜,而是真的跑一遍 build.sh -h
if bh=$(bash tools/build.sh -h 2>&1) &&
   printf '%s' "$bh" | grep -q -- '--password' &&
   printf '%s' "$bh" | grep -q -- '--profile' &&
   printf '%s' "$bh" | grep -q -- '--vm' &&
   printf '%s' "$bh" | grep -q -- '--drill'; then
    ok "tools/build.sh -h 能跑,并列出 --password/--profile/--vm/--drill"
else
    no "tools/build.sh -h 跑不起来,或没列出共用选项(原生路径的 CLI 又退化了)"
fi
# -p 的完整链路:build.sh 的 -p → mkosi --root-password=;容器路径 → KEEL_ROOT_PASSWORD → build.sh
if grep -q 'KEEL_PASSWORD' tools/build.sh && grep -q -- '--root-password=\$PASSWORD' tools/build.sh; then
    ok "build.sh 的 -p/--password 一路接到 mkosi 的 --root-password=(密码归 admin,root 仍锁定)"
else
    no "build.sh 没有把 -p 接到 mkosi 的 --root-password="
fi
if grep -q 'KEEL_ROOT_PASSWORD=' tools/build-container.sh && grep -q 'KEEL_ROOT_PASSWORD' tools/build.sh; then
    ok "-p/--password 在容器路径上经 KEEL_ROOT_PASSWORD 送进容器、再由 build.sh 读出来"
else
    no "容器路径的 -p 没接到 build.sh(KEEL_ROOT_PASSWORD)"
fi
# 额外 profile(变体):容器以前漏传 KEEL_EXTRA_PROFILES ⇒ NixOS 那条路根本加不了 profile
if grep -q 'KEEL_EXTRA_PROFILES=' tools/build-container.sh &&
   grep -q 'keel_cli_extra_profiles' tools/build.sh; then
    ok "--profile / KEEL_EXTRA_PROFILES 在两条路径上都生效(容器会 -e 透传)"
else
    no "容器没有透传 KEEL_EXTRA_PROFILES ⇒ 那条路加不了变体 profile"
fi
# OTA 演练:两条路径共用同一份编排,而且编排脚本不许写死容器里的 /work
if grep -q 'ota-drill-container.sh' tools/build-container.sh && grep -q 'ota-drill-container.sh' tools/build.sh; then
    ok "OTA 演练两条路径都可用(同一份编排:build.sh --drill 与 build-container.sh drill)"
else
    no "演练只有一条路径可用(build.sh 缺 --drill,或容器没接同一份编排)"
fi
if grep -q '/work/' tools/ota-drill-container.sh; then
    no "演练编排写死了容器里的 /work 路径 ⇒ 原生路径跑不了"
else
    ok "演练编排用 cwd 定位仓库(容器与原生宿主都能跑)"
fi
# 过时话术:shebang 统一成 /usr/bin/env bash 之后(坑 #54),不该再教"sudo bash tools/…"
# --exclude=verify.sh:这条断言自己的模式与注释就长这样,别自匹配
if grep -rn --exclude=verify.sh 'sudo bash tools/' AGENTS.md README.md docs/*.md tools/*.sh 2>/dev/null | grep -v '^docs/traps.md' | grep -q .; then
    bad=$(grep -rn --exclude=verify.sh 'sudo bash tools/' AGENTS.md README.md docs/*.md tools/*.sh 2>/dev/null | grep -v '^docs/traps.md' | head -3 | sed 's/^/      /')
    no "还有「sudo bash tools/…」这种过时建议(坑 #54 修好后不需要了):"
    printf '%s\n' "$bad"
else
    ok "没有「要用 sudo bash tools/…」这种过时建议(shebang 已经是 /usr/bin/env bash)"
fi

}
