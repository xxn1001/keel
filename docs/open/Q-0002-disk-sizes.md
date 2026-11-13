---
id: Q-0002
question: What are the exact partition/LV sizes for the target disk?
blocking: F-011 / v0.3
owner: TBD
updated: 2026-11-10
---

# Q-0002 精确尺寸

## Context

默认值：ESP 1 GiB；root 2 GiB ×2；etc 1 GiB；var 16 GiB；home 剩余-10%；VG 留 10%。
目标盘容量未定；安装器需要参数化。

## Options

### A. 固定默认值（建议）

- ESP 1G、root 2G×2、etc 1G、var 16G、home 剩余-10%。
- 适合 ≥64 GiB 盘；小于 32 GiB 需要缩小 var/etc。

### B. 按盘容量比例

- var = 15% disk，home = 剩余，etc = 1G，root = 2G。
- 优点：适配大小盘；缺点：规则复杂，调试难。

### C. 安装时交互

- 安装器提示/参数；默认值仍用 A。
- 优点：灵活；缺点：headless 安装不适合交互。

## Recommendation

A 作为默认；安装器提供 `--var-size`/`--etc-size` 覆盖；小于 32 GiB 的盘拒绝或警告。

## Decision gate

v0.3 安装器实现前定；至少确定目标测试盘容量（QEMU qcow2 与真机）。
