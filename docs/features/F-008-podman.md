---
id: F-008
title: podman userland
status: accepted
target: v0.4
owner: TBD
updated: 2026-11-10
depends: [F-015]
---

# F-008 podman 用户态

## 1. Why

宿主保持最小；用户态软件用容器，避免把编译器/桌面/依赖塞进基底。
v0.4 先做 **rootful + host network**，把复杂度压到最低；rootless 后置。

## 2. Scope

包含：

- `podman` + `conmon` + `crun` + `containers-common`。
- 存储 `/var/lib/containers/storage`（在 data 的 `var` 子卷）。
- `/etc/containers/{registries.conf,policy.json,storage.conf}` 随 `/etc` 播种。
- `podman run --rm hello-world`。
- `-v /home:/home` 持久数据。

不包含：

- rootless（UID/GID 映射、`fuse-overlayfs`、`slirp4netns`）。
- bridge 网络/端口发布（先用 `--network=host`）。
- Kubernetes/quadlet 编排。

## 3. User-visible behavior

- `podman info` 正常。
- `podman run --rm hello-world` 成功。
- `podman run -v /home:/home ...` 能读写家目录。
- 重启后 `podman images` 还在。

## 4. Interfaces

| 接口 | 说明 |
|---|---|
| `podman` | 命令行 |
| `/var/lib/containers/storage` | 镜像/容器存储 |
| `/etc/containers/*.conf` | 配置 |
| `ca-certificates` | pull HTTPS 需要 |
| `--network=host` | v0.4 默认 |

## 5. Design

- Buildroot 是否有 `podman` 包：先确认；没有就自定义 package。
- 依赖：`conmon`、`crun`/`runc`、`netavark`/`aardvark-dns`（bridge 时才要）、`nftables`/`iptables`、`shadow`、`ca-certificates`。
- 内核：`OVERLAY_FS`、`FUSE_FS`、`NAMESPACES`、`USER_NS`、`CGROUPS`、`SECCOMP`、`VETH`、`BRIDGE`、`NF_TABLES`、`BPF_SYSCALL`。
- 存储：overlay2 on ext4；rootful 不需要 `fuse-overlayfs`。
- 网络：`--network=host` 起步；bridge 后置。
- `/var` 要留够；镜像/容器可能很快吃满。

## 6. Failure modes / recovery

| 失败 | 处理 |
|---|---|
| `podman info` 报 storage 错 | 检查 `/var/lib/containers` 权限/空间 |
| overlay 不工作 | 内核 `OVERLAY_FS`；`podman info` 看 graphDriver |
| pull 失败 | 时间/CA/DNS；`--network=host` |
| `/var` 满 | 清理 data；`podman system prune`；扩容 data |
| 容器写宿主 | 只 bind 白名单；不要挂 `/` |

## 7. Acceptance criteria

- [ ] `podman info` 正常。
- [ ] `podman run --rm hello-world` 成功。
- [ ] `podman run -v /home:/home ...` 可读写。
- [ ] 重启后 `podman images` 仍在。
- [ ] 宿主 rootfs 没有引入编译器/桌面。

## 8. Open questions / ADR links

- rootful vs rootless、网络模式：[Q-0001](../open/Q-0001-podman-mode.md)。
- 存储/`/var` 尺寸：F-015、Q-0008。

## 9. Test plan

E2：`podman info`；hello-world；`-v /home`；重启；`/var` 空间告警。
E3：真服务器 pull/run。

## 10. Changelog

| 日期 | 变更 |
|---|---|
| 2026-11-10 | 初稿；rootful/host network 起步 |
