---
id: F-007
title: zram swap
status: accepted
target: v0.3
owner: TBD
updated: 2026-11-10
depends: [F-001]
---

# F-007 zram swap

## 1. Why

服务器可能内存紧张；用 zram 做压缩 swap，不占 system VG/data，不需要 swap LV。
v1 不做 hibernation，所以不需要磁盘 swap。

## 2. Scope

包含：

- `/dev/zram0`，压缩算法 zstd（或 lz4）。
- swap priority 高于磁盘（如果有）。
- 开机自动配置。
- `zramctl` / `swapon --show` 可观察。

不包含：

- hibernation/resume。
- 多个 zram 设备。
- zswap（不同机制）。

## 3. User-visible behavior

- `swapon --show` 显示 `/dev/zram0`。
- 内存压力下不 OOM（在容量范围内）。
- 重启后自动恢复。

## 4. Interfaces

| 接口 | 说明 |
|---|---|
| `systemd-zram-generator` | 优先；生成 `systemd-zram-setup@zram0.service` |
| `/etc/systemd/zram-generator.conf` | 大小/算法 |
| `zramctl` | 查看 |
| `swapon --show` | 验证 |

如果没有 `systemd-zram-generator`，写一个最小 unit 或 C 小工具：

```sh
modprobe zram
echo zstd > /sys/block/zram0/comp_algorithm
echo 4G > /sys/block/zram0/disksize
mkswap /dev/zram0
swapon -p 100 /dev/zram0
```

> 上面的 shell 只作为救援/说明；正式实现用 generator 或编译型 unit，不写 shell 状态机。

## 5. Design

- 大小：`ram * 0.5` 到 `ram * 1.0`，上限 8 GiB；按目标内存定。
- 算法：zstd 优先；CPU 弱可用 lz4。
- priority：100（高于磁盘 swap）。
- 不建 swap LV；system VG 不承载 swap。
- 内核：`CONFIG_ZRAM`、`CONFIG_ZSMALLOC`、`CONFIG_CRYPTO_ZSTD`。

## 6. Failure modes / recovery

| 失败 | 处理 |
|---|---|
| 模块没编 | 内核加 `CONFIG_ZRAM` |
| generator 不存在 | 写最小 unit 或 C 工具 |
| 大小过大 | 降低 `zram-size`；观察 `zramctl` |
| OOM | 加内存/调大 zram；不要靠磁盘 swap 救 |

## 7. Acceptance criteria

- [ ] `swapon --show` 有 `/dev/zram0`。
- [ ] `zramctl` 显示算法/大小。
- [ ] 重启后仍在。
- [ ] 内存压力测试不 OOM（在设定范围内）。

## 8. Open questions / ADR links

- zram 决策：[ADR-0009](../decisions/ADR-0009-zram-sizes.md)。
- generator vs 自写 unit：[Q-0005](../open/Q-0005-zram-generator.md)。

## 9. Test plan

E1/E2：启动后 `swapon --show`；`stress-ng --vm`（如果镜像里有）或 `dd` 压内存。
E3：真服务器观察。

## 10. Changelog

| 日期 | 变更 |
|---|---|
| 2026-11-10 | 初稿 |
