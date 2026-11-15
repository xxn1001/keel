---
id: ADR-0015
title: Boot attempt accounting and failure contract
status: accepted
date: 2026-11-14
deciders: [maintainer]
---

# ADR-0015 启动尝试计数与失败契约

## Context

[ADR-0014](ADR-0014-recovery-partition.md) 解决了"LVM 失败自动进 recovery"，
但没解决两件事：**挂死**和**计数被误扣**。

三个事实叠在一起构成问题：

1. systemd-boot 的 boot counting 是**每次启动尝试把 tries-left 减一**，减一发生在
   引导器启动条目的瞬间，内核还没跑。官方文档原文：

   > the first of the two numbers ('tries left') is decreased by one on every boot attempt

2. `systemd-bless-boot` 要把条目从 indeterminate 改成 good，**必须写 ESP**。

3. 所以当 ESP 无法挂载（FAT 写坏、`fsck` 失败、设备名变化）时，一次完全成功的启动
   也 bless 不了，tries 照样递减。连续几次之后条目变成 bad，换槽，另一个槽同样
   bless 不了，也变 bad。

也就是说：**一个和启动健康无关的故障（ESP 不可写），会把 A/B 两个槽一起判死**，
把回滚机制变成自毁机制。

另外，`panic=-1` 只能处理 panic。如果 initrd 挂在"等一个永远不出现的设备"上，
内核不 panic，机器就那么耗着；直到有人断电。headless 服务器没有键盘，
这条路目前只写在运维人员的脑子里，没写进文档。

## Decision

### 1. tries-left 固定为 10

条目命名为 `keel-a+10.efi` / `keel-b+10.efi`。不给 recovery 条目计数。

理由：ESP 故障到人工修复之间，通常要跨若干次启动（重试、换电源、查线）。
3 次太少，30 次会让"真坏"的槽赖着不走。10 次是"能挡住误判、又不至于拖太久"的量级。

### 2. 启动成功标记放在 `/var`，不放在 ESP

启动成功后由 `keel-boot-ok.service` 写 `/var/lib/keel/boot-ok`（内容：boot id、时间、槽名）。
理由是 `/var` 在 data 分区上，**和 ESP 的故障域独立**。

`keel-boot-repair.service` 在开机早期（`sysinit.target` 之前）执行：

- 若 `/var/lib/keel/boot-ok` 显示最近 N 次启动都成功；
- 且 ESP 可写；
- 且 ESP 上的条目名已经因为计数变坏；
- 则用 `bootctl` 把条目名恢复成 `+10`。

这就是**自愈**：ESP 修好后，不需要人到现场敲 `bootctl`。

### 3. 超时预算

每个关键步骤都有显式超时，**不依赖 systemd 的默认值**：

| 步骤 | 默认超时 | cmdline 覆盖 |
|---|---|---|
| `vgchange -ay system` | 30 s | `keel.timeout=lvm:60` |
| root LV 挂载 | 15 s | `keel.timeout=root:30` |
| `/etc` LV 挂载 | 15 s | `keel.timeout=etc:30` |
| data / `var` / `home` 挂载 | 15 s | `keel.timeout=data:30` |
| ESP 挂载 | 10 s | `keel.timeout=esp:20` |

合计默认 ~85 s（ESP 失败时继续，其余失败进 recovery）。真机慢盘（SD 卡、4 盘 RAID）
用 `keel.timeout=` 覆盖，**不改代码**。

`keel.timeout=` 只影响 initrd 的等待，不影响 recovery 里的操作。

### 4. 故障注入开关

`keel.fail=<step>` 让指定步骤假装失败，用于自动化测试失败路径：

```text
keel.fail=vglv    vgchange 返回非零
keel.fail=root    root 挂载失败
keel.fail=etc     /etc 挂载失败
keel.fail=data    data 子卷挂载失败
keel.fail=esp     ESP 挂载失败
```

实现要求：解析后**立即记录到 `/run/keel/fail`**，串口打印一行
`keel: injecting failure at <step>`，便于确认注入生效而不是真的坏了。

这个开关从第一版就内置。事后加要改 initrd 最脆弱的部分，而现在加只是几行。

### 5. ESP 失败 = 降级，不是致命

沿用现有策略：ESP 挂不上仍继续启动，只是更新和 bless 不可用。
配合第 2 条，这种情况不再导致双槽判死。

## Consequences

优点：

- ESP 故障不再伪装成"启动失败"，A/B 不会因为一个可修的 FAT 问题双双报废。
- 挂死有明确的运维路径：断电 10 次以内会切槽；有 PDU/IPMI 就能脚本化。
- 超时是数字，不是"看情况"；慢盘可用 cmdline 调，不必重新出镜像。
- 失败路径可自动化测试，不需要人肉拔盘。

代价与已知限制：

- **headless 无 PDU 时，第一次 hang 仍需人到现场。** 这是 hard limitation，
  不是实现缺陷；目标硬件应假设有 IPMI/PDU/硬件看门狗，否则要接受"一次现场"。
- `/var` 自身坏掉时（data 分区故障），标记写不了、也读不到，第 2 条的自愈失效。
  这种情况按 ADR-0014 进 recovery，人工处理。
- `keel-boot-repair` 需要 ESP 可写才能改条目名；ESP 一直坏就一直修不了，
  只能靠 10 次窗口。
- 多一个常驻服务（`keel-boot-ok`）和一个早期服务（`keel-boot-repair`）。

## Alternatives rejected

- **ESP 不可写时冻结计数（不消费 try）**：循环依赖。冻结要靠改文件名，
  改文件名要靠写 ESP，而 ESP 正好写不了。且减一发生在引导器阶段，
  initrd 发现时已经扣掉了，回不去。
- **只靠 `panic=-1`**：panic 会重启，挂死不会。挂死是最常见的启动故障。
- **把 ESP 失败当致命，直接进 recovery**：更糟。ESP 坏的时候系统其余部分
  可能是好的，进 recovery 等于把一个可继续运行的机器降级成救援模式。
- **tries-left = 3**：ESP 故障 + 两次重试就到 0，误判概率太高。
- **用 `/var` 代替 ESP 做 bless**：`systemd-bless-boot` 只认 ESP 上的文件名，
  没有旁路。

## References

- [ADR-0006](ADR-0006-update-rollback.md)：boot counting + bless 的总体方案
- [ADR-0014](ADR-0014-recovery-partition.md)：recovery 分区与 initrd fallback
- [design-v01-skeleton.md](../design-v01-skeleton.md)：W-1/W-2 的验收项
- [initrd.md](../initrd.md)：超时与注入的实现位置
- systemd-boot 文档：Boot Counting 一节
