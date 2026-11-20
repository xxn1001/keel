# v0.1 Walking Skeleton 设计

> 状态：draft | 更新：2026-11-14
> 这是**执行契约**，不是架构文档。架构见 [ADR-0010](decisions/ADR-0010-buildroot.md) /
> [ADR-0012](decisions/ADR-0012-system-vg.md) / [ADR-0013](decisions/ADR-0013-data-partition.md) /
> [ADR-0014](decisions/ADR-0014-recovery-partition.md) / [ADR-0015](decisions/ADR-0015-boot-failure-contract.md)。

## 1. 这个文档解决什么问题

[layout.md](layout.md) 和 [initrd.md](initrd.md) 描述了**目标状态**，但没说：

- v0.1 到底只承诺什么；
- 用什么顺序把它做出来；
- 每个阶段怎么算成功、怎么算失败；
- 失败时先查哪里。

结果就是"设计很完整，但没人知道明天该敲哪条命令"。本文补这一段。

## 2. v0.1 范围冻结

### 2.1 纳入

| 项 | 内容 | 对应 feature |
|---|---|---|
| 构建 | Buildroot + br2-external，出 kernel + initrd + rootfs | F-001 |
| 存储 | 4 分区 GPT：`esp` / `recovery` / `system`(LVM) / `data`(btrfs) | F-004, F-015 |
| root | `system/root_a` erofs ro；`root_b` 建好但不切 | F-002 |
| 可写配置 | `system/etc` ext4，initrd 里挂好 | F-004 |
| initrd | P0 shell 脚本；失败进 recovery | F-005, F-012 |
| recovery | 物理分区 + initrd 自动 fallback；ESP recovery UKI 在 v0.2 | F-012 |
| 引导 | UEFI + systemd-boot + UKI A/B | F-001, F-002 |

### 2.2 明确不做

| 不做 | 原因 | 何时 |
|---|---|---|
| 自动 A/B 更新与回滚 | 依赖 boot counting 实测，W-2 之后 | v0.2 |
| ESP 上的 recovery UKI | v0.1 的 fallback 直接挂 recovery 分区，不需要额外 UKI；它防的是 initrd 本身坏掉 | v0.2 |
| P1（systemd initrd） | 见 [Q-0011](open/Q-0011-initrd-p1.md) | 未定 |
| 安装器的交互界面 | 先只有非交互 | v0.3 |
| zram、podman、备份、状态工具 | 与启动链正交 | v0.3+ |
| 签名、dm-verity、Secure Boot | ADR-0007 已排除 | future |

**冻结的含义**：v0.1 的验收只看 2.1 的表。任何"顺手加一点"都不进这版。

## 3. 三个工作项

| ID | 名称 | 性质 | 合并 | 产出 |
|---|---|---|---|---|
| W-0 | br2-external 骨架 | 产品代码 | 是 | 能起到 shell 的镜像 |
| W-1 | 存储栈 spike | 一次性实验 | **否** | A-001/002/006/018 的结论 |
| W-2 | 引导链 spike | 一次性实验 | **否** | A-004/007 的结论 + boot counting 行为 |

顺序：**W-0 → W-1 → W-2**。W-2 必须在 W-1 之后再开：两者失败原因不重叠，混在一起时
分不清是"LVM 没激活"还是"UKI 段拼错"。

## 4. W-0：br2-external 骨架

### 4.1 目标

一个能启动到 shell 的最小镜像，存储还是**单分区单文件系统**。只证明工具链通。

### 4.2 验收

```sh
make -C vendor/buildroot BR2_EXTERNAL="$PWD" O="$PWD/out" keel_qemu_x86_64_defconfig
make -C out
```

产物：`out/images/bzImage`、`out/images/rootfs.cpio`、`out/images/rootfs.tar`。

启动后：串口出现登录提示，`cat /etc/os-release` 显示 keel2，`systemctl --failed` 为空。

### 4.3 放弃条件

- Buildroot 的 systemd 版本 < 254：换 LTS 或在 br2-external 里打补丁。
- 内核缺 `CONFIG_EROFS_FS` / `CONFIG_DM_*`：在 defconfig 里开，不算放弃。
- 出镜像后 20 GiB 磁盘不够：改用 `BR2_TARGET_ROOTFS_EXT2` 之外的裁剪，仍不算放弃。

## 5. W-1：存储栈 spike

### 5.1 目标

证明"4 分区 + LVM + erofs root + ext4 etc + btrfs data + P0 脚本能启动到 multi-user"。

不碰 UEFI。用 `-kernel` 直接启动，缩短迭代：

```sh
qemu-system-x86_64 -m 2048 -nographic \
  -kernel out/images/bzImage \
  -initrd out/images/rootfs.cpio \
  -append "console=ttyS0 root=/dev/system/root_a rootfstype=erofs panic=-1" \
  -drive file=disk.qcow2,if=virtio,format=qcow2
```

### 5.2 前置

- W-0 完成。
- `disk.qcow2` 由安装器脚本在 **guest 内**生成（见 [Q-0010](open/Q-0010-image-build-harness.md)）；
  host 上不需要 loop，也不需要 root。

### 5.3 步骤

1. 起 W-0 的镜像，挂一块空盘，跑 `keel-install --disk /dev/vda`。
2. 重启，走 P0 initrd。
3. 逐条对验收。

### 5.4 验收

全部满足才算 PASS：

| # | 检查 | 期望 |
|---|---|---|
| 1 | `findmnt -R /` | `/` erofs `ro`；`/etc` ext4 `rw`；`/var` `/home` btrfs 子卷；`/boot` vfat |
| 2 | `lvs` | `root_a`、`root_b`、`etc` 都 active |
| 3 | `cat /etc/machine-id` | 非空，重启两次不变 |
| 4 | `systemctl --failed` | 空 |
| 5 | 串口 | 能登录 |
| 6 | 连续 5 次重启 | 都到 multi-user，无 emergency |
| 7 | `keel.fail=vglv` | 进 recovery，不半启动 |
| 8 | `keel.fail=root` | 进 recovery |
| 9 | `keel.fail=etc` | 进 recovery |
| 10 | `keel.fail=data` | 进 recovery |
| 11 | `keel.fail=esp` | 继续启动，`/boot` 未挂，警告可见 |

第 7-11 项依赖 `keel.fail=` 注入开关，见 [ADR-0015](decisions/ADR-0015-boot-failure-contract.md)。

### 5.5 放弃条件

出现任一条就**停下来写结论**，不要继续堆时间：

- `mkfs.erofs` 无法直接写 LV 路径（只能先出镜像文件再 `dd`）：重开 ADR-0002/0012。
- 纯 busybox 的 initrd 无法可靠激活 VG（必须带 udev），导致 initrd 体积或复杂度超出预期：记结论，改 [Q-0011](open/Q-0011-initrd-p1.md) 的取舍。
- erofs 挂在 LV 上时内核报 `EUCLEAN` 或只读异常。

### 5.6 时间盒

W-1 单次不超过 **2 个工作日**。到点没跑到 multi-user 就写结论，把卡点记进
[verification.md](verification.md) 的证据栏，下一轮再开。

## 6. W-2：引导链 spike

### 6.1 目标

证明"OVMF → systemd-boot → UKI A/B → initrd"这条链，以及 boot counting 在异常下的行为。

### 6.2 验收

| # | 检查 | 期望 |
|---|---|---|
| 1 | `bootctl list` | 两个计数条目：`keel-a+10.efi`、`keel-b+10.efi`（recovery UKI 在 v0.2 加） |
| 2 | 从 A 启动成功 | `bootctl list` 里 A 变成 good（无 `+N`），B 仍是 indeterminate |
| 3 | 把 B 的 root LV 写坏，切到 B | 每次尝试 tries 递减；到 0 后自动回 A |
| 4 | ESP 不可挂载 | 系统仍启动成功；`/var/lib/keel/boot-ok` 记录到这次启动 |
| 5 | 恢复 ESP 后重启 | tries 被修复回 `+10`（自愈），见 ADR-0015 |
| 6 | `keel.recovery=1` | 正常 UKI 启动后由 initrd 跳进 recovery 分区；**tries 会减一**，靠 `keel-boot-repair` 在下一次健康启动还原 |

第 3 项为了省时间，可以把 tries 临时设成 `+2` 再测。

### 6.3 放弃条件

- UKI 无法在没有 `ukify` 的情况下组装：退到 `objcopy` 手工拼 section，不算放弃，但要记下命令行。
- systemd-boot 无法在 OVMF 下识别计数条目：改回普通命名，回滚机制改由 `keel-update` 自己记账，重开 ADR-0006。

## 7. 失败归因表

启动卡住时按这张表查，不要凭感觉改代码。

| 症状 | 先查 | 常见原因 |
|---|---|---|
| 串口完全没输出 | `-append` 里的 `console=ttyS0`；`earlycon` | cmdline 没带串口 |
| 卡在 `vgchange` 之前 | `ls /dev/vd*`；`dmesg` 里搜 virtio | initrd 缺 `virtio_blk` 或没有 devtmpfs |
| `vgchange` 报 No volume groups found | `lvm.conf` 的 `filter`；`pvscan` | 设备节点没出现就扫了 |
| root 挂载返回 EINVAL | `dmesg` 里搜 erofs；LV 大小 | 镜像不完整，或 `mkfs.erofs` 写到了错误的设备 |
| `/etc` 挂上后 systemd 重复挂载 | `systemctl list-units --type=mount`；fstab | fstab 里写了核心挂载 |
| `switch_root` 后无输出 | `ls /sysroot/sbin/init`；`file` | rootfs 里没有 systemd，或架构不符 |
| 每次都进 recovery | `keel.fail` 是否残留；`/proc/cmdline` | 上一次注入的参数留在了 UKI 里 |

## 8. 证据格式

每个 spike 的结论都按这个格式记，写进 [verification.md](verification.md) 或该 spike 的
`RESULT.md`。没有命令输出的"验证通过"一律不算。

```text
## W-1 / 2026-11-20 / E2 (QEMU KVM x86_64)
build: buildroot <version>, defconfig keel_qemu_x86_64_defconfig, commit <sha>
branch: spike/s1-storage @ <sha>
result: PASS
evidence:
  - findmnt -R /        (paste)
  - lvs                 (paste)
  - dmesg | grep erofs  (paste)
verdict: A-001 E2-pass, A-002 E2-pass, A-006 E2-pass, A-018 E2-pass
notes: <意外发现，或与本文不符的地方>
```

spike 分支**不合并**，但也不删除；分支名 + commit sha 必须写进结论，方便复查。

## 9. 不在本文范围

- W-0 之前的工具选择（Buildroot 版本）：[Q-0003](open/Q-0003-buildroot-components.md)。
- 安装器的完整流程：F-011。
- 更新的原子性与回滚策略：F-003、ADR-0006。
