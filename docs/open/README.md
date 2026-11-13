# 未决问题

> 状态：living index | 更新：2026-11-13
> 未决问题不藏在聊天里；写进这里，决定后转 ADR/feature 并关闭。

## 索引

| ID | 问题 | 阻塞 | 状态 |
|---|---|---|---|
| [Q-0001](Q-0001-podman-mode.md) | podman rootful/rootless、网络模式 | F-008 / v0.4 | open |
| [Q-0002](Q-0002-disk-sizes.md) | 目标盘容量与精确尺寸 | F-011 / v0.3 | open |
| [Q-0003](Q-0003-buildroot-components.md) | Buildroot LTS/systemd-boot/ukify/LVM units | F-001/F-005 | open |
| [Q-0004](Q-0004-rescue-usb.md) | USB rescue 内容/维护 | F-012 | open |
| [Q-0005](Q-0005-zram-generator.md) | zram generator vs 自写 unit | F-007 | open |
| [Q-0006](Q-0006-etc-factory-merge.md) | `/etc` factory diff/合并流程 | F-004 | open |
| [Q-0007](Q-0007-vfio-scope.md) | VFIO 范围/版本/设备 | F-009 | open |
| [Q-0008](Q-0008-data-fs.md) | data 分区 btrfs vs zfs | F-015 / v0.1 | open |
| [Q-0009](Q-0009-recovery-fallback.md) | P1 recovery fallback 的 unit 实现 | F-005/F-012 | open |

## 规则

- 每个问题一个文件；`blocking` 写 feature/版本。
- 至少列 2 个选项 + 建议 + 决定 gate。
- 决定后：写 ADR（如果是架构决策）或更新 feature；把 Q 状态改 `closed`，链接 ADR。
- 不删除 Q；保留历史。
