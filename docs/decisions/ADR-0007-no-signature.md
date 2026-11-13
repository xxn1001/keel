---
id: ADR-0007
title: No signature, verity, or Secure Boot in v1
status: accepted
date: 2026-11-10
deciders: [maintainer]
---

# ADR-0007 v1 不做签名/verity/Secure Boot

## Context

使用场景是自己构建、马上安装、单用户、无对手。
镜像分发/多租户/远程不可信源都不在 v1 范围。
签名/verity/Secure Boot 会带来密钥管理、固件登记、更新链、调试通道等大量复杂度。

## Decision

- v1 不做 manifest 签名、dm-verity、Secure Boot。
- 固件里关闭 Secure Boot；文档写清。
- 写盘只用 `fsync` + 可选的回读/sha256；不做密码学验证。
- 救援路径（F-012）是唯一的安全网；必须演练。

## Consequences

优点：

- 更新链简单；没有密钥丢失/轮换/固件登记问题。
- 调试方便；不需要签名工具链。
- 镜像构建快。

代价：

- 物理接触即可替换 root/UKI；没有篡改检测。
- 不满足“可证明未被篡改”的场景。
- 未来要做 F-010 时，需要新 ADR 推翻本条，并重新设计更新/启动链。

## Alternatives rejected

- **manifest 签名 + 公钥烤进镜像**：v1 没有分发/对手；复杂度不划算。
- **dm-verity**：需要 roothash 与 UKI/cmdline 绑定；和 A/B 组合要专门设计。
- **Secure Boot + 自签密钥**：每台登记证书/关 SB；调试通道关闭。

## References

- [F-010](../features/F-010-secureboot-verity.md)（future）
- [F-012](../features/F-012-rescue.md)
- [lessons.md](../lessons.md) L-013
