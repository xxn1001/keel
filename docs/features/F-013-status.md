---
id: F-013
title: Status and observability
status: proposed
target: v0.4
owner: TBD
updated: 2026-11-10
depends: [F-003]
---

# F-013 状态与可观测性

## 1. Why

headless 服务器没有本地 UI；需要一条命令回答：

- 我现在在哪个槽？
- 版本是什么？
- `/etc` `/var` `/home` 挂上了吗？
- ESP、system VG、data 还剩多少？
- 上次更新成功还是失败？

## 2. Scope

包含：

- `keel-status`：人类可读 + 可选 JSON。
- 读 `/proc/cmdline`、`bootctl list`、`findmnt`、`lvs`、`df`、`/etc/os-release`。
- 不修改任何状态。

不包含：

- 监控/告警/导出。
- 自动修复。

## 3. User-visible behavior

```text
slot:        a
version:     2026.11.13
root:        erofs ro (/dev/system/root_a)
/etc:        ext4 rw (/dev/system/etc) 31% used
/var:        btrfs rw (data subvol=var) 82% used
/home:       btrfs rw (data subvol=home) 41% used
ESP:         vfat rw (/dev/disk/by-partlabel/esp) 710 MiB free
system VG:   1.0 GiB free
entries:     keel-a.efi (default), keel-b.efi, keel-recovery.efi
last update: success (2026-11-12)
```

## 4. Interfaces

| 接口 | 说明 |
|---|---|
| `/usr/bin/keel-status` | 编译型；只读 |
| `--json` | 机器可读 |
| exit 0 | 正常 |
| exit 1 | 关键项缺失（root/挂载/ESP） |

## 5. Design

- C 或 Rust；不调用 shell。
- 读 `/proc/cmdline` 解析 `root=/dev/system/root_a|root_b`。
- `bootctl list --json=short` 或解析 `bootctl list`；优先 JSON。
- `findmnt -n -o SOURCE,FSTYPE,OPTIONS TARGET`。
- `lvs` 通过 `/dev/system/*` + `stat`/`blkid`，或调用 `lvs` 并解析。
- data 用 `statvfs` 看 `/var`/`/home`；`btrfs filesystem usage` 可选。
- `df` 通过 `statvfs`。
- 上次结果：读 `/var/lib/keel/state`（如果存在），不是 `/etc`。
- 不写状态；不做“自动修复”。

## 6. Failure modes / recovery

| 失败 | 处理 |
|---|---|
| `bootctl` 不存在 | 报 missing；不崩溃 |
| 挂载缺失 | exit 1；打印哪个 |
| ESP 未挂 | 明确警告；更新不可用 |
| JSON 解析失败 | 回退人类输出 + 警告 |

## 7. Acceptance criteria

- [ ] 输出槽/版本/root/`etc`/`var`/`home`/ESP。
- [ ] `--json` 可被 `jq` 解析。
- [ ] 缺挂载时 exit 1。
- [ ] 不修改任何文件。
- [ ] 在 rescue 环境也能运行（只读）。

## 8. Open questions / ADR links

- 状态文件位置/格式：`/var/lib/keel/state`，不进 `/etc`。
- 是否合并到 `keel-update status`：暂不；独立命令更清晰。

## 9. Test plan

E2：正常系统、缺 `/var`、ESP 未挂、rescue 环境。
E3：真机。

## 10. Changelog

| 日期 | 变更 |
|---|---|
| 2026-11-10 | 初稿 |
