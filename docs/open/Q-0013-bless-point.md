---
id: Q-0013
question: When is a boot considered good enough to bless?
blocking: F-003 / v0.2
owner: TBD
updated: 2026-11-18
---

# Q-0013 bless 的判定点

## Context

[ADR-0006](../decisions/ADR-0006-update-rollback.md) 写的成功判据是
"`multi-user.target` + 关键挂载检查，不含 `network-online.target`"。

W-2 实测：`systemd-bless-boot.service` 在 **`basic.target`** 就把启动标成 good 了，
比 multi-user 早得多。也就是说 ADR-0006 想表达的那个判据**实际上没有被执行**——
系统起到 basic.target 就算"好"，后面关键服务全挂也不会触发回滚。

## Options

### A. 接受现状

- `basic.target` 已经覆盖了 initrd 之后的早期失败。
- 缺点：`ssh 起不来`、`/var 挂载后服务崩` 这类问题不会回滚。

### B. 用 drop-in 给我方检查加门（建议）

```ini
# /etc/systemd/system/systemd-bless-boot.service.d/10-keel.conf
[Unit]
After=keel-boot-check.service
Requires=keel-boot-check.service
```

`keel-boot-check.service` 在 multi-user 检查关键挂载和关键服务，失败就 return 非零，
bless 因此不执行 → tries 继续递减 → 最终回滚。

- 优点：复用 systemd 自己的改名逻辑，不改计数格式。
- 缺点：依赖 systemd 不改变 bless 的依赖图（升级时要复查）。

### C. 自己实现 bless

- 自己 rename 文件 + 自己维护计数。控制力最强，但要重写 systemd 已经测过的东西。

### D. 关掉 bless，只靠 keel-boot-ok 记账

- 计数永不归零，回滚退化成人肉操作。不可接受。

## Recommendation

先做 **B**；如果 B 在真机上被发现不可靠（比如 `Requires=` 让 bless 从"延迟"变成"取消"的
行为不稳定），再考虑 C。

## Decision gate

F-003 自动回滚开始之前（v0.2）。在那之前，v0.1 只要求"能启动 + 能手动切槽"，
bless 的行为先按现状记录。
