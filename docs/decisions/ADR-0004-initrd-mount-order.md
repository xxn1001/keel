---
id: ADR-0004
title: initrd owns /etc, /var, /home, /boot mounts
status: accepted
date: 2026-11-10
deciders: [maintainer]
---

# ADR-0004 initrd 拥有状态挂载

> Order extended by [ADR-0012](ADR-0012-system-vg.md) and [ADR-0014](ADR-0014-recovery-partition.md): activate `system` VG before root; fallback to recovery on failure.

## Context

PID1 在启动早期读 `/etc`（machine-id、passwd、hostname、networkd 配置）。
如果 `/etc` 由用户态 systemd 挂，PID1 已经读过只读 root 的 `/etc`：
machine-id 可能变成 transient，journald/sysusers/tmpfiles 行为异常。
`/var` 也有类似问题（journald 早期写日志）。

## Decision

- `/etc`、`/var`、`/home`、`/boot` 都由 **initrd** 挂载，在 `switch_root` 之前完成。
- P0 用一个最小脚本；P1 翻译成 systemd units；顺序不变。
- 失败就进救援 shell，不继续用只读副本启动。
- `/etc/fstab` 不重复写这些卷；`passno=0`；需要挂载的服务用 `RequiresMountsFor=`。

## Consequences

优点：

- PID1 第一次读 `/etc` 就是最终视图；machine-id 稳定。
- journald 从第一次启动就有持久 `/var`。
- 挂载顺序显式，不依赖 fstab-generator/udev 的隐式行为。

代价：

- initrd 必须带 LVM/ext4/erofs/vfat 和 `vgchange`；initrd 变大。
- LVM 激活失败就进不了系统；需要救援路径。
- P0 脚本是临时资产；P1 必须翻译成 units。

## Alternatives rejected

- **fstab + 用户态 systemd**：对 `/etc` 太晚；machine-id/journald 问题。
- **overlay 在用户态挂**：同样太晚；还多 upper/work。
- **dracut 默认 initrd**：不是 systemd-native；`rd.*` 约定与我们的 units 不一致。
- **不做 initrd，root 直接 rw**：失去只读基底；A/B 语义变差。

## References

- [initrd.md](../initrd.md)
- [F-005](../features/F-005-systemd-initrd.md)
- [ADR-0003](ADR-0003-etc-volume.md)
