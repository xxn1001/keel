# initrd

> 状态：accepted | 更新：2026-11-13
> 目标：在 `switch_root` 之前挂好 root、`/etc`、`/var`、`/home`、`/boot`。
> 任何关键挂载失败：进 physical recovery，不继续半启动。

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

| 阶段 | 形态 | 目的 |
|---|---|---|
| P0 | 一个最小脚本 | 先把 LVM/root/etc/data 的挂载顺序跑通 |
| P1 | systemd units | 把同样的顺序翻译成 units；最终形态 |

P0 脚本是临时的，不允许长成第二个 shell 状态机。P1 完成后删除 P0 脚本。

## 3. P0：最小脚本

```sh
#!/bin/sh
set -eu

mount -t devtmpfs devtmpfs /dev
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mkdir -p /sysroot /recovery

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

if ! /sbin/vgchange --noudevsync -ay system; then
    rescue "vgchange failed"
fi
/sbin/vgmknodes

mount -t erofs -o ro /dev/system/root_a /sysroot || rescue "root mount failed"
mount -t ext4 -o rw,noatime /dev/system/etc /sysroot/etc || rescue "etc mount failed"
mount -t btrfs -o rw,noatime,compress=zstd:3,subvol=var \
    /dev/disk/by-partlabel/data /sysroot/var || rescue "var mount failed"
mount -t btrfs -o rw,noatime,compress=zstd:3,subvol=home \
    /dev/disk/by-partlabel/data /sysroot/home || rescue "home mount failed"

mount -t vfat -o rw,noatime /dev/disk/by-partlabel/esp /sysroot/boot \
    || echo "keel: ESP mount failed; updates unavailable"

exec switch_root /sysroot /sbin/init
```

要求：

- `set -eu`；关键挂载失败调用 `rescue`。
- `/sysroot`、`/recovery` 必须是挂载点。
- `vgchange` 后跑 `vgmknodes`，确保 `/dev/system/root_a`、`/dev/system/etc` 存在。
- P0 可以先写死 `root_a`；P1 从 cmdline 的 `root=` 读取槽。
- 不要用 `rd.*`；那是 dracut 约定。

## 4. P1：systemd units

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

| 失败点 | 行为 |
|---|---|
| `vgchange` 失败 | recovery |
| root LV 挂不上 | recovery |
| `/etc` 挂不上 | recovery |
| data/`var`/`home` 挂不上 | recovery |
| ESP 挂不上 | 继续 + 警告；更新不可用 |
| recovery 也挂不上 | shell / USB |
| `keel.recovery=1` | 直接 recovery |

原则：**关键挂载失败就停**。不要退回只读 root 的 `/etc` 继续启动。

## 6. recovery

- `recovery` 分区 1 GiB，erofs ro，BusyBox init + shell。
- ESP 上有独立 recovery UKI，cmdline：

```text
root=PARTLABEL=recovery ro rootfstype=erofs
keel.recovery=1
```

- 正常 initrd 在 LVM/root/etc/data 失败时自动 fallback。
- recovery 工具：`lvm2`、`e2fsprogs`、`btrfs-progs`、`erofs-utils`、`bootctl`、`sgdisk`、`mount`、`blkid`、`dmesg`。
- recovery 是 known-good，不随 A/B 更新自动更新；ESP rescue UKI + USB 仍保留。
- 详见 [F-012](features/F-012-rescue.md) / [ADR-0014](decisions/ADR-0014-recovery-partition.md)。

## 7. initrd 内容

### 7.1 模块

- 存储：`erofs`、`ext4`、`btrfs`、`vfat`、`dm-mod`、`nvme`、`ahci`、`virtio_blk`。
- 输入/救援：`usbhid`、`usb-storage`、`xhci-hcd`。
- 串口：`8250`。
- 看门狗（P2）：硬件看门狗或 `softdog`。

### 7.2 工具

- `busybox` 或 systemd + udev。
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

## 11. 待定

- P1 `keel-recovery.service` 的具体 unit 写法：见 [Q-0009](open/Q-0009-recovery-fallback.md)。
- recovery 更新策略：见 [F-012](features/F-012-rescue.md)。
