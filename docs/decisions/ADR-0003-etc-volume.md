---
id: ADR-0003
title: Separate /etc volume, no overlay
status: superseded
date: 2026-11-10
deciders: [maintainer]
---

# ADR-0003 `/etc` 独立 ext4 LV，不用 overlay

> Superseded by [ADR-0012](ADR-0012-system-vg.md); the "separate ext4, no overlay" decision is retained there.

## Context

root 是只读 erofs；`/etc` 必须可写（machine-id、ssh host key、networkd、passwd/shadow、hostname、locale）。
可选方案：overlayfs、bind `/data/etc`、per-slot `/etc`、独立 LV。

## Decision

- `/etc` 是独立 ext4 LV `vg0/etc`。
- 安装时从镜像 `/etc` 播种一次。
- 不用 overlay；不用 `/data` 抽象；不把 `/etc` 放进 root 槽。
- 保留 `/usr/share/factory/etc`；更新后手工 `diff -r` 合并。
- `/etc` 在 initrd 挂好，PID1 第一次读 `/etc` 就是最终视图。

## Consequences

优点：

- 没有 overlay 的 upper/work、挂载时机、daemon-reload 复杂度。
- `/etc` 是真实文件系统；工具/备份/fsck 行为直观。
- 换槽不丢配置；machine-id/ssh key 持久。
- 文件少，手工 diff 可接受。

代价：

- 新镜像的 `/etc` 默认值不会自动生效；升级后要手工合并。
- 如果 `/etc` 卷损坏/挂不上，启动失败；需要救援。
- 需要播种步骤；安装器多一步。

## Alternatives rejected

- **overlayfs**：能自动合并默认值，但引入 upper/work、挂载顺序、`/etc` 写满即坏等机制；v1 不需要。
- **bind `/data/etc`**：一次性快照；新默认值被旧副本永久遮蔽；仍需合并。
- **per-slot `/etc`**：每次更新配置重置；machine-id/ssh key 变化；不可接受。
- **只读 `/etc`**：machine-id/ssh key/networkd 都写不了；不可行。

## References

- [layout.md](../layout.md)
- [F-004](../features/F-004-lvm-state.md)
- [ADR-0004](ADR-0004-initrd-mount-order.md)
