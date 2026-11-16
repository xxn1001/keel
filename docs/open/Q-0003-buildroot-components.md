---
id: Q-0003
question: Which Buildroot LTS, and does it package systemd-boot/ukify/LVM units?
blocking: F-001 / F-005
owner: TBD
updated: 2026-11-10
---

# Q-0003 Buildroot 组件

## Context

需要：

- Buildroot LTS 版本（钉死）。
- systemd（`BR2_INIT_SYSTEMD`）、`bootctl`、`systemd-bootx64.efi`、`systemd-bless-boot`。
- `ukify`（宿主机 Python；或 Buildroot 的 `systemd-ukify` 包）。
- `lvm2` 的 initrd activation unit/udev 规则。

已知：Buildroot 2025-11 有 `BR2_PACKAGE_SYSTEMD_BOOT` 补丁；2026-02 有 `systemd-ukify` 补丁；是否进入所选 LTS 要确认。

## Options

### A. 选带这些包的 LTS（建议）

- 直接 `make menuconfig` 确认；缺的用 `BR2_EXTERNAL` 自定义 package。
- 优点：可控；缺点：要维护 package。

### B. 宿主机 `ukify` + 手工复制 systemd-boot

- Buildroot 只出 kernel/rootfs/initrd；UKI/ESP 在 post-image 用宿主机工具。
- 优点：不依赖 Buildroot 打包；缺点：宿主机要 Python/pefile。

### C. 换 Yocto

- `uki.bbclass`/systemd-boot 支持更完整；但复杂度高。

## Recommendation

A + B 结合：Buildroot 出 rootfs/initrd；`ukify`/systemd-boot 在宿主机 post-image 完成。
先确认所选 LTS 的 `BR2_PACKAGE_SYSTEMD_BOOT`/`systemd-ukify`。

## Decision gate

v0.1 构建前定；记录 Buildroot 版本、menuconfig 截图/配置、ukify 版本。
