---
id: Q-0009
question: How should P1 systemd initrd trigger recovery fallback?
blocking: F-005 / F-012
owner: TBD
updated: 2026-11-13
---

# Q-0009 recovery fallback 的 unit 实现

## Context

P0 用 shell 的 `rescue()` 函数处理失败。P1 要翻译成 systemd units：
`lvm-activate.service`、`sysroot.mount`、`sysroot-etc.mount`、`sysroot-var.mount` 等失败时，
需要挂 `PARTLABEL=recovery` 并 `switch_root`，而不是停在 emergency。

## Options

### A. `OnFailure=keel-recovery.service`（建议）

- 每个关键 unit 加 `OnFailure=keel-recovery.service`。
- `keel-recovery.service` 是 oneshot：挂 recovery，`exec switch_root /recovery /sbin/init`。
- 优点：systemd-native；失败路径明确。
- 缺点：`OnFailure` 在 initrd 里的行为要实测；多个 unit 同时失败要防重复。

### B. 一个 early init script 包住关键挂载

- P1 仍保留一个小的 `/init` 脚本，systemd 只做后续。
- 优点：控制明确；缺点：又回到脚本，违背 P1 目标。

### C. `systemd-switch-root` 的失败处理

- 用 `systemd-switch-root.service` 的 `OnFailure=`。
- 优点：统一；缺点：只覆盖 switch_root 失败，不覆盖前面的 LVM/mount 失败。

## Recommendation

先试 A；在 QEMU 里分别制造：
- `vgchange` 失败；
- root mount 失败；
- `/etc` mount 失败；
- data mount 失败。

确认 `OnFailure` 能触发且只触发一次。若 systemd initrd 的 `OnFailure` 不可靠，退回 B 的最小脚本。

## Decision gate

F-005 P1 开始前；至少有一个 QEMU 失败注入测试。
