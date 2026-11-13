---
id: F-006
title: Headless server
status: accepted
target: v0.1
owner: TBD
updated: 2026-11-10
depends: [F-001]
---

# F-006 Headless server

## 1. Why

v1 的目标是服务器：有线网络、串口/SSH 管理、无桌面。
先收敛范围，避免 WiFi/GPU/桌面/suspend 把复杂度拉爆。

## 2. Scope

包含：

- 有线 Ethernet（DHCP 起步，可改静态）。
- `systemd-networkd` + `systemd-resolved` + `systemd-timesyncd`。
- `sshd`；root 禁止 SSH 登录；`admin` + sudo。
- 串口 getty：`console=tty0 console=ttyS0,115200`。
- 可选 nftables，只放 SSH。

不包含：

- WiFi、蓝牙、GPU、桌面、音频、suspend/hibernate。
- 多用户/多机管理、防火墙编排。

## 3. User-visible behavior

- 串口能登录；SSH 能登录。
- 拔网线不影响启动，只影响网络。
- 重启后网络自动恢复。

## 4. Interfaces

| 接口 | 说明 |
|---|---|
| `/etc/systemd/network/20-wired.network` | DHCP/静态 |
| `sshd_config` | `PermitRootLogin no` |
| `console=ttyS0,115200` | 串口 |
| `admin` 用户 | uid 1000，sudo |

## 5. Design

- networkd `.network`：`DHCP=yes` 起步；服务器可改静态。
- resolved 管理 `/etc/resolv.conf`（stub）。
- timesyncd 开机同步；TLS/证书需要正确时间。
- sshd 首启生成 host key；不要 bake 进镜像。
- 串口 getty 由 systemd-getty-generator 自动生成；检查 `serial-getty@ttyS0`。
- 防火墙：v1 可以不做；如果做，只允许 SSH。

## 6. Failure modes / recovery

| 失败 | 处理 |
|---|---|
| 网络不启动 | 串口登录；`networkctl status`；检查 `.network`/link 名 |
| SSH 不进 | 串口；`systemctl status sshd`；`ss -lntp` |
| 时间不对 | `timedatectl`；timesyncd |
| 串口无 getty | `systemctl status serial-getty@ttyS0` |

## 7. Acceptance criteria

- [ ] 串口登录成功。
- [ ] `ssh admin@host` 成功。
- [ ] `networkctl status` 有地址/路由/DNS。
- [ ] 拔网线启动不 emergency。
- [ ] 重启 5 次，网络自动恢复。

## 8. Open questions / ADR links

- headless 范围：[ADR-0008](../decisions/ADR-0008-headless-scope.md)。
- DHCP vs 静态：v0.1 先用 DHCP；服务器可后改。

## 9. Test plan

E1/E2：QEMU user-mode network 或 tap；串口/SSH；拔网线。
E3：真服务器有线网络。

## 10. Changelog

| 日期 | 变更 |
|---|---|
| 2026-11-10 | 初稿 |
