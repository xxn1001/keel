# shellcheck shell=bash
# keel verify 模块:keel-check 体检脚本及其判据测试 / cmdline token 匹配 / 下载前检查(原第 1205-1306 行,逐字搬移)

verify_keel_check() {
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

# 便宜的检查必须在下载之前(坑 #51):迁移与 schema 检查只看 manifest,而下载是 GiB 级(erofs 后约 4 GiB)
OU=mkosi.extra/usr/bin/os-update
n_mig=$(grep -n '没有迁移执行器' "$OU" | head -1 | cut -d: -f1)
n_dl=$(grep -n 'for a in "${ARTIFACTS\[@\]}"' "$OU" | head -1 | cut -d: -f1)
if [ -n "$n_mig" ] && [ -n "$n_dl" ] && [ "$n_mig" -lt "$n_dl" ]; then
    ok "os-update fetch 先做迁移/schema 检查再下载(第 $n_mig 行 vs 第 $n_dl 行)"
else
    no "迁移/schema 检查在下载之后(第 ${n_mig:-?} 行 vs 第 ${n_dl:-?} 行)⇒ 会先下完整载荷才拒绝"
fi

}
