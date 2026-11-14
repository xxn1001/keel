# 术语表

> 状态：living document | 更新：2026-11-14
> 文档用中文；代码/标识符用英文。这里是两者的对照。

| 中文 | English / identifier | 说明 |
|---|---|---|
| 基底 | base | 只读的系统根，不含用户软件 |
| 槽 | slot | A/B 之一，对应一个 root LV + 一个 UKI |
| 根逻辑卷 | root LV | `system/root_a` / `system/root_b`，erofs |
| 系统卷组 | system VG | LVM VG `system`，承载 root_a/root_b/etc |
| 数据分区 | data partition | GPT `data`，btrfs，承载 var/home |
| 逻辑卷 | logical volume (LV) | `system/root_a`、`system/etc` |
| 物理卷 | physical volume (PV) | `system` 分区 |
| 卷组 | volume group (VG) | `system` |
| 厚置备 | thick | 创建时分配固定 extents |
| 薄置备 | thin | 共享 thin pool，可超卖；keel2 不使用，LV 全部 thick |
| 子卷 | subvolume | btrfs 子卷，如 `var`、`home` |
| 统一内核镜像 | Unified Kernel Image (UKI) | kernel + initrd + cmdline + microcode |
| 引导加载器 | boot loader | systemd-boot |
| EFI 系统分区 | EFI System Partition (ESP) | FAT，挂 `/boot` |
| 初始化内存盘 | initrd / initramfs | 启动早期挂 root/etc/data |
| 切根 | switch_root | initrd 切换到真正 root |
| 只读根 | read-only root | erofs 挂 `ro` |
| 可写层 | writable layer | `/etc` LV + data 子卷，不是 overlay upper |
| 工厂配置 | factory `/etc` | `/usr/share/factory/etc`，用于 diff |
| 播种 | seed | 安装时把镜像 `/etc` 复制到 `system/etc` |
| 救援分区 | recovery partition | 物理 `recovery`，erofs ro，独立救援 rootfs |
| 救援模式 | rescue mode | `keel.recovery=1`，进 recovery |
| 救援 UKI | recovery UKI | ESP 上的 `keel-recovery.efi` |
| 更新器 | updater | `keel-update`，编译型 |
| 暂存 | stage | 写非活动 root LV + UKI + set-oneshot |
| 切换 | switch | 改默认槽 |
| 回滚 | rollback | 回到旧槽 |
| 启动计数 | boot counting | 文件名里的 `+N` / tries-left |
| 祝福 | bless | `systemd-bless-boot` 把候选标为 good |
| 一次性启动 | one-shot | `bootctl set-oneshot` |
| 看门狗 | watchdog | 硬件/软件定时复位 |
| 内存压缩交换 | zram | 压缩 RAM 作为 swap |
| 容器 | container | podman；不是用户态命名空间 |
| 直通 | passthrough | VFIO，把 PCI 设备交给 VM |
| 门禁 | gate | 版本/阶段的验收条件 |
| 决策记录 | ADR | Architecture Decision Record |
| 特征 | feature | 一个能力，`F-xxx` |
| 未决问题 | open question | `Q-xxxx` |
| 经验 | lesson | `L-xxx` |
| 假设 | assumption | `A-xxx` |
| 环境 | environment | `E0`–`E3` |
