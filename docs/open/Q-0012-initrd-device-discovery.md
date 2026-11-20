---
id: Q-0012
question: How does the initrd find its partitions without udev?
blocking: F-005 / v0.1
owner: TBD
updated: 2026-11-18
---

# Q-0012 initrd 的设备发现方式

## Context

W-1 实测两个事实：

- `/dev/disk/by-partlabel/*` 是 **udev** 建的，P0 busybox initrd 里这个目录不存在；
- `mount -o PARTLABEL=data` 也不行，busybox mount 没有 libblkid 支持。

而 [initrd.md](../initrd.md) 通篇用的是 `/dev/disk/by-partlabel/data` 和
`/dev/disk/by-partlabel/esp`，等于偷偷假设了 udev 存在。W-1/W-2 的 spike 里改用
`/dev/vda1..vda4` 绕过，这在真机上直接失效：NVMe 是 `nvme0n1p1`，SATA 是 `sda1`，
eMMC 是 `mmcblk0p1`。

同时要避免一个错误方向：**不要按设备名做构建配置**（比如"这个镜像给 vda 用"）。
同一个镜像要能跑 QEMU(virtio)、真机 NVMe、U 盘救援；设备名还会随插拔变化。
initrd 应该只认分区名，不认设备名。

需要按构建配置的其实是另一件事：**内核带哪些块设备驱动**
（`virtio_blk` / `nvme` / `ahci`+`sd_mod` / `usb-storage`），那属于 `linux.fragment`。
v0.1 建议四个全编进去（约 100 KB），不做开关。

## Options

### A. initrd 里带 udev

- `/dev/disk/by-*` 全部可用，和现有文档一致。
- 代价：+3~5 MB、启动多约 1 秒、initrd 多一个常驻进程和一个规则集。
- 也解决了"设备插入事件"的问题，但我们根本不需要热插拔。

### B. 自己扫 sysfs 建链接（建议）

纯 shell，约 15 行，零依赖：

```sh
for u in /sys/class/block/*/uevent; do
    grep -q '^DEVTYPE=partition$' "$u" || continue
    name=$(sed -n 's/^PARTNAME=//p' "$u")
    [ -n "$name" ] || continue
    ...
done
```

- 优点：设备无关（`vda4`/`nvme0n1p4`/`sda4`/`mmcblk0p4` 一视同仁）；不引入进程。
- 缺点：要自己 `mknod`（`uevent` 里有 `MAJOR`/`MINOR`）；`PARTNAME` 依赖内核 5.11+。

### C. 全改文件系统 UUID + `blkid`

- root LV 每次重建 UUID 都会变，更新器要回写 cmdline，比 PARTLABEL 更脆。
- data/ext4 用 UUID 可行，但两套规则并存更难解释。

### D. 按构建参数写死设备前缀（否决）

- 镜像与运行环境绑定；换一块盘就起不来；和"同一镜像多目标"直接冲突。

## Recommendation

**B 为主，`blkid` 兜底。**

理由：它保住了"initrd 里没有 udev"这个已经反复确认的选择，代价只是一段可测试的 shell；
而且它把"设备叫什么"这件事彻底从 initrd 里移除了。

## 实现要点

1. **磁盘作用域**：先找带 `PARTNAME=system` 的那块盘，**只在那块盘上**建链接。
   否则插着 USB 救援盘时会有两份 `PARTNAME=data`。
2. 候选盘多于一块 → 打印所有候选并 `exec /bin/sh`，**不许猜**。
3. `mknod` 用 `uevent` 里的 `MAJOR`/`MINOR`；`/dev/disk/by-partlabel/` 目录自己建。
4. 等设备出现要有超时（用 `keel.timeout=` 的预算），不能无限轮询。
5. 兜底：`PARTNAME` 缺失或内核太老时，用 `blkid -t PARTLABEL=system -o device`。
   util-linux 的 `blkid` 已经在镜像里（`BR2_PACKAGE_UTIL_LINUX_BINARIES`，见 PR #11）。
6. 找到之后，把解析结果打印到串口（哪个盘、哪个分区），排障时不用猜。

## Decision gate

v0.1 的 P0 initrd 产品化之前。开工前要确认 6.12 内核的 `uevent` 里确实有 `PARTNAME`；
没有就整条走 `blkid` 兜底。
