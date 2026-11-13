---
id: F-002
title: erofs root LVs with A/B
status: accepted
target: v0.1
owner: TBD
updated: 2026-11-13
depends: [F-001, F-005]
---

# F-002 erofs root LV + A/B

## 1. Why

- 结构性只读：erofs 不能挂成 rw。
- 压缩：root 镜像小。
- A/B：两个 LVM LV，更新整块替换非活动槽，回滚是换槽。
- root 放在 `system` VG 里，不再占用物理 GPT 分区；重建/替换更容易。

## 2. Scope

包含：

- `system/root_a`、`system/root_b` 两个 LVM LV，erofs，挂 `/` ro。
- `root=/dev/system/root_a|root_b rootfstype=erofs`。
- 每个槽一个 UKI（kernel + initrd + cmdline + microcode）。
- 更新只写非活动 LV。

不包含：

- dm-verity / Secure Boot（F-010，future）。
- root 在线扩容（erofs 不支持）。

## 3. User-visible behavior

- `findmnt /` 显示 erofs，挂载选项含 `ro`。
- 切槽后版本变化，`/etc`/data 仍是同一个卷。
- 坏 root LV 不影响另一个槽；LVM 阶段失败进 recovery。

## 4. Interfaces

| 接口 | 说明 |
|---|---|
| `/dev/system/root_a` | A 槽标准 LVM 路径 |
| `/dev/system/root_b` | B 槽标准 LVM 路径 |
| `root=... rootfstype=erofs` | UKI cmdline |
| `mkfs.erofs` | 构建 root LV 镜像 |
| `keel-update` | 写非活动槽（F-003） |

## 5. Design

- 每个 root LV 2 GiB；erofs 内容通常 300–600 MiB，留余量。
- 安装时 `mkfs.erofs /dev/system/root_a rootfs/`。
- cmdline 示例：

```text
root=/dev/system/root_a ro rootfstype=erofs
systemd.gpt_auto=no panic=-1 panic_on_oops=1
console=tty0 console=ttyS0,115200
```

- LVM 标准路径 `/dev/system/root_a`；`/dev/mapper/system-root_a` 是底层 dm 节点，不作为默认。
- initrd 必须 `vgchange -ay system` + `vgmknodes`，再挂 root。
- UKI 由 `ukify` 生成，包含 `.osrel`、`.cmdline`、`.ucode`。
- root LV 重建：`lvremove`/`lvcreate` 或 `lvresize` + `mkfs.erofs`；不能在线 grow erofs。

## 6. Failure modes / recovery

| 失败 | 处理 |
|---|---|
| `vgchange` 失败 | recovery 分区 |
| root LV 挂不上 | recovery |
| 槽内容损坏 | 切另一个槽；recovery |
| 写槽写到一半 | 旧槽仍可启动；更新器拒绝半个 UKI |
| 误写活动槽 | 禁止；更新器先读 `/proc/cmdline` 判断当前槽 |

## 7. Acceptance criteria

- [ ] `findmnt /` = erofs，`ro`。
- [ ] `lvs` 显示 `root_a`/`root_b`。
- [ ] 手动切槽后，`/proc/cmdline` 的 `root=` 与当前槽一致。
- [ ] 坏 B 槽时，A 槽能启动。
- [ ] LVM 失败时能自动进 recovery。
- [ ] `/etc` 和 data 在切槽后保持不变。

## 8. Open questions / ADR links

- 布局：[ADR-0012](../decisions/ADR-0012-system-vg.md)。
- recovery：[ADR-0014](../decisions/ADR-0014-recovery-partition.md)。
- root 2G 是否够：A-010。

## 9. Test plan

E2：`mkfs.erofs` → LVM root 启动 → `findmnt`；切槽；坏槽演练；LVM 失败进 recovery。
E3：真机 NVMe 上重复。

## 10. Changelog

| 日期 | 变更 |
|---|---|
| 2026-11-10 | 初稿（物理分区） |
| 2026-11-13 | 改为 system VG 的 root LV；路径 `/dev/system/*` |
