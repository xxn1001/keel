---
id: F-014
title: Backup and snapshot
status: proposed
target: v0.4
owner: TBD
updated: 2026-11-10
depends: [F-004, F-015]
---

# F-014 备份与快照

## 1. Why

`/etc`、ESP、LVM 元数据、data 是“坏了很贵”的东西。
更新前要能回退；机器丢了要能重建。

## 2. Scope

包含：

- `/etc` tar 备份（更新前）。
- ESP tar 备份（UKI/systemd-boot/loader.conf）。
- LVM 元数据 `vgcfgbackup`（system VG 外）。
- data 的 `btrfs send`（`var`/`home`）。
- 可选 thick snapshot（`/etc`）。
- 备份到 `/var/backups` + USB。

不包含：

- 全盘镜像/远程备份。
- 自动定时备份（可以先手动 + systemd timer 后置）。
- 加密备份。

## 3. User-visible behavior

```text
keel-backup etc
keel-backup esp
keel-backup lvm
keel-backup all
```

输出目标路径；`keel-backup verify <file>` 可校验。

## 4. Interfaces

| 接口 | 说明 |
|---|---|
| `/usr/bin/keel-backup` | 编译型或薄 shell |
| `/var/backups/etc-<date>.tar` | `/etc` |
| `/var/backups/esp-<date>.tar` | ESP |
| `/boot/lvm/system-<date>.vg` | LVM 元数据 |
| `data` send stream | `/var`/`/home` |
| `lvcreate -s` | 可选快照 |

## 5. Design

- `/etc`：`tar -C / -cf ... etc`；排除 `*.bak`/临时文件。
- ESP：`tar -C /boot -cf ... .`；注意 FAT 大小写。
- LVM：`vgcfgbackup -f /boot/lvm/system-<date>.vg`；保留最近 3 份。
- 快照：`lvcreate -s -n etc-snap -L 1G system/etc`；恢复 `lvconvert --merge`。
- data：`btrfs send` 到 USB；本地快照不算备份。
- 备份前检查目标空间；先写临时文件，成功后 rename。
- 不把备份只放在 `/var`（同一 data 分区）；复制到 USB。

## 6. Failure modes / recovery

| 失败 | 处理 |
|---|---|
| 空间不足 | 拒绝；清理旧备份 |
| tar 中途失败 | 删临时文件；旧备份不丢 |
| 快照空间不足 | 用 tar 备份；不要依赖快照 |
| USB 未挂 | 只写 `/var/backups` 并警告 |

## 7. Acceptance criteria

- [ ] `keel-backup all` 生成三份备份。
- [ ] 从 `/etc` tar 恢复后系统能启动。
- [ ] 从 ESP tar 恢复后能启动。
- [ ] `vgcfgrestore` 从备份恢复 VG。
- [ ] 备份不落在 data 的唯一副本。

## 8. Open questions / ADR links

- system VG：[ADR-0012](../decisions/ADR-0012-system-vg.md)。
- data：[ADR-0013](../decisions/ADR-0013-data-partition.md)。
- 救援：[F-012](F-012-rescue.md)。

## 9. Test plan

E2：备份 → 删除 → 恢复；`/etc`、ESP、VG、data 四种。
E3：真机 + USB。

## 10. Changelog

| 日期 | 变更 |
|---|---|
| 2026-11-10 | 初稿 |
