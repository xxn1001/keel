#!/usr/bin/env bash
# keel 静态校验 —— 不需要 loop 设备、不构建镜像
#
# 大部分检查不需要 root;只有「假镜像树实跑 mkosi.finalize」那条需要(它要 chown admin 家目录),
# 非 root 时那条会**明确跳过**而不是假装失败(在 NixOS 宿主上以 admin 跑过一次,见坑 #52)。
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
    # 两套分区布局同时生效。真机上的表现是 repart 拒绝同名 split(docs/traps.md 坑 #20)。
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
    # sysusers 要等可写的 /etc、/etc overlay 又要等 /data ⇒ 循环 ⇒ emergency。
    # /data 现在由 keel-mounts.service 自己挂,ESP 交给 gpt-auto。
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
             "$tree/usr/share/keel/data-skeleton/keel" \
             "$tree/usr/share/keel/data-skeleton/var/lib/dbus"
    : >"$tree/boot/EFI/Linux/keel-a.efi"
    echo 1 >"$tree/usr/share/keel/data-skeleton/keel/schema-version"

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
            [ "$names" = "esp root-a root-b data " ] \
                && ok "安装镜像分区名 = esp root-a root-b data" \
                || no "安装镜像分区名不对:[$names]"
            # 每个分区的大小(MiB)
            set -- $sizes
            [ "$(( $1 * 512 / 1048576 ))" = 1024 ] && ok "esp = 1 GiB" || no "esp 不是 1 GiB(第 1 个分区 $(( $1 * 512 / 1048576 )) MiB)"
            [ "$(( $2 * 512 / 1048576 ))" = 6144 ] && ok "root-a = 6 GiB" || no "root-a 不是 6 GiB($(( $2 * 512 / 1048576 )) MiB)"
            [ "$(( $3 * 512 / 1048576 ))" = 6144 ] && ok "root-b = 6 GiB" || no "root-b 不是 6 GiB($(( $3 * 512 / 1048576 )) MiB)"
            # data 分区必须是项目私有类型,否则首启扩容会误配到 root-b
            voltype=$(sfdisk --dump "$img" 2>/dev/null | grep 'name="data"' | sed -n 's/.*type=\([0-9A-Fa-f-]*\).*/\1/p')
            [ "$voltype" = "D605065B-64F9-4A07-A0B8-70963175C6E6" ] \
                && ok "data 分区类型 = 项目私有 UUID" \
                || no "data 分区类型不是私有 UUID(实际 $voltype)"
            sizes_install="$sizes"
            ;;
        repart/slot-a)
            [ "$names" = "esp root-a " ] && ok "slot-a 载荷分区名 = esp root-a" || no "slot-a 载荷分区名不对:[$names]"
            ;;
        repart/slot-b)
            [ "$names" = "esp root-b " ] && ok "slot-b 载荷分区名 = esp root-b" || no "slot-b 载荷分区名不对:[$names]"
            ;;
        esac
    done

    # os-install 在目标机上跑的是**镜像里那份**定义(mkosi.postinst 装进
    # /usr/lib/keel/repart-install.d),它是 repart/install 去掉 CopyFiles= 的版本。
    # 这里按同样的方式生成一份并真跑一遍:既证明它本身是合法定义,也证明分区表
    # 与构建时那份逐字节一致(名字/尺寸/类型)。
    rt="$tree/repart-runtime"
    mkdir -p "$rt"
    for f in repart/install/*.conf; do
        sed '/^[[:space:]]*CopyFiles=/d' "$f" >"$rt/$(basename "$f")"
    done
    if grep -q 'CopyFiles' "$rt"/*.conf; then
        no "运行时定义里还留着 CopyFiles= —— repart 会去拷宿主机的 /proc、/data"
    else
        ok "运行时 repart 定义没有 CopyFiles=(不会去拷宿主机的 /proc、/data)"
    fi
    rtimg="$tree/rt.raw"; rm -f "$rtimg"
    if systemd-repart --offline=yes --empty=create --size=15G --definitions="$rt" \
            "$rtimg" >"$tree/rt.log" 2>&1; then
        rnames=$(sfdisk --dump "$rtimg" 2>/dev/null | sed -n 's/.*name="\([^"]*\)".*/\1/p' | tr '\n' ' ')
        rsizes=$(sfdisk --dump "$rtimg" 2>/dev/null | sed -n 's/.*size= *\([0-9]*\),.*/\1/p' | tr '\n' ' ')
        rtype=$(sfdisk --dump "$rtimg" 2>/dev/null | grep 'name="data"' | sed -n 's/.*type=\([0-9A-Fa-f-]*\).*/\1/p')
        if [ "$rnames" = "esp root-a root-b data " ] && [ "$rsizes" = "$sizes_install" ] \
           && [ "$rtype" = "D605065B-64F9-4A07-A0B8-70963175C6E6" ]; then
            ok "运行时定义产出的分区表与构建时一致(名字/尺寸/类型)"
        else
            no "运行时定义与构建时的分区表不一致:[$rnames][$rsizes][$rtype] vs [esp root-a root-b data ][$sizes_install]"
        fi
    else
        no "运行时 repart 定义 dry-run 失败(os-install 在目标机上会跑的就是它)"
        tail -5 "$tree/rt.log" | sed 's/^/      /'
    fi
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

# ---------------------------------------------------------------------------
head1 "6. 一致性断言(改一处忘一处的经典位置)"
# ---------------------------------------------------------------------------
uuid_repart=$(sed -n 's/^Type=\(.*\)$/\1/p' repart/install/30-data.conf | head -1)
uuid_grow=$(sed -n 's/^Type=\(.*\)$/\1/p' mkosi.extra/usr/lib/keel/repart.d/40-data-grow.conf | head -1)
[ -n "$uuid_repart" ] && [ "$uuid_repart" = "$uuid_grow" ] \
    && ok "类型 UUID 在安装镜像与扩容定义里一致" \
    || no "类型 UUID 不一致:安装=[$uuid_repart] 扩容=[$uuid_grow]"

skel_repart=$(grep -o 'CopyFiles=[^:]*' repart/install/30-data.conf | head -1 | cut -d= -f2)
if grep -q "$skel_repart" mkosi.finalize; then
    ok "骨架路径 $skel_repart 在 finalize 里也出现"
else
    no "骨架路径 $skel_repart 只在 repart 定义里出现,finalize 没有生成它"
fi

# ---- /data 与 ESP 的挂载方式(坑 #24 / #25)---------------------------------
# /data 不能再靠 cmdline 的 systemd.mount-extra(依赖 udev 符号链接 ⇒ 与 /etc overlay 成环),
# 必须由 keel-mounts.service 自己挂,而且不能通过 .mount 单元引入依赖。
if grep -qE '^[[:space:]]*RequiresMountsFor=/data' mkosi.extra/usr/lib/systemd/system/keel-mounts.service; then
    no "keel-mounts.service 里有 RequiresMountsFor=/data —— 会拉进依赖 udev 的 data.mount,重新造出依赖环(坑 #24)"
else
    ok "keel-mounts.service 没有 RequiresMountsFor=/data(不会引入 udev 依赖环)"
fi

if grep -q 'PARTNAME=\$want' mkosi.extra/usr/lib/keel/lib.sh \
   && grep -q 'keel_part_dev data' mkosi.extra/usr/lib/keel/mounts; then
    ok "lib.sh 用 sysfs 的 PARTNAME 找分区(不依赖 udev),mounts 调它挂 data 分区"
else
    no "找不到「按 PARTNAME 扫 sysfs」的查找逻辑(lib.sh 的 keel_part_dev + mounts 里的调用)—— /data 就挂不上了"
fi

if grep -q 'Before=systemd-random-seed.service' mkosi.extra/usr/lib/systemd/system/keel-mounts.service; then
    ok "keel-mounts 排在 systemd-random-seed 之前(/var 符号链接此时已有效)"
else
    no "keel-mounts 没有排在 systemd-random-seed 之前 —— 它会往悬空的 /var 符号链接写随机种子然后失败(坑 #24)"
fi

# /data 是分区挂载点,镜像树里必须有这个空目录(否则 mount 报 mount point does not exist)
if grep -qE '^[[:space:]]*install -d .*"\$R/data"' mkosi.finalize; then
    ok "mkosi.finalize 建了 /data 挂载点目录"
else
    no "mkosi.finalize 没有建 /data 目录 —— 运行时挂载会失败(坑 #24)"
fi

# ---------------------------------------------------------------------------
# ESP(坑 #36):必须由 keel-mounts 自己扫 PARTNAME=esp 挂上,而且 lib.sh 不许再把
# bootctl 的"猜测路径"当成真挂载点("每个步骤都成功、结果全落空"就是这么来的)。
# ---------------------------------------------------------------------------
if grep -q 'keel_esp_mount' mkosi.extra/usr/lib/keel/mounts \
   && grep -q 'mount -t vfat' mkosi.extra/usr/lib/keel/lib.sh \
   && grep -q 'PARTNAME=\$want' mkosi.extra/usr/lib/keel/lib.sh; then
    ok "keel-mounts 自己挂 ESP(lib.sh 的 keel_esp_mount:按 PARTNAME=esp 扫 sysfs + mount vfat)"
else
    no "keel-mounts 没有自己挂 ESP,或者 lib.sh 里没有 keel_esp_mount(坑 #36)"
fi

if grep -q 'KEEL_ESP_MOUNTED' mkosi.extra/usr/lib/keel/lib.sh \
   && grep -q 'KEEL_ESP_MOUNTED' mkosi.extra/usr/bin/os-status \
   && grep -q 'KEEL_ESP_MOUNTED' mkosi.extra/usr/bin/os-update \
   && grep -q 'KEEL_ESP_MOUNTED' mkosi.extra/usr/lib/keel/confirm; then
    ok "ESP 没挂上时 os-status / os-update / keel-confirm 都会明确报出来(不再静默)"
else
    no "拿 KEEL_ESP_MOUNTED 报错的三处没接好:os-status / os-update / keel-confirm(坑 #36)"
fi

# 顺序:os-update 必须**先**确认 ESP 可用,再 dd 根分区 —— 反过来会留下"新根 + 旧内核"
# 的槽,违反不变量 3,而且失败点离原因很远。
esp_line=$(grep -n 'keel_esp_mount' mkosi.extra/usr/bin/os-update | head -n1 | cut -d: -f1)
dd_line=$(grep -n 'dd if="\$payload" of="\$dev"' mkosi.extra/usr/bin/os-update | head -n1 | cut -d: -f1)
if [ -n "$esp_line" ] && [ -n "$dd_line" ] && [ "$esp_line" -lt "$dd_line" ]; then
    ok "os-update 先确认 ESP(第 $esp_line 行)再写根分区(第 $dd_line 行)"
else
    no "os-update 里 ESP 检查和写根分区的顺序不对(必须先检查 ESP)"
fi

# gpt-auto 必须退场:它对 ESP 的自动挂载静默且不可靠,而我们自己挂了
if grep -q '^[[:space:]]*systemd\.gpt_auto=no' mkosi.conf.d/30-content.conf; then
    ok "cmdline 里有 systemd.gpt_auto=no(gpt-auto 不再插手 ESP,坑 #36)"
else
    no "cmdline 里没有 systemd.gpt_auto=no —— gpt-auto 可能又悄悄挂/不挂 ESP(坑 #36)"
fi

# ESP 挂在哪由我们自己定(/boot),不再依赖 gpt-auto 的选择
if grep -q 'bootctl --print-esp-path' mkosi.extra/usr/lib/keel/lib.sh; then
    ok "lib.sh 里 bootctl --print-esp-path 只作兜底(且必须真的是挂载点)"
else
    no "lib.sh 里连 bootctl 兜底都没了 —— 手工挂到非 /boot 路径的系统会找不到 ESP"
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
# 断言刻意不依赖 `--force` 的位置与写法:先挑出所有构建行,再看其中有几行含 --force。
n_build=$(grep -cE '^[[:space:]]*mkosi .* build$' tools/build.sh)
n_force=$(grep -E '^[[:space:]]*mkosi .* build$' tools/build.sh | grep -c -e '--force' || true)
if [ "$n_build" -ge 3 ] && [ "$n_build" = "$n_force" ]; then
    ok "tools/build.sh 的 $n_build 次构建都带 --force(不会静默复用旧产物)"
else
    no "tools/build.sh 有 $n_build 次构建,只有 $n_force 次带 --force(坑 #23:mkosi 的 build 是'没有才建')"
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

# -p/--password 要一路通到 build 模式(那一模式跑的是 tools/build.sh,只能靠环境变量传进去)
if grep -q -- '-p|--password)' tools/build-container.sh && grep -q 'KEEL_ROOT_PASSWORD' tools/build.sh; then
    ok "-p/--password 也通到 build 模式(build-container.sh → KEEL_ROOT_PASSWORD → build.sh)"
else
    no "build-container.sh 的 -p 没接到 tools/build.sh(KEEL_ROOT_PASSWORD)"
fi

# os-install 的 find_part:live 盘与目标盘**分区同名**(都是 root-a / esp / data),
# 所以必须按"父设备等于目标盘"筛;而且刚写完分区表时 udev 可能还没把 PARTLABEL 填上
# (2026-09 真机踩过:repart 建好了四个分区,这里一个都找不到,坑 #33)⇒ 先扫 sysfs。
# 这段逻辑纯文本可测:造一棵假 sysfs 树(含另一块盘上的同名分区)真跑一遍。
if have sed && have readlink; then
    ft=$(tmpd)
    mkdir -p "$ft/sys/class/block" "$ft/sys/devices/block/vda/vda1" \
             "$ft/sys/devices/block/vda/vda2" "$ft/sys/devices/block/vdb/vdb1"
    printf 'PARTNAME=root-a\n' >"$ft/sys/devices/block/vda/vda1/uevent"
    printf 'PARTNAME=data\n' >"$ft/sys/devices/block/vda/vda2/uevent"
    printf 'PARTNAME=root-a\n' >"$ft/sys/devices/block/vdb/vdb1/uevent"
    ln -s ../../devices/block/vda      "$ft/sys/class/block/vda"
    ln -s ../../devices/block/vda/vda1 "$ft/sys/class/block/vda1"
    ln -s ../../devices/block/vda/vda2 "$ft/sys/class/block/vda2"
    ln -s ../../devices/block/vdb/vdb1 "$ft/sys/class/block/vdb1"
    {
        echo 'keel_log() { :; }'
        echo 'lsblk() { return 0; }'
        echo 'blockdev() { :; }'
        echo 'udevadm() { :; }'
        echo 'TARGET=/dev/vda; TARGET_NAME=vda'
        sed -n '/^find_part() {/,/^}/p' mkosi.extra/usr/bin/os-install \
            | sed "s|/sys/class/block|$ft/sys/class/block|g; s|sleep 1|:|"
    } >"$ft/fn.sh"
    got_a=$(bash -c '. '"$ft"'/fn.sh; find_part root-a' 2>/dev/null)
    got_v=$(bash -c '. '"$ft"'/fn.sh; find_part data' 2>/dev/null)
    got_x=$(bash -c '. '"$ft"'/fn.sh; find_part esp' 2>/dev/null)
    if [ "$got_a" = "/dev/vda1" ] && [ "$got_v" = "/dev/vda2" ] && [ -z "$got_x" ]; then
        ok "find_part 按父设备筛分区(假 sysfs:vda 命中、vdb 上的同名分区被忽略、查不到时输出为空)"
    else
        no "find_part 逻辑不对:root-a=[$got_a] data=[$got_v] esp=[$got_x](期望 /dev/vda1 /dev/vda2 空)"
    fi
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
        no "包清单缺 $pkg(Debian 把 systemd-boot 拆成了三个包,见 docs/traps.md 坑 #18)"
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

# systemd-repart 在目标盘上要自己调 mkfs:vfat 归 dosfstools,ext4 归 e2fsprogs。
# 构建时那次 repart 用的是 mkosi 的 tools tree(里面两个都有),所以镜像里缺了不会报错,
# 只有真机装机、repart 真的去格式化那一刻才炸(坑 #32)。
missing_fmt=0
for pkg in dosfstools e2fsprogs; do
    if grep -qE "^[[:space:]]*${pkg}[[:space:]]*$" mkosi.conf.d/20-packages.conf; then :; else
        no "包清单缺 $pkg —— repart 在目标盘上格式化分区时要用它(坑 #32)"
        missing_fmt=1
    fi
done
[ "$missing_fmt" = 0 ] && ok "包清单包含 dosfstools + e2fsprogs(repart 在目标盘上格式化 ESP / ext4 要用)"

# os-install 在**运行时**要调 systemd-repart(不是构建时那棵 tools tree 里的),
# 所以它必须在包清单里;少了它 U 盘里敲 os-install 会报 "command not found"。
if grep -qE "^[[:space:]]*systemd-repart[[:space:]]*$" mkosi.conf.d/20-packages.conf; then
    ok "包清单包含 systemd-repart(os-install 在目标机上要跑它)"
else
    no "包清单缺 systemd-repart —— os-install 在 U 盘环境里没有 repart 可用"
fi

# os-install 读的定义目录必须正好是 mkosi.postinst 写进去的那个;
# 两边写死的路径一旦不一致,错误只在**装机那一刻**才暴露(真机踩过:镜像是空的)
defs_in_script=$(sed -n 's|^readonly REPART_DEFS="\([^"]*\)".*|\1|p' mkosi.extra/usr/bin/os-install)
if [ "$defs_in_script" = "/usr/lib/keel/repart-install.d" ] \
   && grep -q 'usr/lib/keel/repart-install.d' mkosi.postinst \
   && grep -qF "CopyFiles=/d" mkosi.postinst; then
    ok "os-install 的定义目录($defs_in_script)由 mkosi.postinst 装进镜像(且去掉 CopyFiles=)"
else
    no "os-install 与 mkosi.postinst 对 repart 定义目录不一致(os-install 读 '${defs_in_script:-空}')"
fi

# keel 的"系统版本"必须来自 /usr/lib/os-release 的 IMAGE_VERSION(mkosi 写的),
# **不能**用 Debian 的 VERSION_ID —— 那会让版本显示成 "13",而且 os-update 的版本比较
# 会恒等 ⇒ 永远认为"已经是最新"(坑 #35)。
if sed -n '/^keel_version()/,/^}/p' mkosi.extra/usr/lib/keel/lib.sh | grep -q 'IMAGE_VERSION'; then
    ok "keel_version 读 IMAGE_VERSION(不是 Debian 的 VERSION_ID,坑 #35)"
else
    no "keel_version 没读 IMAGE_VERSION —— 版本会显示成 13、os-update 的版本比较也会失效(坑 #35)"
fi

# /nix 与 /home 必须是「真实目录 + bind mount」,不能是符号链接:
#   nix 硬性拒绝符号链接的 store 路径(坑 #34);
#   /home 是 ProtectHome= 这类沙箱语义的要求。
if grep -qE '^[[:space:]]*ln -s .*/nix' mkosi.finalize; then
    no "mkosi.finalize 把 /nix 做成了符号链接 —— nix 会拒绝(坑 #34)"
else
    ok "mkosi.finalize 没有把 /nix 做成符号链接(坑 #34)"
fi
if grep -qF 'install -d -m 0755 "$R/home" "$R/nix"' mkosi.finalize \
   && grep -q -- 'mount --bind /data/nix /nix' mkosi.extra/usr/lib/keel/mounts \
   && grep -q -- 'mount --bind /data/home /home' mkosi.extra/usr/lib/keel/mounts; then
    ok "finalize 建 /home /nix 空目录 + keel-mounts 各 bind 一次(两个都是真挂载点)"
else
    no "缺 /home 或 /nix 的「真实目录 + bind mount」:finalize 建目录、mounts 里 mount --bind(坑 #34)"
fi

# 运行时不能有 dpkg 工具链(决策 D10):apt 用 RemovePackages,dpkg 是 Essential
# ⇒ 由 mkosi.finalize 显式删 + 断言(RemoveFiles= 的 glob 行为跨 mkosi 版本不一致)
if grep -q 'dpkg-maintscript-helper' mkosi.finalize && grep -q '仍残留 dpkg 工具链' mkosi.finalize; then
    ok "finalize 会删掉 dpkg 工具链并断言删干净"
else
    no "finalize 里没有 dpkg 工具链的删除/断言(决策 D10)"
fi

# DHCP 走 systemd 原生栈(坑 #29 的根因已查清并修好:mkosi 在镜像里写的是
# /etc/machine-id=uninitialized,PID1 的 transient bind mount 又被 /etc overlay 盖住,
# 于是 machine-id 永远是空的 ⇒ networkd 生成 DUID 时拿到 -ENOPKG)。
# 反过来也要断言:不许再出现 dhcpcd —— 两个 DHCP 客户端抢一块网卡只会互相打架。
if grep -qE '^[[:space:]]*DHCP=yes' mkosi.extra/etc/systemd/network/20-wired.network \
   && ! grep -rqE '^[[:space:]]*DHCP=no' mkosi.extra/etc/systemd/network/ \
   && grep -q 'run/machine-id >/etc/machine-id' mkosi.extra/usr/lib/keel/mounts \
   && grep -q 'systemd-machine-id-setup' mkosi.extra/usr/lib/keel/mounts \
   && ! grep -qE '^[[:space:]]*dhcpcd' mkosi.conf.d/20-packages.conf \
   && [ ! -e mkosi.extra/etc/dhcpcd.conf ] \
   && [ ! -e mkosi.extra/usr/lib/systemd/system/keel-dhcpcd.service ] \
   && [ ! -d mkosi.extra/usr/lib/dhcpcd ] \
   && ! grep -q 'keel-dhcpcd' mkosi.extra/usr/lib/systemd/system-preset/00-keel.preset; then
    ok "DHCP 由 systemd-networkd 负责(DHCP=yes + mounts 里固化 machine-id,没有 dhcpcd 残留)"
else
    no "DHCP 配置不对:需要 DHCP=yes + mounts 里固化 machine-id(首选 /run/machine-id,退路 systemd-machine-id-setup),且不能再有 dhcpcd 的包/单元/hook/配置(坑 #29)"
fi

# machine-id 必须在 /etc overlay **挂好之后**才补:在它之前 /etc 还是只读的 lower,
# 写了也留不下来(而且那正是 PID1 transient 方案失效的同一个原因)
mid_line=$(grep -n 'systemd-machine-id-setup' mkosi.extra/usr/lib/keel/mounts | head -n1 | cut -d: -f1)
ovl_line=$(grep -n 'mount -t overlay overlay' mkosi.extra/usr/lib/keel/mounts | head -n1 | cut -d: -f1)
if [ -n "$mid_line" ] && [ -n "$ovl_line" ] && [ "$mid_line" -gt "$ovl_line" ]; then
    ok "machine-id 是在挂完 /etc overlay 之后补的(第 $ovl_line 行挂 overlay,第 $mid_line 行补 ID)"
else
    no "machine-id 的补齐位置不对(mounts 里必须在 'mount -t overlay overlay' 之后)"
fi

# 虚拟机自检(把 machine-id / DHCP 的证据打到控制台)只在 test profile 里,正式产物不带。
# 这是"怎么在容器里验证 guest"的唯一自动化通道,所以它的接线也要被守住:
# 少一个文件、或者不小心放进 mkosi.extra/,都会静默失效(要么不跑,要么跟着发行版发出去)。
if grep -q '^ExtraTrees=mkosi.extra-test$' mkosi.profiles/test.conf \
   && [ -x mkosi.extra-test/usr/lib/keel/selftest ] \
   && [ -f mkosi.extra-test/usr/lib/systemd/system/keel-selftest.service ] \
   && grep -q '^enable keel-selftest.service$' mkosi.extra-test/usr/lib/systemd/system-preset/01-keel-test.preset \
   && [ ! -e mkosi.extra/usr/lib/keel/selftest ] \
   && [ ! -e mkosi.extra/usr/lib/systemd/system/keel-selftest.service ] \
   && [ "$(grep -rl 'mkosi.extra-test' mkosi.conf mkosi.conf.d mkosi.profiles 2>/dev/null | tr '\n' ' ')" = "mkosi.profiles/test.conf " ]; then
    ok "虚拟机自检只在 test profile(mkosi.extra-test + preset 启用,正式产物里没有)"
else
    no "虚拟机自检的接线不对:需要 test.conf 的 ExtraTrees=mkosi.extra-test + 脚本/单元/preset,且不能出现在 mkosi.extra/ 或别的 profile 里"
fi

# 尽力而为:ExtraTrees= 是集合型(追加)设置,万一哪天追加语义变了,自检树就静默不生效。
# 解析不出来不判失败(输出格式与 mkosi 版本有关),只把事实说出来。
if mkosi --profile install --profile test summary >/dev/null 2>&1; then
    if mkosi --profile install --profile test summary 2>/dev/null | grep -q 'mkosi\.extra-test'; then
        ok "mkosi 解析 test profile 时确实带上了 mkosi.extra-test"
    else
        no "mkosi 解析 test profile 时**没有**带上 mkosi.extra-test(ExtraTrees= 的追加语义变了?)"
    fi
else
    warn "mkosi 不可用,跳过 ExtraTrees 解析核对"
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

# swapfile:必须按 /data 的可用空间给自己设上限,而且不能留下半截文件。
# 教训(2026-09,VM 实测):live 镜像的 data 分区只有 1 GiB,而默认大小按内存算(1.9G)
# ⇒ dd 写到 ENOSPC,半个 swapfile 把 /data 填满 ⇒ /etc overlay 的 upper 再也写不进去。
if grep -q 'df -P -B1 /data' mkosi.extra/usr/lib/keel/swapfile \
   && grep -q 'SWAP_NEW' mkosi.extra/usr/lib/keel/swapfile \
   && grep -q 'rm -f "$SWAP_NEW"' mkosi.extra/usr/lib/keel/swapfile \
   && grep -q 'MIN_SWAP' mkosi.extra/usr/lib/keel/swapfile; then
    ok "swapfile 按可用空间设上限(一半),中途失败会清掉半截文件、空间不足时不报错"
else
    no "swapfile 脚本缺少「按可用空间设上限 / 失败清理半截文件」的逻辑(live 镜像会把 /data 写满)"
fi

# ---------------------------------------------------------------------------
# keel-confirm 必须**同时**挂在 boot-complete.target 与 multi-user.target 上(坑 #41):
# boot-complete.target 只在"计数启动"时被 generator 拉进事务,而回滚发生在非计数启动上。
CONFIRM=mkosi.extra/usr/lib/systemd/system/keel-confirm.service
if grep -qE '^WantedBy=.*boot-complete\.target' "$CONFIRM" &&
   grep -qE '^WantedBy=.*multi-user\.target' "$CONFIRM" &&
   grep -q '^Requires=.*boot-complete\.target' "$CONFIRM"; then
    ok "keel-confirm 由 multi-user 拉起(并 Requires=boot-complete.target)⇒ 回滚那次非计数启动也会记录失败"
else
    no "keel-confirm 少了 multi-user.target 那条 WantedBy ⇒ 回滚后不会记录失败/清理坏条目(坑 #41)"
fi

# /data 的文件系统扩容:必须有 resize2fs 兜底(坑 #42:systemd-growfs 对"自己 mount(8)
# 挂的"挂载点会失败,2026-09 用 40G 假盘复现过"分区扩到 27G、文件系统还是 974M")。
if grep -q 'command -v systemd-growfs' mkosi.extra/usr/lib/keel/firstboot &&
   grep -q 'resize2fs "$vol"' mkosi.extra/usr/lib/keel/firstboot &&
   grep -q 'systemd 包不带它' mkosi.extra/usr/lib/keel/firstboot &&
   grep -q 'part_bytes / 20' mkosi.extra/usr/lib/keel/firstboot; then
    ok "keel-firstboot:growfs 有则试、resize2fs 必跑、按 5% 容差判断是否扩到位(坑 #42)"
else
    no "keel-firstboot 的扩容逻辑不完整(缺 resize2fs / 缺 growfs 存在性判断 / 缺 5% 容差)"
fi
if grep -q 'resize2fs "$data_dev"' mkosi.extra/usr/bin/os-rescue &&
   grep -q '现在的大小:分区' mkosi.extra/usr/bin/os-rescue; then
    ok "os-rescue --grow-data 同样有 resize2fs 兜底,并打印分区/文件系统两个尺寸"
else
    no "os-rescue --grow-data 没有 resize2fs 兜底(坑 #42)"
fi

# OTA 演练(mkosi.extra-test/):必须只在 test profile,且被 test preset 启用
if [ -x mkosi.extra-test/usr/lib/keel/ota-drill ] &&
   [ -f mkosi.extra-test/usr/lib/systemd/system/keel-ota-drill.service ]; then
    ok "OTA 演练脚本与单元在 mkosi.extra-test/ 里(只有 test profile 会挂进镜像)"
else
    no "OTA 演练文件缺失或 ota-drill 不可执行"
fi
if grep -q '^enable keel-ota-drill.service'       mkosi.extra-test/usr/lib/systemd/system-preset/01-keel-test.preset; then
    ok "test preset 启用了 keel-ota-drill.service"
else
    no "test preset 没启用 keel-ota-drill"
fi
if grep -rq 'keel-ota-drill' mkosi.postinst mkosi.finalize mkosi.extra 2>/dev/null; then
    no "正式镜像的构建脚本/目录里出现了 keel-ota-drill(它必须只活在 test profile)"
else
    ok "正式产物完全不含 OTA 演练"
fi
if grep -q 'drill)' tools/build-container.sh &&
   grep -q 'ota-drill-container.sh' tools/build-container.sh &&
   [ -x tools/ota-drill-container.sh ] &&
   grep -q 'truncate -s 40G' tools/ota-drill-container.sh &&
   grep -q 'DRILL_BOOT_VERSION' tools/ota-drill-container.sh &&
   grep -q 'python3 -m http.server' tools/ota-drill-container.sh &&
   grep -q 'urllib.request' tools/ota-drill-container.sh; then
    ok "drill 模式:独立编排脚本(远古引导版本 + truncate 40G + 容器内 HTTP 源 + python3 探测)"
else
    no "drill 编排不完整(见 tools/build-container.sh / tools/ota-drill-container.sh)"
fi
if grep -q 'systemctl poweroff' mkosi.extra-test/usr/lib/keel/ota-drill; then
    ok "演练 p2 结束会 poweroff(宿主不用靠 timeout 杀 VM)"
else
    no "演练结束后不会自己关机 ⇒ 宿主每次都得等 timeout"
fi

# 槽切换用的 bootctl 动词(坑 #43):Debian 的 systemd 257 没有 set-preferred,
# 所以候选槽必须走 set-oneshot、持久选择走 set-default,而且都收敛到 lib.sh 的 helper。
# systemd-bless-boot 在 /usr/lib/systemd/ 下,不在 PATH 里(坑 #60):
# os-rescue --mark-bad 以前用 `command -v systemd-bless-boot` 判「装没装」⇒ 永远说找不到。
n_abs=$(grep -n '/usr/lib/systemd/systemd-bless-boot' mkosi.extra/usr/bin/os-rescue | head -1 | cut -d: -f1)
n_cmd=$(grep -n 'command -v systemd-bless-boot' mkosi.extra/usr/bin/os-rescue | head -1 | cut -d: -f1)
if [ -n "$n_abs" ] && { [ -z "$n_cmd" ] || [ "$n_abs" -lt "$n_cmd" ]; }; then
    ok "os-rescue 先按绝对路径找 systemd-bless-boot(它不在 PATH 里;command -v 只作兜底,坑 #60)"
else
    no "os-rescue 用 command -v 找 systemd-bless-boot ⇒ 二进制明明在也会报「找不到」(坑 #60)"
fi
if grep -q '^keel_boot_candidate() { bootctl set-oneshot' mkosi.extra/usr/lib/keel/lib.sh &&
   grep -q '^keel_boot_default() { bootctl set-default' mkosi.extra/usr/lib/keel/lib.sh; then
    ok "lib.sh 定义了 keel_boot_candidate(set-oneshot)/keel_boot_default(set-default)(坑 #43)"
else
    no "lib.sh 缺少 bootctl 动词的封装(坑 #43)"
fi
if grep -q 'keel_boot_candidate "\$candidate_id"' mkosi.extra/usr/bin/os-update &&
   grep -q 'candidate_id="keel-\${target}.efi"' mkosi.extra/usr/bin/os-update &&
   grep -q 'keel_boot_default "\$pref"' mkosi.extra/usr/bin/os-update &&
   grep -q 'keel_boot_default "\$uki_name"' mkosi.extra/usr/lib/keel/confirm; then
    ok "os-update(stage=候选/switch=固化)与 keel-confirm(固化)都走 helper"
else
    no "还有调用点没改用 helper(候选槽 set-oneshot / 固化 set-default)"
fi
# 只看**非注释行**:注释里提到"原设计用的是 set-preferred"是解释,不是调用
if grep -rn '^[^#]*bootctl set-preferred' mkosi.extra/ >/dev/null 2>&1; then
    bad=$(grep -rln '^[^#]*bootctl set-preferred' mkosi.extra/ | tr '\n' ' ')
    no "仍有代码调用 bootctl set-preferred(systemd 257 会报 Unknown command verb):$bad"
else
    ok "没有任何地方再调用 bootctl set-preferred(它只出现在解释性注释里)"
fi

# 安装镜像 ESP 里的 UKI 名字必须是 keel-a.efi(mkosi 默认是 &e-&k = keel-<内核版本>,
# 那样 os-update rollback / switch 在一台刚装好的机器上找不到槽 a 的条目 —— 坑 #44)
if grep -qE '^UnifiedKernelImageFormat=keel-a$' mkosi.profiles/install.conf; then
    ok "install profile 钉住 UnifiedKernelImageFormat=keel-a(ESP 里的槽 a 条目就叫 keel-a.efi)"
else
    no "install profile 没钉 UnifiedKernelImageFormat ⇒ ESP 里会是 keel-<kver>.efi,按槽名找不到(坑 #44)"
fi
if grep -q 'selected' mkosi.extra/usr/lib/keel/confirm &&
   grep -q 'entry_\$slot' mkosi.extra/usr/lib/keel/confirm; then
    ok "keel-confirm 在 keel-<槽>.efi 不存在时退回「本次启动选中的条目」,并把名字记进 state(坑 #44)"
else
    no "keel-confirm 缺少条目名兜底(坑 #44)"
fi

# 控制台日志级别(决策 D27 / 坑 #61):内核 console_loglevel 出厂是 7 ⇒ 图形/串口控制台
# 会被 audit(PAM 认证)记录时不时刷一屏;我们用 sysctl 降到 4(dmesg/journal 一条不少,
# systemd 自己的 [ OK ] 启动进度照旧)。
if grep -qE '^kernel\.printk = 4 4 1 7$' mkosi.extra/etc/sysctl.d/10-keel-console.conf 2>/dev/null; then
    ok "sysctl drop-in 把内核控制台日志级别降到 4(不刷 audit,又不按掉启动进度,坑 #61)"
else
    no "缺少 mkosi.extra/etc/sysctl.d/10-keel-console.conf 或里面的 kernel.printk 不对(坑 #61)"
fi
# 启动早期顺序(sysctl / journald / journal-flush 都必须排在 keel-mounts 之后)
KM=mkosi.extra/usr/lib/systemd/system/keel-mounts.service
miss=""
for u in systemd-sysctl.service systemd-journald.service systemd-journal-flush.service; do
    grep -q "^Before=$u$" "$KM" || miss="$miss $u"
done
if [ -z "$miss" ]; then
    ok "keel-mounts 排在这三个单元之前:sysctl / journald / journal-flush(否则用户 drop-in 不生效、日志不落盘,坑 #61)"
else
    no "keel-mounts 缺 Before 顺序:$miss ⇒ /etc overlay 还没挂上它们就跑了(坑 #61)"
fi
# 自动回滚的前提:panic 会自动重启(决策 D24 / 坑 #46)
if grep -qE '^[[:space:]]*panic=-1$' mkosi.conf.d/30-content.conf; then
    ok "cmdline 里有 panic=-1(内核 panic ⇒ 立即重启 ⇒ 候选槽那次失败之后能自动回退)"
else
    no "cmdline 里没有 panic=-1 ⇒ 新槽 panic 时机器会停在黑屏,自动回滚不会发生(坑 #46)"
fi
if grep -q 'debugfs' tools/ota-drill-container.sh &&
   grep -q 'slot-\$BAD_SLOT.root.raw' tools/ota-drill-container.sh &&
   grep -q 'File not found' tools/ota-drill-container.sh &&
   grep -q '不要.*只看 debugfs 的退出码' tools/ota-drill-container.sh; then
    ok "演练会做一个起不来的坏载荷(debugfs 删 PID1 + **按输出文本**回读确认 + 重算 sha256)"
else
    no "drill 模式缺少坏载荷的准备(破坏性回滚验不了)"
fi

# v1 不支持 /data 迁移:带 migrate= 的载荷必须在 fetch 阶段被拒(而不是装上)
if grep -q 'migrate=' mkosi.extra/usr/bin/os-update &&
   grep -q '还没有迁移执行器' mkosi.extra/usr/bin/os-update; then
    ok "os-update fetch 会拒绝声明了 /data 迁移的载荷(v1 没有迁移执行器,拒绝好过假装迁移过)"
else
    no "os-update 没有拒绝带 migrate= 的载荷 ⇒ 可能装上一个要求迁移的版本(回滚后旧系统读不懂 /data)"
fi
if grep -q 'migrate=mkdir' tools/ota-drill-container.sh &&
   grep -q 'SRC_MIG' mkosi.extra-test/usr/lib/keel/ota-drill; then
    ok "演练会造一个带 migrate= 的载荷并验证它被拒绝"
else
    no "演练没有覆盖「带迁移的载荷被拒绝」这一项"
fi

# 运行时看门狗(决策 D25 / 坑 #50):主镜像与 initrd 各一份,且两边的值必须一致
WD_MAIN=mkosi.extra/etc/systemd/system.conf.d/keel-watchdog.conf
WD_INITRD=mkosi.extra-initrd/etc/systemd/system.conf.d/keel-watchdog.conf
if [ -f "$WD_MAIN" ] && [ -f "$WD_INITRD" ] &&
   grep -q '^RuntimeWatchdogSec=60' "$WD_MAIN" &&
   grep -q '^RuntimeWatchdogSec=60' "$WD_INITRD"; then
    if grep -q '^RebootWatchdogSec=' "$WD_MAIN" && grep -q '^RebootWatchdogSec=' "$WD_INITRD"; then
        ok "运行时看门狗配置在主镜像与 initrd 里都有,两边 RuntimeWatchdogSec 一致(坑 #50)"
    else
        no "看门狗配置缺 RebootWatchdogSec"
    fi
else
    no "缺少看门狗配置(或两边不一致)⇒ initrd 冻结时机器会一直挂着,自动回退不会发生(坑 #50)"
fi
if grep -qE '^ExtraTrees=mkosi\.extra-initrd$' mkosi.initrd.conf; then
    ok "mkosi.initrd.conf 把 mkosi.extra-initrd 挂进 initrd(initrd 不读主镜像的 /etc)"
else
    no "mkosi.initrd.conf 里没有 ExtraTrees=mkosi.extra-initrd ⇒ initrd 拿不到看门狗配置"
fi
if grep -q '^softdog$' mkosi.extra/etc/modules-load.d/keel-watchdog.conf; then
    ok "没有硬件看门狗的设备上会加载 softdog 兜底"
else
    no "没有加载 softdog ⇒ 部分真机上 RuntimeWatchdogSec 只会打一条警告"
fi

# 启动失败看门狗(决策 D26):没到 boot-complete ⇒ 自动重启;三类失败各一道兜底
BF=mkosi.extra/usr/lib/systemd/system/keel-boot-failed-reboot.service
if [ -f "$BF" ] && grep -q '^WantedBy=emergency.target rescue.target$' "$BF" &&
   [ -x mkosi.extra/usr/lib/keel/boot-failed-reboot ] &&
   grep -q '^enable keel-boot-failed-reboot.service$' \
        mkosi.extra/usr/lib/systemd/system-preset/00-keel.preset; then
    if grep -q '/run/keel/boot-complete' mkosi.extra/usr/lib/keel/confirm &&
       grep -q 'systemctl stop keel-boot-failed-reboot' mkosi.extra/usr/lib/keel/boot-failed-reboot; then
        ok "启动失败看门狗:emergency/rescue 时 60 秒后自动回退,且告诉人怎么取消(决策 D26)"
    else
        no "启动失败看门狗缺「boot-complete 标记」或「取消方式」提示"
    fi
else
    no "缺少 keel-boot-failed-reboot(emergency 那类失败会停在提示符前,自动回滚不成立)"
fi

# libvirt 验证脚本(真机前的模拟):必须可执行,且指向目标盘/串口/更新源三件事都在
if [ -x tools/libvirt-test.sh ] &&
   grep -q 'os-install /dev/vdb' tools/libvirt-test.sh &&
   grep -q 'virsh console' tools/libvirt-test.sh &&
   grep -q '192.168.122.1' tools/libvirt-test.sh; then
    ok "libvirt-test.sh 在(装机 → 串口控制台 → 本地更新源 三条路径都写了)"
else
    no "tools/libvirt-test.sh 缺失或不完整(真机前的模拟没法做)"
fi
# 固件查找:两套命名 + 显式条数检查(坑 #55)。
# 只认 OVMF_CODE* 的写法在 NixOS 宿主上必然找不到固件(/run/libvirt/nix-ovmf 里是
# edk2-x86_64-code.fd);而 `readarray -t x < <(cmd) || die` 是**死代码** ——
# 进程替换的退出码不会传给 readarray,真正报出来的是 unbound variable。
if grep -q 'edk2-x86_64-code.fd' tools/libvirt-test.sh &&
   grep -q 'load_ovmf' tools/libvirt-test.sh &&
   grep -q 'OVMF\[@\]' tools/libvirt-test.sh; then
    ok "libvirt-test.sh 认两套固件命名(OVMF_CODE*/edk2-*)且显式检查固件找到没(坑 #55)"
else
    no "libvirt-test.sh 只认 OVMF_CODE* 或不检查固件条数 ⇒ NixOS 宿主上只会报 unbound variable(坑 #55)"
fi
# 仓库里的权限位会**原样**进镜像,而 git 不跟踪读权限(坑 #57):
# 0600 的 /etc/systemd/network/*.network 会让 systemd-networkd 读不到 ⇒ 网络静默失效。
# 断言仓库里不存在"组/其他人不可读"的文件(可执行文件放宽到 0755)。
badmodes=$(find mkosi.extra mkosi.extra-initrd mkosi.extra-test -type f ! -perm -o+r 2>/dev/null | head -5)
if [ -z "$badmodes" ]; then
    ok "mkosi.extra*/ 里没有「其他用户不可读」的文件(git 不跟踪读权限,只能在构建前查,坑 #57)"
else
    no "这些文件不是其他用户可读的 ⇒ 镜像里会被对应的非 root 服务读不到(坑 #57):"
    printf '%s\n' "$badmodes" | sed 's/^/      /'
fi
if grep -q 'etc/systemd/network' mkosi.postinst && grep -q '其他用户可读' mkosi.postinst; then
    ok "mkosi.postinst 构建期归一化权限并回读断言(不指望 checkout 的 umask,坑 #57)"
else
    no "mkosi.postinst 没有把权限掰回来/没有断言 ⇒ 坏 umask 会静默产出没网的镜像(坑 #57)"
fi
if grep -q 'readarray -t ovmf' tools/libvirt-test.sh; then
    no "还有 mapfile/readarray ... || die 这种死代码(进程替换的退出码不传出来,坑 #55)"
else
    ok "没有把「找不到固件」押在 readarray 的退出码上(它根本不传,坑 #55)"
fi
# 域 XML:os/boot 与 per-device boot order 不能混用(现代 libvirt 直接拒绝定义,
# 报 "per-device boot elements cannot be used together with os/boot elements" —— 坑 #56)
if grep -q "boot dev='hd'" tools/libvirt-test.sh; then
    no "域 XML 里还有 <os><boot dev='hd'/>(和磁盘上的 <boot order=> 冲突,libvirt 拒绝定义,坑 #56)"
else
    ok "域 XML 只用 per-device <boot order=> 定启动顺序(不与 os/boot 冲突,坑 #56)"
fi
# 域 XML 要带**稳定的 uuid**,否则第二次 render(切到目标盘启动)时 define 会报
# "domain 'keel-test' already exists with uuid …"(坑 #58);prepare 还要先清掉旧域。
if grep -q 'domain_uuid' tools/libvirt-test.sh && grep -q '<uuid>' tools/libvirt-test.sh; then
    ok "域 XML 带稳定 uuid(同一次演练里 live→target 两次 define 不会撞名,坑 #58)"
else
    no "render_xml 不带 uuid ⇒ 第二次 define 会报 already exists with uuid(坑 #58)"
fi
# 从目标盘启动时必须把"U 盘"(vda)摘掉(坑 #59):两块盘都在时固件会按 NVRAM 里的旧条目
# 又启动 live 盘,演练于是把 live 的体检结论当成装好的系统的。
if grep -q 'boot_target" != target' tools/libvirt-test.sh && grep -q 'vda_xml' tools/libvirt-test.sh; then
    ok "「--boot target」会把 live 盘摘掉(等价于真机拔 U 盘,也才能真正验证独立启动,坑 #59)"
else
    no "「--boot target」没有摘掉 live 盘 ⇒ 固件可能又启动 live,结论是假的(坑 #59)"
fi
if grep -q 'virsh undefine "\$DOMAIN" --nvram' tools/libvirt-test.sh; then
    ok "prepare 会先 destroy+undefine 旧域(不留下引用旧盘的僵尸域)"
else
    no "prepare 没有清理已存在的域 ⇒ 重建磁盘后旧域还指着它们"
fi
if grep -q 'virsh define "\$(xml_path)" >/dev/null || die' tools/libvirt-test.sh; then
    ok "virsh define 的退出码被检查(define 失败不会再伪装成 start 失败,坑 #56)"
else
    no "virsh define 没检查退出码 ⇒ define 被拒后报的是「域未定义」这种误导性错误(坑 #56)"
fi
if grep -q 'console=ttyS0' mkosi.conf.d/30-content.conf; then
    ok "cmdline 里有 console=ttyS0(服务器串口/带外管理与 libvirt 验证都要它)"
else
    no "cmdline 里没有 console=ttyS0 ⇒ libvirt 的 virsh console 看不到启动日志"
fi

# 装机后的体检:真身在镜像里(随更新),家目录里只放转发(骨架只播种一次)
if [ -x mkosi.extra/usr/share/keel/keel-check ] &&
   grep -q 'SKEL/home/admin/keel-check' mkosi.finalize &&
   grep -q '/usr/share/keel/keel-check' mkosi.finalize; then
    ok "体检脚本在镜像里,admin 家目录里是转发入口(升级后跑到的仍是最新版)"
else
    no "缺少 keel-check 或它没有注入 admin 家目录(装机后没有体检入口)"
fi
if bash -n mkosi.extra/usr/share/keel/keel-check 2>/dev/null &&
   grep -q 'head1 "9. nix' mkosi.extra/usr/share/keel/keel-check; then
    ok "keel-check 语法通过且检查项齐全(身份/挂载/data/账号/网络/服务/引导链/硬件/nix)"
else
    no "keel-check 语法有问题或检查项不全"
fi

# 体检脚本的判据本身要有测试(坑 #52):它曾经用 `grep '^panic=-1' /proc/cmdline` 把一台
# 好机器判成硬失败 —— /proc/cmdline 是**一整行**,`^` 锚的是整行开头,所以除了第一个 token
# 谁也匹配不上。这里做两件事:① 功能测试 token 匹配;② 禁止再出现"对着 /proc/cmdline 用 ^"。
cl_has() { bash -c '. ./mkosi.extra/usr/lib/keel/lib.sh 2>/dev/null; keel_cmdline_has "$1" "$2"' _ "$1" "$2"; }
cld=$(tmpd); printf '%s\n' 'ro amd_iommu=on intel_iommu=on iommu=pt systemd.gpt_auto=no panic=-1 console=tty0 console=ttyS0,115200' >"$cld/cmdline"
printf '%s\n' 'ro quiet nopanic=-1 panic=0' >"$cld/decoy"
if cl_has panic=-1 "$cld/cmdline" && cl_has amd_iommu=on "$cld/cmdline" &&
   cl_has console=ttyS0,115200 "$cld/cmdline" &&
   ! cl_has panic=0 "$cld/cmdline" && cl_has nopanic=-1 "$cld/decoy" && ! cl_has panic=-1 "$cld/decoy"; then
    ok "keel_cmdline_has 按整个 token 匹配(非首个 token 也命中;panic=0/nopanic=-1 不误命中,坑 #52)"
else
    no "keel_cmdline_has 的匹配语义不对 ⇒ 体检脚本会误判 cmdline(坑 #52)"
fi
if grep -rn "grep [^|]*'\^[^']*'[^|]*/proc/cmdline" mkosi.extra/ 2>/dev/null | grep -q .; then
    bad=$(grep -rn "grep [^|]*'\^[^']*'[^|]*/proc/cmdline" mkosi.extra/ | head -3 | sed 's/^/      /')
    no "还有地方对着 /proc/cmdline 用 ^ 锚定(grep 把整行当一行 ⇒ 永远不匹配,坑 #52):"
    printf '%s\n' "$bad"
else
    ok "没有任何地方对着 /proc/cmdline 用 ^ 锚定(要么走 keel_cmdline_has,要么先切成 token)"
fi
if grep -q 'keel_cmdline_has panic=-1' mkosi.extra/usr/share/keel/keel-check &&
   grep -q 'command -v keel_cmdline_has' mkosi.extra/usr/share/keel/keel-check; then
    ok "keel-check 用 lib.sh 的 token 匹配判 panic=-1,且 lib.sh 读不到时自己兜一份"
else
    no "keel-check 的 cmdline 判据没走 keel_cmdline_has(坑 #52 会复发)"
fi
# 体检脚本报的每一类结论都要能对上"事实来源",否则又是一次"医生说谎":
# 微码/TPM 在虚拟机里是宿主的事(应报跳过,不是警告),看门人在启动 3 分钟后才有结论。
if grep -q 'systemd-detect-virt' mkosi.extra/usr/share/keel/keel-check &&
   grep -q 'keel-data-guard.timer' mkosi.extra/usr/share/keel/keel-check; then
    ok "keel-check 会区分「虚拟机/真机」与「看门人还没到点」,不把正常情况报成警告"
else
    no "keel-check 缺少环境区分(虚拟机里会把正常情况报成警告 —— 2026-09 实测)"
fi
# 非 root 跑也要说真话(2026-09 在装好的系统上以 admin 跑过一次,抓到四条误报):
#   * swapon 在 /usr/sbin,非交互 ssh 的 PATH 里没有 ⇒ 有 swap 被报成「没有」
#   * /etc/sudoers.d/10-keel-admin 是 0440 root:root ⇒ `-r` 判成「缺」 ⇒ 假失败
#   * blockdev 读块设备要权限 ⇒ 拿到 0 字节,却打出「分区 0 MiB,尺寸一致」的**假 ✓**
#   * [ -w /sys/firmware/efi/efivars ] 是 0700 root:root ⇒ 能写也被报成「否」
if grep -q '/proc/swaps' mkosi.extra/usr/share/keel/keel-check &&
   ! grep -q 'swapon --show' mkosi.extra/usr/share/keel/keel-check; then
    ok "keel-check 从 /proc/swaps 读 swap(不依赖 PATH 里的 /usr/sbin/swapon)"
else
    no "keel-check 用 swapon 判 swap ⇒ 非 root / 非交互 shell 下会把有 swap 报成没有"
fi
if grep -q '\[ -e /etc/sudoers.d/10-keel-admin \]' mkosi.extra/usr/share/keel/keel-check; then
    ok "keel-check 判 sudoers 规则用 -e(非 root 用 -r 会得到「缺」的假失败)"
else
    no "keel-check 用 -r 判 /etc/sudoers.d/10-keel-admin ⇒ 非 root 下假失败"
fi
if grep -q '读不到 data 分区的设备大小' mkosi.extra/usr/share/keel/keel-check; then
    ok "keel-check 读不到分区大小时报「跳过」,不会拿 0 比出假 ✓"
else
    no "keel-check 拿读不到的 0 字节和设备大小比 ⇒ 非 root 下会打出假 ✓"
fi
if grep -q 'findmnt -no OPTIONS /sys/firmware/efi/efivars' mkosi.extra/usr/share/keel/keel-check &&
   ! grep -q '^[^#]*\[ -w /sys/firmware/efi/efivars \]' mkosi.extra/usr/share/keel/keel-check; then
    ok "keel-check 从挂载选项判 EFI 变量可写性(不靠 0700 目录的 [ -w ])"
else
    no "keel-check 用 [ -w efivars ] 判可写性 ⇒ 非 root 下会说错"
fi
# 非 root 实跑:整份脚本必须能跑到汇总(不崩、也不半途而废)。
# 注意:这条要**从 root 掉到别的 uid** 才跑得起来(setpriv 需要特权),所以非 root 调用者跳过。
if [ "$(id -u)" != 0 ]; then
    skip "非 root:跳过「以 uid 65534 实跑 keel-check」(setpriv 掉权限需要 root)"
elif have setpriv; then
    setpriv --reuid=65534 --regid=65534 --clear-groups bash mkosi.extra/usr/share/keel/keel-check >"$cld/nonroot.out" 2>&1 || true
    if grep -q '汇总' "$cld/nonroot.out"; then
        ok "以非 root(uid 65534)实跑 keel-check 能跑完整份并给出汇总"
    else
        no "非 root 跑 keel-check 没跑到汇总:"
        tail -5 "$cld/nonroot.out" | sed 's/^/      /'
    fi
else
    skip "没装 setpriv(util-linux),跳过「非 root 实跑 keel-check」这条"
fi

# 便宜的检查必须在下载之前(坑 #51):迁移与 schema 检查只看 manifest,而下载是 13 GiB
OU=mkosi.extra/usr/bin/os-update
n_mig=$(grep -n '没有迁移执行器' "$OU" | head -1 | cut -d: -f1)
n_dl=$(grep -n 'for a in "${ARTIFACTS\[@\]}"' "$OU" | head -1 | cut -d: -f1)
if [ -n "$n_mig" ] && [ -n "$n_dl" ] && [ "$n_mig" -lt "$n_dl" ]; then
    ok "os-update fetch 先做迁移/schema 检查再下载(第 $n_mig 行 vs 第 $n_dl 行)"
else
    no "迁移/schema 检查在下载之后(第 ${n_mig:-?} 行 vs 第 ${n_dl:-?} 行)⇒ 会先下 13 GiB 才拒绝"
fi

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

# ---------------------------------------------------------------------------
head1 "9. /data 磁盘预算(决策 D23)"
# ---------------------------------------------------------------------------
JD=mkosi.extra/etc/systemd/journald.conf.d/keel.conf
if [ -f "$JD" ] && grep -q '^SystemMaxUse=' "$JD" && grep -q '^SystemKeepFree=' "$JD"; then
    ok "journald 有显式的 SystemMaxUse / SystemKeepFree(/data 写满会连带 /etc 写不进去)"
else
    no "缺少 $JD(或没写死上限)—— journald 默认按文件系统百分比算"
fi
if [ -f mkosi.extra/usr/lib/systemd/system/keel-nix-gc.service ] &&
   [ -f mkosi.extra/usr/lib/systemd/system/keel-nix-gc.timer ]; then
    if grep -q 'nix-collect-garbage' mkosi.extra/usr/lib/systemd/system/keel-nix-gc.service &&
       grep -q 'max-freed' mkosi.extra/usr/lib/systemd/system/keel-nix-gc.service; then
        ok "keel-nix-gc.service/timer:自带 nix GC(Debian 的 nix-setup-systemd 没有定时器)"
    else
        no "keel-nix-gc.service 里没有 nix-collect-garbage / --max-freed"
    fi
else
    no "缺少 keel-nix-gc.service 或 .timer"
fi
DG=mkosi.extra/usr/lib/keel/data-guard
if [ -f "$DG" ]; then
    if [ ! -x "$DG" ]; then
        no "$DG 没有可执行权限(systemd 会拒绝启动它)"
    elif grep -q 'WARN=' "$DG" && grep -q 'RESERVE' "$DG" && grep -q 'keel_log' "$DG"; then
        ok "keel-data-guard:阈值分级 + 交还应急空间 + 结论写进 /data/keel/data-guard.state"
    else
        no "data-guard 缺少阈值/应急空间逻辑"
    fi
else
    no "缺少 $DG"
fi
if [ -f mkosi.extra/usr/lib/systemd/system/keel-data-guard.service ] &&
   [ -f mkosi.extra/usr/lib/systemd/system/keel-data-guard.timer ]; then
    ok "keel-data-guard.service/timer 存在(启动 3 分钟后 + 每天一次)"
else
    no "缺少 keel-data-guard.service 或 .timer"
fi
if grep -q 'enable keel-data-guard.timer' "$PRESET" && grep -q 'enable keel-nix-gc.timer' "$PRESET"; then
    ok "preset 启用了两个新定时器"
else
    no "preset 没有启用 keel-data-guard.timer / keel-nix-gc.timer"
fi
if grep -q 'RESERVE=' mkosi.extra/usr/lib/keel/firstboot && grep -q 'fallocate -l 256M' mkosi.extra/usr/lib/keel/firstboot; then
    ok "keel-firstboot 第 6 步预留 256 MiB 应急空间(小文件系统跳过)"
else
    no "keel-firstboot 里没有应急空间的创建逻辑"
fi
if grep -q 'etc.bak-\*' mkosi.extra/usr/lib/keel/mounts && grep -q 'tail -n +2' mkosi.extra/usr/lib/keel/mounts; then
    ok "os-rescue --reset-etc 的备份只留最近一份(否则每次重置都堆一份 /etc 副本)"
else
    no "mounts 里没有清理旧 etc.bak-* 的逻辑"
fi
if grep -q 'free_bytes' mkosi.extra/usr/bin/os-update && grep -q 'os-update gc' mkosi.extra/usr/bin/os-update; then
    ok "os-update fetch 先查 /data 空间(4 个产物约 13 GiB)"
else
    no "os-update fetch 没有检查 /data 可用空间"
fi
if grep -q '自动清理旧载荷失败' mkosi.extra/usr/bin/os-update && grep -q 'cmd_gc >/dev/null' mkosi.extra/usr/bin/os-update; then
    ok "os-update stage 成功后自动清理旧载荷"
else
    no "os-update stage 之后没有自动清理旧载荷"
fi
if grep -q '空间看门人' mkosi.extra/usr/bin/os-status && grep -q '应急空间' mkosi.extra/usr/bin/os-status; then
    ok "os-status 报告看门人结论与应急空间状态"
else
    no "os-status 没有 /data 看门人那一节"
fi

# ---------------------------------------------------------------------------
printf '\n\033[1m结果: %d 通过, %d 失败' "$pass" "$fail"
[ "$skipped" -gt 0 ] && printf ', %d 跳过' "$skipped"
printf '\033[0m\n'
[ "$fail" = 0 ] || exit 1
