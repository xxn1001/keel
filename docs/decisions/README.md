# 决策记录（ADR）

> 状态：living index | 更新：2026-11-14
> 已接受的 ADR **不改正文**；新决定写新 ADR，旧的标 `Superseded by ADR-xxxx`。

## 索引

| ID | 决策 | 状态 | 日期 |
|---|---|---|---|
| [ADR-0001](ADR-0001-partition-layout.md) | 4 个物理分区；root 在 LVM 外 | superseded by 0012 | 2026-11-10 |
| [ADR-0002](ADR-0002-lvm-state.md) | LVM thick 状态池（etc/var/home） | superseded by 0012/0013 | 2026-11-10 |
| [ADR-0003](ADR-0003-etc-volume.md) | `/etc` 独立 ext4 LV，不用 overlay | superseded by 0012 | 2026-11-10 |
| [ADR-0004](ADR-0004-initrd-mount-order.md) | initrd 拥有 `/etc /var /home /boot` 挂载 | accepted; order extended by 0012/0014 | 2026-11-10 |
| [ADR-0005](ADR-0005-uki-boot.md) | ESP + systemd-boot + UKI；不设 boot_a/b | accepted | 2026-11-10 |
| [ADR-0006](ADR-0006-update-rollback.md) | 编译型 `keel-update` + boot counting 回滚 | accepted; slot path updated by 0012 | 2026-11-10 |
| [ADR-0007](ADR-0007-no-signature.md) | v1 不做签名/verity/Secure Boot | accepted | 2026-11-10 |
| [ADR-0008](ADR-0008-headless-scope.md) | v1 只做 headless 服务器、有线、串口 | accepted | 2026-11-10 |
| [ADR-0009](ADR-0009-zram-sizes.md) | zram swap；不建 swap LV；默认尺寸 | superseded by 0012/0013 for sizes | 2026-11-10 |
| [ADR-0010](ADR-0010-buildroot.md) | 构建系统用 Buildroot LTS | accepted | 2026-11-10 |
| [ADR-0011](ADR-0011-rescue-media.md) | 救援 = ESP recovery UKI + USB 双份 | accepted; extended by 0014 | 2026-11-10 |
| [ADR-0012](ADR-0012-system-vg.md) | `system` VG：root LV + `/etc` LV | accepted | 2026-11-13 |
| [ADR-0013](ADR-0013-data-partition.md) | 独立 data 分区承载 `/var` `/home` | accepted | 2026-11-13 |
| [ADR-0014](ADR-0014-recovery-partition.md) | recovery 分区 + initrd fallback | accepted | 2026-11-13 |
| [ADR-0015](ADR-0015-boot-failure-contract.md) | 启动尝试计数（tries=10）、`/var` 自愈标记、超时契约、`keel.fail=` 注入 | accepted | 2026-11-14 |
| [ADR-0016](ADR-0016-maintenance-in-recovery.md) | 安装/更新工具只放 recovery；`keel.mode=` 三入口；ESP 为写入口例外 | accepted | 2026-11-20 |
| [ADR-0017](ADR-0017-etc-baseline.md) | 出厂 `/etc` 基线在 `/usr/etc`；更新时按 ostree 规则三方合并 | accepted | 2026-11-23 |
| [ADR-0018](ADR-0018-system-root-tools.md) | system root 保留通用文件系统工具；只有维护工具住在 recovery | accepted | 2026-11-24 |

## 规则

- 一个 ADR 一个决定；不要把多个决定塞进一篇。
- 内容：Context / Decision / Consequences / Alternatives rejected / References。
- 已接受后只追加 `Superseded by`，不改结论。允许术语统一、错别字、失效链接、
  以及不改结论的 layout note，但必须在 PR 里单独说明。
- 被否决的提案也保留（`rejected`），理由比决定更有价值。
- 新 ADR 编号递增，不复用。
