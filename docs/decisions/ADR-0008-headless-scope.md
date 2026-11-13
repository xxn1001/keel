---
id: ADR-0008
title: v1 is a headless wired server
status: accepted
date: 2026-11-10
deciders: [maintainer]
---

# ADR-0008 v1 只做 headless 服务器

## Context

目标平台是长期在线的服务器；暂时没有笔记本/桌面需求。
WiFi、GPU、桌面、suspend 会把内核、固件、用户态复杂度拉高，且与“最小基底”冲突。

## Decision

- v1 只支持 **headless 服务器**：
  - 有线 Ethernet（DHCP 起步，可改静态）。
  - 串口控制台 + SSH。
  - 无 GPU 厂商驱动、无 WiFi、无桌面、无音频、无 suspend/hibernate。
- 内核裁掉 WiFi/GPU/声卡；保留串口、有线网卡、存储、virtio。
- 未来要桌面/笔记本：新 feature，不改 v1 范围。

## Consequences

优点：

- 内核/固件/rootfs 小；启动路径短。
- 测试环境简单（QEMU + 串口/网络）。
- 不需要处理显卡/电源管理。

代价：

- 不能直接当日常笔记本。
- 需要串口或 BMC 才能本地管理；没有显示器也能跑。
- 未来加桌面要重新评估 F-009/F-010 和内核配置。

## Alternatives rejected

- **笔记本优先**：WiFi/GPU/suspend 会拖慢 v1；且当前目标不是它。
- **桌面 + 服务器双形态**：分支/配置爆炸；v1 不做。
- **无串口，只靠 SSH**：网络坏了就进不去；串口是底线。

## References

- [F-006](../features/F-006-headless-server.md)
- [F-009](../features/F-009-vfio.md)（future）
- [outline.md](../outline.md)
