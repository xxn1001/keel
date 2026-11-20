# 验证台账

> 状态：living document | 更新：2026-11-18
> 规则：**没有环境 + 命令输出，不写“已验证”。** 文档确认只写“doc-confirmed”。

## 1. 环境分级

| ID | 环境 | 能做什么 | 不能做什么 |
|---|---|---|---|
| E0 | 仅文档/静态检查 | 读 man、`systemd-analyze verify`、编译小工具、review | 启动内核、分区、LVM、erofs 挂载、UKI |
| E1 | QEMU TCG（无 KVM） | 启动、挂载、systemd、更新、回滚（慢） | 性能/真机固件相关 |
| E2 | QEMU KVM | 同 E1，接近真机速度 | 真机固件/磁盘/网卡 |
| E3 | 真机（目标服务器） | 全部 | — |

## 2. 状态词

| 状态 | 含义 |
|---|---|
| `untested` | 没测过 |
| `doc-confirmed` | 只查了文档/源码，没有运行 |
| `static-checked` | 静态检查/编译通过，没有启动 |
| `E1-pass` / `E2-pass` / `E3-pass` | 在对应环境通过，有证据 |
| `failed` | 测过，失败 |
| `blocked` | 缺环境/硬件 |

## 3. 可用的验证环境

这一节记录"哪些环境做过什么"，**不是规范**。换机器、换人另起一行，不要覆盖旧记录。

| 环境 | 实际用它做过什么 | 能作为什么证据 |
|---|---|---|
| E0 文档沙箱 | Android proot，aarch64，f2fs；无 `/dev/kvm`、`/dev/loop`、qemu、lvm、mkfs.erofs、ukify、bootctl | 只能 `static-checked`；**不能**作为启动、分区、LVM、erofs、UKI、回滚的证据 |
| E2 构建机 | CachyOS x86_64，QEMU 11.1.3，`/dev/kvm` 可用，Buildroot 2025.02.19（W-0 2026-11-15，W-1 2026-11-17） | 可以作为启动类证据，但只对**当次记录**有效 |

"当前环境"不是仓库级事实：同一份文档可能同时由 E0 的人审、E2 的机器跑。
写证据时以第 8 节的记录为准，不要靠本节推断"现在能测什么"。

## 4. 假设台账

| ID | 假设 | 状态 | 环境 | 验证方法 | 证据 |
|---|---|---|---|---|---|
| A-001 | LVM LV 上 `mkfs.erofs`，`root=/dev/system/root_a rootfstype=erofs` 能挂 | E2-pass | E2 | `mkfs.erofs --all-root /dev/system/root_a`；`mount -t erofs`；`findmnt /`；`dmesg` | mkfs.erofs 1.9.4 rc=0；`findmnt /` erofs ro；`dump.erofs` 4096/2652；[W-1](evidence/2026-11-17-w1-storage.md) |
| A-002 | systemd initrd 里 `vgchange -ay system` → root → etc → data 顺序能跑通 | untested | E1/E2 | QEMU 串口 + `systemd.log_level=debug`；`systemctl list-jobs` | P0 busybox 等价路径 E2-pass；systemd initrd（P1）未测；[W-1](evidence/2026-11-17-w1-storage.md) |
| A-003 | `systemd-sysupdate` 的 `Type=partition` 语义 | doc-confirmed | E0 | `sysupdate.d(5)`：只支持 GPT 分区，不支持 LVM；v1 不用 | man page |
| A-004 | OVMF 下 UKI + systemd-boot 能启动 A/B/recovery，`bootctl list` 看到三个条目 | untested | E1/E2 | QEMU + OVMF；`bootctl list`；`efibootmgr -v` | A/B E2-pass；recovery UKI 不在 W-2；[W-2](evidence/2026-11-18-w2-boot.md) |
| A-005 | `vgcfgrestore` 能从 ESP 的备份救回 `system` VG | untested | E1/E2 | 破坏 VG 元数据；recovery；`vgcfgrestore -f /boot/lvm/system-... system` | — |
| A-006 | `/etc` LV 在 PID1 读 `/etc` 之前挂好，machine-id 稳定 | E2-pass | E2 | `findmnt /etc`；`cat /etc/machine-id`；重启两次比对 | 5 次正常启动 machine-id 一致；`/etc` ext4 rw；[W-1](evidence/2026-11-17-w1-storage.md) |
| A-007 | boot counting + `systemd-bless-boot` 在 UKI 命名（`keel-b+3.efi`）下工作 | E2-pass | E2 | 坏 B 槽；重启；`bootctl list` 看 tries-left | B+2 -> B+1-1 -> B+0-2；bless 生效；repair 还原 +10；[W-2](evidence/2026-11-18-w2-boot.md) |
| A-008 | 串口 getty 和 SSH 都能进；断网不影响启动 | untested | E1/E2/E3 | `-serial mon:stdio`；`systemctl status serial-getty@ttyS0`；`ssh` | — |
| A-009 | Buildroot 的 systemd 是否带 `systemd-boot`/`bootctl`/`systemd-bless-boot`/`ukify` | doc-confirmed | E0 | 2025.02.19 源码检查 | systemd 256.17；`BR2_PACKAGE_SYSTEMD_BOOT` 存在；目标 `ukify` disabled；[W-0](evidence/2026-11-15-w0-skeleton.md) |
| A-010 | 2 GiB root LV 在 P4（podman 进 `/usr`）后仍够用 | untested | E0/E2 | 构建后 `du -sh`；`df -h /`；留 30% 余量 | — |
| A-011 | Buildroot 有 `zram-generator` 或可用最小 unit 替代 | doc-confirmed | E0 | `make menuconfig` 搜 `zram`；没有就写 C unit | man page |
| A-012 | `/etc` ext4 LV 的 `lvextend` + `resize2fs` 在线扩容 | untested | E1/E2 | `lvextend -L +512M system/etc`；`resize2fs`；`df -h /etc` | — |
| A-013 | thick snapshot 能备份/恢复 `/etc` | untested | E1/E2 | `lvcreate -s`；`lvconvert --merge`；对比文件 | — |
| A-014 | rootful podman + host network 能在最小 rootfs 跑 | untested | E1/E2 | `podman run --rm hello-world`；`podman info` | — |
| A-015 | ESP 上的 LVM 元数据备份在 recovery 环境可读 | untested | E1/E2 | recovery 挂 ESP；`vgcfgrestore -f` | — |
| A-016 | fstab 只放注释时，systemd 不会重复挂载/fsck | untested | E1/E2 | `systemctl list-units --type=mount`；`journalctl -b`；`findmnt` | — |
| A-017 | LVM/root/etc/data 失败时 initrd 能自动进 recovery | untested | E1/E2 | 分别注入失败；观察串口；`switch_root` | — |
| A-018 | data btrfs 的 `var`/`home` 子卷能在 initrd 挂载 | E2-pass | E2 | `mkfs.btrfs`；`subvol=`；`findmnt` | `findmnt -R /` 显示 `/dev/vda4[/var]` 与 `[/home]` 为 btrfs；[W-1](evidence/2026-11-17-w1-storage.md) |
| A-019 | 写满 `/var` 不影响 `/etc`，但会影响 `/home` | untested | E1/E2 | 填 data；`df`；写 `/etc`/`/home` | — |
| A-020 | `btrfs send` 到 USB 能恢复 `var`/`home` | untested | E1/E2 | send/receive；对比文件 | — |
| A-021 | `keel.fail=<step>` 注入让 initrd 走到预期分支（vglv/root/etc/data/esp） | E2-pass | E2 | 分别注入；串口找 `keel: injecting failure at <step>`；`/run/keel/fail.*` | 5 个注入均命中；前四个落 initrd shell，esp 继续到 multi-user；[W-1](evidence/2026-11-17-w1-storage.md) |
| A-022 | 设备不出现时 initrd 在超时预算内失败并进 recovery，不挂死 | untested | E1/E2 | `keel.timeout=root:5` + 拿掉 root 设备；用串口时间戳计时 | — |
| A-023 | ESP 不可写时仍启动成功并写 `/var/lib/keel/boot-ok`；ESP 恢复后 tries 被还原成 `+10` | E2-pass | E2 | `keel.fail=esp`；`cat /var/lib/keel/boot-ok`；修好 ESP 后 `bootctl list` | ESP 失败仍到 multi-user，boot-ok 有记录；下次启动 repair 还原 B+10；[W-2](evidence/2026-11-18-w2-boot.md) |
| A-024 | 所有条目都是 bad 时 systemd-boot 仍会启动其中一个，不会彻底不启动 | doc-confirmed | E0 | systemd-boot 文档 Boot Counting 一节 | 文档原文 |
| A-025 | 非法 `keel.*` 参数不改变启动路径：拼错、未知值、超范围一律忽略并警告，只有非法 `root=` 进 recovery | untested | E1/E2 | 分别注入 `keel.xxx=1`、`keel.fail=bogus`、`keel.timeout=root:abc`、`keel.timeout=root:0`、`keel.recovery=true`；观察串口与是否仍到 multi-user | — |

## 5. 特征测试矩阵

| Feature | 最小验证 | 环境 |
|---|---|---|
| F-001 | 启动到 multi-user；串口登录；5 次重启 | E1/E2 |
| F-002 | `findmnt /` erofs ro；LVM root；切槽；坏槽 | E1/E2 |
| F-003 | `keel-update stage`；切槽；破坏 B；自动回 A | E2 |
| F-004 | `lvs`；`findmnt /etc`；`/etc` 持久；fstab 注释 | E1/E2 |
| F-005 | P0 脚本 → P1 units；顺序不变；失败进 recovery | E1/E2 |
| F-006 | 串口 getty；SSH；拔网线不影响启动 | E1/E2/E3 |
| F-007 | `swapon --show` 显示 zram；内存压力测试 | E1/E2 |
| F-008 | `podman run --rm hello-world`；重启后镜像在 | E2/E3 |
| F-009 | future：IOMMU + `vfio-pci` + VM 直通 | E3 |
| F-010 | future：Secure Boot + verity | E3 |
| F-011 | 空盘安装 → 首启 → 重启 | E2 |
| F-012 | recovery fallback；五项救援演练 | E2 |
| F-013 | `keel-status` 输出槽/版本/挂载/空间 | E2 |
| F-014 | 备份 → 恢复 `/etc`/ESP/VG/data | E2 |
| F-015 | data 子卷挂载；`/var` 满不影响 `/etc`；send | E1/E2 |

## 6. 关键命令

```sh
findmnt -R /
findmnt /etc /var /home /boot
lvs -a -o +devices
pvs -o +pv_name,vg_name
vgs system
bootctl list
bootctl status
efibootmgr -v
systemctl --failed
journalctl -b -p err
cat /etc/machine-id
swapon --show
df -h / /etc /var /home /boot
btrfs subvolume list /var
btrfs filesystem usage /var
btrfs scrub status /var
stat -c '%a %U:%G' /etc/ssh /etc/passwd /etc/shadow
podman info
```

## 7. 失败演练

| 演练 | 期望 |
|---|---|
| `root=` 指向不存在的 LV | initrd 进 recovery；不 panic 循环 |
| `vgchange -ay system` 失败 | recovery；root 不挂 |
| root LV 挂不上 | recovery |
| `/etc` LV 挂不上/内容坏 | recovery；从 factory/备份恢复 |
| data 挂不上 | recovery；仍能挂 system root |
| 写坏 B 槽 root | 重启自动回 A；`bootctl list` 可见 tries-left |
| 破坏 VG 元数据 | recovery；`vgcfgrestore` 从 ESP 恢复 |
| 清空 ESP | USB `bootctl install` + 复制 UKI |
| 填满 `/var` | `/etc` 仍可写；`/home` 受影响；更新被拒绝 |
| 拔网线 | 启动继续；SSH 失败；不触发回滚 |

## 8. 证据记录

每次验证一份文件，索引如下：

| 日期 | 工作项 | 环境 | 结果 | 证据 |
|---|---|---|---|---|
| 2026-11-15 | W-0 skeleton | E2 | PASS | [2026-11-15-w0-skeleton.md](evidence/2026-11-15-w0-skeleton.md) |
| 2026-11-17 | W-1 storage | E2 | PASS | [2026-11-17-w1-storage.md](evidence/2026-11-17-w1-storage.md) |
| 2026-11-18 | W-2 boot chain | E2 | PASS | [2026-11-18-w2-boot.md](evidence/2026-11-18-w2-boot.md) |

证据要求：

- 命令原文。
- 关键输出（不要只写“成功”）。
- 版本/构建号。
- 如果失败：现象、根因、下一步。

## 9. 规则

1. `doc-confirmed` 不是 `pass`。
2. `static-checked` 不是 `pass`。
3. 没有 E1/E2/E3 的启动输出，不写“可启动”。
4. 一个假设变了（工具版本/分区布局/内核 config），相关状态回到 `untested`。
5. 每次发布/里程碑收口，重跑本文件的 gate 项。
6. 架构调整后，旧的 A-001/A-002 等状态必须重置；不要沿用旧布局的“通过”。
