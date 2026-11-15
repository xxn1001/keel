# initrd

> 状态：accepted | 更新：2026-11-14
> 目标：在 `switch_root` 之前挂好 root、`/etc`、`/var`、`/home`、`/boot`。
> 任何关键挂载失败：进 physical recovery，不继续半启动。
> 超时预算与故障注入见 [ADR-0015](decisions/ADR-0015-boot-failure-contract.md)；
> v0.1 的执行顺序见 [design-v01-skeleton.md](design-v01-skeleton.md)。

## 1. 目标

- 激活 `system` VG。
- 挂 root LV（erofs，`ro`）。
- 挂 `/etc`（ext4）、`/var`/`/home`（data btrfs 子卷）。
- 挂 ESP 到 `/boot`。
- 挂 `/proc`、`/sys`、`/dev`。
- `switch_root` 到真正 systemd。
- 失败时挂 `recovery` 分区并 `switch_root` 到救援 rootfs。

非目标：网络、解密、verity。v1 不做。

## 2. 两个阶段

| 阶段 | 形态 | 状态 |
|---|---|---|
| P0 | 一个最小脚本 | v0.1 的实现 |
| P1 | systemd units | **待评估，非承诺**：见 [Q-0011](open/Q-0011-initrd-p1.md) |

原来的路线是"P0 临时、P1 最终形态"。现在改成：P0 至少用到 v0.3，
P1 是否值得做单独评估。原因见 Q-0011（主要是挂死时的可诊断性）。

P0 脚本仍然是脚本，不允许长成第二个 shell 状态机：只做挂载和失败判定，
不做状态、不做版本比较、不做更新。

超时和故障注入**不是 P1 的预备动作**，是 P0 本身必须具备的能力。

## 3. P0：最小脚本

```sh
#!/bin/sh
set -eu

# cmdline knobs: see docs/decisions/ADR-0015-boot-failure-contract.md
fail=
timeout_lvm=30
timeout_root=15
timeout_etc=15
timeout_data=15
timeout_esp=10

# cmdline is space separated; word splitting is intended here.
# shellcheck disable=SC2013
for arg in $(cat /proc/cmdline); do
    case "$arg" in
        keel.fail=*)
            fail=${arg#keel.fail=}
            ;;
        keel.timeout=*)
            kv=${arg#keel.timeout=}
            name=${kv%%:*}
            secs=${kv##*:}
            case "$name" in
                lvm)  timeout_lvm=$secs ;;
                root) timeout_root=$secs ;;
                etc)  timeout_etc=$secs ;;
                data) timeout_data=$secs ;;
                esp)  timeout_esp=$secs ;;
            esac
            ;;
    esac
done

mkdir -p /run/keel /sysroot /recovery
mount -t devtmpfs devtmpfs /dev
mount -t proc proc /proc
mount -t sysfs sysfs /sys

# step <name> <seconds> <command...>
step() {
    _name=$1
    _limit=$2
    shift 2
    if [ "$fail" = "$_name" ]; then
        echo "keel: injecting failure at $_name"
        : > "/run/keel/fail.$_name"
        return 1
    fi
    timeout "$_limit" "$@"
}

rescue() {
    echo "keel: $*; entering recovery"
    if mount -t erofs -o ro /dev/disk/by-partlabel/recovery /recovery; then
        exec switch_root /recovery /sbin/init
    fi
    echo "keel: recovery mount failed; dropping to shell"
    exec /bin/sh
}

if grep -q 'keel.recovery=1' /proc/cmdline; then
    rescue "keel.recovery=1"
fi

step vglv "$timeout_lvm" /sbin/vgchange --noudevsync -ay system \
    || rescue "vgchange failed or timed out"
/sbin/vgmknodes

step root "$timeout_root" mount -t erofs -o ro /dev/system/root_a /sysroot \
    || rescue "root mount failed"

step etc "$timeout_etc" mount -t ext4 -o rw,noatime /dev/system/etc /sysroot/etc \
    || rescue "etc mount failed"

step data "$timeout_data" mount -t btrfs -o rw,noatime,compress=zstd:3,subvol=var \
    /dev/disk/by-partlabel/data /sysroot/var \
    || rescue "var mount failed"

step data "$timeout_data" mount -t btrfs -o rw,noatime,compress=zstd:3,subvol=home \
    /dev/disk/by-partlabel/data /sysroot/home \
    || rescue "home mount failed"

# ESP is degraded, not fatal.
step esp "$timeout_esp" mount -t vfat -o rw,noatime /dev/disk/by-partlabel/esp /sysroot/boot \
    || echo "keel: ESP mount failed; updates and boot counting unavailable"

exec switch_root /sysroot /sbin/init
```

要求：

- `set -eu`；关键挂载失败调用 `rescue`；每个步骤都有超时，不靠默认值。
- `/sysroot`、`/recovery` 必须是挂载点；`switch_root` 前 `/sysroot` 必须真的挂着东西。
- `vgchange` 后跑 `vgmknodes`，确保 `/dev/system/root_a`、`/dev/system/etc` 存在。
- P0 可以先写死 `root_a`；从 cmdline 的 `root=` 读槽位是加分项，不是 v0.1 必须。
- 不要用 `rd.*`；那是 dracut 约定。
- `keel.fail=<step>` 只影响该步骤，注入时必须打印一行
  `keel: injecting failure at <step>`，并在 `/run/keel/` 留标记，避免和真故障混淆。
- `keel.timeout=<name>:<seconds>` 只调整对应步骤的等待时间，不影响 recovery 里的操作。
- busybox 必须带 `timeout` applet；没有的话改用 `-t` 轮询，不能裸跑 `mount`。

## 4. P1：systemd units

> **本节是草案，不是 v0.1 承诺。** P1 是否做，见 [Q-0011](open/Q-0011-initrd-p1.md)；
> 如果做，失败触发方式见 [Q-0009](open/Q-0009-recovery-fallback.md)。

| unit | 作用 | 关键排序 |
|---|---|---|
| `lvm-activate.service` | `vgchange -ay system` | `Before=sysroot.mount sysroot-etc.mount` |
| `sysroot.mount` | 挂 root LV | `What=/dev/system/root_a`；`After=lvm-activate.service` |
| `sysroot-etc.mount` | 挂 `/etc` | `What=/dev/system/etc`；`After=sysroot.mount` |
| `sysroot-var.mount` | 挂 data `subvol=var` | `What=/dev/disk/by-partlabel/data`；`After=sysroot.mount` |
| `sysroot-home.mount` | 挂 data `subvol=home` | 同上 |
| `sysroot-boot.mount` | 挂 ESP | `What=/dev/disk/by-partlabel/esp`；`After=sysroot.mount` |
| `keel-recovery.service` | 失败时挂 recovery 并切根 | 各关键 mount 的 `OnFailure=` |
| `initrd.target` | initrd 终点 | `Wants=` 上述 mounts |
| `systemd-switch-root.service` | 切根 | `After=initrd.target` |

顺序：

```text
lvm-activate.service
  -> sysroot.mount
  -> sysroot-etc.mount
  -> sysroot-var.mount / sysroot-home.mount
  -> sysroot-boot.mount
  -> initrd.target
  -> systemd-switch-root.service
```

注意：

- `lvm-activate.service` 必须排在 `sysroot.mount` **之前**；root 现在依赖 LVM。
- `sysroot-etc.mount` 依赖 `sysroot.mount`；`/etc` 是 root 下的挂载点。
- `sysroot-var.mount`/`home` 依赖 `sysroot.mount`，不依赖 `/etc`。
- `keel-recovery.service` 由关键 unit 的 `OnFailure=` 触发；它挂 `PARTLABEL=recovery` 并 `switch_root`。
- `keel.recovery=1` 用 `ConditionKernelCommandLine=` 或最早的 oneshot 处理。
- initrd 的 `/etc/lvm/lvm.conf` 是 initrd 自己的，不依赖 root 的 `/etc`。
- 不要依赖 `rd.lvm.lv=`；自己写 unit/脚本。

## 5. 失败处理

| 失败点 | 默认超时 | 行为 |
|---|---|---|
| `vgchange` 失败或超时 | 30 s | recovery |
| root LV 挂不上或超时 | 15 s | recovery |
| `/etc` 挂不上或超时 | 15 s | recovery |
| data / `var` / `home` 挂不上或超时 | 15 s | recovery |
| ESP 挂不上或超时 | 10 s | 继续 + 警告；更新与 boot counting 不可用 |
| recovery 也挂不上 | — | shell / USB |
| `keel.recovery=1` | — | 直接 recovery |

原则：**关键挂载失败就停**。不要退回只读 root 的 `/etc` 继续启动。

### 5.1 超时是契约的一部分

"挂死"和"失败"在 headless 机器上的代价不同：失败可以自动处理，挂死只能靠人断电。
所以每个等待步骤都必须有超时，且超时按失败处理。

- 默认值见上表；真机慢盘用 `keel.timeout=<name>:<seconds>` 覆盖，不改代码。
- 覆盖只影响 initrd，不影响 recovery 里的操作。
- 超时后必须打印是哪一步、等了多久，便于事后判断是盘慢还是真坏。

### 5.2 启动成功标记（`/var`，不是 ESP）

`systemd-bless-boot` 要写 ESP 才能把条目标成 good。ESP 坏掉时，
一次完全成功的启动也会被 boot counting 记成失败。见
[ADR-0015](decisions/ADR-0015-boot-failure-contract.md)。

因此：

- `keel-boot-ok.service` 在启动成功后写 `/var/lib/keel/boot-ok`（槽名、boot id、时间）。
- `keel-boot-repair.service` 在早期检查：标记健康 + ESP 可写 + 条目名已坏，则用
  `bootctl` 把 `keel-<slot>` 恢复到 `+10`。
- 这一段**不在 initrd 里**，是正常运行时的 systemd 服务。

ESP 挂不上时 initrd 仍然继续启动，因为 ESP 故障不应该把一个还能跑的机器降级成救援模式。

## 6. recovery

- `recovery` 分区 1 GiB，erofs ro，BusyBox init + shell。
- ESP 上有独立 recovery UKI，cmdline：

```text
root=PARTLABEL=recovery ro rootfstype=erofs
keel.recovery=1
```

- 正常 initrd 在 LVM/root/etc/data 失败时自动 fallback。
- recovery 工具：`lvm2`、`e2fsprogs`、`btrfs-progs`、`erofs-utils`、`bootctl`、`sgdisk`、`mount`、`blkid`、`dmesg`。
- recovery 是 known-good，不随 A/B 更新自动更新；ESP recovery UKI + USB 仍保留。
- 详见 [F-012](features/F-012-rescue.md) / [ADR-0014](decisions/ADR-0014-recovery-partition.md)。

## 7. initrd 内容

### 7.1 模块

- 存储：`erofs`、`ext4`、`btrfs`、`vfat`、`dm-mod`、`nvme`、`ahci`、`virtio_blk`。
- 输入/救援：`usbhid`、`usb-storage`、`xhci-hcd`。
- 串口：`8250`。
- 看门狗（P2）：硬件看门狗或 `softdog`。

### 7.2 工具

- `busybox` 或 systemd + udev。
- busybox 必须带 `timeout` applet（超时是契约，不是可选优化）。
- `lvm2`、`e2fsprogs`、`btrfs-progs`、`erofs-utils`。
- `mount`、`blkid`、`dmesg`。
- `/etc/lvm/lvm.conf`（最小配置）。

## 8. LVM 路径

- 标准路径：`/dev/system/root_a`、`/dev/system/etc`。
- `/dev/mapper/system-root_a` 是底层 dm 节点；不作为默认路径。
- P0 没有 udev 时：`vgchange --noudevsync -ay system` + `vgmknodes`。
- P1 有 systemd-udevd；仍然建议保留 `vgmknodes` 作为兜底。
- LV 名用下划线，避免 `/dev/mapper` 的 `--` 转义。

## 9. fstab 策略

- initrd 挂载 `/`、`/etc`、`/var`、`/home`、`/boot`；`/etc/fstab` 不重复写。
- fstab 只放注释，或以后追加非关键/自动挂载项；`passno=0`。
- 需要这些挂载的服务用 `RequiresMountsFor=`。
- 验收看 `findmnt`，不只看 `systemctl list-units --type=mount`。

## 10. 测试清单

1. `findmnt -R /` 显示 `/` erofs ro，`/etc` ext4，`/var`/`/home` btrfs，`/boot` vfat。
2. `lvs` 显示 `root_a`、`root_b`、`etc` active。
3. `cat /etc/machine-id` 非空；重启两次不变。
4. `systemctl --failed` 为空。
5. `bootctl list` 能看到 A/B/recovery。
6. 连续 5 次重启，无 emergency。
7. `keel.recovery=1` 能进 recovery；`/etc` 没有被挂载覆盖。
8. 破坏 VG 元数据/root/etc/data，能自动进 recovery。
9. `keel.fail=vglv|root|etc|data` 分别进 recovery，且串口有
   `keel: injecting failure at <step>`。
10. `keel.fail=esp` 仍能启动到 multi-user，`/boot` 未挂，警告可见。
11. `keel.timeout=root:60` 生效：故意让 root 设备慢出现，确认不会提前放弃。
12. ESP 挂不上时仍写 `/var/lib/keel/boot-ok`；恢复 ESP 后 `keel-boot-repair`
    把条目名还原成 `+10`。

## 11. 待定

- P1 是否值得做：见 [Q-0011](open/Q-0011-initrd-p1.md)。
- 若做 P1，`keel-recovery.service` 的 unit 写法：见 [Q-0009](open/Q-0009-recovery-fallback.md)。
- 镜像怎么造、测试装置怎么起：见 [Q-0010](open/Q-0010-image-build-harness.md)。
- recovery 更新策略：见 [F-012](features/F-012-rescue.md)。
