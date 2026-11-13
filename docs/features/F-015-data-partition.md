---
id: F-015
title: Data partition for /var and /home
status: accepted
target: v0.1
owner: TBD
updated: 2026-11-13
depends: [F-001]
---

# F-015 data 分区：`/var` 和 `/home`

## 1. Why

- `/var` 和 `/home` 从 system VG 移出，放到独立 data 分区。
- system VG 坏了，recovery 仍能挂 data 备份。
- `/var` 和 `/home` 共享剩余空间是有意为之；用 btrfs 子卷/快照/压缩。
- `/etc` 已经在 system VG 的 ext4 LV，不受 data 共享空间影响。

## 2. Scope

包含：

- GPT `data` 分区，剩余空间，btrfs。
- 子卷 `var`、`home`。
- initrd 挂载 `/var`、`/home`。
- journald `SystemMaxUse`、podman prune、80% 告警。
- `btrfs scrub` + `btrfs send` 到 USB。

不包含：

- `/etc`（F-004）。
- zfs（Q-0008，future）。
- 强制 qgroup（当前共享是有意为之）。

## 3. User-visible behavior

- `findmnt /var /home` 是 btrfs，`subvol=var|home`。
- 重启后 `/var` 日志/podman 镜像、`/home` 数据仍在。
- `/var` 写满会影响 `/home`，但不会影响 `/etc`。
- data 挂不上时进 recovery。

## 4. Interfaces

| 接口 | 说明 |
|---|---|
| `/dev/disk/by-partlabel/data` | btrfs 设备 |
| `subvol=var` | `/var` |
| `subvol=home` | `/home` |
| `btrfs subvolume` | 创建/快照 |
| `btrfs send` | 备份到 USB |

## 5. Design

### 5.1 布局

```text
data (btrfs)
|-- var
`-- home
```

- `mkfs.btrfs -L data /dev/disk/by-partlabel/data`。
- `btrfs subvolume create /mnt/var`、`/mnt/home`。
- 顶层不直接挂载；initrd 用 `subvol=` 分别挂。

### 5.2 挂载选项

```text
rw,noatime,compress=zstd:3,subvol=var
rw,noatime,compress=zstd:3,subvol=home
```

- SSD 可加 `ssd`；TRIM 用 `discard=async`（按内核/介质决定）。
- 不做 boot fsck；用 `btrfs scrub`。

### 5.3 共享空间的缓解

- journald：`SystemMaxUse=2G`（按盘调整）。
- podman：定期 `podman system prune`；监控 `/var/lib/containers`。
- 80% 告警；90% 拒绝大写入/更新。
- 备份：`btrfs send` 到 USB；本地快照不算备份。
- 如果以后要硬限制 `/var`，评估 qgroup/squota 或 zfs dataset quota。

## 6. Failure modes / recovery

| 失败 | 处理 |
|---|---|
| data 分区缺失 | recovery |
| btrfs 挂不上 | recovery；`btrfs check` |
| `/var` 写满 | `/etc` 仍可写；清理/扩容；`/home` 受影响 |
| data 整体损坏 | recovery；`btrfs check`/备份恢复 |
| scrub 发现错误 | 记录；从备份恢复受影响文件 |

## 7. Acceptance criteria

- [ ] `findmnt /var /home` 是 btrfs，子卷正确。
- [ ] `/var` 和 `/home` 重启后数据仍在。
- [ ] 写满 `/var` 后 `/etc` 仍可写。
- [ ] `btrfs scrub` 能跑完。
- [ ] `btrfs send` 到 USB，能恢复一个测试子卷。
- [ ] data 挂不上时自动进 recovery。

## 8. Open questions / ADR links

- data 决策：[ADR-0013](../decisions/ADR-0013-data-partition.md)。
- btrfs vs zfs：[Q-0008](../open/Q-0008-data-fs.md)。
- recovery：[F-012](F-012-rescue.md)。

## 9. Test plan

E2：mkfs.btrfs → 子卷 → 挂载 → 重启；写满 `/var`；scrub；send/receive；data 失败进 recovery。
E3：真机 NVMe/SSD。

## 10. Changelog

| 日期 | 变更 |
|---|---|
| 2026-11-13 | 新增：data 分区承载 var/home；btrfs 基线 |
