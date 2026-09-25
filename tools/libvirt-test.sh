#!/usr/bin/env bash
# keel —— 在 libvirt 里做「真机前」的验证(供 virt-manager / libvirtd 用户使用)
#
# 为什么要有它:mkosi 的 `vm` 用的是 mkosi 自己的 QEMU 参数与临时固件变量;
# 而"真机"最接近的模拟环境是 libvirt —— 独立可写的 NVRAM、持久磁盘、virtio-scsi、
# 有 NAT 网络(guest 能直接访问宿主的 192.168.122.1,更新源不用绕 QEMU 的 SLIRP)。
# virt-manager 能做的这里都能做,区别是这个脚本**可重复、把日志留在文件里**,
# 出问题时有东西可看(而不是靠回忆图形界面点了什么)。
#
# 用法(在仓库根目录,不需要 root,除非你没加进 libvirt 组):
#   tools/libvirt-test.sh prepare        # 造磁盘(overlay + 40G 目标盘)+ 域 XML
#   tools/libvirt-test.sh start          # 定义并启动(串口日志 → mkosi.output/libvirt/console.log)
#   tools/libvirt-test.sh console        # 连串口控制台(virsh console;退出按 Ctrl+])
#   tools/libvirt-test.sh log            # 看串口日志(tail -f)
#   tools/libvirt-test.sh net            # 看 guest 拿到的 IP
#   tools/libvirt-test.sh update-serve   # 宿主上起本地更新源(guest 用 http://192.168.122.1:8000)
#   tools/libvirt-test.sh destroy        # 关机并删除域(磁盘与日志保留)
#   tools/libvirt-test.sh nuke           # 连磁盘/日志一起删
#
# 典型的一次完整演练:
#   tools/build.sh                              # 产出 dist/keel-<版本>/
#   tools/libvirt-test.sh prepare && tools/libvirt-test.sh start
#   tools/libvirt-test.sh console               # 登录 admin;网线(虚拟的)里已经通
#     # 在 guest 里:
#     #   sudo os-update check                 (可选:先确认没有源)
#     #   sudo os-install /dev/vdb             ← 装到目标盘
#     #   sudo reboot
#   tools/libvirt-test.sh destroy && tools/libvirt-test.sh start --boot target
#   tools/libvirt-test.sh console               # 现在跑的是**装机后的系统**
#     # 在 guest 里:确认 os-status、df -h /data、nix-shell -p fastfetch
#   tools/libvirt-test.sh update-serve          # 宿主机上起更新源
#     # 在 guest 里:echo UPDATE_SOURCE=http://192.168.122.1:8000 | sudo tee -a /data/keel/config
#     #   sudo os-update check && sudo os-update fetch && sudo os-update stage --reboot
#   # 重启后应该在新槽;再 os-update rollback 回旧槽 —— 这就是真机上的 A/B。
set -euo pipefail
cd "$(dirname "$0")/.."

DOMAIN=${KEEL_LIBVIRT_DOMAIN:-keel-test}
WORK=mkosi.output/libvirt
TARGET_SIZE=${KEEL_LIBVIRT_TARGET_SIZE:-40G}
PORT=${KEEL_LIBVIRT_PORT:-8000}
RAM=${KEEL_LIBVIRT_RAM:-2048}
CPUS=${KEEL_LIBVIRT_CPUS:-2}

log() { printf 'keel-libvirt: %s\n' "$*" >&2; }
die() { printf 'keel-libvirt: 错误:%s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "找不到 $1(需要 libvirt 的 virsh 与 qemu-img)"; }

# 用哪份安装镜像:优先 dist/ 里最新的产物(它带完整载荷),否则退回 mkosi.output/keel.raw
find_install_image() {
    local d
    for d in $(ls -1d dist/keel-* 2>/dev/null | sort -Vr); do
        if [ -f "$d/keel.raw" ]; then printf '%s' "$d/keel.raw"; return 0; fi
    done
    if [ -f mkosi.output/keel.raw ]; then printf '%s' mkosi.output/keel.raw; return 0; fi
    return 1
}

# OVMF 固件:两套命名都要认(坑 #55)。
#
#   * 发行版常见:OVMF_CODE*.fd + 配对的 OVMF_VARS*.fd
#   * NixOS / QEMU:edk2-x86_64-code.fd + edk2-i386-vars.fd
#     (QEMU 的 "i386" 变量文件就是 x86 通用那份;virt-manager 生成的域 XML 也这么配 ——
#      项目所有者的机器上 /run/libvirt/nix-ovmf 里**只有**这套命名,所以只认 OVMF_CODE*
#      的写法在那台机器上必然找不到固件。)
# NVRAM 要可写,所以调用方会复制一份到 WORK 里再给域用。
find_ovmf() {
    local d f v
    for d in /run/libvirt/nix-ovmf /usr/share/OVMF /usr/share/edk2/ovmf \
             /usr/share/qemu/OVMF /usr/share/edk2/x64 /usr/share/qemu; do
        [ -d "$d" ] || continue
        for f in "$d"/OVMF_CODE*.fd; do
            [ -f "$f" ] || continue
            v=${f/OVMF_CODE/OVMF_VARS}
            [ -f "$v" ] || continue
            printf '%s\n%s\n' "$f" "$v"
            return 0
        done
        for f in "$d"/edk2-x86_64-code.fd "$d"/edk2-i386-code.fd; do
            [ -f "$f" ] || continue
            for v in "$d"/edk2-i386-vars.fd "$d"/edk2-x86_64-vars.fd; do
                [ -f "$v" ] || continue
                printf '%s\n%s\n' "$f" "$v"
                return 0
            done
        done
    done
    return 1
}

# 取固件并**显式校验条数**:`mapfile -t x < <(cmd)` **不会**把 cmd 的失败传出来
# (进程替换的退出码被丢掉),所以 `readarray ... || die "找不到 OVMF"` 是死代码 ——
# 真正报出来的是 `ovmf[0]: unbound variable`(set -u 下),看起来像脚本坏了,
# 其实只是没找到固件。判据要自己去看结果(坑 #55)。
load_ovmf() {
    OVMF=()
    mapfile -t OVMF < <(find_ovmf)
    [ "${#OVMF[@]}" -ge 2 ] || die "找不到 OVMF 固件(两套命名都试了:/run/libvirt/nix-ovmf、/usr/share/OVMF 等)"
}

xml_path() { printf '%s/%s.xml' "$WORK" "$DOMAIN"; }

# 域的 UUID 必须**稳定**:render_xml 会被调用两次(live / target),不带 uuid 时
# libvirt 每次 define 都想"新建"一个同名域,第二次直接报
#   operation failed: domain 'keel-test' already exists with uuid …
# ⇒ 第一次生成后写进 $WORK/$DOMAIN.uuid,之后一直复用(2026-09 实测,坑 #58)。
domain_uuid() {
    local f="$WORK/$DOMAIN.uuid"
    if [ -s "$f" ]; then cat "$f"; return 0; fi
    mkdir -p "$WORK"
    cat /proc/sys/kernel/random/uuid >"$f"
    cat "$f"
}

render_xml() {
    local boot_target=$1 ovmf_code=$2
    # 从**目标盘**启动时,把"U 盘"(vda)整个摘掉 —— 真机上这一步就是"拔掉 U 盘再重启"。
    #
    # 为什么必须摘:两块盘都在时,固件会优先走它 NVRAM 里的启动项,而 live 那次的启动项
    # 还在(装机时 os-install 只是往目标 ESP 里装了引导器,并没有删掉 vda 的条目)⇒
    # 实测结果是**又启动了 live 盘**,演练于是把 live 系统的体检结论当成了"装好的系统"的
    # (2026-09 实测,坑 #59)。摘掉之后才真的验证了"装好的系统能独立启动"。
    local vda_xml=""
    if [ "$boot_target" != target ]; then
        read -r -d '' vda_xml <<DISK || true
    <!-- vda = "U 盘"(安装镜像的 qcow2 overlay,写操作落在 overlay 上,原始产物不动) -->
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' discard='unmap'/>
      <source file='$PWD/$WORK/install.qcow2'/>
      <target dev='vda' bus='virtio'/>
      <boot order='1'/>
    </disk>
DISK
    fi
    cat >"$(xml_path)" <<EOF
<domain type='kvm'>
  <name>$DOMAIN</name>
  <uuid>$(domain_uuid)</uuid>
  <memory unit='MiB'>$RAM</memory>
  <vcpu>$CPUS</vcpu>
  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <loader readonly='yes' type='pflash'>$ovmf_code</loader>
    <nvram>$PWD/$WORK/nvram.fd</nvram>
    <!-- 启动顺序**只用**磁盘上的 per-device <boot order=>**(见下面 vda/vdb)。
         这里以前还写着 os 级的 boot dev=hd,现代 libvirt 会直接拒绝定义:
           unsupported configuration: per-device boot elements cannot be used
           together with os/boot elements
         (2026-09 第一次真的跑 libvirt 演练时撞到,坑 #56) -->
  </os>
  <features><acpi/><apic/></features>
  <cpu mode='host-passthrough' check='none'/>
  <clock offset='utc'/>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>restart</on_crash>
  <devices>
$vda_xml    <!-- vdb = 目标盘(os-install 会把它整块擦掉) -->
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' discard='unmap'/>
      <source file='$PWD/$WORK/target.qcow2'/>
      <target dev='vdb' bus='virtio'/>
      <boot order='$([ "$boot_target" = target ] && echo 1 || echo 2)'/>
    </disk>
    <controller type='scsi' model='virtio-scsi'/>
    <interface type='network'>
      <source network='default'/>
      <model type='virtio'/>
    </interface>
    <!-- 串口:pty 给 virsh console 用,同时把全部输出落一份到文件(排错靠它) -->
    <serial type='pty'>
      <target port='0'/>
      <log file='$PWD/$WORK/console.log' append='off'/>
    </serial>
    <console type='pty'><target type='serial' port='0'/></console>
    <!-- 图形控制台仍然留着:virt-manager 可以像平常一样打开它 -->
    <graphics type='vnc' port='-1' autoport='yes' listen='127.0.0.1'/>
    <video><model type='vga'/></video>
    <rng model='virtio'><backend model='random'>/dev/urandom</backend></rng>
    <memballoon model='virtio'/>
  </devices>
</domain>
EOF
}

cmd_prepare() {
    need virsh; need qemu-img
    local img; img=$(find_install_image) || die "找不到安装镜像:先跑 tools/build.sh(或 mkosi ... build)"
    load_ovmf
    mkdir -p "$WORK"
    # 从零开始:上次留下的域必须先删掉 —— 它可能还在跑,而且引用的正是下面要重建的那两块盘。
    # `--nvram` 把旧的 UEFI 变量一起删掉(反正 prepare 会重新复制一份干净的 vars 文件)。
    if virsh dominfo "$DOMAIN" >/dev/null 2>&1; then
        log "已存在的域 $DOMAIN:先 destroy + undefine(--nvram),从干净状态开始"
        virsh destroy "$DOMAIN" >/dev/null 2>&1 || true
        virsh undefine "$DOMAIN" --nvram >/dev/null 2>&1 || virsh undefine "$DOMAIN" >/dev/null 2>&1 || true
    fi
    rm -f "$WORK/$DOMAIN.uuid"          # 新的一次演练 = 新的域身份
    log "安装镜像:$img"
    log "OVMF    :${OVMF[0]}"
    # 盘:安装镜像用 qcow2 overlay(不复制 15 GiB);目标盘 40 GiB 稀疏
    rm -f "$WORK/install.qcow2" "$WORK/target.qcow2"
    qemu-img create -q -f qcow2 -F raw -b "$PWD/$img" "$WORK/install.qcow2"
    qemu-img create -q -f qcow2 "$WORK/target.qcow2" "$TARGET_SIZE"
    cp -f "${OVMF[1]}" "$WORK/nvram.fd"
    render_xml live "${OVMF[0]}"
    log "磁盘与域 XML 就绪:$WORK/"
    log "下一步:tools/libvirt-test.sh start"
}

cmd_start() {
    need virsh
    local boot_target=live
    [ "${1:-}" = --boot ] && boot_target=${2:-live}
    [ -f "$(xml_path)" ] || die "还没有域 XML:先跑 tools/libvirt-test.sh prepare"
    [ -f "$WORK/nvram.fd" ] || die "缺少 NVRAM:先跑 tools/libvirt-test.sh prepare"
    # 改了启动顺序就重新渲染一次 XML(其它内容不变)
    if [ "$boot_target" = target ]; then
        local img; img=$(find_install_image) || die "找不到安装镜像"
        load_ovmf
        render_xml target "${OVMF[0]}"
        log "启动顺序:目标盘(vdb)优先 —— 这次跑的是装机后的系统"
    fi
    # default 网络是活的吗(libvirt 默认不自动启动它)
    if ! virsh net-info default >/dev/null 2>&1; then
        die "没有名为 default 的 libvirt 网络:virt-manager 里启用它,或 virsh net-define/start"
    fi
    if [ "$(virsh net-info default | awk '/^Active/{print $2}')" != "yes" ]; then
        log "启动 libvirt 的 default 网络(guest 需要 DHCP 与宿主 192.168.122.1)"
        virsh net-start default >/dev/null || die "virsh net-start default 失败(需要 root?)"
    fi
    # 每次都 define:改了启动顺序(或换了产物)时,已存在的域配置要跟着更新。
    # **检查退出码**:以前这里不检查,define 被 libvirt 拒绝之后还会继续往下走,
    # 报出来的是 "Failed to start domain … which is not defined"(坑 #56)。
    virsh define "$(xml_path)" >/dev/null || die "virsh define 失败:域 XML 被 libvirt 拒绝(把 $(xml_path) 喂给 virsh define 看完整错误)"
    virsh start "$DOMAIN" >/dev/null || die "virsh start $DOMAIN 失败(看 /var/log/libvirt/qemu/$DOMAIN.log)"
    log "已启动。串口控制台:tools/libvirt-test.sh console    串口日志:tools/libvirt-test.sh log"
}

cmd_console() { need virsh; exec virsh console "$DOMAIN"; }
cmd_log()     { [ -f "$WORK/console.log" ] || die "还没有串口日志(先 start)"; exec tail -f "$WORK/console.log"; }

cmd_net() {
    need virsh
    echo "guest 地址(来自 libvirt 的 DHCP 租约):"
    virsh net-dhcp-leases default 2>/dev/null | sed 's/^/  /'
    virsh domifaddr "$DOMAIN" --source lease 2>/dev/null | sed 's/^/  /' || true
}

cmd_update_serve() {
    local d; d=$(ls -1d dist/keel-* 2>/dev/null | sort -V | tail -1) || d=""
    [ -n "$d" ] || die "dist/ 下没有载荷目录:先跑 tools/build.sh"
    log "把 $d 通过 HTTP 提供给 guest:http://192.168.122.1:$PORT/"
    log "guest 里执行:echo UPDATE_SOURCE=http://192.168.122.1:$PORT | sudo tee -a /data/keel/config"
    if command -v python3 >/dev/null 2>&1; then
        exec python3 -m http.server "$PORT" --bind 0.0.0.0 --directory "$d"
    fi
    log "宿主没有 python3 ⇒ 用容器提供(podman/docker)"
    if command -v podman >/dev/null 2>&1; then
        exec podman run --rm -p "$PORT:$PORT" -v "$PWD/$d:/srv:ro,Z" \
            docker.io/library/debian:trixie \
            sh -c "apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends python3-minimal >/dev/null && python3 -m http.server $PORT --bind 0.0.0.0 --directory /srv"
    fi
    die "既没有 python3 也没有 podman —— 手动起一个能把 $d 暴露到 0.0.0.0:$PORT 的 HTTP 服务即可"
}

cmd_destroy() { need virsh; virsh destroy "$DOMAIN" >/dev/null 2>&1 || true; virsh undefine "$DOMAIN" >/dev/null 2>&1 || true; log "域已删除(磁盘与日志保留在 $WORK/)"; }
cmd_nuke()    { cmd_destroy; rm -rf "$WORK"; log "磁盘与日志也删了"; }

case "${1:-}" in
    prepare)      cmd_prepare ;;
    start)        shift; cmd_start "$@" ;;
    console)      cmd_console ;;
    log)          cmd_log ;;
    net)          cmd_net ;;
    update-serve) cmd_update_serve ;;
    destroy)      cmd_destroy ;;
    nuke)         cmd_nuke ;;
    *) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
