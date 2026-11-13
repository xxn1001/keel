---
id: ADR-0012
title: System VG with root LVs and /etc
status: accepted
date: 2026-11-13
deciders: [maintainer]
---

# ADR-0012 system VG：root LV + /etc LV

> Supersedes [ADR-0001](ADR-0001-partition-layout.md), [ADR-0002](ADR-0002-lvm-state.md), [ADR-0003](ADR-0003-etc-volume.md), and the size part of [ADR-0009](ADR-0009-zram-sizes.md).

## Context

旧布局把 `root-a`/`root-b` 放在物理 GPT 分区，`/etc`/`/var`/`/home` 放在 `pool` 的 LVM LV。
新的目标：

- 去掉物理 root 分区，把 A/B 放进 `system` VG，减少分区表对 root 的约束。
- `/etc` 仍然需要独立、可写、简单；不能和 `/var` 共享剩余空间。
- `/var`/`/home` 移到独立 data 分区，共享存储是有意为之。
- root 在 LVM 后，LVM 失败会导致正常系统起不来；必须增加物理 recovery 分区。

## Decision

GPT 固定 4 个分区：

| # | 名称 | 大小 | 类型 | 角色 |
|---|---|---|---|---|
| 1 | `esp` | 1 GiB | EF00 | systemd-boot + UKI A/B + recovery UKI |
| 2 | `recovery` | 1 GiB | 8300 | erofs ro 救援 rootfs |
| 3 | `system` | 6 GiB | 8E00 | LVM PV，`vg system` |
| 4 | `data` | 剩余 | 8300 | btrfs，`var`/`home` 子卷 |

`system` VG：

| LV | 大小 | 文件系统 | 挂载 |
|---|---|---|---|
| `root_a` | 2 GiB | erofs | `/`（ro） |
| `root_b` | 2 GiB | erofs | 备用槽 |
| `etc` | 1 GiB | ext4 | `/etc` |

- VG 留约 1 GiB 空闲（约 16%）。
- LV 名用下划线，避免 `/dev/mapper` 的 `-` 转义。
- root 用标准路径 `/dev/system/root_a` / `/dev/system/root_b`；`/etc` 用 `/dev/system/etc`。
- `/etc` 是独立 ext4 LV，不在 data 分区，不用 overlay。
- recovery 分区和 fallback 见 [ADR-0014](ADR-0014-recovery-partition.md)。
- data 分区见 [ADR-0013](ADR-0013-data-partition.md)。

## Consequences

优点：

- root A/B 不再占用物理分区；重建/替换 root LV 不需要改 GPT。
- `/etc` 与 `/var`/`/home` 的剩余空间隔离；`/var` 写满不会拖死 `/etc`。
- `/etc` 是简单 ext4，可 fsck、可在线扩、可 tar/快照备份。
- data 分区独立，system VG 坏了还能从 recovery 挂 data 备份。
- `system` VG 小，布局清晰：root + etc。

代价：

- 正常启动现在依赖 LVM 激活 root 和 `/etc`；LVM 工具/元数据/udev 失败就起不来。
- root_a、root_b、etc 共享同一个 VG 的元数据；元数据坏了三个一起没。
- recovery 从“可选”变成“必须”；必须自动 fallback、必须演练。
- root 仍是 erofs，不能 resize；root LV 只是更容易重建，不是可 grow 的 root。
- `root=` 从 `PARTLABEL` 改成 `/dev/system/root_a|b`；更新器、UKI cmdline、验证假设都要改。

## Alternatives rejected

- **保持 root 在物理分区**：更简单，但不符合“root 进 system VG”的目标。
- **root 进 LVM 但不加 recovery**：LVM 元数据坏了连救援 root 都没有；不可接受。
- **`/etc` 放 data btrfs 子卷**：btrfs 子卷共享空间/故障域，`/etc` 会被 `/var` 拖死；需要 qgroup，复杂。
- **`/etc` 放独立 GPT 分区**：隔离更好，但多一个分区；本方案用 system VG 的 etc LV，靠 recovery 兜底。
- **thin LV**：thin pool 满会拖垮所有 LV；v1 继续用 thick。

## References

- [layout.md](../layout.md)
- [initrd.md](../initrd.md)
- [F-002](../features/F-002-erofs-root.md)
- [F-004](../features/F-004-lvm-state.md)
- [ADR-0013](ADR-0013-data-partition.md)
- [ADR-0014](ADR-0014-recovery-partition.md)
