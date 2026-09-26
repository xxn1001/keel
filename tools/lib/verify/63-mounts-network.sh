# shellcheck shell=bash
# keel verify 模块:/nix /home / dpkg / DHCP / machine-id / 自检 / 命令与 preset / swapfile(原第 740-843 行,逐字搬移)

verify_mounts_network() {
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

}
