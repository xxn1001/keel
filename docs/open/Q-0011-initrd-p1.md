---
id: Q-0011
question: Is a systemd-based (P1) initrd worth building at all?
blocking: F-005 / v0.2 (was a commitment, now deferred)
owner: TBD
updated: 2026-11-14
---

# Q-0011 P1 initrd 是否值得做

## Context

[ADR-0004](../decisions/ADR-0004-initrd-mount-order.md) 和 F-005 原本的路线是：
P0 用最小脚本跑通顺序，P1 翻译成 systemd units，P1 是"最终形态"。

重新审视后发现这个承诺的成本被低估了。systemd 的 initrd 模式不是几个 mount unit，
而是一整套图：

```text
sysroot.mount
  -> initrd-root-fs.target
  -> initrd-parse-etc.service
  -> initrd-fs.target
  -> initrd-switch-root.target
  -> systemd-switch-root.service
```

外加 `systemd-fstab-generator`、`systemd-gpt-auto-generator` 的介入。
平时这套图是 dracut 用 generator 生成的；手写等于自己实现半个 generator。

而我们实际需要的动作只有：**5 次 mount + 1 次 switch_root**。

## Options

### A. P0 shell 作为长期实现（建议）

- 60 行脚本，`set -eu`，`set -x` 到串口。
- 优点：失败时能一行行看到停在哪；改动成本极低；initramfs 不需要 udev，
  体积小、启动快。
- 缺点：不符合"systemd 是唯一 init"的审美；脚本里要自己写超时和 fallback。

### B. 完整 P1

- 优点：和用户态一致；日志统一进 journal（但 initrd 的 journal 重启就没了）。
- 缺点：unit 图正确性难保证；hang 时排障更难；需要 udev 进 initramfs，
  体积和启动时间都涨。

### C. 混合：P0 脚本 + switch_root 后全 systemd

- 实际上就是 A（现在 root 里已经是完整 systemd）。这个选项只是说明
  "initrd 是脚本"不违反"系统 init 是 systemd"。

### D. 引入 dracut/mkinitcpio 生成 initrd

- 优点：图是别人验证过的；缺点：引入一个大依赖，和 Buildroot 的最小化目标冲突，
  且生成过程不可控。

## Recommendation

**A**，至少到 v0.3。理由：

- 风险最高的是"挂死"，而 A 在挂死时能告诉你在第几行；B 只能靠 `systemd.log_level=debug`
  加串口回读。
- 我们用 systemd 的目的是**运行时**的服务管理，不是为了让 initrd 也变成 systemd。
  这两件事可以分开。
- 如果以后 initrd 逻辑真的复杂到需要依赖图（比如加密、多路径、网络根），
  那时再上 P1 也不迟——那时的收益才是真实的。

什么时候重新评估：v0.3 之前，或者出现"initrd 需要按条件并联多个子系统"的需求时。

## Decision gate

v0.3 规划时。届时如果 A 还够用，把 F-005 的 P1 从路线图移除，ADR-0004 补一条
`Amended by`；如果不够用，按 Q-0009 的 A 方案实现 P1。
