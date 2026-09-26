# shellcheck shell=bash
# keel verify 模块:libvirt 验证脚本与域 XML(原第 1123-1204 行,逐字搬移)

verify_libvirt() {
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
# 范围覆盖**所有 tracked 文件**(不只 mkosi.extra*/):mkosi.conf / mkosi.profiles/* / docs/*.md
# 也一样会被 mkosi 或 mkosi.postinst 读,0600 只是 umask 的意外产物。
# --cached --others --exclude-standard:已跟踪的 + 还没提交但**没被 ignore** 的。
# 只看已跟踪文件会漏掉最危险的那一刻 —— 新文件刚写好、还没 commit 的时候(实测就是这么漏的)。
badmodes=$(git ls-files -z --cached --others --exclude-standard 2>/dev/null |
           xargs -0 -r stat -c '%a %n' 2>/dev/null | awk '$1 !~ /[4567]$/ {print $2}' | head -5)
if [ -z "$badmodes" ]; then
    ok "仓库里没有「其他用户不可读」的文件(git 不跟踪读权限,只能在构建前查,坑 #57)"
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

}
