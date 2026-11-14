---
id: F-012
title: Rescue and recovery
status: accepted
target: v0.1/v0.3
owner: TBD
updated: 2026-11-14
depends: [F-002, F-004, F-015]
---

# F-012 救援与恢复

## 1. Why

root 和 `/etc` 在 system VG 上；LVM 失败时正常系统起不来。
v1 不做签名/verity；救援是唯一安全网。没有演练过的救援路径等于没有救援。

## 2. Scope

包含：

- 物理 `recovery` 分区（1G erofs ro），自包含救援 rootfs。
- ESP 上的 recovery UKI。
- 正常 initrd 在 LVM/root/etc/data 失败时自动 fallback。
- `keel.recovery=1` 强制进入 recovery。
- USB rescue rootfs。
- LVM 元数据、ESP、`/etc`、data 的备份/恢复。
- 救援演练：坏 `/etc`、坏 UKI、坏 VG 元数据、清空 ESP、LVM 失败、data 失败。

不包含：

- 自动远程救援。
- 加密恢复。
- recovery 自动随 A/B 更新。

## 3. User-visible behavior

- LVM/root/etc/data 失败时，系统自动进 recovery，而不是停 emergency。
- 启动菜单能选 recovery UKI。
- recovery shell 能挂 system VG、`/etc`、data 并修复。
- USB 能启动到独立救援环境。

## 4. Interfaces

| 接口 | 说明 |
|---|---|
| `keel.recovery=1` | 强制 recovery |
| `/dev/disk/by-partlabel/recovery` | 物理救援 rootfs |
| `EFI/Linux/keel-recovery.efi` | ESP 上的 recovery UKI |
| `vgcfgbackup -f /boot/lvm/...` | 元数据备份 |
| `vgcfgrestore -f ... system` | 恢复 |
| `bootctl install` | 重建 ESP 引导 |

## 5. Design

### 5.1 recovery 分区

- 1 GiB，erofs ro，BusyBox init + shell；`/run`/`/tmp` tmpfs。
- 不依赖 system VG，也不依赖 data。
- 工具：`lvm2`、`e2fsprogs`、`btrfs-progs`、`erofs-utils`、`bootctl`、`sgdisk`、`mount`、`blkid`、`dmesg`。
- 可手动挂 system root、`/etc`、data：

```sh
vgchange -ay system
mount /dev/system/root_a /mnt/root
mount /dev/system/etc /mnt/etc
mount -t btrfs -o subvol=var /dev/disk/by-partlabel/data /mnt/var
```

### 5.2 recovery UKI 与 fallback

- ESP 上的 recovery UKI：`root=PARTLABEL=recovery ro rootfstype=erofs`，`keel.recovery=1`。
- 正常 initrd 在 `vgchange`/root/etc/data 失败时挂 recovery 并 `switch_root`。
- `keel.recovery=1` 直接进 recovery。
- P1 unit 实现见 [Q-0009](../open/Q-0009-recovery-fallback.md)。

### 5.3 known-good

- recovery 不随 A/B 更新自动更新；否则新内核/新 initrd 一起坏，recovery 也救不了。
- recovery 更新必须单独、显式、在 QEMU/真机验证后写。
- ESP recovery UKI + USB 仍保留；recovery 不防磁盘/ESP 物理损坏。

### 5.4 备份

- LVM 元数据：每次改布局 `vgcfgbackup -f /boot/lvm/system-<date>.vg`；复制到 USB。
- ESP：`tar -C /boot -cf /var/backups/esp-<date>.tar .`；复制到 USB。
- `/etc`：`tar -C / -cf /var/backups/etc-<date>.tar etc`。
- data：`btrfs send` 到 USB；本地快照不算备份。

## 6. Failure modes / recovery

| 场景 | 恢复 |
|---|---|
| LVM 元数据坏 | recovery；`vgcfgrestore` 从 ESP/USB |
| root 坏 | 切槽；recovery |
| `/etc` 内容坏 | recovery；从 factory/备份恢复 |
| data 坏 | recovery；`btrfs check`/备份 |
| UKI 写坏 | ESP 备份；`bootctl install` |
| ESP 清空 | USB `bootctl install` + 复制 UKI |
| 两个槽都坏 | USB rescue + 重装 |

## 7. Acceptance criteria

- [ ] LVM 失败自动进 recovery。
- [ ] recovery UKI 能启动并掉 shell。
- [ ] USB rescue 能启动并挂目标盘。
- [ ] 坏 `/etc` 能恢复。
- [ ] 坏 UKI 能恢复。
- [ ] 坏 VG 元数据能 `vgcfgrestore`。
- [ ] 清空 ESP 能重建。
- [ ] data 失败能进 recovery 并挂 system root。

## 8. Open questions / ADR links

- recovery 决策：[ADR-0014](../decisions/ADR-0014-recovery-partition.md)。
- 救援介质：[ADR-0011](../decisions/ADR-0011-rescue-media.md)。
- USB 内容：[Q-0004](../open/Q-0004-rescue-usb.md)。
- fallback unit：[Q-0009](../open/Q-0009-recovery-fallback.md)。

## 9. Test plan

E2：LVM/root/etc/data 失败自动 recovery；救援演练；`vgcfgrestore`；ESP 重建。
E3：真机至少做一次“清空 ESP + 恢复”和“破坏 VG 元数据 + recovery”。

## 10. Changelog

| 日期 | 变更 |
|---|---|
| 2026-11-10 | 初稿（ESP rescue + USB） |
| 2026-11-13 | 增加物理 recovery 分区、recovery UKI、initrd fallback |
| 2026-11-14 | 术语统一：`rescue UKI` 改为 `recovery UKI` |
