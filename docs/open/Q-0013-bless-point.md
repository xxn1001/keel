---
id: Q-0013
question: When is a boot considered good enough to bless?
blocking: F-003 / v0.2
owner: TBD
status: closed
updated: 2026-11-26
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

## Resolution (2026-11-26)

选 B 的受控版本，不依赖 systemd 的 `systemd-bless-boot.service`：

- `/etc/systemd/system/systemd-bless-boot.service` 是 `/dev/null` 的符号链接，mask 掉
  原生服务；generator 仍会拉它，但 mask 优先。
- `keel-boot-ok.service` 在 `multi-user.target` 之后检查 `/` 是 erofs ro、`/etc` 已挂、
  `/var`/`/home` 是 btrfs 子卷、`systemctl --failed` 为空；全过才显式调用
  `/usr/lib/systemd/systemd-bless-boot good`。
- 即使 bless 失败（例如 ESP 不可写），只要健康检查通过，仍写
  `/var/lib/keel/boot-ok`，满足 ADR-0015 的 ESP 故障降级。
- `keel-boot-repair.service` 在 `sysinit.target` 读取 boot-ok；若 ESP 可写，把记录槽的
  counted UKI 还原成 `keel-<slot>+10.efi`。
- 全树搜索确认除被 mask 的 unit 外，没有其他 unit 调用 `systemd-bless-boot`。

Q 关闭；实现见 `board/qemu/x86_64/rootfs-overlay/`。
