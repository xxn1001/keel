---
id: ADR-0010
title: Buildroot LTS as the build system
status: accepted
date: 2026-11-10
deciders: [maintainer]
---

# ADR-0010 构建系统用 Buildroot LTS

## Context

要从源码组一个最小系统，不用 mkosi/发行版安装器。
候选：LFS/BLFS、Buildroot、Yocto、debootstrap + 手工组装。

目标不是“体验编译 toolchain”，而是“理解并控制启动链、分区、initrd、更新”。
LFS 的大量时间在 toolchain/glibc；Yocto 的 layer/recipe 对单机项目过重。

## Decision

- 用 **Buildroot LTS**，钉死版本。
- 两个 defconfig：rootfs 与 initrd。
- rootfs 出 tar；post-image 用 `mkfs.erofs` 生成 root 镜像。
- UKI 用宿主机 `ukify` 后处理（`--linux --initrd --cmdline --os-release --microcode`）。
- 不用目标上的包管理器；更新 = 重建镜像 + 写非活动槽。

## Consequences

优点：

- 构建快、配置直观、产物可控。
- 没有 mkosi 的隐式默认值/脚本继承。
- 适合单机、最小化、学习启动链。

代价：

- 包可能不全（podman/systemd-boot/ukify 需要确认/自定义）。
- 没有 Yocto 的 SDK/包源/多机型支持。
- 每次加包要重建；没有在线升级。

## Alternatives rejected

- **LFS/BLFS**：时间长，重点在 toolchain；对启动链学习帮助不如 Buildroot。
- **Yocto**：layer/recipe 复杂度高；单机项目过重。
- **debootstrap + 手工组装**：快，但会把 Debian 的包/脚本假设带进来；不够“从零”。
- **mkosi**：被明确抛弃；隐式默认值/脚本继承是旧项目的坑。

## References

- [F-001](../features/F-001-minimal-base.md)
- [Q-0003](../open/Q-0003-buildroot-components.md)
- [lessons.md](../lessons.md) L-008
