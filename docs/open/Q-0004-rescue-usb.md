---
id: Q-0004
question: What goes on the USB rescue image, and how is it kept current?
blocking: F-012
owner: TBD
updated: 2026-11-14
---

# Q-0004 USB rescue 内容

## Context

ESP recovery UKI 依赖目标盘；ESP 坏/清空时需要 USB。
USB 可能过期；工具太少修不了，太多则体积/维护成本高。

## Options

### A. 最小工具集（建议）

- `sh`、`busybox`、`lvm2`、`e2fsprogs`、`erofs-utils`、`bootctl`、`sgdisk`、`mount`、`blkid`、`dmesg`、`vim/nano`。
- 体积小；覆盖 LVM/ESP/erofs 恢复。

### B. 完整 Buildroot rootfs

- 与主系统同 rootfs + 额外工具。
- 体积大；维护简单（同一构建）。

### C. 发行版 live ISO

- 工具全；但引入另一个发行版，和“从零”理念冲突。

## Recommendation

A；用与主系统同一个 Buildroot 配置加一个 `rescue` fragment 生成。
每次发布时重建 USB 镜像，并在文档写“最后更新时间”。

## Decision gate

v0.2 救援基础前定；至少确定工具清单和 USB 生成方式。
