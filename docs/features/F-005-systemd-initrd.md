---
id: F-005
title: systemd initrd
status: accepted
target: v0.1/v0.2
owner: TBD
updated: 2026-11-13
depends: [F-001, F-004, F-015]
---

# F-005 systemd initrd

## 1. Why

root、`/etc`、`/var`、`/home` 必须在 PID1 之前挂好；否则 machine-id、journald、sysusers 都会出问题。
P0 用最小脚本把 LVM/root/etc/data 的顺序跑通；P1 翻译成 systemd units。systemd 是最终形态。

## 2. Scope

包含：

- `vgchange -ay system`。
- 挂 root LV（erofs ro）。
- 挂 `/etc`（ext4）。
- 挂 `/var`/`/home`（data btrfs 子卷）。
- 挂 `/boot`（ESP）。
- `switch_root` 到真正 systemd。
- 失败自动进 recovery。
- `keel.recovery=1` 强制救援。

不包含：

- 网络、解密、verity。
- dracut 兼容层。

## 3. User-visible behavior

- 启动后 `findmnt -R /` 显示所有挂载。
- `/etc/machine-id` 稳定。
- 关键挂载失败时进 recovery，而不是半启动。

## 4. Interfaces

| 接口 | 说明 |
|---|---|
| `initrd/init` | P0 脚本（临时） |
| `initrd/units/` | P1 systemd units |
| `keel.recovery=1` | 强制救援 |
| `lvm-activate.service` | `vgchange -ay system` |
| `sysroot.mount`、`sysroot-etc.mount` 等 | P1 units |

详细 unit 表和顺序见 [`../initrd.md`](../initrd.md)。

## 5. Design

### P0

- 一个 `#!/bin/sh` 脚本；`set -eu`。
- 顺序：`vgchange` → root → `/etc` → data → ESP → `switch_root`。
- 任何关键挂载失败：`rescue()` 挂 recovery 并切根。
- 只用于 v0.1；P1 完成后删除。

### P1

- `lvm-activate.service` 排在 `sysroot.mount` 之前。
- `sysroot.mount`：`What=/dev/system/root_a`，erofs ro。
- `sysroot-etc.mount`：`What=/dev/system/etc`，ext4。
- `sysroot-var.mount`/`sysroot-home.mount`：data btrfs，`subvol=var|home`。
- `sysroot-boot.mount`：ESP。
- `initrd.target` + `systemd-switch-root.service`。
- `keel-recovery.service` 由关键 unit 的 `OnFailure=` 触发；实现见 [Q-0009](../open/Q-0009-recovery-fallback.md)。

## 6. Failure modes / recovery

| 失败 | 处理 |
|---|---|
| `vgchange` 失败 | recovery |
| root 挂不上 | recovery |
| `/etc` 挂不上 | recovery |
| data/`var`/`home` 挂不上 | recovery |
| ESP 挂不上 | 继续 + 警告；更新不可用 |
| recovery 挂不上 | shell / USB |

## 7. Acceptance criteria

- [ ] P0 能在 QEMU 启动到 multi-user。
- [ ] P1 units 与 P0 的挂载顺序一致。
- [ ] LVM/root/etc/data 失败都能进 recovery。
- [ ] `keel.recovery=1` 强制进 recovery。
- [ ] 连续 5 次重启，无 emergency。

## 8. Open questions / ADR links

- initrd 挂载顺序：[ADR-0004](../decisions/ADR-0004-initrd-mount-order.md)、[ADR-0012](../decisions/ADR-0012-system-vg.md)。
- recovery fallback：[ADR-0014](../decisions/ADR-0014-recovery-partition.md)、[Q-0009](../open/Q-0009-recovery-fallback.md)。
- Buildroot LVM units：[Q-0003](../open/Q-0003-buildroot-components.md)。

## 9. Test plan

E1/E2：P0 启动；P1 替换；失败注入；recovery fallback。
E3：真机重复。

## 10. Changelog

| 日期 | 变更 |
|---|---|
| 2026-11-10 | 初稿 |
| 2026-11-13 | LVM 先于 root；etc/data/recovery 顺序 |
