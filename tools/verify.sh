#!/bin/bash
# keel 静态校验 —— 不需要 root、不需要 loop 设备、不构建镜像
#
# 能在这里查的:
#   1. mkosi 三个 profile 的配置解析
#   2. kernel cmdline 一致性(每个产物恰好一个 root=PARTLABEL=root-<槽>,且和产物对得上)
#   3. repart 分区布局(真跑 systemd-repart,用假镜像树喂 CopyFiles)
#   4. systemd 单元语法(systemd-analyze verify)
#   5. shell 脚本(shellcheck + bash -n)
#   6. 几处"改一处忘一处"的一致性断言
#
# 查不了的:真实构建与启动。那是 tools/build.sh + 真机/虚拟机的事(docs/architecture.md §13)。
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

pass=0; fail=0; skipped=0
ok()    { printf '  \033[32m✓\033[0m %s\n' "$*"; pass=$((pass+1)); }
no()    { printf '  \033[31m✗\033[0m %s\n' "$*"; fail=$((fail+1)); }
warn()  { printf '  \033[33m!\033[0m %s\n' "$*"; }
skip()  { printf '  \033[33m-\033[0m %s\n' "$*"; skipped=$((skipped+1)); }
head1() { printf '\n\033[1m%s\033[0m\n' "$*"; }
have()  { command -v "$1" >/dev/null 2>&1; }

TMPS=()
cleanup() { local d; for d in ${TMPS[@]+"${TMPS[@]}"}; do rm -rf "$d"; done; }
trap cleanup EXIT
tmpd() { local d; d=$(mktemp -d); TMPS+=("$d"); printf '%s' "$d"; }

PROFILES="install slot-a slot-b"
declare -A WANT_SLOT=([install]=root-a [slot-a]=root-a [slot-b]=root-b)

# ---------------------------------------------------------------------------
head1 "1. mkosi 配置解析"
# ---------------------------------------------------------------------------
if ! have mkosi; then
    skip "没装 mkosi,跳过"
else
    for p in $PROFILES; do
        out=$(tmpd)
        if mkosi --profile "$p" summary >"$out/summary" 2>&1; then
            ok "--profile $p 解析通过"
        else
            no "--profile $p 解析失败"
            grep -E '^‣' "$out/summary" | head -5 | sed 's/^/      /'
        fi
    done
    # 虚拟机测试用的组合(install + test)也要能解析。它不在上面的 PROFILES 里,但正是
    # docs/install.md §1 让人跑的命令 —— 漏检的话"新增一个 profile 导致组合解析失败"要等到
    # 真机上才发现。
    out=$(tmpd)
    if mkosi --profile install --profile test summary >"$out/summary" 2>&1; then
        ok "--profile install --profile test 解析通过(虚拟机测试用的组合)"
    else
        no "--profile install --profile test 解析失败"
        grep -E '^‣' "$out/summary" | head -5 | sed 's/^/      /'
    fi
    # RepartDirectories 的守卫。**刻意不解析 mkosi 的输出**:那条路已被证明是版本相关的
    # (25.x 与 27 的 --json 结构不同;而 verify.sh 开了 pipefail,mkosi 一旦不支持 --json
    #  整条管道就失败,断言会误报),而且它只是"症状"。
    # 改成检查**输入侧的不变量** —— 它们正是导致故障的两个条件,与 mkosi 版本无关:
    #   ① 源码树里不能存在名为 mkosi.repart 的目录(mkosi 会把它当隐式默认值);
    #   ② 每个产物 profile 必须恰好设一个 RepartDirectories=,且那个目录存在、里面有 .conf。
    # 背景:mkosi 把"存在 mkosi.repart/"当默认值 + 集合型设置是追加语义 ⇒ 两者叠加会让
    # 两套分区布局同时生效。真机上的表现是 repart 拒绝同名 split(AGENTS.md 坑 #20)。
    if [ -e mkosi.repart ]; then
        no "源码树里存在 mkosi.repart/ —— 它会成为 RepartDirectories= 的隐式默认值,和 profile 里设的目录叠加(坑 #20);请把布局放到 repart/ 下的子目录"
    else
        ok "源码树里没有 mkosi.repart/(不会触发隐式默认值)"
    fi
    for p in $PROFILES; do
        f="mkosi.profiles/$p.conf"
        cnt=$(grep -c '^RepartDirectories=' "$f" 2>/dev/null || true)
        dir=$(sed -n 's/^RepartDirectories=//p' "$f" 2>/dev/null | head -1)
        if [ "$cnt" != 1 ]; then
            no "$f 里 RepartDirectories= 出现 $cnt 次(必须恰好 1 次)"
        elif [ ! -d "$dir" ]; then
            no "$f 指向的目录不存在:$dir"
        elif ! ls "$dir"/*.conf >/dev/null 2>&1; then
            no "$f 指向的目录里没有分区定义:$dir"
        else
            ok "--profile $p → $dir(存在且含分区定义)"
        fi
    done
    # 尽力而为:如果 mkosi 的输出恰好能解析出来,再核对一次实际解析结果。
    # 解析不出来**不判失败** —— 输出格式是版本相关的,不该让校验依赖它。
    resolved=$(mkosi --profile install summary 2>/dev/null | awk '
        # summary 里有多个镜像(先 tools tree、再 initrd、最后才是主镜像),
        # 每出现一次 "Repart Directories:" 就重置一次计数,END 时打印的就是主镜像那份。
        /Repart Directories:/ {
            col = index($0, "Repart Directories:") + length("Repart Directories:")
            v = substr($0, col + 1)
            gsub(/^[ \t]+|[ \t]+$/, "", v)
            n = (v == "" || v == "none") ? 0 : 1
            inblock = 1
            next
        }
        inblock && /^[ \t]+[^ \t]/ {
            if (match($0, /[^ \t]/) - 1 >= col) { n++; next }
            inblock = 0
            next
        }
        inblock && !/^[ \t]*$/ { inblock = 0 }
        END { if (inblock || n != "") print n }
    ' | tail -1)
    case "$resolved" in
        1)   ok "mkosi 实际解析出的 RepartDirectories 也是 1 个" ;;
        '')  warn "没能从 mkosi summary 里解析出 RepartDirectories(不影响判定,输入侧已检查)" ;;
        *)   warn "mkosi 实际解析出 $resolved 个 RepartDirectories —— 输入侧看起来正常,若是真异常请把 'mkosi --profile install summary' 的输出报告出来" ;;
    esac

    # 不带 --profile 会解析成功但没有任何 root=(产物形态必须显式选)。
    # 拦截点在构建期:mkosi.finalize 检查 $MKOSI_CONFIG。这里断言两件事:
    #   ① 不带 profile 确实没有 root=;② finalize 里的守卫还在。
    nf=$(tmpd)
    mkosi summary >"$nf/s" 2>/dev/null || true
    if grep -q 'root=PARTLABEL=root-' "$nf/s" 2>/dev/null; then
        no "不带 --profile 竟然也带 root=,产物形态的隔离被破坏了"
    else
        ok "不带 --profile 时没有 root=(构建期会被 finalize 守卫拦下)"
    fi
    if grep -q 'root=PARTLABEL=root-\[ab\]' mkosi.finalize; then
        ok "mkosi.finalize 里的 cmdline 守卫存在"
    else
        no "mkosi.finalize 里的 cmdline 守卫不见了 —— 两个产物 profile 同时启用会静默产出坏镜像"
    fi
fi

# ---------------------------------------------------------------------------
head1 "2. kernel cmdline 一致性"
# ---------------------------------------------------------------------------
for p in $PROFILES; do
    s=$(tmpd)
    mkosi --profile "$p" summary >"$s/s" 2>/dev/null || { skip "--profile $p 解析失败,跳过"; continue; }
    found=$(grep -o 'root=PARTLABEL=root-[ab]' "$s/s" | sort -u)
    n=$(printf '%s\n' "$found" | grep -c . || true)
    if [ "$n" != 1 ]; then
        no "--profile $p:cmdline 里 root=PARTLABEL 匹配到 $n 个(必须恰好 1 个)"
        printf '%s\n' "$found" | sed 's/^/      /'
    elif [ "$found" != "root=PARTLABEL=${WANT_SLOT[$p]}" ]; then
        no "--profile $p:cmdline 指向 $found,但期望 root=PARTLABEL=${WANT_SLOT[$p]}"
    else
        ok "--profile $p:cmdline 恰好指向 ${WANT_SLOT[$p]}"
    fi
    # ro 是承重墙,不能丢。
    grep -qE 'Kernel Command Line: ro' "$s/s" || no "--profile $p:cmdline 缺少 ro"
    # 反向断言:cmdline 里**不能**再出现 systemd.mount-extra(坑 #24)。
    # 它会在主系统里生成依赖 udev 符号链接的 .mount 单元,而 udev 要等 sysusers、
    # sysusers 要等可写的 /etc、/etc overlay 又要等 /Volume ⇒ 循环 ⇒ emergency。
    # /Volume 现在由 keel-mounts.service 自己挂,ESP 交给 gpt-auto。
    if grep -qE 'systemd\.mount-extra=' "$s/s"; then
        no "--profile $p:cmdline 里还有 systemd.mount-extra(会引入 udev 依赖环,坑 #24)"
    else
        ok "--profile $p:cmdline 没有 systemd.mount-extra(不会引入 udev 依赖环)"
    fi
done

# ---------------------------------------------------------------------------
head1 "3. repart 分区布局"
# ---------------------------------------------------------------------------
if ! have systemd-repart || ! have sfdisk; then
    skip "缺 systemd-repart 或 sfdisk,跳过"
else
    tree=$(tmpd)
    mkdir -p "$tree/boot/EFI/Linux" "$tree/efi" "$tree/etc" \
             "$tree/usr/share/keel/volume-skeleton/keel" \
             "$tree/usr/share/keel/volume-skeleton/var/lib/dbus"
    : >"$tree/boot/EFI/Linux/keel-a.efi"
    echo 1 >"$tree/usr/share/keel/volume-skeleton/keel/schema-version"

    for d in repart/install repart/slot-a repart/slot-b; do
        img="$tree/out.raw"; rm -f "$img"
        # --offline=yes 是必须的:systemd-repart 自己的默认是 --offline=auto,
        # 意思是"能建 loop 设备就用 loop"。在容器里(尤其 --privileged 把宿主机的
        # /dev 暴露进来时)loop 设备看得见但用不了,repart 不会回退到 offline,
        # 而是直接报 "Failed to make loopback device ...: Device or resource busy"。
        # mkosi 自己的默认是 RepartOffline=yes(即绝不会走到 loop 那条路),
        # 所以这里也必须显式对齐,否则这个校验在不同环境里行为不一致。
        if ! systemd-repart --offline=yes --empty=create --size=15G --definitions="$d" \
                --copy-source="$tree" "$img" >"$tree/log" 2>&1; then
            no "$d:systemd-repart 执行失败"
            tail -5 "$tree/log" | sed 's/^/      /'
            continue
        fi
        names=$(sfdisk --dump "$img" 2>/dev/null | sed -n 's/.*name="\([^"]*\)".*/\1/p' | tr '\n' ' ')
        sizes=$(sfdisk --dump "$img" 2>/dev/null | sed -n 's/.*size= *\([0-9]*\),.*/\1/p' | tr '\n' ' ')
        case "$d" in
        repart/install)
            [ "$names" = "esp root-a root-b volume " ] \
                && ok "安装镜像分区名 = esp root-a root-b volume" \
                || no "安装镜像分区名不对:[$names]"
            # 每个分区的大小(MiB)
            set -- $sizes
            [ "$(( $1 * 512 / 1048576 ))" = 1024 ] && ok "esp = 1 GiB" || no "esp 不是 1 GiB(第 1 个分区 $(( $1 * 512 / 1048576 )) MiB)"
            [ "$(( $2 * 512 / 1048576 ))" = 6144 ] && ok "root-a = 6 GiB" || no "root-a 不是 6 GiB($(( $2 * 512 / 1048576 )) MiB)"
            [ "$(( $3 * 512 / 1048576 ))" = 6144 ] && ok "root-b = 6 GiB" || no "root-b 不是 6 GiB($(( $3 * 512 / 1048576 )) MiB)"
            # volume 必须是项目私有类型,否则首启扩容会误配到 root-b
            voltype=$(sfdisk --dump "$img" 2>/dev/null | grep 'name="volume"' | sed -n 's/.*type=\([0-9A-Fa-f-]*\).*/\1/p')
            [ "$voltype" = "D605065B-64F9-4A07-A0B8-70963175C6E6" ] \
                && ok "volume 类型 = 项目私有 UUID" \
                || no "volume 类型不是私有 UUID(实际 $voltype)"
            ;;
        repart/slot-a)
            [ "$names" = "esp root-a " ] && ok "slot-a 载荷分区名 = esp root-a" || no "slot-a 载荷分区名不对:[$names]"
            ;;
        repart/slot-b)
            [ "$names" = "esp root-b " ] && ok "slot-b 载荷分区名 = esp root-b" || no "slot-b 载荷分区名不对:[$names]"
            ;;
        esac
    done
fi

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

# ---------------------------------------------------------------------------
head1 "6. 一致性断言(改一处忘一处的经典位置)"
# ---------------------------------------------------------------------------
uuid_repart=$(sed -n 's/^Type=\(.*\)$/\1/p' repart/install/30-volume.conf | head -1)
uuid_grow=$(sed -n 's/^Type=\(.*\)$/\1/p' mkosi.extra/usr/lib/keel/repart.d/40-volume-grow.conf | head -1)
[ -n "$uuid_repart" ] && [ "$uuid_repart" = "$uuid_grow" ] \
    && ok "volume 类型 UUID 在安装镜像与扩容定义里一致" \
    || no "volume 类型 UUID 不一致:安装=[$uuid_repart] 扩容=[$uuid_grow]"

skel_repart=$(grep -o 'CopyFiles=[^:]*' repart/install/30-volume.conf | head -1 | cut -d= -f2)
if grep -q "$skel_repart" mkosi.finalize; then
    ok "骨架路径 $skel_repart 在 finalize 里也出现"
else
    no "骨架路径 $skel_repart 只在 repart 定义里出现,finalize 没有生成它"
fi

# ---- /Volume 与 ESP 的挂载方式(坑 #24 / #25)---------------------------------
# /Volume 不能再靠 cmdline 的 systemd.mount-extra(依赖 udev 符号链接 ⇒ 与 /etc overlay 成环),
# 必须由 keel-mounts.service 自己挂,而且不能通过 .mount 单元引入依赖。
if grep -qE '^[[:space:]]*RequiresMountsFor=/Volume' mkosi.extra/usr/lib/systemd/system/keel-mounts.service; then
    no "keel-mounts.service 里有 RequiresMountsFor=/Volume —— 会拉进依赖 udev 的 Volume.mount,重新造出依赖环(坑 #24)"
else
    ok "keel-mounts.service 没有 RequiresMountsFor=/Volume(不会引入 udev 依赖环)"
fi

if grep -q 'PARTNAME=volume' mkosi.extra/usr/lib/keel/mounts; then
    ok "/usr/lib/keel/mounts 用 sysfs 的 PARTNAME 找 volume(不依赖 udev)"
else
    no "/usr/lib/keel/mounts 没有 PARTNAME=volume 的查找逻辑 —— /Volume 就挂不上了"
fi

if grep -q 'Before=systemd-random-seed.service' mkosi.extra/usr/lib/systemd/system/keel-mounts.service; then
    ok "keel-mounts 排在 systemd-random-seed 之前(/var 符号链接此时已有效)"
else
    no "keel-mounts 没有排在 systemd-random-seed 之前 —— 它会往悬空的 /var 符号链接写随机种子然后失败(坑 #24)"
fi

# /Volume 是分区挂载点,镜像树里必须有这个空目录(否则 mount 报 mount point does not exist)
if grep -qE '^[[:space:]]*install -d .*"\$R/Volume"' mkosi.finalize; then
    ok "mkosi.finalize 建了 /Volume 挂载点目录"
else
    no "mkosi.finalize 没有建 /Volume 目录 —— 运行时挂载会失败(坑 #24)"
fi

# ESP 路径不能硬编码:gpt-auto 挂到 /boot 还是 /efi 取决于镜像里哪个目录存在。
if grep -q 'bootctl --print-esp-path' mkosi.extra/usr/lib/keel/lib.sh; then
    ok "lib.sh 用 bootctl --print-esp-path 现问 ESP 路径(不硬编码 /efi)"
else
    no "lib.sh 没有用 bootctl --print-esp-path 探测 ESP —— gpt-auto 挂到 /boot 时所有 ESP 操作都会失败(坑 #25)"
fi

if grep -rn '/efi/EFI' mkosi.extra/usr/bin mkosi.extra/usr/lib/keel 2>/dev/null | grep -v 'lib.sh' | grep -q .; then
    no "有脚本硬编码 /efi/EFI 路径(应该用 \$KEEL_UKI_DIR):"
    grep -rn '/efi/EFI' mkosi.extra/usr/bin mkosi.extra/usr/lib/keel 2>/dev/null | grep -v 'lib.sh' | head -5 | sed 's/^/      /'
else
    ok "没有脚本硬编码 /efi/EFI(都用 \$KEEL_UKI_DIR)"
fi

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
n_build=$(grep -cE '^[[:space:]]*mkosi .* build$' tools/build.sh)
n_force=$(grep -cE '^[[:space:]]*mkosi .*--force build$' tools/build.sh)
if [ "$n_build" -ge 3 ] && [ "$n_build" = "$n_force" ]; then
    ok "tools/build.sh 的 $n_build 次构建都带 --force(不会静默复用旧产物)"
else
    no "tools/build.sh 有 $n_build 次构建,只有 $n_force 次带 --force(坑 #23:mkosi 的 build 是'没有才建')"
fi

if grep -q -- '--force build' tools/build-container.sh; then
    ok "tools/build-container.sh 的 build 步骤带 --force"
else
    no "tools/build-container.sh 的 build 步骤没带 --force(--profile test 改变了配置,不 -f 就会拿旧镜像开虚拟机,坑 #23)"
fi

if grep -q -- '-v "$WS:/var/tmp"' tools/build-container.sh; then
    ok "build-container.sh 把 mkosi.workspace 绑到容器的 /var/tmp(产物与缓存不跨设备)"
else
    warn "build-container.sh 没有把 mkosi.workspace 绑到 /var/tmp —— 构建仍会成功,但收尾会退化成复制 14 GiB"
fi

# test profile 必须是"已知密码",不能是 Autologin(那条路径在 systemd 257 上会死循环,坑 #26)
if grep -qE '^[[:space:]]*RootPassword=' mkosi.profiles/test.conf \
   && ! grep -qE '^[[:space:]]*Autologin=' mkosi.profiles/test.conf; then
    ok "test profile 用 RootPassword(不用 Autologin —— 那条路径会死循环,坑 #26)"
else
    no "mkosi.profiles/test.conf 应该是 RootPassword= 且不设 Autologin=(坑 #26)"
fi

if grep -rn 'common-os' --include='*' . 2>/dev/null | grep -v '^\./\.git/' | grep -v '^\./tools/verify\.sh:' | grep -q .; then
    no "还有残留的旧名字 common-os:"
    grep -rn 'common-os' --include='*' . 2>/dev/null | grep -v '^\./\.git/' | grep -v '^\./tools/verify\.sh:' | head -5 | sed 's/^/      /'
else
    ok "没有残留的旧名字"
fi

# Debian 把 systemd-boot 拆成三个包,少一个的后果分别是"构建失败"和"启动后才炸":
#   缺 systemd-boot-efi   → mkosi 生成 UKI 时报 systemd-stub not found
#   缺 systemd-boot-tools → 构建能过,但运行时没有 bootctl(keel-firstboot/keel-confirm 都要用)
missing_pkgs=0
for pkg in systemd-boot systemd-boot-efi systemd-boot-tools; do
    if grep -qE "^[[:space:]]*${pkg}[[:space:]]*$" mkosi.conf.d/20-packages.conf; then :; else
        no "包清单缺 $pkg(Debian 把 systemd-boot 拆成了三个包,见 AGENTS.md 坑 #18)"
        missing_pkgs=1
    fi
done
[ "$missing_pkgs" = 0 ] && ok "包清单包含 systemd-boot 三件套"

# Debian 13 把 /bin/login 拆成独立包:缺了它控制台登录提示会每两秒重开(坑 #28)
if grep -qE "^[[:space:]]*login[[:space:]]*$" mkosi.conf.d/20-packages.conf; then
    ok "包清单包含 login(控制台登录 agetty → /bin/login 可用;libpam-runtime 是它的依赖)"
else
    no "包清单缺 login —— agetty exec /bin/login 失败,控制台登录提示会每两秒重开(坑 #28)"
fi

# 运行时不能有 dpkg 工具链(决策 D10):apt 用 RemovePackages,dpkg 是 Essential
# ⇒ 由 mkosi.finalize 显式删 + 断言(RemoveFiles= 的 glob 行为跨 mkosi 版本不一致)
if grep -q 'dpkg-maintscript-helper' mkosi.finalize && grep -q '仍残留 dpkg 工具链' mkosi.finalize; then
    ok "finalize 会删掉 dpkg 工具链并断言删干净"
else
    no "finalize 里没有 dpkg 工具链的删除/断言(决策 D10)"
fi

# DHCP:networkd 的 DHCPv4 在本镜像里起不来(坑 #29)⇒ 必须是 dhcpcd + DHCP=no
if grep -qE '^[[:space:]]*dhcpcd-base[[:space:]]*$' mkosi.conf.d/20-packages.conf \
   && grep -qE '^[[:space:]]*DHCP=no' mkosi.extra/etc/systemd/network/20-wired.network \
   && [ -x mkosi.extra/usr/lib/dhcpcd/dhcpcd-hooks/20-keel-resolved ]; then
    ok "DHCP 由 dhcpcd 负责(networkd DHCP=no + DNS 交给 resolved 的 hook)"
else
    no "DHCP 配置不完整:需要 dhcpcd-base + DHCP=no + dhcpcd-hooks/20-keel-resolved(坑 #29)"
fi

missing=0
for c in os-status os-update os-rescue os-install; do
    [ -e "mkosi.extra/usr/bin/$c" ] || { no "缺少命令 $c"; missing=1; }
done
[ "$missing" = 0 ] && ok "四个 os-* 命令都在"

# 四个单元的启用项都在 preset 里
for u in keel-mounts keel-firstboot keel-confirm keel-swapfile; do
    grep -q "^enable $u.service$" mkosi.extra/usr/lib/systemd/system-preset/00-keel.preset \
        || no "preset 里没有 enable $u.service"
done
ok "preset 覆盖了四个 keel 单元"

# ---------------------------------------------------------------------------
printf '\n\033[1m结果: %d 通过, %d 失败' "$pass" "$fail"
[ "$skipped" -gt 0 ] && printf ', %d 跳过' "$skipped"
printf '\033[0m\n'
[ "$fail" = 0 ] || exit 1
