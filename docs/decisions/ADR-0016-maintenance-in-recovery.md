---
id: ADR-0016
title: Maintenance tools live in the recovery partition, not in the system root
status: accepted
date: 2026-11-20
deciders: [maintainer]
---

# ADR-0016 维护工具只放在 recovery 分区

## Context

v0.1 需要两件会写系统级块设备的工具：

- `keel-install`：把空盘变成可启动的 keel2（GPT、LVM、mkfs、写 ESP）；
- `keel-update`：整块替换非活动的 root LV，并写 ESP 上的引导条目。

原来的写法是把它们编进 system root，和 sshd、journald 放在一起。问题是：

1. **运行中的系统随身带着一把格式化工具。** root 是 erofs ro，本来没有任何修改自己的
   手段；但 `/usr/bin/keel-update` 一放进去，这个性质就没了。
2. **安装器和更新器的代码 80% 是重的**（分区、LVM、mkfs、写 UKI、写 ESP、校验），
   放两份要么重复实现，要么抽库。
3. **recovery 分区是"永远不启动的备份"，一定会烂。** ADR-0014 把它定为 known-good、
   不随 A/B 更新；没有任何机制保证它跟得上布局变化。
4. **Q-0010 已经决定安装器就是测试装置**，也就是每次 CI 都在跑安装器；安装器住哪儿
   直接决定了测试跑的是不是产品路径。

## Decision

### 1. 写盘工具只在 recovery

- `keel-install`、`keel-update` **只存在于 recovery 分区**，system root 不含它们，
  也不含 `mkfs.*`、`sgdisk`、`bootctl` 这类只为写盘存在的工具。
- system root 的职责收敛为"跑服务"。

### 2. 一棵树，三个入口

recovery 的内容只有一份，按用途打包成两种形态：

| 形态 | 启动方式 | `keel.mode=` | 干什么 |
|---|---|---|---|
| `recovery.cpio` | RAM，目标盘为空 | `install` | 跑 `keel-install`，写完盘提示重启 |
| `recovery.erofs` | 分区 `PARTLABEL=recovery` | `rescue`（缺省） | 掉进 shell，工具齐全 |
| `recovery.erofs` | 分区 `PARTLABEL=recovery` | `update` | 跑 `keel-update`，写完重启 |

`/init`（cpio 形态）是 `/sbin/init` 的符号链接，两种形态共用同一份入口脚本。
`keel.mode=` 由 recovery 自己的入口消费。

与 `keel.recovery=1` 的关系：那是 **initrd 层**的"别继续启动了，直接去 recovery"，
由正常启动路径的 initrd 消费。两者不同层，不要合并。

### 3. 更新的两段式

| 段 | 在哪跑 | 做什么 |
|---|---|---|
| 取回 | system root（有网络） | 把镜像放到 `/var/lib/keel/staging/`，然后请求下次启动进 recovery |
| 应用 | recovery | 读载荷、写非活动 root LV、写 ESP 条目、重启 |

"请求下次启动进 recovery"用一次性的引导条目（`bootctl set-oneshot`），不改默认槽。
v0.1 连取回都不做：手动放进 `/var/lib/keel/staging/` 即可。

载荷位置的两个视角（同一个文件）：

- 运行中的系统：`/var/lib/keel/staging/`（`/var` 是 data 分区的 `var` 子卷）；
- recovery：data 挂到 `/mnt/data`，`-o subvol=var` 之后是 `/mnt/data/lib/keel/staging/`。

安装时目标盘还没有这些，载荷来自一块单独挂进来的介质（U 盘 /
QEMU 的第二块盘），挂在 `/mnt/usb`，`keel-install --source /mnt/usb`。

### 3.1 怎么进 recovery

初始化时进 recovery 靠 ESP 上的一个引导条目（`keel-recovery`），
"下次启动进 recovery"就是给它排一次 one-shot：`bootctl set-oneshot keel-recovery`
（systemd 256 已确认有该子命令）。

这个条目的载体是 ESP recovery UKI。它在 v0.1 不存在（v0.1 的 recovery 只由 initrd
的 fallback 进入），到 v0.2 随更新流程一起加入。**它从"可选"变成"更新路径的必要入口"**，
这是 ADR-0016 带来的变化：没有它，运行中的系统无法要求"下次进 recovery"。

### 4. recovery 不自我更新

它不能重写自己正在运行的文件系统。recovery 的更新只能靠**外部介质**
（USB 启动、或重装），与 ADR-0014 的 known-good 一致。

### 5. ESP 是明确例外

`systemd-bless-boot`（`basic.target`）和 `keel-boot-repair`（`sysinit`）都必须写 ESP，
这是 [ADR-0015](ADR-0015-boot-failure-contract.md) 的核心机制。所以运行中的系统
`/boot` 必须 `rw`，也就意味着它能替换 UKI。

因此本 ADR 约束的是 **root 文件系统 LV 的写入权**，不是"整个引导链只读"。

## Consequences

优点：

- **只有一条被批准的改系统路径**，而且是显式的、会重启的、看得见的那条。
- **recovery 每次安装/更新都被用到**，不再是一份没人跑过的备份；"演练"变成日常。
- **安装器和更新器共享同一套工具和环境**，不用写两遍，也不用抽库。
- **system root 变小变简单**：没有 `mkfs.*`、`sgdisk`、`keel-*` 写盘工具。
- **安装介质 = 救援环境**：拿去装机的那个东西，就是机器坏了要进去的那个东西。

代价：

- **每次都多一次重启**。更新是"重启进 recovery → 写 → 重启进新槽"。
- **`keel-update` 里的 bug 很贵**：修它要拿 U 盘。因此它必须比别的组件更小、更保守、
  依赖更少，并且要能被 `keel-install` 的测试路径顺带覆盖。
- **recovery 更新有额外流程**，不能跟着 A/B 走；文档和验收都要为此留一条。
- **语义是设计纪律，不是安全边界**。有 root 权限的人仍然可以 `dd` 写 LV。准确的表述是
  "没有随镜像发布的工具能改 root"，不是"改不了"。

## Alternatives rejected

- **写盘工具放 system root**：就是本文要解决的问题；root 从"不可自改"退化成"靠自觉"。
- **单独做第 5 个维护分区**：分区数从 4 变 5，recovery 已经具备全部工具和
  "系统不运行时它在跑"的性质，再加一个只会增加布局复杂度。
- **只走网络更新（root 里下载+写盘）**：更新路径依赖网络和运行中的系统健康；
  系统坏了就没法修自己。而且写盘代码仍需进 root。
- **把更新载荷预先塞进 recovery 分区**：recovery 1 GiB 装得下，但那样每次换载荷都要
  重写 recovery，等于让 known-good 分区变成可变分区；载荷放 data 或 U 盘更干净。
- **recovery 双槽自更新**：复杂度翻倍，收益只是省一次插 U 盘。

## References

- [ADR-0014](ADR-0014-recovery-partition.md) recovery 分区（职责由本文扩展，结论不变）
- [ADR-0015](ADR-0015-boot-failure-contract.md) boot counting 与 ESP 写入
- [ADR-0006](ADR-0006-update-rollback.md) 更新与回滚
- [Q-0010](../open/Q-0010-image-build-harness.md) 安装器即测试装置
- [F-003](../features/F-003-ab-update.md) / [F-011](../features/F-011-installer.md) /
  [F-012](../features/F-012-rescue.md)
- [initrd.md](../initrd.md) §6.1 `keel.mode=`
