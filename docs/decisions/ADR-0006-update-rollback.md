---
id: ADR-0006
title: Compiled updater plus boot-counting rollback
status: accepted
date: 2026-11-10
deciders: [maintainer]
---

# ADR-0006 编译型更新器 + boot counting 回滚

> Slot path updated by [ADR-0012](ADR-0012-system-vg.md): `root=/dev/system/root_a|root_b`. Boot-counting logic is unchanged.

## Context

headless 服务器更新失败时没人按键；必须自动回旧槽。
旧方案用大型 shell 库管理状态，难维护、错误处理弱。
`systemd-sysupdate` 支持 GPT partition + UKI，但会用 `_empty`/版本号改写分区 label，
与固定的 `root-a`/`root-b` 和 `root=PARTLABEL=` 冲突。

> Layout note: since [ADR-0012](ADR-0012-system-vg.md), root lives in `system` VG LVs and
> `root=` uses `/dev/system/root_a|root_b`; `PARTLABEL` now applies only to `data` and `recovery`.
> The sysupdate decision below (A-003) is unchanged.

## Decision

- 自制 **编译型** `keel-update`（C 静态 musl 优先；Rust/C++ 可选），**不用 shell 状态机**。
- 子命令：`stage`、`switch`、`status`。
- `stage` 顺序：读 `/proc/cmdline` 定当前槽 → 拒绝目标已挂载/空间不足 → 写非活动 root + `fsync` → 写 UKI + `fsync` → `bootctl set-oneshot keel-<slot>`。
- 入口点最后写：先 root，后 UKI。
- 回滚：boot counting + `systemd-bless-boot`；`panic=-1` + 运行时看门狗 + emergency 超时重启。
- 成功判据：`multi-user.target` + 关键挂载检查；不含 `network-online.target`。
- v1 不做签名/verity（ADR-0007）。

## Consequences

优点：

- 关键逻辑可测试、错误处理明确、无 shell 全局状态。
- root/UKI 写入顺序固定；失败不会留下半个入口点。
- 不依赖 sysupdate 的 label 语义。

代价：

- 需要自己维护一个二进制和它的测试。
- 没有 delta/压缩传输；每次写整块 erofs。
- 依赖 systemd-boot 的 boot counting/bless 行为。

## Alternatives rejected

- **systemd-sysupdate**：label 语义与固定 `root-a/b` 冲突；v1 不用，仅参考。
- **shell 更新器**：旧项目的教训；状态机不可维护。
- **手动 `dd` + `bootctl`**：容易漏步骤；不适合 headless。
- **无自动回滚，只手动切槽**：服务器起不来时不可接受。

## References

- [F-003](../features/F-003-ab-update.md)
- [ADR-0005](ADR-0005-uki-boot.md)
- [verification.md](../verification.md) A-007
