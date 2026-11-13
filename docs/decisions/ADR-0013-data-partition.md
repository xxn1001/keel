---
id: ADR-0013
title: Separate data partition for /var and /home
status: accepted
date: 2026-11-13
deciders: [maintainer]
---

# ADR-0013 data 分区承载 `/var` 和 `/home`

## Context

`/etc` 已经移到 `system` VG 的独立 ext4 LV，解决了关键配置被 `/var` 拖死的问题。
`/var` 和 `/home` 可以共享一个独立 data 分区；共享剩余空间是有意为之。
候选文件系统：btrfs、zfs。zfs 的 dataset quota 更自然，但内核模块 out-of-tree、initrd 导入复杂。

## Decision

- GPT `data` 分区使用剩余空间，标签 `data`。
- v1 基线使用 **btrfs**；`/var`、`/home` 是两个子卷：

```text
data (btrfs)
|-- var
`-- home
```

- `/etc` **不**放在 data；它在 `system` VG 的 `etc` LV。
- `/var` 和 `/home` 共享 data 的空闲空间；这是明确取舍，不默认启用 qgroup。
- 降低风险的配套措施：
  - journald `SystemMaxUse` 限制。
  - podman 镜像/容器定期 prune；监控 data 使用率。
  - 80% 告警；90% 拒绝大写入/更新。
  - 定期 `btrfs scrub`。
  - 备份用 `btrfs send` 到 USB/另一块盘；本地快照不算备份。
- zfs 不在 v1；保留 [Q-0008](../open/Q-0008-data-fs.md) 评估。

## Consequences

优点：

- `/var` 和 `/home` 独立于 system VG；system VG 坏了，recovery 仍能挂 data 备份。
- 子卷/快照/压缩/send-receive 可用。
- 不需要为 `/var`/`/home` 维护两个 LVM LV。
- `/etc` 与 data 的故障域和空间隔离。

代价：

- `/var` 写满会吃掉 `/home` 的剩余空间；这是有意的共享。
- data 文件系统整体损坏时，`/var` 和 `/home` 一起坏；子卷不是独立故障域。
- btrfs 修复能力有限；必须 scrub + 外部备份。
- 如果以后要硬配额，需要 qgroup/squota，或改用 zfs dataset quota。
- zfs 方案会把内核模块、initrd 导入、ARC 调参带进来；v1 不选。

## Alternatives rejected

- **LVM 上继续放 `/var`/`/home` 两个 ext4 LV**：隔离最好，但没有子卷/快照/压缩；不符合本次目标。
- **`/etc`、`/var`、`/home` 全放 data btrfs**：`/etc` 会被共享空间/文件系统故障拖死；已否决。
- **zfs 作为 v1 基线**：out-of-tree 模块、initrd 导入、Buildroot 集成复杂度高；留待评估。
- **btrfs + 强制 qgroup**：qgroup 有性能和 corner case 成本；当前共享是有意为之，先不上，保留后续选项。

## References

- [layout.md](../layout.md)
- [F-015](../features/F-015-data-partition.md)
- [Q-0008](../open/Q-0008-data-fs.md)
- [ADR-0012](ADR-0012-system-vg.md)
