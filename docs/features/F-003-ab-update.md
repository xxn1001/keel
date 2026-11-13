---
id: F-003
title: Atomic A/B update and rollback
status: accepted
target: v0.2/v0.3
owner: TBD
updated: 2026-11-13
depends: [F-002, F-005]
---

# F-003 原子更新 + 自动回滚

## 1. Why

headless 服务器起不来没人按键；更新必须原子，失败必须自动回旧槽。
不用 shell 状态机；更新器是编译型二进制。

## 2. Scope

包含：

- `keel-update`：`stage` / `switch` / `status`。
- 写非活动 root LV + 写 UKI + `bootctl set-oneshot`。
- boot counting + `systemd-bless-boot`。
- `panic=-1` + 运行时看门狗 + emergency 超时重启。
- 成功判据：`multi-user.target` + 关键挂载检查，不含 `network-online.target`。
- LVM 阶段失败由 initrd fallback 到 recovery，不由 boot counting 处理。

不包含：

- 自动下载/定时更新。
- 增量更新/delta。
- Secure Boot/verity（F-010）。

## 3. User-visible behavior

```text
keel-update stage <payload-dir>
keel-update switch a|b
keel-update status
```

- `stage`：把 payload 写进非活动 root LV，安排下次启动。
- `switch`：改默认槽。
- `status`：当前槽、ESP 条目、LV 大小、上次结果。

## 4. Interfaces

| 接口 | 说明 |
|---|---|
| `/usr/bin/keel-update` | C 静态 musl 二进制；无 shell |
| `keel-update.service` | systemd unit，`ExecStart=/usr/bin/keel-update stage <dir>` |
| `/dev/system/root_a|root_b` | 目标 LV 标准路径 |
| `/boot/EFI/Linux/keel-<slot>+3.efi` | 候选 UKI |
| `bootctl set-oneshot keel-<slot>` | 一次性启动 |
| `boot-complete.target` | 成功判据 |

payload 目录：

```text
<payload-dir>/
|-- root.erofs
|-- keel-<slot>.efi
`-- VERSION
```

## 5. Design

### 5.1 stage 顺序

1. 读 `/proc/cmdline` 的 `root=/dev/system/root_a|root_b`，确定当前槽。
2. 目标槽 = 另一个；拒绝目标 == 当前。
3. 检查目标 LV 存在、payload 大小 ≤ LV、ESP 剩余空间足够。
4. 检查目标 LV 没有被挂载（`/proc/self/mountinfo`/`findmnt`）。
5. 打开 `/dev/system/root_b`（`O_WRONLY|O_SYNC`），顺序写 `root.erofs`，`fsync`。
6. 写 ESP `EFI/Linux/keel-<slot>+3.efi`，`fsync`。
7. `bootctl set-oneshot keel-<slot>`（entry ID 不带 `+3`）。
8. 返回 0；任一步失败返回非 0。

顺序理由：**入口点最后写**。先写 root，后写 UKI；如果 UKI 写失败，旧 UKI 仍指向旧 root。

LVM 说明：

- 更新只写 LV 块设备，**不改 LVM 元数据**；不需要 `lvcreate`/`lvresize`。
- `vgchange -ay system` 会激活两个 root；目标 active 但未挂载即可写。
- 如果目标 LV 被挂载，拒绝。
- 如果 VG 元数据/激活失败，更新器无法启动；由 recovery 处理。

### 5.2 成功/失败

- 成功：到达 `boot-complete.target`；`systemd-bless-boot` 把 `keel-<slot>+3.efi` 改名为 `keel-<slot>.efi`；`bootctl set-default`。
- 失败：one-shot 已消费；下次启动回默认（旧槽）。
- 三类系统失败：
  - panic：`panic=-1` 立即重启。
  - PID1 冻住：硬件看门狗/softdog 复位。
  - 停在 emergency：`keel-boot-failed-reboot.timer` 60 秒重启。
- LVM/root 挂载失败：initrd 直接进 recovery；boot counting 不适用。

### 5.3 成功判据

`boot-complete.target` 排在 `multi-user.target` 之后，并检查：

- `/` 是 erofs ro。
- `/etc` 是 ext4，挂载点。
- `/var`/`/home` 是 btrfs 子卷，挂载点。
- `sshd` 已启动（可选）。

**不**把 `network-online.target` 放进去：DHCP 慢/网线没插不应触发回滚。

## 6. Failure modes / recovery

| 失败 | 处理 |
|---|---|
| 目标 LV 已挂载 | 拒绝 |
| payload 大于 LV | 拒绝 |
| ESP 空间不足 | 拒绝；清理 `.failed`/旧候选 |
| 写 root 失败 | 返回非 0；旧槽不受影响 |
| 写 UKI 失败 | 返回非 0；旧 UKI 仍指向旧 root |
| 新槽起不来 | 自动回旧槽；保留坏槽供排查 |
| LVM 阶段失败 | recovery 分区 |
| 两个槽都坏 | recovery + USB |

## 7. Acceptance criteria

- [ ] `keel-update stage` 写入非活动 root LV；当前槽不变。
- [ ] 重启进入新槽；`bootctl list` 显示 bless 后的条目。
- [ ] 故意破坏 B 槽；重启自动回 A。
- [ ] panic/冻住/emergency 三类失败都能复位。
- [ ] `/etc` 和 data 跨更新保持。
- [ ] 连续 10 次更新/回滚，无半写。
- [ ] LVM 元数据坏时进 recovery，不进入半启动。

## 8. Open questions / ADR links

- 更新/回滚决策：[ADR-0006](../decisions/ADR-0006-update-rollback.md)。
- root 在 system VG：[ADR-0012](../decisions/ADR-0012-system-vg.md)。
- recovery：[ADR-0014](../decisions/ADR-0014-recovery-partition.md)。
- 不用 sysupdate 的理由：见 ADR-0006。

## 9. Test plan

E2：正常更新 → 回滚；坏槽 → 自动回滚；panic/冻住/emergency 演练；ESP 填满；目标 LV 已挂载拒绝。
E3：真机更新 5 轮。

## 10. Changelog

| 日期 | 变更 |
|---|---|
| 2026-11-10 | 初稿（物理 root 分区） |
| 2026-11-13 | 改为 root LV；路径 `/dev/system/*`；LVM 失败进 recovery |
