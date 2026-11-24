---
id: F-003
title: Atomic A/B update and rollback
status: accepted
target: v0.2/v0.3
owner: TBD
updated: 2026-11-20
depends: [F-002, F-005]
---

# F-003 原子更新 + 自动回滚

## 1. Why

headless 服务器起不来没人按键；更新必须原子，失败必须自动回旧槽。
不用 shell 状态机；更新器是编译型二进制。

## 2. Scope

包含：

- `keel-update`：`stage` / `switch` / `status`，**只存在于 recovery 分区**，不进 system root。
- 运行中的系统只负责"把镜像取回 `/var/lib/keel/staging/`"和"请求下次启动进 recovery"。
- 写非活动 root LV + 写 UKI + `bootctl set-oneshot`。
- boot counting + `systemd-bless-boot`。
- `panic=-1` + 运行时看门狗 + emergency 超时重启。
- 成功判据：`multi-user.target` + 关键挂载检查，不含 `network-online.target`。
- LVM 阶段失败由 initrd fallback 到 recovery，不由 boot counting 处理。

不包含：

- 自动下载/定时更新。
- 增量更新/delta。
- Secure Boot/verity（F-010）。
- 在运行中的系统里直接写 root LV —— 那是 recovery 的活，见
  [ADR-0016](../decisions/ADR-0016-maintenance-in-recovery.md)。

## 3. User-visible behavior

```text
# 1) 运行中的系统：只取回，不写盘
cp rootfs.erofs /var/lib/keel/staging/
bootctl set-oneshot keel-recovery      # 下次启动进 recovery
reboot

# 2) recovery：真的写盘
keel-update stage /mnt/data/lib/keel/staging
keel-update switch b
keel-update status
reboot                                  # 进新槽
```

- `stage`：把 payload 写进非活动 root LV，安排下次启动。**只在 recovery 里可用。**
- `switch`：改默认槽。只在 recovery 里可用。
- `status`：当前槽、ESP 条目、LV 大小、上次结果。
- 第一部分由 systemd 的常规工具（`cp`/`scp`/`curl`）就能完成，不需要 `keel-*`；
  真正的写入器只在 recovery 里。

## 4. Interfaces

| 接口 | 说明 |
|---|---|
| `/sbin/keel-update` | C 二进制，随 recovery 树发布；system root 里没有 |
| `keel.mode=update` | recovery 的 init 按此分派，直接执行 `keel-update stage /mnt/data/lib/keel/staging` |
| `/dev/system/root_a` / `root_b` | 目标 LV 标准路径 |
| `/boot/EFI/Linux/keel-<slot>+3.efi` | 候选 UKI |
| `bootctl set-oneshot keel-<slot>` | 一次性启动 |
| `boot-complete.target` | 成功判据 |
| `/var/lib/keel/staging/` | 载荷落地位置（运行中视角） |

payload 目录：

```text
<payload-dir>/
|-- rootfs.erofs
|-- keel-<slot>.efi
`-- VERSION
```

## 5. Design

### 5.0 执行位置

`keel-update` 只存在于 recovery 分区（[ADR-0016](../decisions/ADR-0016-maintenance-in-recovery.md)）。
运行中的系统没有它，因此"改 root"这件事在物理上只有一条路径：进 recovery。

| 步骤 | 谁做 | 备注 |
|---|---|---|
| 取回镜像 | 运行中的系统 | 普通 `cp`/`scp`/`curl`，不用 `keel-*` |
| 请求下次进 recovery | 运行中的系统 | `bootctl set-oneshot keel-recovery` |
| 写 root LV 与 ESP | recovery | `keel-update stage` |
| 切默认槽 | recovery | `keel-update switch` |
| 回滚判据 | 新槽启动时 | boot counting，见 §5.2 |

这样做的好处是：删除 root 的任意文件都不会让更新能力消失；反过来，更新代码出问题
也不会影响正常启动。代价是每次更新多一次重启。

### 5.1 stage 顺序

1. 确定"当前可用槽"：读 `/mnt/data/lib/keel/boot-ok` 里的 `slot=`（[ADR-0015](../decisions/ADR-0015-boot-failure-contract.md)
   写的成功标记）。读不到时退到 ESP 的默认条目；两者都没有就拒绝执行。
   **不要读 `/proc/cmdline`**：在 recovery 里 cmdline 不带 `root=`，没有槽信息。
2. 目标槽 = 另一个；拒绝目标 == 当前。
3. 检查目标 LV 存在、payload 大小 ≤ LV、ESP 剩余空间足够。
4. 检查目标 LV 没有被挂载（`/proc/self/mountinfo`/`findmnt`）。
5. 打开 `/dev/system/root_b`（`O_WRONLY|O_SYNC`），顺序写 `rootfs.erofs`，`fsync`。
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
| 2026-11-20 | `keel-update` 移入 recovery；更新改两段式；当前槽从 `/var/lib/keel/boot-ok` 读 |
