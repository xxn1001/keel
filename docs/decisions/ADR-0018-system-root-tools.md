---
id: ADR-0018
title: The system root keeps generic filesystem tools
status: accepted
date: 2026-11-24
deciders: [maintainer]
---

# ADR-0018 system root 保留通用文件系统工具

## Context

[ADR-0016](ADR-0016-maintenance-in-recovery.md) 决定 `keel-install` / `keel-update`
只住在 recovery，同一节里还写了一句"system root 也不含 `mkfs.*`、`sgdisk`、`bootctl`
这类只为写盘存在的工具"。

V3a 照这条实施了：post-build 先把整个 target 复制成 `out/target-full`，再从
`out/target` 删掉五个工具。实测下来这个做法三处得不偿失：

1. `mkfs.erofs` 不是"只能格式化 root LV"的工具，它能直接对一个镜像文件操作；
   `dump.erofs` / `fsck.erofs` 本来就是只读的。
2. 为了"先复制再删"，多了一棵 40 MB 的影子树，和一段"增量构建时先把删掉的文件
   拷回来"的还原逻辑——那是整个 V3a 里最容易出错的一段代码。
3. 删掉它们并不改变任何安全性质：有 root 的人本来就 `dd` 得动。

## Decision

- **system root 保留通用文件系统工具**（`mkfs.*`、`sgdisk`、`btrfs`、`lvm` 等）。
  不再维护任何删除清单。
- 只有 **`keel-install` 和 `keel-update` 不住在 system root**：它们的 Buildroot 包
  直接装进 `$(BINARIES_DIR)`，只有 recovery 树会取用。
- 因此 ADR-0016 的语义收窄为：**没有随镜像发布的"维护工具"能重写 root LV**，
  而不是"root 里没有任何写盘能力"。

## Consequences

优点：

- 少一棵影子树、少一段还原逻辑，构建链路只留一条。
- 运行中的系统仍能格式化 U 盘、检查文件系统——这些是正常运维动作。
- `keel-install` / `keel-update` 依旧不进 root，"改 root 只有一条被批准的路径"不变。

代价：

- "root 不可自改"从**结构保证**退化为**代码组织保证**：以后谁把维护工具往
  `TARGET_DIR` 里一装，没有任何机制会拦。
  对策是 `tools/mkrecovery.sh` 只从 `$(BINARIES_DIR)` 取这两个二进制，并把这条写进
  [F-012](../features/F-012-rescue.md)。
- 镜像里多约 3 MB（erofs 压缩后更少）。

## Alternatives rejected

- **继续按清单删**：收益近乎零（这些工具对正常运维无害），成本是一整条影子树逻辑。
- **把通用工具做成可选包**：`BR2_PACKAGE_KEEL_INSTALL` 本来就可选，但"少装一个我们
  自己写的包"和"删掉通用工具"是两件事，后者没有对应收益。
- **用文件属性/权限限制**：root 不受文件权限约束，拦不住。

## References

- [ADR-0016](ADR-0016-maintenance-in-recovery.md)：本文只取代它 Decision 第 1 节的第二句
- [F-011](../features/F-011-installer.md) / [F-012](../features/F-012-rescue.md)
