---
id: ADR-0011
title: Rescue media = ESP recovery UKI + USB
status: accepted
date: 2026-11-10
deciders: [maintainer]
---

# ADR-0011 救援 = ESP recovery UKI + USB 双份

> Extended by [ADR-0014](ADR-0014-recovery-partition.md): add a physical recovery partition and initrd fallback. The rescue cmdline is now `keel.recovery=1`; `keel.rescue=1` is obsolete.

## Context

v1 不做签名/verity；物理/软件故障时，救援是唯一恢复路径。
ESP 是单点：FAT 无校验，可能被写坏/清空。
只靠 USB 可能找不到/过期；只靠 ESP 可能在 ESP 坏时失效。

## Decision

- ESP 上放一个 **recovery UKI**（`EFI/Linux/keel-recovery.efi`，cmdline `keel.recovery=1`），启动后进 recovery shell。
- 另做 **USB rescue rootfs**，带 `lvm2`、`e2fsprogs`、`erofs-utils`、`bootctl`、`sgdisk`。
- LVM 元数据备份到 ESP/USB；ESP/`/etc` 备份到 `/var/backups` + USB。
- 四项演练必须通过：坏 `/etc`、坏 UKI、坏 VG 元数据、清空 ESP。

## Consequences

优点：

- 两个入口，互补；ESP 坏时 USB 能重建。
- 元数据备份在 system VG 之外；LVM 坏了能恢复。
- 救援路径被演练，不是纸面。

代价：

- 两份介质要维护/更新；USB 可能过期。
- ESP 多占一个 UKI 的空间（1 GiB 足够）。
- 演练要花时间；不练等于没有。

## Alternatives rejected

- **只靠 USB**：找不到/过期/接口坏；ESP 上的 recovery UKI 更快。
- **只靠 ESP**：ESP 坏/清空时没有入口。
- **不做 rescue，重装**：数据/配置丢失；headless 机器没有本地安装介质。
- **依赖签名/verity 恢复**：v1 不做签名。

## References

- [F-012](../features/F-012-rescue.md)
- [Q-0004](../open/Q-0004-rescue-usb.md)
- [ADR-0007](ADR-0007-no-signature.md)
