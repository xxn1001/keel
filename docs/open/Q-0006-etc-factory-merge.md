---
id: Q-0006
question: How to diff/merge /etc against factory defaults after an update?
blocking: F-004
owner: TBD
status: closed
updated: 2026-11-24
---

# Q-0006 `/etc` factory 合并

## Context

`/etc` 是独立 LV，播种一次；新镜像的 `/etc` 默认值不会自动生效。
需要一个可重复的流程：更新后知道哪些文件是用户改的、哪些是新默认值。

## Options

### A. 手工 `diff -r --no-dereference /usr/etc /etc`（建议 v1）

- 简单；文件少时够用。
- 缺点：靠人；容易忘。

### B. `keel-etc-diff` 编译工具

- 输出三类：相同/用户改/新增默认；可选三方合并。
- 优点：可重复；缺点：要写工具，三方合并复杂。

### C. 每次更新重新播种（覆盖用户改动）

- 不可接受；丢配置。

## Recommendation

已被 [ADR-0017](../decisions/ADR-0017-etc-baseline.md) 取代：

- 基线位置定为 `/usr/etc`；
- 更新时做**三方合并**（旧基线 A / 新基线 B / 当前 `/etc` C），规则借 ostree 的
  `merge_configuration_from`，不再是"手工 diff"；
- 手工 `diff -r --no-dereference /usr/etc /etc` 降级为排障手段，不是流程本身。

选项 B（`keel-etc-diff` 独立工具）不单独做：合并是 `keel-update` 的一步，不做成
第二个命令。选项 C（每次重新播种）仍然否决。

## Decision gate

已决定（2026-11-24），见 [ADR-0017](../decisions/ADR-0017-etc-baseline.md)。
实现随更新器（F-003 / v0.2）落地。

## Notes (2026-11-23)

基线位置已定为 `/usr/etc`；合并算法待更新器设计时定，参考 ostree
`merge_configuration_from` 的判定表。
