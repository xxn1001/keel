---
id: Q-0002
question: What are the exact partition/LV sizes for the target disk?
blocking: F-011 / v0.3
owner: TBD
updated: 2026-11-14
---

# Q-0002 精确尺寸

## Context

目标盘容量未定；安装器需要参数化。

当前默认值就是 [layout.md](../layout.md) 里的表，来源是
[ADR-0012](../decisions/ADR-0012-system-vg.md) 和
[ADR-0013](../decisions/ADR-0013-data-partition.md)：

- 固定分区：ESP 1 GiB、recovery 1 GiB、system 6 GiB、data = 剩余。
- `system` VG：`root_a` 2 GiB、`root_b` 2 GiB、`etc` 1 GiB，VG 留约 1 GiB 空闲（16%）。

`/var` 和 `/home` 是 data 分区上的 btrfs 子卷，**不是 LV**，所以不存在
"var/home 的 LV 尺寸"可调。data 拿多少空间，由"盘容量减去固定分区"决定。

## Options

### A. 固定默认值（建议）

- ESP 1 GiB、recovery 1 GiB、system 6 GiB、data = 剩余。
- system VG 内：root_a 2 GiB、root_b 2 GiB、etc 1 GiB、约 1 GiB 空闲。
- 适合 >= 32 GiB 的盘；小于 32 GiB 时 data 太小，安装器拒绝或强警告。

### B. 按盘容量比例

- system = max(6 GiB, 8% disk)，ESP/recovery 固定，data = 剩余。
- 优点：大盘上 data 更大，不被 6 GiB 卡死；缺点：规则复杂，故障时难解释。

### C. 安装时覆盖

- A 作默认，安装器接受 `--esp-size`、`--recovery-size`、`--system-size`。
- data 不接受显式尺寸，始终吃剩余空间，避免出现"盘上有空洞"。
- 优点：灵活；缺点：headless 安装不适合交互，参数只能从无人值守配置来。

## Recommendation

A 作为默认；安装器支持覆盖 `--esp-size` / `--recovery-size` / `--system-size`，
data 始终为剩余空间。小于 32 GiB 的盘拒绝，除非显式 `--force-small-disk`。

`/var` 的容量不由安装器控制，而是和 `/home` 共享 data 的空闲空间（有意为之）。
需要给 `/var` 设硬限额属于另一个问题，见 [Q-0008](Q-0008-data-fs.md)。

## Decision gate

v0.3 安装器实现前定。至少先确定两个目标测试盘容量：

- QEMU qcow2：建议 64 GiB，够装下 system 6 GiB + 一份 data 余量。
- 真机：待定，直接影响 ESP/system 是否要按 B 放大。
