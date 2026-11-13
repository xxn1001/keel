---
id: F-011
title: Installer
status: accepted
target: v0.3
owner: TBD
updated: 2026-11-13
depends: [F-001, F-002, F-004, F-015, F-005]
---

# F-011 安装器

## 1. Why

把空盘变成可启动的 keel2：GPT、LVM、erofs root LV、ext4 `/etc`、btrfs data、recovery、ESP、`bootctl install`。
安装器只做一次；不要长成第二个 `os-install`。

## 2. Scope

包含：

- GPT：`esp`、`recovery`、`system`、`data`。
- LVM：`system` VG + `root_a`、`root_b`、`etc`。
- `mkfs.erofs` root_a/root_b/recovery；`mkfs.ext4` etc；`mkfs.btrfs` data + `var`/`home` 子卷。
- 复制 rootfs；播种 `/etc`；清 machine-id/ssh key。
- `bootctl install` + NVRAM。
- 首启生成 machine-id/ssh host key。

不包含：

- 在线升级/迁移。
- 双系统/分区缩小。
- 图形安装器。

## 3. User-visible behavior

- `install.sh /dev/sdX`（或从 live USB）完成后，目标盘能启动。
- 首启进入登录；`/etc`、`/var`、`/home` 持久。
- `bootctl list` 有 A/B/recovery。
- 目标盘不是当前系统盘；已挂载/非块设备/容量不足时拒绝。

## 4. Interfaces

| 接口 | 说明 |
|---|---|
| `installer/install.sh` | 入口；可编译或 shell 胶水 |
| `--disk /dev/sdX` | 目标盘 |
| `--payload <dir>` | rootfs/UKI |
| `--yes` | 跳过确认 |
| `efibootmgr`/`bootctl` | NVRAM |

## 5. Design

1. 拒绝：目标 == 当前根盘、已挂载、非块设备、容量不足。
2. `sgdisk --zap-all`；建 p1 ESP 1G、p2 recovery 1G、p3 system 6G、p4 data 剩余；设置 label/type。
3. `mkfs.vfat` ESP；`mkfs.erofs` recovery；`pvcreate`；`vgcreate system`；`lvcreate root_a/root_b/etc`；`mkfs.erofs` root；`mkfs.ext4` etc。
4. `mkfs.btrfs` data；`btrfs subvolume create var`、`home`。
5. 挂 root_a、etc、var、home、ESP；`cp -a` rootfs；播种 `/etc`；写 fstab 注释模板；建 `/home/root`、`/var/log/journal`、`/var/lib/containers`（P4）。
6. `bootctl --esp-path=/boot install`；复制 UKI A/B/recovery；`loader.conf` default A。
7. 写 NVRAM 指向目标 ESP；确认不是 USB。
8. 首启生成 machine-id/ssh host key。

约束：

- **不要**把带 LVM 的镜像直接 `dd` 到多块盘：VG/PV UUID 冲突。安装时现建。
- 安装脚本只做一次；不要把更新逻辑塞进来。
- 所有 `mkfs`/`lvcreate`/`btrfs subvolume` 失败都要停下，不继续。
- `/etc/fstab` 只放注释，不写核心挂载。

## 6. Failure modes / recovery

| 失败 | 处理 |
|---|---|
| 选错盘 | 拒绝当前根盘；二次确认 |
| LVM 创建失败 | 停止；清 GPT 重来 |
| btrfs 子卷失败 | 停止；清 data 重来 |
| ESP 安装失败 | 检查 vfat/`systemd-bootx64.efi` |
| NVRAM 没写 | `efibootmgr` 手动加；rescue |
| 首启没生成 machine-id | 检查 `/etc` 挂载/权限 |

## 7. Acceptance criteria

- [ ] 空盘安装 → 首启 → 登录。
- [ ] `findmnt -R /` 正确：erofs/ext4/btrfs/vfat。
- [ ] `lvs` 三个 LV active。
- [ ] `bootctl list` 有 A/B/recovery。
- [ ] `efibootmgr -v` 指向目标 ESP。
- [ ] `/etc/machine-id` 非空且唯一。
- [ ] `/etc/fstab` 没有核心挂载 entry。
- [ ] 重启 5 次，无 emergency。

## 8. Open questions / ADR links

- system VG：[ADR-0012](../decisions/ADR-0012-system-vg.md)。
- data：[ADR-0013](../decisions/ADR-0013-data-partition.md)。
- recovery：[ADR-0014](../decisions/ADR-0014-recovery-partition.md)。
- 精确尺寸：[Q-0002](../open/Q-0002-disk-sizes.md)。

## 9. Test plan

E2：空盘（qcow2）安装 → 首启 → 重启；E3：目标服务器（保留救援 U 盘）。

## 10. Changelog

| 日期 | 变更 |
|---|---|
| 2026-11-10 | 初稿 |
| 2026-11-13 | 新 GPT/LVM/btrfs/recovery；fstab 注释 |
