---
id: ADR-0005
title: ESP + systemd-boot + UKI; no boot_a/b partitions
status: accepted
date: 2026-11-10
deciders: [maintainer]
---

# ADR-0005 ESP + systemd-boot + UKI

## Context

A/B 要求 kernel 与 root 永远配对。
如果 kernel/initrd 放在单独 `/boot`，root 在另一个分区，更新时可能只换一半。
systemd-boot 只读 FAT（ESP/XBOOTLDR），不能读 erofs/ext4。

## Decision

- 一个 1 GiB ESP（vfat），挂 `/boot`。
- systemd-boot 作为引导器。
- 每个槽一个 **UKI**：kernel + initrd + cmdline + microcode。
- 不设 `boot_a`/`boot_b` 分区；不共享 kernel + BLS。
- 微码进 UKI 的 `.ucode` 段（`ukify --microcode`）。
- cmdline 加 `systemd.gpt_auto=no`，ESP 由 initrd 显式挂。
- 更新时先写 root，最后写 UKI（入口点最后）。

## Consequences

优点：

- kernel/root 配对由 UKI 保证；不会出现旧内核配新根。
- ESP 是唯一引导入口，结构简单。
- 微码跟槽走，随系统原子更新。
- 回滚 = 换 UKI/默认条目。

代价：

- ESP 1 GiB；UKI 较大（systemd initrd 时可能 60-100 MiB）。
- 需要 `ukify`/systemd-boot 工具链；Buildroot 可能不完整打包。
- Secure Boot 关闭（v1 不签名）。

## Alternatives rejected

- **kernel + initrd + BLS 条目**：需要手动保证 kernel/root 配对；容易漂移。
- **`boot_a`/`boot_b` 独立分区**：systemd-boot 读不了非 FAT；还要配对。
- **GRUB**：能读 ext4/LVM，但复杂、与 systemd-boot counting 集成差。
- **共享 kernel + 两个 BLS 条目**：违反“每槽完整 UKI”。

## References

- [layout.md](../layout.md)
- [F-002](../features/F-002-erofs-root.md)
- [F-003](../features/F-003-ab-update.md)
