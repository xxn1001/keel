---
id: Q-0005
question: Use systemd-zram-generator or a small custom unit for zram?
blocking: F-007
owner: TBD
updated: 2026-11-10
---

# Q-0005 zram 实现方式

## Context

需要开机创建 `/dev/zram0`、设置算法/大小、`mkswap`、`swapon -p 100`。
`systemd-zram-generator` 是 systemd 的独立项目（Rust），Buildroot 不一定有。

## Options

### A. systemd-zram-generator（建议，如果有包）

- 优点：标准、配置简单、unit 自动生成。
- 缺点：Buildroot 可能没有；多一个 Rust 包。

### B. 自写最小 unit + 工具

- 用 `modprobe`/`zramctl`/`mkswap`/`swapon`，写成 oneshot unit 或 C 小工具。
- 优点：不依赖外部包；缺点：要维护。

### C. 内核 cmdline `zram` 参数

- 有限；不能做 mkswap/swapon 全流程。

## Recommendation

先查所选 Buildroot LTS 是否有 `systemd-zram-generator`；有就用 A，没有就 B（C 小工具，不用 shell 状态机）。

## Decision gate

v0.3 前定；记录选择与配置。
