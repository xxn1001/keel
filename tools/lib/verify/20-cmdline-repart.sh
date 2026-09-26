# shellcheck shell=bash
# keel verify 模块:kernel cmdline 一致性 + repart 分区布局(原第 131-300 行,逐字搬移)

verify_cmdline() {
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
}

verify_repart() {

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

    # ⚠ 产物镜像必须放在 $tree **外面**:`--copy-source=$tree` 配合 `CopyFiles=/` 会把
    # $tree 整个拷进根分区 —— 如果 out.raw 放在 $tree 里,那就是"把正在写的镜像拷进它自己"。
    # v1(ext4)侥幸没炸,是因为 mke2fs 会跳过稀疏文件的空洞;erofs 老老实实读满 15 GiB,
    # 于是卡死在这里(2026-09 换 erofs 时实测:repart 的临时源目录里出现了 16 GB 的 out.raw)。
    outdir=$(tmpd)
    for d in repart/install repart/slot-a repart/slot-b; do
        img="$outdir/out.raw"; rm -f "$img"
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

    # ── v1.1 erofs 只读根:载荷侧解钉死 / 安装侧钉死 ──────────────────────
    # 这两条互为反证,只改一边(或两边一起改)都会在某处炸:
    #   - 载荷侧留着 SizeMaxBytes=6G ⇒ 一份载荷又变成 6 GiB(本次改动白做);
    #   - 安装侧去掉 6 GiB          ⇒ 分区表变了,老机器/不变量 9 直接废掉。
    # 也守 Minimize=yes:它是"只占内容大小"的开关,不写就默认 off。
    payload_bad=""
    for f in repart/slot-a/10-root-a.conf repart/slot-b/10-root-b.conf; do
        grep -qE '^[[:space:]]*Format=erofs[[:space:]]*$'  "$f" || payload_bad="$payload_bad $f:非erofs"
        grep -qE '^[[:space:]]*Minimize=yes[[:space:]]*$' "$f" || payload_bad="$payload_bad $f:缺Minimize"
        grep -qE '^[[:space:]]*SizeMaxBytes='              "$f" && payload_bad="$payload_bad $f:还钉着尺寸"
    done
    if [ -z "$payload_bad" ]; then
        ok "槽载荷 = erofs + Minimize=yes 且没有 SizeMaxBytes ⇒ 不再被钉到 6 GiB"
    else
        no "槽载荷的 erofs/解钉死没做全:$payload_bad"
    fi
    if grep -qE '^[[:space:]]*Format=erofs[[:space:]]*$' repart/install/10-root-a.conf &&
       grep -qE '^[[:space:]]*SizeMinBytes=6G[[:space:]]*$' repart/install/10-root-a.conf &&
       grep -qE '^[[:space:]]*SizeMaxBytes=6G[[:space:]]*$' repart/install/10-root-a.conf; then
        ok "安装侧 root-a = erofs 且尺寸仍钉死 6 GiB(槽位是布局常量,不变量 9)"
    else
        no "安装侧 root-a 不是「erofs + 6 GiB」—— 装出来的根格式或分区表会不对"
    fi
    # 空槽不能写 Format=:repart 拒绝格式化没有源文件的 erofs
    #   Cannot format erofs filesystem without source files, refusing.
    # v1 的 `Format=ext4`(空 ext4 合法)在这里正好是个陷阱。
    if grep -qE '^[[:space:]]*Format=' repart/install/20-root-b.conf; then
        no "安装侧 root-b 写了 Format= —— 空槽格式化 erofs 会被 repart 拒绝(只能保持未格式化)"
    else
        ok "安装侧 root-b 保持未格式化(空槽:repart 拒绝空 erofs;未格式化也给首次更新干净的起点)"
    fi

    # os-install 在目标机上跑的是**镜像里那份**定义(mkosi.postinst 装进
    # /usr/lib/keel/repart-install.d),它是 repart/install 去掉 CopyFiles= 的版本。
    # 这里按同样的方式生成一份并真跑一遍:既证明它本身是合法定义,也证明分区表
    # 与构建时那份逐字节一致(名字/尺寸/类型)。
    rt="$tree/repart-runtime"
    mkdir -p "$rt"
    for f in repart/install/*.conf; do
        # 必须与 mkosi.postinst **逐字同源**:两条 sed 表达式(去 CopyFiles=、去 Format=erofs)。
        # Format=erofs 也得去掉:erofs 需要源文件,而运行时定义没有 CopyFiles ⇒ repart 拒绝
        #   Cannot format erofs filesystem without source files, refusing.
        # ⇒ os-install 的建表直接失败。root-a 随后被 live 根 dd 覆盖,root-b 等首次更新。
        sed -e '/^[[:space:]]*CopyFiles=/d' -e '/^[[:space:]]*Format=erofs[[:space:]]*$/d' \
            "$f" >"$rt/$(basename "$f")"
    done
    if grep -q 'CopyFiles' "$rt"/*.conf; then
        no "运行时定义里还留着 CopyFiles= —— repart 会去拷宿主机的 /proc、/data"
    else
        ok "运行时 repart 定义没有 CopyFiles=(不会去拷宿主机的 /proc、/data)"
    fi
    if grep -q 'Format=erofs' "$rt"/*.conf; then
        no "运行时定义里还留着 Format=erofs ⇒ os-install 建表会失败(erofs 需要源文件;坑 #32 的同类)"
    else
        ok "运行时 repart 定义没有 Format=erofs(装机不格式化槽根:a 靠 dd、b 等首次更新)"
    fi
    # 上面那份是 verify 自己 sed 的;真正装进镜像的是 mkosi.postinst 那段 —— 断言两者同源,
    # 否则会出现最坏的一种:verify 全绿、真实 os-install 却建表失败。
    if grep -q 'Format=erofs\[\[:space:\]\]' mkosi.postinst; then
        ok "mkosi.postinst 也去掉了 Format=erofs(verify 的模拟与真实装机定义同源)"
    else
        no "mkosi.postinst 没有去掉 Format=erofs ⇒ 真实 os-install 会建表失败(verify 却全绿)"
    fi
    rtimg="$outdir/rt.raw"; rm -f "$rtimg"
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

}
