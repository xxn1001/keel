---
id: F-009
title: VFIO device passthrough
status: idea
target: future
owner: TBD
updated: 2026-11-10
depends: [F-006]
---

# F-009 VFIO / 设备直通

## 1. Why

未来把 GPU/NIC 等 PCI 设备直通给 VM，宿主保持最小、不装厂商驱动。
这是 **future**，不进 v1；但特征表要预留，避免以后改结构。

## 2. Scope

包含：

- IOMMU（Intel VT-d / AMD-Vi）。
- `vfio-pci` 绑定设备。
- QEMU/libvirt 在用户态运行（可以在 podman 里，也可以直接在 rootfs）。
- 设备 reset/ROM/ACS 的兼容性记录。

不包含：

- 宿主 GPU 桌面/游戏。
- SR-IOV（单独评估）。
- 嵌套虚拟化。

## 3. User-visible behavior

- 宿主看不到被直通的设备（或只看到 vfio 绑定）。
- VM 里能看到设备并使用。
- 宿主不加载厂商 GPU 驱动。

## 4. Interfaces

| 接口 | 说明 |
|---|---|
| kernel cmdline | `intel_iommu=on` / `amd_iommu=on` `iommu=pt` |
| `vfio-pci.ids=` | 绑定设备 |
| `/sys/kernel/iommu_groups/` | IOMMU group |
| `virsh`/`qemu-system-x86_64` | VM |
| `/etc/modprobe.d/vfio.conf` | 设备绑定 |

## 5. Design

- 内核：`CONFIG_IOMMU_SUPPORT`、`CONFIG_VFIO`、`CONFIG_VFIO_PCI`、`CONFIG_VFIO_IOMMU_TYPE1`、`CONFIG_KVM`。
- cmdline：`intel_iommu=on iommu=pt`（AMD 对应 `amd_iommu=on`）。
- 绑定：`vfio-pci.ids=10de:xxxx` 或 `driver_override`。
- GPU：需要 ROM（`/sys/bus/pci/devices/.../rom`）和 reset quirk；部分消费卡不支持干净 reset。
- ACS：检查 IOMMU group 是否隔离；否则需要 ACS override（有安全代价）。
- 宿主不装 NVIDIA/AMD 用户态驱动；VM 里装。
- QEMU/libvirt 可以后续用 podman 跑，也可以进 rootfs；先不要定。

## 6. Failure modes / recovery

| 失败 | 处理 |
|---|---|
| 设备不在独立 IOMMU group | ACS override 或换插槽 |
| GPU reset 不干净 | 换卡/用 vendor reset quirk |
| 宿主驱动抢设备 | `vfio-pci` 早绑定；blacklist |
| VM 黑屏 | ROM/驱动/显示配置 |

## 7. Acceptance criteria

- [ ] `dmesg` 显示 IOMMU enabled。
- [ ] `lspci -k` 显示设备绑定 `vfio-pci`。
- [ ] VM 能启动并使用设备。
- [ ] 宿主不加载厂商驱动。
- [ ] 重启后绑定仍生效。

## 8. Open questions / ADR links

- VFIO 范围/版本：[Q-0007](../open/Q-0007-vfio-scope.md)。
- headless 范围：[ADR-0008](../decisions/ADR-0008-headless-scope.md)。

## 9. Test plan

E3：目标服务器 + 实际设备；记录 IOMMU group、ROM、reset 行为。
E2 只能做假设备/嵌套，参考价值有限。

## 10. Changelog

| 日期 | 变更 |
|---|---|
| 2026-11-10 | 初稿；标 future，不进 v1 |
