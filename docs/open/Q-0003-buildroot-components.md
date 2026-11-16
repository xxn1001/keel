---
id: Q-0003
question: Which Buildroot LTS, and does it package systemd-boot/ukify/LVM units?
blocking: F-001 / F-005
owner: TBD
updated: 2026-11-15
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

## Decision (2026-11-15)

采用 **Buildroot 2025.02.19 LTS**。依据是官方下载页
<https://buildroot.org/download.html> 的表格（2026-11-15 读取）：

| 分支 | 类型 | End of Life | 最新版本 | 发布日期 |
|---|---|---|---|---|
| `2025.02.x` | Long-term support | March 2028 | `2025.02.19` | 2026-10-22 |
| `2026.08.1.x` | Stable | December 2026 | `2026.08.1` | 2026-10-22 |

`2026.08.1` 只是 Stable，EOL 为 2026-12，不能作为 v0.1 的 LTS 基线。

固定 tarball：

```text
URL:    https://buildroot.org/downloads/buildroot-2025.02.19.tar.xz
SHA256: e5e58bff1da91f022f60cefdfe280140c08023cd0aeec1e5f6f9da0ea866d69c
```

组件结论（基于 2025.02.19 源码检查，未启动验证）：

- systemd 256.17，满足 v0.1 的 `>= 254` 要求。
- `BR2_PACKAGE_SYSTEMD_BOOT` 存在；W-2 再验证 EFI 产物。
- `bootctl`、`systemd-bless-boot` 由 systemd 目标包构建；W-2 在 E2/E3 验证安装路径与 boot counting。
- `ukify` 在目标 systemd 构建中为 `-Dukify=disabled`，2025.02.19 没有 `systemd-ukify` 包；W-2 用宿主机 `ukify` 做 UKI 后处理（Option B）。
- `lvm2` 用户态与 initrd activation unit/udev 规则留给 W-1 验证。

W-0 的构建与启动证据见 feat PR #6；`versions.env` 固定 URL 与 sha256。

本决策**不转 ADR**：它固定的是依赖版本，不是架构。机器可读的真相在 `versions.env`，
变更时改版本号 + sha256，并重跑 W-0 的构建与启动验证即可。

## Decision gate

已决定（2026-11-15）：v0.1 使用 Buildroot 2025.02.19。升级 Buildroot 必须单独 PR，并重跑 W-0 构建与启动验证。
