---
id: Q-0006
question: How to diff/merge /etc against factory defaults after an update?
blocking: F-004
owner: TBD
updated: 2026-11-10
---

# Q-0006 `/etc` factory 合并

## Context

`/etc` 是独立 LV，播种一次；新镜像的 `/etc` 默认值不会自动生效。
需要一个可重复的流程：更新后知道哪些文件是用户改的、哪些是新默认值。

## Options

### A. 手工 `diff -r /usr/share/factory/etc /etc`（建议 v1）

- 简单；文件少时够用。
- 缺点：靠人；容易忘。

### B. `keel-etc-diff` 编译工具

- 输出三类：相同/用户改/新增默认；可选三方合并。
- 优点：可重复；缺点：要写工具，三方合并复杂。

### C. 每次更新重新播种（覆盖用户改动）

- 不可接受；丢配置。

## Recommendation

v1 用 A，文档写清步骤；如果 `/etc` 文件数量增长，再做 B。
不做自动三方合并（旧项目的教训：复杂度高、收益低）。

## Decision gate

v0.4 前定；至少确定 factory 目录和 diff 命令。
