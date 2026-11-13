---
id: ADR-0009
title: zram swap; no swap LV; default sizes
status: superseded
date: 2026-11-10
deciders: [maintainer]
---

# ADR-0009 zram swap 与默认尺寸

> Superseded by [ADR-0012](ADR-0012-system-vg.md) and [ADR-0013](ADR-0013-data-partition.md) for sizes; zram decision remains.

## Context

服务器可能内存紧张，需要 swap；但 v1 不做 hibernation，不需要磁盘 swap。
pool 里再放 swap LV 会增加 LVM 管理面和空间占用。
同时需要给 ESP/root/LV 一个默认可用的尺寸，避免每次从零算。

## Decision

- swap 用 **zram**（`/dev/zram0`），不建 swap LV、不用 swapfile。
- zram 大小：`ram * 0.5` 到 `ram * 1.0`，上限 8 GiB；算法 zstd，priority 100。
- 默认尺寸：
  - ESP 1 GiB；root-a/root-b 各 2 GiB。
  - `vg0/etc` 1 GiB；`vg0/var` 16 GiB；`vg0/home` 剩余-10%；VG 留 10% 空闲。
- 实际安装按目标盘参数化；这些是默认值，不是硬编码。

## Consequences

优点：

- 不占 pool；没有 swap LV/swapfile 的写放大。
- 配置简单；zram 启动快。
- 尺寸默认值让安装器有可执行起点。

代价：

- zram 吃 RAM；内存压力大时效果有限。
- 不支持 hibernation（v1 本来不做）。
- 需要内核 `CONFIG_ZRAM` 和 generator/unit。

## Alternatives rejected

- **swap LV**：占 pool；需要 LVM 管理；v1 不需要磁盘 swap。
- **swapfile**：文件系统/空间/碎片问题；zram 更轻。
- **zswap**：不同机制（缓存到磁盘 swap），v1 没有磁盘 swap。
- **不配 swap**：内存紧张时 OOM；zram 成本低。

## References

- [F-007](../features/F-007-zram.md)
- [layout.md](../layout.md)
- [Q-0002](../open/Q-0002-disk-sizes.md)
