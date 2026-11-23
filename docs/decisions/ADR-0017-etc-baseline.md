---
id: ADR-0017
title: Vendor /etc baseline lives in /usr/etc, merged three-way on update
status: accepted
date: 2026-11-23
deciders: [maintainer]
---

# ADR-0017 出厂 `/etc` 基线放在 `/usr/etc`

## Context

root 是整块替换的 erofs 镜像，`/etc` 是独立的 ext4 LV，**不随镜像变化**
（[ADR-0003](ADR-0003-etc-volume.md)）。安装时把镜像里的 `/etc` 播种一次，之后就没有任何
机制把新版本的默认配置送进已安装的系统。

原文档写的是"保留 `/usr/share/factory/etc` 作为 diff 基准"。v0.1 实施时发现这个假设是错的：

- `/usr/share/factory/etc` 是 **systemd 自己的**目录，里面只有它安装的 5 个默认文件
  （`issue`、`nsswitch.conf`、`locale.conf`、`vconsole.conf`、`pam.d`）；
- 它永远小于真正的 `/etc`，拿它当"出厂快照"做 diff 只会得到一堆噪音；
- 我们往里写，等于两个 owner 争同一个路径。

同时 `/etc` 里的很多条目是**相对符号链接**（`os-release -> ../usr/lib/os-release`、
`localtime`、`resolv.conf`、`mtab`）。任何"把 `/etc` 整棵树复制到别处"的做法都会让这些
链接悬空——这是相对链接的固有性质，不是错误。

## Decision

1. **基线位置是 `/usr/etc`**，位于 root 镜像内，由 `board/qemu/x86_64/post-build.sh`
   在 `/etc` 定稿（os-release、fstab、machine-id）之后用 `rm -rf` + `cp -a` 生成。
2. `/usr/share/factory/etc` **属于 systemd，我们不写**。
3. 基线**只做结构化比较，永不解引用**：比较用 `diff -r --no-dereference`，
   合并逻辑比较的是符号链接的目标字符串，不是"文件是否存在"。
4. **更新时做三方合并**，三个输入：

   | 代号 | 内容 | 从哪来 |
   |---|---|---|
   | A | 旧基线 | 非活动的 root LV，挂 `ro` 读 |
   | B | 新基线 | 新镜像里的 `/usr/etc` |
   | C | 用户当前配置 | `/etc` LV，`rw` |

   规则：

   | A vs B | B vs C | 动作 |
   |---|---|---|
   | 相同 | 相同 | 不动 |
   | 变了 | 相同 | 用 B 覆盖 C |
   | 相同 | 变了 | 保留 C |
   | 变了 | 变了 | 保留 C，B 另存，记冲突 |
   | A 有 B 无 | 相同 | 删除 C |
   | A 有 B 无 | 变了 | 保留 C |

5. **冲突与新文件不写进 `/etc`**：写到 `/var/lib/keel/etc-conflicts/`，
   并在 `/var/lib/keel/merge.log` 记录一行。`/etc` 里不留 `.new` 之类的游离文件。
6. **拿不准就保留**。任何无法判定的分支一律保留 C 并记日志；`/etc` 是这个系统里唯一
   不可重建的东西，宁可留垃圾也不删。
7. **A 读不到就跳过合并**（旧 root 损坏、或本来就是它坏了才要更新）。此时 `/etc`
   完全不动，只把新基线随新 root 一起装进去，下次更新就有 A 了。
8. **合并发生在 recovery 里**（[ADR-0016](ADR-0016-maintenance-in-recovery.md)），
   顺序是：写新 root → 读 A、B → 合并进 `/etc` → 写 ESP → 重启。

v0.1 **不实现合并**，只把基线的位置和格式定下来；实现属于更新器（F-003）。

## Consequences

优点：

- 新版本的默认配置能到达已安装的系统，同时不覆盖用户改动——这是"`/etc` 不进镜像"
  这个决定必须补上的一半。
- 基线是一个普通目录：能 `ls`、能 `diff`、出事能手工 `cp` 回来，不需要专门工具。
- 三方合并在 recovery 里做，和"只有 recovery 能写系统"一致。
- A 和 B 都是只读挂载，只有 C 可写，误操作的爆炸半径被限制在 `/etc`。

代价：

- 每个 root 镜像多一份 `/etc`（约 1 MiB）。
- 合并必须能挂上旧 root；旧 root 坏时退化为"不合并"，新默认值要再等一轮。
- 这是**唯一会删除 `/etc` 文件**的代码路径，必须有单测，且默认行为是保留。
- 规则表借自 ostree，但只借规则，不复用代码：glib、SELinux label、xattr、
  hardlink 这些我们都没有，抄代码只会把不必要的复杂度带进来。

## Alternatives rejected

- **继续用 `/usr/share/factory/etc`**：那是 systemd 的目录，不是我们的基线；
  两个 owner 共用一个路径，迟早互相覆盖。
- **不做基线，更新时不动 `/etc`**：新默认值永远到不了已安装的系统，密码策略、
  nsswitch、unit 默认值会无声过期。
- **每次更新用新镜像的 `/etc` 覆盖**：丢掉 machine-id、host key、网络配置，
  等于每次更新重装。
- **只比 mtime/大小，不存内容**：配置文件的 mtime 在复制、解包、`cp -a` 之后不可靠，
  据此判断"用户改过没有"会误删。
- **用 tarball 或 manifest 当基线**：能做，但人工排障不直观。manifest 可以在合并实现时
  作为加速手段补上，不替代目录。

## References

- ostree：`src/libostree/ostree-sysroot-deploy.c`，`merge_configuration_from()`
- [ADR-0002](ADR-0002-lvm-state.md) / [ADR-0003](ADR-0003-etc-volume.md) `/etc` 独立 LV
- [ADR-0016](ADR-0016-maintenance-in-recovery.md) 维护工具在 recovery
- [F-004](../features/F-004-lvm-state.md) / [F-003](../features/F-003-ab-update.md)
- [Q-0006](../open/Q-0006-etc-factory-merge.md) 合并流程
