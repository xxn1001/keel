# 磁盘布局

> 状态：accepted | 更新：2026-11-14
> 本文只放 GPT / LVM / 文件系统 / 挂载的表和理由。安装命令见 F-011。

## 1. 设计原则

1. **root 在 system VG**：`root_a`/`root_b` 是 LVM LV，erofs，A/B。
2. **`/etc` 单独 ext4 LV**：小、简单、和 `/var` 的剩余空间隔离。
3. **`/var`/`/home` 在独立 data 分区**：共享空间是有意为之；btrfs 子卷。
4. **recovery 是物理分区**：LVM/root/etc/data 失败时还能启动救援。
5. **root 只读**：erofs；更新是整块替换非活动 LV。
6. **尺寸可参数化**：root LV 可重建；`/etc` 可扩；data 可扩。

## 2. GPT

| # | 名称 | 默认大小 | GPT 类型 | 文件系统 | 挂载 | 说明 |
|---|---|---|---|---|---|---|
| 1 | `esp` | 1 GiB | EFI System (`ef00`) | vfat | `/boot` | systemd-boot + UKI A/B + recovery UKI |
| 2 | `recovery` | 1 GiB | Linux filesystem (`8300`) | erofs | — | 独立救援 rootfs，ro |
| 3 | `system` | 6 GiB | Linux LVM (`8e00`) | LVM PV | — | `vg system` |
| 4 | `data` | 剩余 | Linux filesystem (`8300`) | btrfs | `/var` `/home` | 共享 data |

标签固定：`esp`、`recovery`、`system`、`data`。
`root=` 用 LVM 标准路径，不用 `PARTLABEL`；data 用 `PARTLABEL=data`。

## 3. system VG

| LV | 默认大小 | 文件系统 | 挂载 | 说明 |
|---|---|---|---|---|
| `system/root_a` | 2 GiB | erofs | `/` (ro) | A 槽 |
| `system/root_b` | 2 GiB | erofs | — | B 槽 |
| `system/etc` | 1 GiB | ext4 | `/etc` | 播种一次；机器配置持久 |

规则：

- 全部 **thick LV**，不用 thin。
- VG 约 6 GiB：root 4 GiB + etc 1 GiB + 约 1 GiB 空闲（16%）。
- LV 名用下划线：`root_a`、`root_b`、`etc`。不要用 `root-a`，LVM 在 `/dev/mapper` 里会把 `-` 转义成 `--`。
- `/etc` 可在线 `lvextend` + `resize2fs`；root erofs 不能 resize，扩容=重建 LV 镜像。
- swap 用 zram，不建 swap LV。

## 4. data 分区

| 子卷 | 挂载 | 说明 |
|---|---|---|
| `var` | `/var` | journald、podman 存储 |
| `home` | `/home` | 用户数据 |

- data 分区使用剩余空间；btrfs 是 v1 基线；zfs 见 [Q-0008](open/Q-0008-data-fs.md)。
- `/etc` **不**在 data；它在 `system/etc`。
- `/var` 和 `/home` 共享 data 的空闲空间；这是明确取舍。
- 缓解措施：journald `SystemMaxUse`、podman prune、80% 告警、`btrfs scrub`、`btrfs send` 到 USB。
- 不默认启用 qgroup；如果以后要硬限制 `/var`，再评估 qgroup/squota 或 zfs dataset quota。

## 5. 挂载表

| 目标 | 源 | 类型 | 选项 | 谁挂 |
|---|---|---|---|---|
| `/` | `/dev/system/root_a` 或 `root_b` | erofs | `ro` | kernel / initrd |
| `/etc` | `/dev/system/etc` | ext4 | `rw,noatime` | initrd |
| `/var` | `/dev/disk/by-partlabel/data` | btrfs | `rw,noatime,compress=zstd:3,subvol=var` | initrd |
| `/home` | `/dev/disk/by-partlabel/data` | btrfs | `rw,noatime,compress=zstd:3,subvol=home` | initrd |
| `/boot` | `/dev/disk/by-partlabel/esp` | vfat | `rw,noatime` | initrd |
| `/tmp` | tmpfs | tmpfs | `mode=1777` | systemd |
| `/run` | tmpfs | tmpfs | `mode=0755` | systemd |

`/root` 不单独挂载：把 `/etc/passwd` 里 root 的 home 改成 `/home/root`，并在 `home` 子卷里预建 `root/`（0700）。

### 5.1 LVM 路径

- LVM 标准路径是 `/dev/<VG>/<LV>`：`/dev/system/root_a`、`/dev/system/etc`。
- `/dev/mapper/system-root_a` 是底层 device-mapper 节点；文档和 cmdline 用标准路径。
- initrd 在 `vgchange -ay system` 后要确保 `/dev/system/*` 存在：P1 由 udev 创建；P0 用 `vgmknodes`。
- 不要用 `/dev/mapper` 作为默认路径；只在调试/udev 缺失时作为后备。

## 6. 启动链

```text
UEFI
  -> ESP: systemd-boot
  -> UKI keel-a.efi / keel-b.efi
       root=/dev/system/root_a ro rootfstype=erofs
       systemd.gpt_auto=no panic=-1
       console=tty0 console=ttyS0,115200
  -> initrd:
       vgchange -ay system
       mount /dev/system/root_a /sysroot      (erofs, ro)
       mount /dev/system/etc   /sysroot/etc   (ext4, rw)
       mount data subvol=var   /sysroot/var   (btrfs, rw)
       mount data subvol=home  /sysroot/home  (btrfs, rw)
       mount ESP               /sysroot/boot  (vfat, rw)
       switch_root
  -> systemd (multi-user.target, sshd, serial getty)
```

失败处理：

- `vgchange`、root、etc、data 任一失败：挂 `recovery` 并 `switch_root`。
- ESP 挂不上：继续启动 + 警告；更新不可用。
- `keel.recovery=1`：直接进 recovery。

## 7. 为什么这样分

### 7.1 root 在 system VG

- 去掉物理 root-a/root-b，A/B 在 VG 内重建更容易。
- root 选择由 `/dev/system/root_a|b` 决定；UKI 每个槽一个。
- 代价：正常启动依赖 LVM；必须有 recovery。

### 7.2 `/etc` 在 system VG，独立 ext4

- `/etc` 是关键配置；不能和 `/var` 共享剩余空间。
- ext4 简单、可 fsck、可在线扩、可 tar/快照。
- `/etc` 不跟 root 槽走；换槽不丢 machine-id/ssh key/networkd。
- 新镜像的 `/etc` 默认值不自动生效；保留 `/usr/share/factory/etc` 做 diff。

### 7.3 `/var`/`/home` 在 data

- data 独立于 system VG；system VG 坏了还能从 recovery 挂 data。
- 共享空间是有意为之；子卷/快照/压缩/send 可用。
- 代价：`/var` 可以吃满 data，`/home` 受影响；data 文件系统坏了两个一起坏。

### 7.4 recovery

- LVM/root/etc/data 失败时，正常系统起不来；recovery 是物理分区，不依赖 LVM/data。
- recovery 是 known-good，不自动随 A/B 更新；ESP recovery UKI + USB 仍然保留。

## 8. 尺寸

| 目标盘 | ESP | recovery | system | data |
|---|---|---|---|---|
| 100 GiB | 1 GiB | 1 GiB | 6 GiB | ~92 GiB |
| 32 GiB | 1 GiB | 1 GiB | 6 GiB | ~24 GiB |

- root 2 GiB ×2；erofs 内容通常 300–600 MiB，留余量。
- `/etc` 1 GiB；实际通常 <100 MiB；可扩。
- system VG 约 1 GiB 空闲；data 是剩余空间。
- 实际按目标盘参数化；这是默认值。

## 9. `/etc/fstab`

`/etc/fstab` 是 `/etc` LV 里的普通文件。它**不能**用来挂 `/etc` 自己：要读 fstab 必须先挂 `/etc`，要挂 `/etc` 只能靠 initrd。

策略：

- `/`、`/etc`、`/var`、`/home`、`/boot` 都由 initrd 挂载；fstab **不重复写**。
- fstab 只放注释，或以后追加非关键/自动挂载项。
- 所有条目 `passno=0`。
- 需要这些挂载的服务用 `RequiresMountsFor=`。
- 验收看 `findmnt`，不只看 `systemctl list-units --type=mount`。

建议内容：

```text
# keel2: critical mounts are owned by initrd.
# Do not add /, /etc, /var, /home, or /boot here.
# See docs/initrd.md and docs/layout.md.
```

recovery 有自己的 `/etc/fstab`；要修 system 的 `/etc`，在 recovery 里手动：

```sh
mount /dev/system/etc /mnt/etc
```

## 10. 参考命令（仅示意，实际在 F-011）

```sh
sgdisk --zap-all /dev/sdX
sgdisk -n 1:0:+1G   -t 1:ef00 -c 1:esp      /dev/sdX
sgdisk -n 2:0:+1G   -t 2:8300 -c 2:recovery /dev/sdX
sgdisk -n 3:0:+6G   -t 3:8e00 -c 3:system   /dev/sdX
sgdisk -n 4:0:0     -t 4:8300 -c 4:data     /dev/sdX

mkfs.vfat -F32 /dev/disk/by-partlabel/esp
mkfs.erofs /dev/disk/by-partlabel/recovery recovery-rootfs/

pvcreate /dev/disk/by-partlabel/system
vgcreate system /dev/disk/by-partlabel/system
lvcreate -n root_a -L 2G system
lvcreate -n root_b -L 2G system
lvcreate -n etc    -L 1G system

mkfs.erofs /dev/system/root_a rootfs/
mkfs.erofs /dev/system/root_b rootfs/
mkfs.ext4 /dev/system/etc

mkfs.btrfs -L data /dev/disk/by-partlabel/data
mount /dev/disk/by-partlabel/data /mnt
btrfs subvolume create /mnt/var
btrfs subvolume create /mnt/home
umount /mnt
```

> 这些命令会在 F-011 里变成安装器；不要直接复制到生产盘。

## 11. 失败矩阵

| 故障 | 正常启动 | 恢复 |
|---|---|---|
| system VG 元数据坏 | `vgchange` 失败 | recovery；`vgcfgrestore` |
| root_a 坏 | 切 root_b | recovery / 旧槽 |
| `etc` LV 坏/满 | 起不来或 `/etc` 写失败 | recovery；e2fsck/备份 |
| data 挂不上 | `/var`/`/home` 失败 | recovery；btrfs check |
| `/var` 写满 | `/etc` 不受影响；`/home` 受影响 | 清理/扩容；告警 |
| ESP 坏 | 无 UKI | USB |
| 磁盘坏 | 全没 | USB/离线备份 |

## 12. 待定

- data 文件系统最终选择：见 [Q-0008](open/Q-0008-data-fs.md)。
- 精确尺寸/目标盘：见 [Q-0002](open/Q-0002-disk-sizes.md)。
- recovery 更新策略：见 [F-012](features/F-012-rescue.md)。
