---
id: Q-0008
question: btrfs or zfs for the data partition in v1?
blocking: F-015 / v0.1
owner: TBD
updated: 2026-11-13
---

# Q-0008 data 文件系统

## Context

`/etc` 已经移到 `system` VG 的 ext4 LV；data 分区只承载 `/var` 和 `/home`，共享剩余空间是有意为之。
需要决定 v1 用 btrfs 还是 zfs；两者都能做子卷/dataset、快照、压缩、send/receive。

## Options

### A. btrfs（建议 v1）

- 优点：mainline；Buildroot 只需 `btrfs-progs`；initrd 简单；子卷/快照/send 成熟。
- 缺点：子卷共享空间/故障域；要硬配额需 qgroup/squota；修复能力有限。
- 当前取舍：共享空间是有意的，不默认上 qgroup；用 journald 限额、监控、外部备份降风险。

### B. zfs

- 优点：dataset quota/reservation 更自然；快照/send/压缩/加密成熟；ARC。
- 缺点：内核模块 out-of-tree；Buildroot 有包但仍受内核版本/udev 影响；initrd 要 `zpool import`；ARC 吃内存；CDDL。
- 适合未来需要硬配额/加密时。

### C. LVM + ext4

- 优点：硬隔离最好；简单。
- 缺点：没有子卷/快照/压缩；不符合本次目标。

## Recommendation

v1 用 A（btrfs）。把 zfs 作为 B 选项留给后续；如果 btrfs 的 scrub/修复/空间监控不能接受，再重新评估 B。
如果以后要硬限制 `/var`，优先评估 btrfs squota/qgroup，或 zfs dataset quota；不要在 v1 同时支持两者。

## Decision gate

F-015 设计完成前；至少完成：
- `/var` 写满不影响 `/etc`（已由 etc LV 保证）；
- `/var` 写满对 `/home` 的影响可观测/可清理；
- btrfs scrub + send/receive 恢复演练。
