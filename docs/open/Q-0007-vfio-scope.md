---
id: Q-0007
question: What is the VFIO scope, target version, and supported devices?
blocking: F-009
owner: TBD
updated: 2026-11-10
---

# Q-0007 VFIO 范围

## Context

VFIO 是 future feature；需要 IOMMU、`vfio-pci`、QEMU/libvirt、设备 reset/ROM/ACS。
不同 GPU/NIC 的兼容性差异很大；不能笼统承诺“支持直通”。

## Options

### A. 单设备 PoC（建议起点）

- 一块已知兼容的 GPU 或 NIC；记录 IOMMU group/reset/ROM。
- 优点：可验证；缺点：范围窄。

### B. 通用 GPU 直通

- 多厂商/多型号；需要 reset quirk/ROM/ACS 矩阵。
- 优点：通用；缺点：工作量/不确定性大。

### C. 不做 VFIO

- v1 不需要；保留 feature 但永不实现。
- 优点：省事；缺点：失去未来扩展。

## Recommendation

先 A，作为 future 的 PoC；不承诺通用 GPU。等 v1 稳定后再定版本。

## Decision gate

v1.0 之后；需要实际硬件和 IOMMU 环境。
