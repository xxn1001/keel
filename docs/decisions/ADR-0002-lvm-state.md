---
id: ADR-0002
title: LVM thick state pool for /etc, /var, /home
status: superseded
date: 2026-11-10
deciders: [maintainer]
---

# ADR-0002 LVM thick 状态池

> Superseded by [ADR-0012](ADR-0012-system-vg.md) and [ADR-0013](ADR-0013-data-partition.md).

## Context

`/etc`、`/var`、`/home` 需要独立、可写、可扩容。
`/var` 会被 journald、podman 镜像/容器持续占用；`/home` 是用户数据；`/etc` 很小但关键。
需要一个比“固定 GPT 分区”更灵活的尺寸方案，同时避免 thin pool 的新故障模式。

## Decision

- `pool` 分区做 LVM PV；VG `vg0`。
- 三个 **thick** LV：`vg0/etc`（1 GiB ext4）、`vg0/var`（16 GiB ext4）、`vg0/home`（剩余-10% ext4）。
- VG 留 10% 空闲，给快照/扩容。
- 不用 thin pool；不用 swap LV（zram 代替）。
- `/etc` 安装时从镜像播种一次；`/usr/share/factory/etc` 作为 diff 基准。
- LVM 元数据备份到 ESP/USB，不放 `/etc` 作为唯一副本。

## Consequences

优点：

- 尺寸可在线调整（`lvextend` + `resize2fs`）。
- 单个 LV 满不会直接拖垮其他 LV（thick 隔离）。
- 不需要为 `/var` 预留固定 GPT 分区。
- thick 的行为可预测；没有 thin pool 满导致全卷 I/O 错误的问题。

代价：

- 多一层 LVM：initrd 必须激活 VG；元数据是新的单点。
- thick 快照要预留空间；大量快照不划算。
- `/etc` 默认值不会随新镜像自动更新，需要手工 diff。

## Alternatives rejected

- **thin pool**：快照便宜，但 pool 满会拖垮所有 LV，需要 dmeventd/监控；v1 不需要。
- **GPT 分区承载 `/etc /var /home`**：简单，但尺寸固定；`/var` 增长要动分区表。
- **单个 ext4 state 分区 + 目录**：`/etc` 和 `/var` 共享故障域；一个写满全坏。
- **swap LV/swapfile**：v1 不做 hibernation；zram 更轻。

## References

- [layout.md](../layout.md)
- [F-004](../features/F-004-lvm-state.md)
- [F-007](../features/F-007-zram.md)
