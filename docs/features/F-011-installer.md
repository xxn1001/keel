---
id: F-011
title: Installer
status: accepted
target: v0.1/v0.3
owner: TBD
updated: 2026-11-26
depends: [F-001, F-002, F-004, F-015, F-005]
---

# F-011 安装器

## 1. Why

把空盘变成可启动的 keel2：GPT、LVM、erofs root LV、ext4 `/etc`、btrfs data、recovery、ESP、`bootctl install`。
安装器只做一次；不要长成第二个 `os-install`。

它同时是 **v0.1 唯一的造盘手段**：host 上没有 loop、没有 root，装不出盘；
[Q-0010](../open/Q-0010-image-build-harness.md) 因此规定"安装器就是测试装置"。
所以它从 v0.1 就开始存在，只是没有交互界面。

按 [ADR-0016](../decisions/ADR-0016-maintenance-in-recovery.md)，**安装器住在 recovery 树里**，
不进 system root。

## 2. Scope

包含：

- GPT：`esp`、`recovery`、`system`、`data`。
- LVM：`system` VG + `root_a`、`root_b`、`etc`。
- `mkfs.erofs` root_a/root_b/recovery；`mkfs.ext4` etc；`mkfs.btrfs` data + `var`/`home` 子卷。
- 复制 rootfs；播种 `/etc`；清 machine-id/ssh key。
- `bootctl install` + NVRAM。
- 首启生成 machine-id/ssh host key。

不包含：

- 在线升级/迁移。
- 双系统/分区缩小。
- 图形安装器。

版本切分：

| 版本 | 内容 |
|---|---|
| v0.1 | 非交互最小版：`--disk` + `--source`、`--dry-run`、区分退出码。够 CI 和本地测试用 |
| v0.3 | 交互确认、进度输出、从 U 盘自动找载荷、失败后清理提示 |

## 3. User-visible behavior

- 从 recovery 的 `install` 模式启动（`keel.mode=install`），跑
  `keel-install --source /mnt/usb --disk /dev/vdX`，完成后重启，目标盘能启动。
- 首启进入登录；`/etc`、`/var`、`/home` 持久。
- `bootctl list` 有 A/B/recovery。
- 目标盘不是当前系统盘；已挂载/非块设备/容量不足时拒绝。

## 4. Interfaces

| 接口 | 说明 |
|---|---|
| `installer/keel-install` | 入口；住在 recovery 树里，`/sbin/keel-install`；**C 二进制**，shell 只做测试装置的胶水 |
| `--disk /dev/vdX` | 目标盘 |
| `--source <dir>` | 载荷目录（U 盘挂载点或任意目录）。**只认目录，不认传输方式** |
| `--dry-run` | 打印计划，不动盘；允许对普通文件跑（测试用），真实运行只接受块设备 |
| `--force` | 盘上已有分区时覆盖 |
| `--timeout <sec>` | 每步等待的上限，默认 60；没有无限循环 |
| `efibootmgr`/`bootctl` | NVRAM |

## 5. Design

0. 运行环境：从 `recovery.cpio` 启动（`keel.mode=install`），RAM 里跑，目标盘是一块空盘。
   载荷来自 `--source`；这个目录可以是 U 盘挂载点，也可以是 QEMU 挂进来的第二块盘。
   安装器**只认目录**，不关心载荷是 U 盘、9p 还是别的什么。
1. 拒绝：不是块设备、已被挂载、上面已有激活的 VG、小于 8 GiB、`--source` 里缺文件。
2. `wipefs -a`；`sfdisk` 写 GPT：p1 `esp` 1 GiB (`EF00`)、p2 `recovery` 1 GiB (`8300`)、
   p3 `system` 6 GiB (`8E00`)、p4 `data` 到盘尾 (`8300`)，1 MiB 对齐。
3. `partx -a`，然后调 `/sbin/keel-discover`（复用 initrd 的 `discover.sh`），
   轮询到四个 `/dev/disk/by-partlabel/*` 都在；超时退出 4。
   **不要在 C 里再写一遍 sysfs 扫描**。
   - `partx` 走 BLKPG 直接加设备，不带分区名；没有 udev 时，新加的分区在 sysfs
     `uevent` 里没有 `PARTNAME`，`discover.sh` 用
     `blkid -c /dev/null -t PARTLABEL=...` 回退补齐。
   - `partx -a` 之前先做一次 best-effort 的 `partx -d`，清掉内核里的旧分区映射，
     这样 `--force` 重装已有分区表的盘也能走通。
4. `pvcreate` / `vgcreate system` / `lvcreate` `root_a` 2G、`root_b` 2G、`etc` 1G；
   `vgmknodes`；轮询到 `/dev/system/root_a` 出现（recovery 里没有 udev，这一步必须等）。
5. **先写 root**：`rootfs.erofs` → `root_a` 和 `root_b`（两槽写同一份，A/B 起点一致）；
   `recovery.erofs` → `p2`。
6. **再从 root 播种 `/etc`**：`mount -o ro /dev/system/root_a /mnt/root`；
   `mkfs.ext4` etc LV，挂 `/mnt/etc`，`cp -a /mnt/root/etc/. /mnt/etc/`。
   这份 `/etc` 只有这一个来源——不打 `etc.tar`，也不 loop 挂镜像文件。
7. `mkfs.btrfs` data；`btrfs subvolume create var`、`home`；挂 var/home；建
   `/home/root`（0700）、`/var/lib/keel`、`/var/log/journal`。
8. （V4b）`mkfs.vfat` ESP；挂 `/mnt/esp`；复制 UKI A/B；`loader.conf`
   default `keel-a.efi`（UKI 的 id 含 `.efi` 后缀，写 `keel-a` 匹配不到）；
   `bootctl --esp-path=/mnt/esp install`；写 NVRAM；卸载。
9. 首启生成 machine-id/ssh host key。

验收也按这个切：**V4a 只验内容**（`sfdisk -d`、`lvs`、`blkid`、`dump.erofs`、
挂上 root 看 `/etc` 与 `/usr/etc`），**V4b 才验启动**。

实现语言：**C，静态链接优先**，与 `keel-update` 同一策略。安装器只调用外部工具
（`sfdisk`/`lvm`/`mkfs.*`/`bootctl`），自己不解析分区表，但**顺序、拒绝条件、退出码、
`--dry-run` 都由编译代码控制**——这是 [AGENTS.md](../../AGENTS.md) §5 "写盘逻辑必须编译"
的范围。外部命令一律 `fork` + `execvp` 传 argv 数组，**不出现 `system()` / `popen()`**。

非交互入口：recovery 的 init 在 `keel.mode=install` 下，若 cmdline 同时带
`keel.install.disk=` 和 `keel.install.source=`，就直接执行
`keel-install --disk <d> --source <s>`，结束后打印一行并掉 shell；否则打印用法。

工具依赖（都进 recovery 树）：

| 用途 | 工具 | 包 |
|---|---|---|
| 建 GPT | `sfdisk`、`wipefs` | `util-linux` |
| 重读分区表 | `partx` | `util-linux` |
| 写 ESP | `mkfs.vfat` | `dosfstools` |
| `/etc` | `mkfs.ext4` | `e2fsprogs` |
| data | `mkfs.btrfs`、`btrfs` | `btrfs-progs` |
| root / recovery | `mkfs.erofs`、`dump.erofs` | `erofs-utils` |
| VG / LV | `lvm` | `lvm2` |
| 引导条目 | `bootctl` | `systemd` |

`gdisk`（`sgdisk`）目前仍由 defconfig 打开，但安装器用 `sfdisk`；等 V4 落地后可以把它
和随之而来的 `BR2_TOOLCHAIN_BUILDROOT_CXX` 一起去掉。

约束：

- **不要**把带 LVM 的镜像直接 `dd` 到多块盘：VG/PV UUID 冲突。安装时现建。
- 安装脚本只做一次；不要把更新逻辑塞进来。
- 所有 `mkfs`/`lvcreate`/`btrfs subvolume` 失败都要停下，不继续。
- **播种 `/etc` 必须在 root LV 写完之后**，从已挂载的 root 复制。不要为了拿 `/etc`
  去 loop 挂镜像文件：`CONFIG_BLK_DEV_LOOP` 和 busybox 的 loop 支持都不保证在。
- `/etc/fstab` 只放注释，不写核心挂载。

## 6. Failure modes / recovery

| 失败 | 处理 |
|---|---|
| 选错盘 | 拒绝当前根盘；二次确认 |
| LVM 创建失败 | 停止；清 GPT 重来 |
| btrfs 子卷失败 | 停止；清 data 重来 |
| ESP 安装失败 | 检查 vfat/`systemd-bootx64.efi` |
| NVRAM 没写 | `efibootmgr` 手动加；rescue |
| 首启没生成 machine-id | 检查 `/etc` 挂载/权限 |

## 7. Acceptance criteria

- [ ] 从 `recovery.cpio`（`keel.mode=install` + `keel.install.disk/source`）启动，对空盘安装成功。
- [ ] `--dry-run` 在不碰盘的情况下打印完整计划（分区表、LV、要写的文件）。
- [ ] 空盘安装 → 首启 → 登录。
- [ ] `findmnt -R /` 正确：erofs/ext4/btrfs/vfat。
- [ ] `lvs` 三个 LV active。
- [ ] `bootctl list` 有 A/B（recovery UKI 是 v0.2）。
- [ ] `efibootmgr -v` 指向目标 ESP。
- [ ] `/etc/machine-id` 非空且唯一。
- [ ] `/etc/fstab` 没有核心挂载 entry。
- [ ] 重启 5 次，无 emergency。

## 8. Open questions / ADR links

- system VG：[ADR-0012](../decisions/ADR-0012-system-vg.md)。
- data：[ADR-0013](../decisions/ADR-0013-data-partition.md)。
- recovery：[ADR-0014](../decisions/ADR-0014-recovery-partition.md)。
- 精确尺寸：[Q-0002](../open/Q-0002-disk-sizes.md)。

## 9. Test plan

E2：空盘（qcow2）安装 → 首启 → 重启；E3：目标服务器（保留救援 U 盘）。

## 10. Changelog

| 日期 | 变更 |
|---|---|
| 2026-11-10 | 初稿 |
| 2026-11-13 | 新 GPT/LVM/btrfs/recovery；fstab 注释 |
| 2026-11-20 | 移入 recovery 树；`--payload` 改 `--source`；v0.1 出非交互最小版 |
| 2026-11-20 | `/etc` 播种改为"先写 root，再从挂载的 root 复制"；明确不用 `etc.tar`、不 loop 挂镜像 |
