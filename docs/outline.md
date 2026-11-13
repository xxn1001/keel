# keel2 Outline

> 状态：draft v0.2 | 维护者：待定 | 更新：2026-11-13
> 这是地图，不是设计文档。细节在链接里。

## 1. 这是什么

keel2 是一个**自己构建的最小 Linux 系统**，目标形态是 **headless 服务器**：

- 只读 **erofs** 基底，A/B 两个 LVM LV。
- 可写状态：`/etc` 是 system VG 的独立 ext4 LV；`/var`/`/home` 在独立 data 分区（btrfs）。
- 物理 **recovery** 分区，LVM/root/etc/data 失败时自动进救援。
- **systemd** 是唯一 init；initrd 最终也用 systemd。
- **Buildroot LTS** 构建；没有 mkosi、nix、发行版包管理器。
- 更新器是**编译型** `keel-update`，不是 shell 状态机。
- 用户态软件后续用 podman；VFIO 是未来特征。

设计原则：**可解释、可重建、可救援**。先让系统能稳定启动和回滚，再加功能。

## 2. 特征（Feat）

| ID | 特征 | 状态 | 目标 | 依赖 | 文档 |
|---|---|---|---|---|---|
| F-001 | 最小可启动基底（Buildroot + systemd + serial） | accepted | v0.1 | — | [F-001](features/F-001-minimal-base.md) |
| F-002 | erofs root LV + A/B | accepted | v0.1 | F-001, F-005 | [F-002](features/F-002-erofs-root.md) |
| F-003 | 原子更新 + 自动回滚 | accepted | v0.2/v0.3 | F-002, F-005 | [F-003](features/F-003-ab-update.md) |
| F-004 | system VG：root + `/etc` | accepted | v0.1 | F-001 | [F-004](features/F-004-lvm-state.md) |
| F-005 | systemd initrd | accepted | v0.1/v0.2 | F-001, F-004, F-015 | [F-005](features/F-005-systemd-initrd.md) |
| F-006 | headless server（有线/串口/SSH） | accepted | v0.1 | F-001 | [F-006](features/F-006-headless-server.md) |
| F-007 | zram swap | accepted | v0.3 | F-001 | [F-007](features/F-007-zram.md) |
| F-008 | podman 用户态 | accepted | v0.4 | F-015 | [F-008](features/F-008-podman.md) |
| F-009 | VFIO / 设备直通 | idea | future | F-006 | [F-009](features/F-009-vfio.md) |
| F-010 | Secure Boot + dm-verity | deferred | future | F-002, F-005 | [F-010](features/F-010-secureboot-verity.md) |
| F-011 | 安装器（空盘 GPT/LVM/btrfs/recovery） | accepted | v0.3 | F-001/002/004/015 | [F-011](features/F-011-installer.md) |
| F-012 | 救援与恢复 | accepted | v0.1/v0.3 | F-002/004/015 | [F-012](features/F-012-rescue.md) |
| F-013 | 状态与可观测性 | proposed | v0.4 | F-003 | [F-013](features/F-013-status.md) |
| F-014 | 备份与快照 | proposed | v0.4 | F-004/015 | [F-014](features/F-014-backup.md) |
| F-015 | data 分区：`/var` `/home` | accepted | v0.1 | F-001 | [F-015](features/F-015-data-partition.md) |

状态图例见 [`README.md`](README.md)。特征 ID 一旦分配，不重排、不复用。

## 3. 磁盘布局

| # | 分区 | 角色 | 文件系统 |
|---|---|---|---|
| 1 | `esp` | 引导：systemd-boot + UKI + recovery UKI | vfat |
| 2 | `recovery` | 物理救援 rootfs | erofs |
| 3 | `system` | LVM PV；`system/root_a`、`root_b`、`etc` | LVM + erofs/ext4 |
| 4 | `data` | `/var`、`/home` 子卷 | btrfs |

启动链：

```text
UEFI
  -> ESP: systemd-boot
  -> UKI keel-a.efi / keel-b.efi
       kernel + initrd + cmdline + microcode
  -> initrd: vgchange -> root -> /etc -> /var -> /home -> /boot
  -> switch_root
  -> systemd: multi-user.target + sshd + serial getty
```

精确大小、GPT 类型、挂载选项见 [`layout.md`](layout.md)。
initrd 的挂载顺序和 units 见 [`initrd.md`](initrd.md)。

## 4. initrd

两个阶段：

| 阶段 | 形态 | 目标 |
|---|---|---|
| P0 | 一个最小脚本 | 先把 LVM/root/etc/data 的挂载顺序跑通 |
| P1 | systemd units | 同样的顺序翻译成 units；systemd 是最终形态 |

固定顺序：

```text
vgchange -ay system
  -> mount /dev/system/root_a (erofs, ro)
  -> mount /dev/system/etc (ext4, rw)
  -> mount data subvol=var / subvol=home (btrfs, rw)
  -> mount ESP at /boot
  -> switch_root
```

任何关键挂载失败：挂 `recovery` 并 `switch_root`，**不**退回半启动。
`keel.recovery=1` 强制直接进 recovery。

## 5. 版本规划

| 版本 | 主题 | 包含特征 | Gate |
|---|---|---|---|
| v0.1 | walking skeleton | F-001, F-002, F-004, F-015, F-005(P0), F-006, F-012(basic) | QEMU 登录；root/etc/data 挂载正确；LVM 失败能进 recovery；连续 5 次重启 |
| v0.2 | 引导链 | F-005(P1), F-003(手动 A/B), F-012(USB/recovery UKI) | UKI + systemd-boot；手动切槽；10 次重启 |
| v0.3 | 安装与回滚 | F-003(自动), F-007, F-011, F-012(完整) | 空盘安装；破坏 B 槽自动回 A；recovery 演练通过 |
| v0.4 | 用户态 | F-008, F-013, F-014 | podman hello-world；状态可读；备份可恢复 |
| v1.0 | 稳定 | 收口、长跑、文档 | 真服务器连续运行一周；断电/重启 10 次 |
| future | 扩展 | F-009 VFIO, F-010 Secure Boot/verity, data fs zfs | 单独设计，不阻塞 v1 |

版本号是计划，不是承诺。每个版本只加一层；不通过 gate 不进入下一个。
详细 gate 和 definition of done 见 [`roadmap.md`](roadmap.md)。

## 6. 非目标（v1）

- 笔记本：WiFi、GPU、桌面、suspend/hibernate。
- 镜像签名、dm-verity、Secure Boot。
- root 用 btrfs/zfs；data 用 btrfs，zfs 留 future。
- 用户态发行版命名空间（systemd `RootDirectory=`）。
- 自动更新定时器、多机管理、集群。
- 包管理器、nix、mkosi。

## 7. 文档地图

- 决策：`decisions/ADR-*.md`（只增不改）
- 未决：`open/Q-*.md`
- 特征：`features/F-*.md`
- 协作：`workflow.md`
- 测试：`testing.md`
- CI：`ci.md`
- 经验：`lessons.md`
- 验证：`verification.md`
- 术语：`glossary.md`

## 8. 变更记录

| 日期 | 变更 |
|---|---|
| 2026-11-10 | 从讨论稿拆出 outline；建立 features/decisions/open 结构 |
| 2026-11-13 | root 移入 system VG；`/etc` 独立 ext4；data 分区；recovery；新增 F-015 |
