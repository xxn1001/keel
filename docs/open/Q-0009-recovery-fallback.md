---
id: Q-0009
question: If a P1 systemd initrd is built, how should it trigger recovery fallback?
blocking: none (P1 itself is deferred to Q-0011)
owner: TBD
updated: 2026-11-14
---

# Q-0009 recovery fallback 的 unit 实现

## 范围变化

这个问题原来是"P1 怎么实现 fallback"，默认 P1 一定会做。
现在 P1 本身降级成待评估项（[Q-0011](Q-0011-initrd-p1.md)），所以本文改成：

> **如果**做 P1，fallback 怎么触发。

P0（shell 脚本）不依赖本文，它的失败路径由 [ADR-0015](../decisions/ADR-0015-boot-failure-contract.md)
的超时预算和 `keel.fail=` 注入定义。

## Context

P0 用脚本里的 `rescue()` 函数处理失败，逻辑一目了然。
P1 要翻译成 systemd units：`lvm-activate.service`、`sysroot.mount`、`sysroot-etc.mount`、
`sysroot-var.mount` 等失败时，需要挂 `PARTLABEL=recovery` 并 `switch_root`，
而不是停在 emergency。

难点不在"挂 recovery"，在**判定**：

- systemd 里"单位失败"和"单位还在等"是两回事；挂死要等到超时才变成失败；
- 多个 unit 可能同时失败，`OnFailure=` 会触发多次；
- initrd 里的 journal 默认在内存里，失败后重启就没了，排障要靠串口和 `systemd.log_level=debug`。

## Options

### A. `OnFailure=keel-recovery.service`（原建议）

- 每个关键 unit 加 `OnFailure=keel-recovery.service`。
- `keel-recovery.service` 是 oneshot：挂 recovery，`exec switch_root /recovery /sbin/init`。
- 优点：systemd-native；失败路径明确。
- 缺点：`OnFailure` 是否会在 initrd 的 `initrd-*` target 图里可靠触发要实测；
  需要 `StartLimitBurst=1` 之类的去重，否则多次失败会重复执行。

### B. 一个 early init script 包住关键挂载

- P1 仍保留一个小的 `/init` 脚本，systemd 只做后续。
- 优点：控制明确，和 P0 行为一致；缺点：又回到脚本，P1 的意义被削掉一半。

### C. 用 `systemd-switch-root` 的失败处理

- 只覆盖 switch_root 失败，不覆盖前面的 LVM/mount 失败。
- 不完整，只能作为补充。

### D. 不做 P1（P0 作为长期实现）

- 见 [Q-0011](Q-0011-initrd-p1.md)。本文在 D 成立时自动作废。

## Recommendation

先不决定。等 Q-0011 有结论：

- 若 Q-0011 选"保持 P0"，本文关闭，标记 `closed: not applicable`。
- 若 Q-0011 选"做 P1"，按 A 实现，并必须先在 QEMU 里验证四件事：
  - `OnFailure=` 在 initrd 图里触发；
  - 多次失败只触发一次；
  - 触发时 `/sysroot` 已经是挂载点（否则 `switch_root` 目标不合法）；
  - 超时失败（不是立即失败）也能触发。

## Decision gate

Q-0011 有结论之后。在那之前不动。
