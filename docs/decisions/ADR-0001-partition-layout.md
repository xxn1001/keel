---
id: ADR-0001
title: Four physical partitions; root outside LVM
status: superseded
date: 2026-11-10
deciders: [maintainer]
---

# ADR-0001 4 个物理分区；root 在 LVM 外

> Superseded by [ADR-0012](ADR-0012-system-vg.md).

## Context

需要一个 A/B 可回滚的只读 root，以及可写的 `/etc` `/var` `/home`。
早期方案考虑过“一个大分区内部全用 LVM”，但那样 root 也依赖 LVM：
LVM 元数据/激活失败时，连救援 root 都没有。

## Decision

GPT 固定 4 个物理分区：

1. `esp` - 1 GiB vfat，systemd-boot + UKI + rescue UKI。
2. `root-a` - 2 GiB erofs，A 槽。
3. `root-b` - 2 GiB erofs，B 槽。
4. `pool` - 剩余，LVM PV；内部 `vg0/etc`、`vg0/var`、`vg0/home`。

`root=` 用 `PARTLABEL=root-a|root-b`；pool 只承载状态，不承载 root。

## Consequences

优点：

- root 挂载不依赖 LVM；pool 坏了还能挂 root 进救援。
- 更新器按 `PARTLABEL` 找非活动槽，整块写入；不需要动 LVM。
- root 是物理分区，未来若用 sysupdate 也兼容 `Type=partition`。

代价：

- root 大小固定（2 GiB）；erofs 不能 resize，扩容靠重建镜像。
- 分区表一次定死；老机器改布局要重装。
- 多一个 pool 分区的 LVM 管理层。

## Alternatives rejected

- **全部 LVM（root 也是 LV）**：LVM 激活失败就没有 root；救援路径差。
- **单 root + overlay 做 A/B**：更新/回滚语义复杂；overlay upper 与状态耦合。
- **btrfs 子卷**：v1 明确不用 btrfs；结构性只读弱。
- **root 用 ext4 + ro 挂载**：不是结构性只读；仍可能被 remount rw。

## References

- [layout.md](../layout.md)
- [F-002](../features/F-002-erofs-root.md)
- [ADR-0002](ADR-0002-lvm-state.md)
