# initrd

> 状态：accepted | 更新：2026-11-24
> 目标：在 `switch_root` 之前挂好 root、`/etc`、`/var`、`/home`、`/boot`。
> 任何关键挂载失败：进 physical recovery，不继续半启动。
> 超时预算与故障注入见 [ADR-0015](decisions/ADR-0015-boot-failure-contract.md)；
> v0.1 的执行顺序见 [design-v01-skeleton.md](design-v01-skeleton.md)。

## 1. 目标

- 激活 `system` VG。
- 挂 root LV（erofs，`ro`）。
- 挂 `/etc`（ext4）、`/var`/`/home`（data btrfs 子卷）。
- 挂 ESP 到 `/boot`。
- 挂 `/proc`、`/sys`、`/dev`。
- `switch_root` 到真正 systemd。
- 失败时挂 `recovery` 分区并 `switch_root` 到救援 rootfs。

非目标：网络、解密、verity。v1 不做。

## 2. 两个阶段

| 阶段 | 形态 | 状态 |
|---|---|---|
| P0 | 一个最小脚本 | v0.1 的实现 |
| P1 | systemd units | **待评估，非承诺**：见 [Q-0011](open/Q-0011-initrd-p1.md) |

原来的路线是"P0 临时、P1 最终形态"。现在改成：P0 至少用到 v0.3，
P1 是否值得做单独评估。原因见 Q-0011（主要是挂死时的可诊断性）。

P0 脚本仍然是脚本，不允许长成第二个 shell 状态机：只做挂载和失败判定，
不做状态、不做版本比较、不做更新。

超时和故障注入**不是 P1 的预备动作**，是 P0 本身必须具备的能力。

## 3. P0：最小脚本

P0 是一个顺序脚本，只做挂载和失败判定。代码位置：

| 文件 | 作用 |
|---|---|
| `board/common/initrd/init` | 只写启动顺序 |
| `board/common/initrd/lib/cmdline.sh` | 解析并校验 cmdline |
| `board/common/initrd/lib/discover.sh` | 按 GPT 分区名发现设备并建链接 |

行为清单：

1. 挂 `devtmpfs`、`proc`、`sysfs`。
2. 解析 `/proc/cmdline`；`root=` 非法时进 recovery（§5.3）。
3. 按 §3.1 发现 `system` 所在盘和 `recovery`/`data`/`esp`；发现失败掉 shell。
4. `keel.recovery=1` 直接进 recovery。
5. `vgchange --noudevsync -ay system`，然后 `vgmknodes`。
6. 依次挂 root、`/etc`、`/var`、`/home`，每步有超时；失败进 recovery。
7. 挂 ESP；失败只警告，继续启动。
8. `switch_root` 到 systemd。

要求：

- `set -eu`；关键挂载失败调用 recovery；每个等待步骤都有超时（ADR-0015）。
- `root=` 只接受 `/dev/system/root_a` 和 `/dev/system/root_b`；其他值进 recovery。
- `keel.fail`/`keel.timeout` 的校验见 §5.3；注入时必须打印
  `keel: injecting failure at <step>` 并在 `/run/keel/` 留标记。
- busybox 必须带 `timeout` applet；设备慢时发现重试到 `KEEL_T_LVM`，不新增第六个超时名字。

### 3.1 设备发现

只认 GPT 分区名，不认设备名。锚点是 `PARTNAME=system` 所在的那块盘：

1. 枚举 `/sys/class/block/*/uevent`，取 `DEVTYPE=partition` 且 `PARTNAME=system` 的分区。
2. 所属盘用 `basename(dirname(readlink -f /sys/class/block/<part>))` 得到，不按设备名裁剪。
3. 只在锚点那块盘上找 `recovery`、`data`、`esp`；其他盘上的同名标签一律忽略。
4. 锚点盘两块，或同一盘上某标签出现两次：打印候选，返回 3，不建链接；零锚点算缺失，由调用方重试。
5. 节点由 devtmpfs 提供，缺失时才用 uevent 的 `MAJOR`/`MINOR` 补建，再建
   `/dev/disk/by-partlabel/<label>` 链接。
6. 零锚点且 `blkid` 存在时，用 `blkid -t PARTLABEL=system -o device` 反推；
   仍找不到返回 3。

发现成功固定打印一行：

```text
keel: discover: disk=vda system=vda3 recovery=vda2 data=vda4 esp=vda1
```

缺失的标签留空。决定记录在 [Q-0012](open/Q-0012-initrd-device-discovery.md)。

### 3.2 退出码与日志

固定日志格式：

```text
keel: <step>: <message>
keel: <step>: timed out after <n>s
keel: warn: <message>
keel: error: <message>
```

退出码：

| 码 | 含义 |
|---|---|
| 0 | 不会出现；成功路径一定 `exec switch_root` |
| 1 | 进 recovery 失败，落 shell |
| 2 | `root=` 非法且无法进 recovery |
| 3 | 设备发现失败，落 shell |

只有 `root=` 非法会改变启动路径；其他 `keel.*` 参数非法时只警告并忽略（§5.3）。

## 4. P1：systemd units

> **本节是草案，不是 v0.1 承诺。** P1 是否做，见 [Q-0011](open/Q-0011-initrd-p1.md)；
> 如果做，失败触发方式见 [Q-0009](open/Q-0009-recovery-fallback.md)。

| unit | 作用 | 关键排序 |
|---|---|---|
| `lvm-activate.service` | `vgchange -ay system` | `Before=sysroot.mount sysroot-etc.mount` |
| `sysroot.mount` | 挂 root LV | `What=/dev/system/root_a`；`After=lvm-activate.service` |
| `sysroot-etc.mount` | 挂 `/etc` | `What=/dev/system/etc`；`After=sysroot.mount` |
| `sysroot-var.mount` | 挂 data `subvol=var` | `What=/dev/disk/by-partlabel/data`；`After=sysroot.mount` |
| `sysroot-home.mount` | 挂 data `subvol=home` | 同上 |
| `sysroot-boot.mount` | 挂 ESP | `What=/dev/disk/by-partlabel/esp`；`After=sysroot.mount` |
| `keel-recovery.service` | 失败时挂 recovery 并切根 | 各关键 mount 的 `OnFailure=` |
| `initrd.target` | initrd 终点 | `Wants=` 上述 mounts |
| `systemd-switch-root.service` | 切根 | `After=initrd.target` |

顺序：

```text
lvm-activate.service
  -> sysroot.mount
  -> sysroot-etc.mount
  -> sysroot-var.mount / sysroot-home.mount
  -> sysroot-boot.mount
  -> initrd.target
  -> systemd-switch-root.service
```

注意：

- `lvm-activate.service` 必须排在 `sysroot.mount` **之前**；root 现在依赖 LVM。
- `sysroot-etc.mount` 依赖 `sysroot.mount`；`/etc` 是 root 下的挂载点。
- `sysroot-var.mount`/`home` 依赖 `sysroot.mount`，不依赖 `/etc`。
- `keel-recovery.service` 由关键 unit 的 `OnFailure=` 触发；它挂 `PARTLABEL=recovery` 并 `switch_root`。
- `keel.recovery=1` 用 `ConditionKernelCommandLine=` 或最早的 oneshot 处理。
- initrd 的 `/etc/lvm/lvm.conf` 是 initrd 自己的，不依赖 root 的 `/etc`。
- 不要依赖 `rd.lvm.lv=`；自己写 unit/脚本。

## 5. 失败处理

| 失败点 | 默认超时 | 行为 |
|---|---|---|
| `vgchange` 失败或超时 | 30 s | recovery |
| root LV 挂不上或超时 | 15 s | recovery |
| `/etc` 挂不上或超时 | 15 s | recovery |
| data / `var` / `home` 挂不上或超时 | 15 s | recovery |
| ESP 挂不上或超时 | 10 s | 继续 + 警告；更新与 boot counting 不可用 |
| recovery 也挂不上 | — | shell / USB |
| `keel.recovery=1` | — | 直接 recovery |

原则：**关键挂载失败就停**。不要退回只读 root 的 `/etc` 继续启动。

### 5.1 超时是契约的一部分

"挂死"和"失败"在 headless 机器上的代价不同：失败可以自动处理，挂死只能靠人断电。
所以每个等待步骤都必须有超时，且超时按失败处理。

- 默认值见上表；真机慢盘用 `keel.timeout=<name>:<seconds>` 覆盖，不改代码。
- 覆盖只影响 initrd，不影响 recovery 里的操作。
- 超时后必须打印是哪一步、等了多久，便于事后判断是盘慢还是真坏。

### 5.2 启动成功标记（`/var`，不是 ESP）

`systemd-bless-boot` 要写 ESP 才能把条目标成 good。ESP 坏掉时，
一次完全成功的启动也会被 boot counting 记成失败。见
[ADR-0015](decisions/ADR-0015-boot-failure-contract.md)。

因此：

- `keel-boot-ok.service` 在启动成功后写 `/var/lib/keel/boot-ok`（槽名、boot id、时间）。
- `keel-boot-repair.service` 在早期检查：标记健康 + ESP 可写 + 条目名已坏，则用
  `bootctl` 把 `keel-<slot>` 恢复到 `+10`。
- 这一段**不在 initrd 里**，是正常运行时的 systemd 服务。

ESP 挂不上时 initrd 仍然继续启动，因为 ESP 故障不应该把一个还能跑的机器降级成救援模式。

### 5.3 cmdline 参数校验

手抖输错一个参数，不能让系统行为**静默改变**。规则：

| 输入 | 行为 |
|---|---|
| `keel.xxx=...`（未知键） | 打印 `keel: warn: unknown parameter keel.xxx, ignored`，继续正常启动 |
| `keel.fail=<未知值>` | 打印警告，忽略该注入，正常启动 |
| `keel.timeout=root:abc` | 打印警告，忽略该条，用默认值 |
| `keel.timeout=foo:30` | 打印警告，忽略未知 name |
| `keel.timeout=root:0` / `:99999` | 收敛到 `[1, 600]`，打印实际生效值 |
| `keel.recovery=1` | 只认精确的 `1`；`=true`/`=yes` 一律忽略并警告 |
| `keel.mode=<install\|rescue\|update>` | initrd **不消费**，原样透传给 recovery；不要当成未知参数警告 |
| `root=` 不在白名单 | 打印并进 recovery（这是唯一允许改变启动路径的非法输入） |
| 同一参数出现两次 | 最后一个生效，并打印冲突警告 |

原则：**只有 `root=` 非法才允许改变启动路径；`keel.*` 非法一律降级为"忽略 + 警告"。**

理由：[ADR-0015](decisions/ADR-0015-boot-failure-contract.md) 的 `keel.fail=` 和
`keel.timeout=` 是会写进 UKI cmdline 的，一次残留就会被当成正常配置执行。

## 6. recovery

- `recovery` 分区 1 GiB，erofs ro，BusyBox init + shell。
- ESP 上有独立 recovery UKI，cmdline：

```text
keel.recovery=1
keel.mode=rescue
```

- **不要写 `root=`。** P0 只接受 `root=/dev/system/root_a|root_b`（§5.3），
  `root=PARTLABEL=recovery` 会先触发一条 `keel: error: invalid root=`；而 initrd
  根本不使用这个值——`keel.recovery=1` 在挂任何东西之前就把控制权交给 recovery。

- 正常 initrd 在 LVM/root/etc/data 失败时自动 fallback。
- recovery 工具：`lvm2`、`e2fsprogs`、`btrfs-progs`、`erofs-utils`、`dosfstools`（`mkfs.vfat`，安装器要写 ESP）、`gdisk`（`sgdisk`）、`bootctl`、`mount`、`blkid`、`dmesg`。
- recovery 是 known-good，不随 A/B 更新自动更新；ESP recovery UKI + USB 仍保留。
- 详见 [F-012](features/F-012-rescue.md) / [ADR-0014](decisions/ADR-0014-recovery-partition.md)。

### 6.1 维护模式（`keel.mode=`）

recovery 树同时是安装介质和更新执行环境（[ADR-0016](decisions/ADR-0016-maintenance-in-recovery.md)）。
进去以后干什么，由 cmdline 决定：

| `keel.mode=` | 打包形态 | 启动条件 | 行为 |
|---|---|---|---|
| `install` | `recovery.cpio`（RAM） | 目标盘为空 | 跑 `keel-install`，写完提示重启 |
| `rescue`（缺省） | `recovery.erofs`（分区） | 任何情况 | 掉进 shell，工具齐全 |
| `update` | `recovery.erofs`（分区） | data 上有载荷 | 跑 `keel-update`，写完重启 |

两层参数不要混：

- `keel.recovery=1` 是 **initrd 层**的"别继续启动了，直接去 recovery"，由正常启动的
  initrd 消费（§3 的 `rescue()`）。
- `keel.mode=` 是 **recovery 层**的"你进去以后干什么"，由 recovery 自己的 `/sbin/init`
  消费。缺省 `rescue`，未知值按 `rescue` 处理并打印警告。

载荷位置（同一个文件的两个视角）：

| 视角 | 路径 |
|---|---|
| 运行中的系统 | `/var/lib/keel/staging/` |
| recovery（data 挂在 `/mnt/data`，`-o subvol=var`） | `/mnt/data/lib/keel/staging/` |
| 安装时（U 盘 / QEMU 第二块盘挂在 `/mnt/usb`） | `/mnt/usb/` |

## 7. initrd 内容

### 7.1 模块

- 存储：`erofs`、`ext4`、`btrfs`、`vfat`、`dm-mod`、`nvme`、`ahci`、`virtio_blk`。
- 输入/救援：`usbhid`、`usb-storage`、`xhci-hcd`。
- 串口：`8250`。
- 看门狗（P2）：硬件看门狗或 `softdog`。

### 7.2 工具

- `busybox` 或 systemd + udev。
- busybox 必须带 `timeout` applet（超时是契约，不是可选优化）。
- `lvm2`、`e2fsprogs`、`btrfs-progs`、`erofs-utils`。
- `mount`、`blkid`、`dmesg`。
- `/etc/lvm/lvm.conf`（最小配置）。

### 7.3 组装

- `out/target` 是唯一来源；initrd 和 recovery 都直接从这棵树取文件。
- `tools/mkinitrd.sh` 组装 `out/images/initrd.cpio`；`tools/mkrecovery.sh` 用同一棵
  recovery 树输出 `out/images/recovery.erofs` 和 `out/images/recovery.cpio`。
- `tools/lib/collect-deps.py` 用 PATH 里的 `readelf -d` 递归收集 NEEDED 闭包；
  缺库或缺少动态加载器时非零退出。
- `board/qemu/x86_64/post-image.sh` 调用上面两个脚本；工具和目录清单以脚本为准。
- cpio 为 newc，属主 0:0：优先 `cpio --owner=0:0`，否则用 fakeroot。

### 7.4 产物与 UKI

`out/images/` 的固定产物：

| 文件 | 用途 |
|---|---|
| `bzImage` | 内核，UKI 的 `.linux` |
| `initrd.cpio` | P0 initrd，UKI 的 `.initrd` |
| `rootfs.erofs` | system root 镜像 |
| `recovery.erofs` | recovery 分区 |
| `recovery.cpio` | 安装/维护时 RAM 启动 |
| `keel-a.efi`、`keel-b.efi` | A/B UKI |
| `manifest.txt` | sha256、字节数、文件名 |

`tools/mkuki.sh` 调用宿主 `ukify build`，`--stub` 显式指向目标树里的
`out/target/usr/lib/systemd/boot/efi/linuxx64.efi.stub`；不使用宿主自己的 stub。
至少要生成这四个段：

| 段 | 来源 |
|---|---|
| `.osrel` | `out/target/usr/lib/os-release` |
| `.cmdline` | 脚本生成 |
| `.linux` | `out/images/bzImage` |
| `.initrd` | `out/images/initrd.cpio` |

ukify 可能额外加 `.uname`、`.sbat`，属正常现象。

cmdline 两个槽只差 `root=`：

```text
root=/dev/system/root_a ro rootfstype=erofs console=tty0 console=ttyS0,115200 systemd.gpt_auto=no panic=-1
```

- 不加 `keel.fail=`/`keel.timeout=`；测试注入走 QEMU cmdline，不改产物。
- 产物名不带 `+N`。boot counting 的 `+N` 由安装器写 ESP 时加，v0.2 才验证。
- `mkuki.sh` 不自己算 VMA，也不写 image base；段布局由 ukify 处理。脚本依次查找
  `command -v ukify`、`/usr/lib/systemd/ukify`、`/usr/bin/ukify`，找不到就失败，
  不回退到手写实现。
- `board/qemu/x86_64/post-image.sh` 的顺序是 initrd → recovery → UKI → manifest；
  manifest 最后生成，保证哈希覆盖的是最终文件。
- `tools/qemu/run-uki-smoke.sh` 是测试装置：造 64 MiB vfat ESP，用 OVMF 启动
  systemd-boot 和 `keel-a.efi`，不参与安装器。

## 8. LVM 路径

- 标准路径：`/dev/system/root_a`、`/dev/system/etc`。
- `/dev/mapper/system-root_a` 是底层 dm 节点；不作为默认路径。
- P0 没有 udev 时：`vgchange --noudevsync -ay system` + `vgmknodes`。
- P1 有 systemd-udevd；仍然建议保留 `vgmknodes` 作为兜底。
- LV 名用下划线，避免 `/dev/mapper` 的 `--` 转义。
- **分区路径**（`/dev/disk/by-partlabel/*`）在无 udev 时不存在，`PARTLABEL=` 挂载选项
  busybox 也不支持。分区怎么找见 §3.1 和 [Q-0012](open/Q-0012-initrd-device-discovery.md)。

## 9. fstab 策略

- initrd 挂载 `/`、`/etc`、`/var`、`/home`、`/boot`；`/etc/fstab` 不重复写。
- fstab 只放注释，或以后追加非关键/自动挂载项；`passno=0`。
- 需要这些挂载的服务用 `RequiresMountsFor=`。
- 验收看 `findmnt`，不只看 `systemctl list-units --type=mount`。

## 10. 测试清单

1. `findmnt -R /` 显示 `/` erofs ro，`/etc` ext4，`/var`/`/home` btrfs，`/boot` vfat。
2. `lvs` 显示 `root_a`、`root_b`、`etc` active。
3. `cat /etc/machine-id` 非空；重启两次不变。
4. `systemctl --failed` 为空。
5. `bootctl list` 能看到 A/B/recovery。
6. 连续 5 次重启，无 emergency。
7. `keel.recovery=1` 能进 recovery；`/etc` 没有被挂载覆盖。
8. 破坏 VG 元数据/root/etc/data，能自动进 recovery。
9. `keel.fail=vglv|root|etc|data` 分别进 recovery，且串口有
   `keel: injecting failure at <step>`。
10. `keel.fail=esp` 仍能启动到 multi-user，`/boot` 未挂，警告可见。
11. `keel.timeout=root:60` 生效：故意让 root 设备慢出现，确认不会提前放弃。
12. ESP 挂不上时仍写 `/var/lib/keel/boot-ok`；恢复 ESP 后 `keel-boot-repair`
    把条目名还原成 `+10`。

## 11. 待定

- P1 是否值得做：见 [Q-0011](open/Q-0011-initrd-p1.md)。
- 若做 P1，`keel-recovery.service` 的 unit 写法：见 [Q-0009](open/Q-0009-recovery-fallback.md)。
- 镜像怎么造、测试装置怎么起：见 [Q-0010](open/Q-0010-image-build-harness.md)。
- recovery 更新策略：见 [F-012](features/F-012-rescue.md)。
