---
id: Q-0010
question: How are disk images built and tested without loop devices or root?
blocking: W-1 / v0.1
owner: TBD
updated: 2026-11-14
---

# Q-0010 镜像构建与测试装置

## Context

要验证 A/B、recovery、安装器，都必须先有一块"已经分好区、有 LVM、有两个 erofs LV"的盘。
但两块环境都不给力：

- GitHub-hosted runner：没有 `/dev/loop`、没有 root，不能 `losetup`/`kpartx`；
- 文档撰写环境（E0）：同样没有 loop，也没有 qemu。

现在的文档只写了"安装时会建"，没人说过第一个镜像从哪来。

## Options

### A. guest 内安装器两阶段（建议）

```text
phase 1: 起一个小 VM（W-0 的镜像），挂空白 qcow2
         guest 内跑 keel-install --disk /dev/vda
         sfdisk -> pvcreate -> vgcreate -> lvcreate
                 -> mkfs.erofs / mkfs.ext4 / mkfs.btrfs
phase 2: 同一块盘重启，走正常启动链，跑验收
```

- 优点：不需要 loop、不需要 root，CI 与本地同一套；**安装器从第一天就被测**，
  不用等 v0.3；失败留在 guest 里看完再关机。
- 缺点：每次多一次 VM 启动（TCG 下约 +40 s）；安装器必须能处理"盘上已有内容"。

### B. CI runner 带 loop

- 用 self-hosted runner，加 `--privileged` 或者 `CAP_SYS_ADMIN`。
- 优点：宿主侧脚本简单，`losetup` 后直接 `mkfs`。
- 缺点：runner 变成特权环境，安全面变大；和"任何人能复现"冲突。

### C. 宿主用 `qemu-nbd` / `guestfish`

- 不需要 loop，但需要 `nbd` 内核模块或 libguestfs 全家桶。
- 优点：宿主侧可控；缺点：依赖重，TCG runner 上装不下来，且需要 root 加载模块。

## Recommendation

A。核心理由不是"省事"，是**测试路径和产品路径合一**：安装器本来就要写这块盘，
测试装置复用它，等于每次 CI 都在跑安装器。

配套要求（写进 F-011 的接口）：

- `keel-install --disk <dev>` 非交互，可重复执行，已有分区时默认拒绝（`--force` 覆盖）；
- 退出码区分：0 成功、2 参数错、3 磁盘不认识、4 写失败；
- 所有破坏性操作前先 `--dry-run` 打印计划；
- 结束时打印摘要，便于在串口日志里 grep。

## Decision gate

W-1 开始前。至少要确定：qcow2 尺寸（建议 64 GiB）、phase 1 用哪个镜像、
以及 CI 里怎么等待 phase 1 结束（串口匹配字符串还是退出码）。
