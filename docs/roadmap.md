# 版本规划与 gate

> 状态：draft | 更新：2026-11-13
> 版本号是计划，不是承诺。每个版本只加一层；不通过 gate 不进入下一个。

## 1. 原则

1. **Walking skeleton first**：先让系统能启动、能登录、能重启，再加功能。
2. **一个版本一层**：不要同时改分区、initrd、UKI、安装器、回滚。
3. **每个 gate 有可观察证据**：`findmnt`、`lvs`、`bootctl list`、`efibootmgr`、`journalctl -b`。
4. **不做日期承诺**：只做依赖顺序和 gate。
5. **保留 known-good 槽**：任何更新都不覆盖两个槽。
6. **root 在 LVM 后，recovery 是 v0.1 的一部分**：没有 recovery 的 LVM root 不可接受。

## 2. 版本总表

| 版本 | 主题 | 特征 | Gate |
|---|---|---|---|
| v0.1 | walking skeleton | F-001, F-002, F-004, F-015, F-005(P0), F-006, F-012(基础) | QEMU 登录；root/etc/data 挂载正确；LVM 失败进 recovery；5 次重启 |
| v0.2 | 引导链 | F-005(P1), F-003(手动 A/B), F-012(USB/recovery UKI) | UKI + systemd-boot；手动切槽；10 次重启 |
| v0.3 | 安装与回滚 | F-003(自动), F-007, F-011, F-012(完整) | 空盘安装；破坏 B 槽自动回 A；recovery 演练通过 |
| v0.4 | 用户态 | F-008, F-013, F-014 | podman hello-world；状态可读；备份可恢复 |
| v1.0 | 稳定 | 收口、长跑、文档 | 真服务器连续运行一周；断电/重启 10 次 |
| future | 扩展 | F-009 VFIO, F-010 Secure Boot/verity, data fs zfs | 单独设计，不阻塞 v1 |

## 3. v0.1 walking skeleton

**目标**：在 QEMU 里从零启动到 multi-user：

- `system` VG 的 `root_a`（erofs ro）。
- `system/etc`（ext4）。
- data 的 `var`/`home` 子卷（btrfs）。
- 物理 recovery 能兜底。

包含：

- F-001 最小基底（Buildroot + kernel + rootfs + 串口）。
- F-002 erofs root LV（两个 LV 都创建；先启动 A）。
- F-004 system VG（root_a/root_b/etc）。
- F-015 data 分区（var/home）。
- F-005 P0（脚本 initrd）。
- F-006 headless（串口 + 有线 + SSH）。
- F-012 基础 recovery（分区 + initrd fallback；UKI 在 v0.2）。

Gate：

- `findmnt -R /`：`/` erofs ro；`/etc` ext4；`/var`/`/home` btrfs；`/boot` vfat。
- `lvs`：`root_a`、`root_b`、`etc` active。
- `cat /etc/machine-id` 非空；重启两次不变。
- `systemctl --failed` 为空。
- 连续 5 次重启，无 emergency。
- 改 `/etc/hostname` 后重启仍在。
- 破坏 VG 元数据，能自动进 recovery 并 `vgcfgrestore`。
- data 挂不上时能进 recovery。

不包含：UKI A/B 完整回滚、自动更新、安装器、podman、zram。

## 4. v0.2 引导链

**目标**：把 kernel/initrd/cmdline 打包成 UKI，放 ESP，用 systemd-boot 启动 A/B；手动切槽。

包含：

- F-005 P1（systemd initrd units）。
- F-003 手动 A/B（`stage`/`switch`，先不自动回滚）。
- F-012 USB rescue + recovery UKI（基础）。

Gate：

- `bootctl list` 看到 `keel-a.efi`、`keel-b.efi`、`keel-recovery.efi`。
- 手动 `bootctl set-default keel-b.efi` 后重启进入 B 槽；`findmnt /` 是 erofs ro。
- `keel-update stage` 能写非活动 LV；ESP 里有 `keel-b+3.efi`。
- 连续 10 次重启，无 emergency。
- `keel.recovery=1` 能进 recovery。
- 破坏 B 槽 root，能切回 A。

不包含：自动回滚、安装器、podman、zram。

## 5. v0.3 安装与回滚

**目标**：空盘安装；更新失败自动回旧槽；救援演练通过。

包含：

- F-003 自动回滚（boot counting + `systemd-bless-boot` + `panic=-1` + watchdog + emergency timer）。
- F-007 zram。
- F-011 安装器（GPT/LVM/btrfs/recovery/`bootctl install`）。
- F-012 完整救援（recovery + USB + LVM/data 备份）。

Gate：

- 空盘安装 → 首启 → 更新 → 破坏 B 槽 → 重启自动回 A。
- 三类失败演练：panic、PID1 冻住、停在 emergency。
- 救援演练：删 `/etc`、写坏 UKI、破坏 VG 元数据、清空 ESP、data 挂不上，都能恢复。
- 连续 10 次重启；`/etc` 不丢。
- `/var` 写满，`/etc` 仍可写。

不包含：podman、状态工具、备份工具。

## 6. v0.4 用户态

**目标**：podman 能跑；状态可读；备份可恢复。

包含：

- F-008 podman（rootful + host network 起步）。
- F-013 状态工具（当前槽、版本、挂载、ESP/system VG/data 空间、上次更新）。
- F-014 备份（`/etc`、ESP、LVM 元数据、data）。

Gate：

- `podman run --rm hello-world` 成功；重启后 `podman images` 还在。
- `keel-status` 输出当前槽、版本、挂载、空间。
- 从备份恢复 `/etc`、ESP、VG 元数据、data，系统能启动。
- 宿主仍然是最小系统（没有桌面/编译器/包管理器）。

## 7. v1.0 稳定

**目标**：目标服务器连续运行一周；断电/重启 10 次；文档收口。

Gate：

- 连续运行 7 天，无 emergency、无 fs error。
- 断电 10 次，能启动；`/etc`/data 不丢。
- 更新 5 轮，A/B 交替；每轮都能回滚。
- 救援演练 5 项全过。
- 文档中的“未验证”要么有证据，要么明确标注。

## 8. future

- F-009 VFIO：设备直通；需要 IOMMU、`vfio-pci`、QEMU/libvirt；不阻塞 v1。
- F-010 Secure Boot + dm-verity：会推翻 v1 的“不签名”决策；需要新 ADR。
- data fs zfs：见 Q-0008；不在 v1。

## 9. Definition of done（每个 feature）

一个 feature 算 done，必须同时满足：

1. 代码/配置已合并。
2. 文档状态改为 `done`，验收命令和证据写进 `verification.md`。
3. 失败模式有记录；救援路径可用。
4. 不违反 `lessons.md` 中适用的条目。
5. 没有引入新的“只有作者知道”的隐式约定。

## 10. Gate 规则

- 不通过当前 gate，不开始下一个版本的功能。
- 任何“看起来成功”的步骤，必须有可观察证据。
- 出现“命令返回 0 但状态不对”的情况，先修验证方法，再继续。
- `feat/*` / `refactor/*` 先合设计 PR；实现 PR 必须通过 lint + unit；涉及启动/存储再加 build + smoke。
- `main` 必须保持 Green；tag 必须通过 release workflow + `verification.md` 的真机记录。
- 详细流程见 [`workflow.md`](workflow.md)，测试见 [`testing.md`](testing.md)，CI 见 [`ci.md`](ci.md)。
