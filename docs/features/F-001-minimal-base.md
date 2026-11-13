---
id: F-001
title: Minimal bootable base
status: accepted
target: v0.1
owner: TBD
updated: 2026-11-10
depends: []
---

# F-001 最小可启动基底

## 1. Why

先有一个能启动、能登录、能重启的最小系统，后面的 A/B、LVM、更新、podman 才有地方落。
不用发行版安装器、不用 mkosi；用 Buildroot 从源码组出 kernel + rootfs + initrd。

## 2. Scope

包含：

- Buildroot LTS，两个 defconfig：rootfs 与 initrd。
- Linux kernel + 最小模块集。
- systemd 作为 init。
- 串口控制台、基本 getty。
- QEMU 启动到 multi-user。

不包含：

- A/B（F-002）、system VG / data（F-004/F-015）、更新（F-003）、podman（F-008）。
- 桌面、WiFi、GPU、Secure Boot。

## 3. User-visible behavior

- QEMU 里能启动到登录提示。
- 串口能看到 kernel + systemd 日志。
- `systemctl --failed` 为空。
- 连续 5 次重启，无 emergency。

## 4. Interfaces

| 接口 | 说明 |
|---|---|
| `buildroot/configs/keel_defconfig` | rootfs 配置 |
| `buildroot/configs/keel_initrd_defconfig` | initrd 配置 |
| `buildroot/linux.fragment` | 内核配置增量 |
| `buildroot/rootfs-overlay/` | `/etc` 模板、units、networkd |
| `buildroot/post-image.sh` | rootfs tar → erofs；initrd cpio；UKI（P1） |
| `output/` | kernel、rootfs、initrd、UKI、manifest |

## 5. Design

- Buildroot 出 rootfs tar；post-image 用 `mkfs.erofs` 生成 root 镜像。
- initrd 用第二个 Buildroot 配置（`O=output/initrd`），避免把整个 rootfs 塞进去。
- kernel 用 `BR2_LINUX_KERNEL_CUSTOM_CONFIG_FILE` + fragment；先 `localmodconfig` 再手工裁剪。
- systemd 用 `BR2_INIT_SYSTEMD=y`；`BR2_ROOTFS_MERGED_USR=y`。
- 串口：kernel cmdline `console=tty0 console=ttyS0,115200`。
- 镜像组装：P0 可以手工 `dd`/QEMU；P1 用 genimage 或安装器。

## 6. Failure modes / recovery

| 失败 | 处理 |
|---|---|
| 内核起不来 | QEMU 串口日志；检查 cmdline/root= |
| systemd 不进 multi-user | `systemd.log_level=debug`；`systemctl --failed` |
| 缺模块 | initrd 加模块；`modprobe` 检查 |
| 串口无输出 | cmdline `console=`；QEMU `-serial mon:stdio` |

## 7. Acceptance criteria

- [ ] QEMU 启动到登录提示。
- [ ] `findmnt /` 显示预期 root 文件系统。
- [ ] `systemctl --failed` 为空。
- [ ] 连续 5 次重启，无 emergency。
- [ ] 串口日志可见。

## 8. Open questions / ADR links

- Buildroot LTS 版本、systemd-boot/ukify 是否打包：见 [Q-0003](../open/Q-0003-buildroot-components.md)。
- Buildroot 选型：[ADR-0010](../decisions/ADR-0010-buildroot.md)。

## 9. Test plan

E1/E2：`tools/qemu.sh` 启动；串口抓日志；`systemctl --failed`；重启 5 次。
E3：目标服务器上重复一次。

## 10. Changelog

| 日期 | 变更 |
|---|---|
| 2026-11-10 | 初稿 |
