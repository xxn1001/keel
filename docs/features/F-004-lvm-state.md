---
id: F-004
title: System VG for root and /etc
status: accepted
target: v0.1
owner: TBD
updated: 2026-11-13
depends: [F-001]
---

# F-004 system VG：root + `/etc`

## 1. Why

- root A/B 放进 `system` VG，去掉物理 root 分区。
- `/etc` 必须可写、关键、体积小；用独立 ext4 LV，和 `/var` 的剩余空间隔离。
- `/var`/`/home` 放到独立 data 分区（F-015），system VG 只负责系统。

## 2. Scope

包含：

- GPT `system` 分区 → `pvcreate` → `vg system`。
- `system/root_a`、`system/root_b`（2G erofs）。
- `system/etc`（1G ext4）。
- VG 约 1G 空闲（16%）。
- `/etc` 安装时从镜像播种一次；保留 `/usr/share/factory/etc`。
- `/etc/fstab` 只放注释/非关键项，不重复核心挂载。
- LVM 元数据备份到 ESP/USB。

不包含：

- `/var`/`/home`（F-015，data 分区）。
- thin pool / 大量快照。
- swap LV（zram）。

## 3. User-visible behavior

- `lvs` 显示 `root_a`、`root_b`、`etc`。
- `findmnt /etc` 是 ext4，`rw`。
- 重启后 `/etc/hostname`、machine-id、ssh host key 仍在。
- `/etc/fstab` 没有 `/`、`/etc`、`/var`、`/home`、`/boot` 的 active entry。

## 4. Interfaces

| 接口 | 说明 |
|---|---|
| `/dev/disk/by-partlabel/system` | LVM PV |
| `system` | VG 名 |
| `/dev/system/root_a`、`root_b`、`etc` | LV 标准路径 |
| `vgcfgbackup -f /boot/lvm/...` | 元数据备份 |
| `/usr/share/factory/etc` | 出厂默认配置 |

## 5. Design

### 5.1 尺寸

| LV | 默认 | 说明 |
|---|---|---|
| `root_a` | 2 GiB | erofs |
| `root_b` | 2 GiB | erofs |
| `etc` | 1 GiB | ext4；实际通常 <100 MiB |

system 分区 6 GiB；VG 约 1 GiB 空闲。`etc` 可 `lvextend` + `resize2fs` 在线扩。

### 5.2 播种 `/etc`

1. 挂 `system/etc` 到临时目录。
2. `cp -a` 镜像 `/etc/.`。
3. 清空 `machine-id`；删除 ssh host key；设置 hostname。
4. 保留 `/usr/share/factory/etc` 作为 diff 基准。
5. 写 fstab 注释模板，不写核心挂载。

### 5.3 fstab

`/etc/fstab` 在 `/etc` LV 里，不能用来挂 `/etc` 自己。规则：

- initrd 挂 `/`、`/etc`、`/var`、`/home`、`/boot`；fstab 不重复。
- 只放注释，或以后追加非关键/自动挂载项。
- `passno=0`。

建议：

```text
# keel2: critical mounts are owned by initrd.
# Do not add /, /etc, /var, /home, or /boot here.
```

### 5.4 元数据

- 权威元数据在 PV 的 metadata area；`/etc/lvm/backup` 只是文本副本。
- 每次改布局：`vgcfgbackup -f /boot/lvm/system-<date>.vg`；复制到 USB。
- 恢复：`vgcfgrestore -f ... system`。

## 6. Failure modes / recovery

| 失败 | 处理 |
|---|---|
| VG 未激活 | recovery；`vgchange -ay system` |
| `/etc` 挂不上 | recovery；不要退回 ro root 的 `/etc` |
| `/etc` 满 | 系统异常；`lvextend`/清理；recovery |
| VG 元数据损坏 | `vgcfgrestore` 从 ESP/USB |
| `/etc` 内容坏 | recovery 挂 root + factory/备份恢复 |

## 7. Acceptance criteria

- [ ] `lvs` 三个 LV active。
- [ ] `findmnt /etc` 是 ext4，`rw`。
- [ ] `/etc/hostname` 修改重启后仍在。
- [ ] `lvextend + resize2fs` 后 `df` 变大。
- [ ] `vgcfgbackup` 文件在 ESP；`vgcfgrestore` 演练通过。
- [ ] `/etc` 里没有 baked machine-id/ssh key。
- [ ] `/etc/fstab` 没有核心挂载 active entry。
- [ ] 破坏 VG 元数据后能进 recovery。

## 8. Open questions / ADR links

- system VG：[ADR-0012](../decisions/ADR-0012-system-vg.md)。
- recovery：[ADR-0014](../decisions/ADR-0014-recovery-partition.md)。
- data：[F-015](F-015-data-partition.md)。
- 精确尺寸：[Q-0002](../open/Q-0002-disk-sizes.md)。

## 9. Test plan

E2：建 VG/LV → 挂载 → 重启；`lvextend`；破坏元数据 → `vgcfgrestore`；检查 fstab。
E3：真机重复。

## 10. Changelog

| 日期 | 变更 |
|---|---|
| 2026-11-10 | 初稿（pool 承载 etc/var/home） |
| 2026-11-13 | 改为 system VG；只承载 root + etc；fstab 注释策略 |
