---
id: Q-0001
question: podman rootful or rootless in v0.4, and which network mode?
blocking: F-008 / v0.4
owner: TBD
updated: 2026-11-10
---

# Q-0001 podman 模式

## Context

v0.4 要能跑容器。rootful 简单，但容器进程是 root；rootless 更安全，但需要 subuid/subgid、`newuidmap`、`fuse-overlayfs`、`slirp4netns`、cgroup delegation。
网络：`--network=host` 最简单；bridge/端口发布需要 netavark/nftables。

## Options

### A. rootful + host network（建议 v0.4）

- 优点：依赖少；overlay2 直接可用；调试简单。
- 缺点：容器内 root = 宿主 root；隔离弱；端口共享宿主网络。

### B. rootful + bridge

- 优点：端口发布/隔离好一点。
- 缺点：netavark/nftables/veth/bridge 依赖；调试多。

### C. rootless + host network

- 优点：非 root 容器；更安全。
- 缺点：subuid/subgid、newuidmap、fuse-overlayfs、cgroup delegation；复杂度高。

### D. rootless + slirp4netns

- 优点：完整 rootless。
- 缺点：最复杂；性能和兼容性坑最多。

## Recommendation

v0.4 先 **A（rootful + host network）**，把 podman 跑通；
rootless/bridge 作为后续 feature，不在 v0.4 gate 里。

## Decision gate

v0.4 开始前定；如果选 A，F-008 的验收只要求 rootful + host network。
