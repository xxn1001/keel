---
id: ADR-0014
title: Recovery partition and initrd fallback
status: accepted
date: 2026-11-13
deciders: [maintainer]
---

# ADR-0014 recovery 分区与 initrd fallback

## Context

root 和 `/etc` 现在都在 `system` VG 上；LVM 激活/元数据/udev 失败时，正常系统起不来。
boot counting 只能处理“systemd 起来了但服务失败”；它救不了 initrd 阶段的 LVM 失败。
ESP 上的 rescue UKI 可以手动选，但 headless 服务器可能没有键盘；需要自动 fallback。

## Decision

- GPT `recovery` 分区 1 GiB，erofs ro，自包含救援 rootfs。
- ESP 上放一个独立的 recovery UKI，cmdline：

```text
root=PARTLABEL=recovery ro rootfstype=erofs
keel.recovery=1
```

- 正常 initrd 在以下失败时自动挂 recovery 并 `switch_root`：
  - `vgchange -ay system` 失败；
  - root LV 挂载失败；
  - `/etc` LV 挂载失败；
  - data 分区/`var`/`home` 挂载失败。
- `keel.recovery=1` 可强制直接进 recovery。
- recovery rootfs 用 BusyBox init + shell，不跑完整 systemd；只读，`/run`/`/tmp` 用 tmpfs。
- recovery 工具：`lvm2`、`e2fsprogs`、`btrfs-progs`、`erofs-utils`、`bootctl`、`sgdisk`、`mount`、`blkid`、`dmesg`。
- recovery **不随 A/B 更新自动更新**；它是 known-good，更新必须单独、显式、验证过。
- ESP rescue UKI + USB 仍然保留；recovery 不防磁盘/ESP 物理损坏。

## Consequences

优点：

- LVM 阶段失败也能自动进救援，不依赖键盘。
- recovery 独立于 system VG 和 data；能修 LVM、ext4、btrfs、ESP。
- 与 ESP rescue UKI、USB 形成三层救援。

代价：

- 多一个 1 GiB 分区和一个 recovery UKI；ESP 需要放 3 个 UKI。
- recovery rootfs/工具要维护；过期 recovery 可能修不了新布局。
- recovery 在同一块盘上，不防盘坏。
- initrd 多一条 fallback 路径；必须演练，否则等于没有。
- recovery 更新策略要单独设计，不能跟着每次更新自动覆盖。

## Alternatives rejected

- **只靠 ESP rescue UKI 手动选**：headless 可能没有键盘；LVM 失败时无法自动恢复。
- **只靠 USB**：可能找不到/过期/接口坏；ESP recovery 更快。
- **不做 recovery，LVM 失败就重装**：数据/配置丢失；不可接受。
- **recovery 也放 LVM**：LVM 坏了 recovery 也没了；必须物理分区。
- **recovery 跑完整 systemd**：依赖多、体积大、可能重复挂载目标系统；BusyBox 更稳。

## References

- [F-012](../features/F-012-rescue.md)
- [initrd.md](../initrd.md)
- [ADR-0011](ADR-0011-rescue-media.md)
- [ADR-0012](ADR-0012-system-vg.md)
