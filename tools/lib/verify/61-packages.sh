# shellcheck shell=bash
# keel verify 模块:包清单与 os-install 定义目录(原第 626-676 行,逐字搬移)

verify_packages() {

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
for pkg in dosfstools e2fsprogs erofs-utils; do
    if grep -qE "^[[:space:]]*${pkg}[[:space:]]*$" mkosi.conf.d/20-packages.conf; then :; else
        no "包清单缺 $pkg —— repart 在目标盘上格式化分区时要用它(坑 #32)"
        missing_fmt=1
    fi
done
[ "$missing_fmt" = 0 ] && ok "包清单包含 dosfstools + e2fsprogs + erofs-utils(repart 在目标盘上格式化 ESP / data / erofs 根要用;v1.1 起根是 erofs)"

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

}
