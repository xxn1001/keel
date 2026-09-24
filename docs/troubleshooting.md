# keel 排错手册

> **本文描述的是设计目标行为。** mkosi 配置与 `mkosi.extra/usr/bin/os-*` 尚未实现,实现完成前以
> [`architecture.md`](architecture.md) 和实际脚本为准。标"待验证"的点见 `architecture.md` §13。

按**症状**组织,先判断自己在哪一类:

| 症状 | 去哪节 |
|---|---|
| **构建就失败了 / 开虚拟机起不来** | **§0** |
| 完全进不了系统(看不到引导、控制台没反应) | §1 |
| 起来了,但某些功能不对 | §2 |
| `/Volume` / 持久状态有问题 | §3 |
| nix 用不了 | §4 |
| 更新之后不对 | §5 |
| 要找人求助 | §6 |
| 想"手工修一下根分区" | §7(先读,别做) |

## 0. 构建期(还没到真机)

### 0.1 `The workspace directory (…) cannot be a subdirectory of any source directory (…)`

完整形态:

```
‣ Output path /work/mkosi.output/keel.raw exists already. (Use --force to rebuild.)
‣ The workspace directory (/work/mkosi.workspace) cannot be a subdirectory of any source directory (/work)
‣ (Set BuildSources= to the empty string or use WorkspaceDirectory= to configure a different workspace directory)
```

| 项 | 说明 |
|---|---|
| 含义 | mkosi 不允许 workspace 位于任何 `BuildSources=` 之内,而 `BuildSources=` 的默认值**就是配置目录**(`/work`) |
| 原因 | `mkosi.conf` 里设了 `WorkspaceDirectory=mkosi.workspace`(仓库内的路径)。现在已改成不设该设置,原因写在 `mkosi.conf` 的注释里 |
| 修 | `mkosi.conf` 里**不要**设 `WorkspaceDirectory=`;容器场景由 `tools/build-container.sh` 把 `mkosi.workspace/` 绑到容器的 `/var/tmp`(`AGENTS.md` 坑 #22) |
| 注意 | 第一行不是错误:它是 `build` 那一步"产物已存在、直接跳过"的提示(坑 #23),三条来自两次 mkosi 调用 |

### 0.2 `Output path … exists already. (Use --force to rebuild.)` 之后什么都没发生

| 项 | 说明 |
|---|---|
| 含义 | mkosi 的 `build` 是"**没有才建**":产物已存在 → 打印这行 → **返回 0**,不构建 |
| 后果 | 版本号只写在镜像内部,所以你会拿到"版本号是新的、内容是旧的"镜像,而且没有任何报错 |
| 修 | 改了配置/换了 profile(例如加 `--profile test`)之后必须 `mkosi … --force build`;`tools/build.sh` 与 `tools/build-container.sh` 已经带上 |
| 怎么确认拿到的是新镜像 | `mkosi.output/keel.manifest` 里的时间戳,或进系统后 `os-status`(`AGENTS.md` 坑 #23) |

### 0.3 其它构建期报错

| 报错 | 去哪 |
|---|---|
| `Default tools tree requested but it is out-of-date or has not been built yet` | `AGENTS.md` 坑 #19:先 `build` 再 `vm` |
| `A cache directory must be configured in order to use --incremental` | 坑 #16:mkosi 25.x 必须显式配 `CacheDirectory=`(已配好) |
| `systemd-stub not found at /usr/lib/systemd/boot/efi/linuxx64.efi.stub` | 坑 #18:缺 `systemd-boot-efi` |
| `Failed to make loopback device …: Device or resource busy` | 坑 #17:容器里 repart 要 `--offline=yes` |
| `Distribution of your host can't be detected …` | 坑 #15:宿主不受支持,用 `tools/build-container.sh` |

## 1. 完全进不了系统

按代价从低到高试:

| # | 手段 | 做法 |
|---|---|---|
| 1 | 换槽启动 | 开机时按 `space` 呼出 systemd-boot 菜单,选另一个槽的条目(`keel-a.efi` / `keel-b.efi`) |
| 2 | 追加内核参数 | 菜单里选中条目按 `e` 编辑 cmdline:**仅在未启用 Secure Boot 时有效**(v1 没启用;这条路径本身也待验证,§13.1 #5)。常用 `systemd.unit=rescue.target`(单人维护模式)、`rd.break`(在 initrd 里停下,查 `/Volume` 挂载问题)、`systemd.log_level=debug`。改动只影响这一次启动 |
| 3 | 读条目名 | 菜单里像 `keel-b+2-1.efi` 这样的名字 = 新槽已尝试并失败过;计数归零后引导器会跳过它(§5.3 ⑩) |
| 4 | U 盘 live 环境 | 把同一个 `keel.raw` 写到 U 盘、UEFI 启动:它就是一套完整 keel,可以直接 `os-rescue`、翻日志、重装系统(§7.1 B) |
| 5 | 连菜单都没出来 | 主板固件可能清了 EFI 变量(R4):系统会走 fallback 路径 `EFI/BOOT/BOOTX64.EFI`;进系统后 `bootctl install` 重建 NVRAM 启动项(`keel-firstboot` 也是这么做的,§7.2 ③) |

在菜单里选另一个槽能起来 ⇒ 这就是自动回滚已经发生过(或即将发生),按 §5 收集证据。

## 2. 能进系统,但行为不对

### 2.1 没有图形界面 / 登录不了

| 症状 | 结论 |
|---|---|
| 只有文本控制台 | **预期行为**:`main` 不含 GPU 驱动/固件,靠 `simpledrm`/`efifb` 出文本(§7.3)。要图形界面得等 `desktop` profile |
| 控制台登录不了 | 初始凭据尚未在 `architecture.md` 中规定(待验证);用 U 盘 live 环境进去看 `/etc/passwd` 与 `/Volume/keel/state` |
| SSH 连不上 | `systemctl status sshd`;`ip a` 确认有 IP;`journalctl -b -u sshd -p warning`。用户的公钥要自己放进 `~/.ssh/authorized_keys`(`/home` 在 `/Volume` 上,会持久化) |

### 2.2 网络不通

```bash
ip a                                                          # 有没有网卡、有没有地址(有线走 systemd-networkd,决策 D15)
networkctl status                                             # 每条链路的状态与配置来源
resolvectl status                                             # DNS:stub 在不在、上游是谁
resolvectl query deb.debian.org
journalctl -b -u systemd-networkd -u systemd-resolved -p warning
```

常见原因:网线/交换机是物理问题;DHCP 没拿到(`networkctl status <if>` 的 `State` 卡在 `configuring`);
`/etc/resolv.conf` 没指向 `/run/systemd/resolve/stub-resolv.conf`(postinst 里做的,§11 —— 被改坏就走 §3 的
`--reset-etc`)。无线网络 main 不做。

## 3. `/Volume` 相关

`/Volume` 由 initrd 挂载(不变量 2),`/var`、`/root`、`/nix` 都是指向它的符号链接。
所以 `/Volume` 一出问题,表现就是"到处都是空目录、机器像刚装好一样"。

```bash
findmnt /Volume                          # 挂上了吗(该挂载由 cmdline 的 systemd.mount-extra 产生,§5.1)
ls /Volume                               # var home nix overlayfs ota keel ...
systemctl status Volume.mount            # 挂载单元本身的状态(§10)
systemctl status keel-mounts.service     # bind /home + 挂 /etc overlay(§10)
systemctl status keel-firstboot.service  # 首启五件事:骨架 / 扩容 / NVRAM / swapfile / state
du -xh -d1 /Volume | sort -h             # 空间去哪了
journalctl --disk-usage                  # journal 占了多少
```

| 症状 | 处理 |
|---|---|
| 骨架不见了(目录缺失、`/var/log` 空) | `sudo os-rescue --init-volume`(幂等重建/修复骨架,§9) |
| `/etc` 被改坏、回滚后行为异常 | `sudo os-rescue --reset-etc`:清空 overlay upper,下次启动从镜像重新播种。**先备份**:它会丢掉 ssh 主机密钥、machine-id、账号、网络配置 —— 把要留的东西复制到 `/Volume/home/<user>/` 下(那不在 upper 里) |
| 装机后 `/Volume` 还是很小 | 正常应由首启的 `keel-firstboot` 自动扩盘(§7.2 ②);没扩成就用手动入口 `sudo os-rescue --grow-volume`,再 `lsblk` 确认 |
| `/Volume` 满了 | 先清 `/Volume/ota/`(用 `os-update gc`,§8),再清 journal(`journalctl --vacuum-size=`) |

## 4. nix 相关

| 症状 | 排查 |
|---|---|
| `nix` 命令不存在 | 基底包是 `nix-bin` + `nix-setup-systemd`(决策 D7);`command -v nix` 都没有说明镜像不对 |
| `/nix` 空 / 没挂上 | `ls -ld /nix` 应是指向 `/Volume/nix` 的符号链接;`findmnt /Volume`;`ls /Volume/nix`。`/Volume` 没挂 ⇒ `/nix` 悬空,回到 §3 |
| `nix-daemon` 不工作 | 它的单元带 `ConditionPathIsReadWrite=/nix/var/nix/daemon-socket`,所以 **`/Volume` 没挂好时它根本不会启动**:`systemctl status nix-daemon` 会写 condition 未满足被跳过,而不是失败。先把 `/Volume` 修好,再 `systemctl restart nix-daemon` |
| `nix` 报数据库 schema 太新 | 回滚造成的:基底升级过 nix,旧槽的 nix 读不了新 DB(§13.2 R3)。见 `update.md` §5 —— 要么回到新槽用新版 nix,要么按 R3 处理,别在旧版上反复跑 nix 试图"修好"它 |
| 换到另一个槽后 nix 里的包"消失" | 不应该发生:`/nix` 在 `/Volume` 上,两个槽共用同一个 store。真发生了说明 `/Volume` 挂载或符号链接有问题,回到 §3 |

```bash
systemctl status nix-daemon.service
journalctl -b -u nix-daemon -p warning
```

## 5. 更新相关

| 症状 | 排查 |
|---|---|
| 更新后卡住 / 反复重启 | 看 `bootctl list` 的条目名:`keel-b+2-1.efi` 这种计数递减 = 新槽连续启动失败,即将自动回滚(§5.3 ⑩) |
| 怎么确认回滚了 | `os-status` 里槽/版本没变;ESP 上有 `keel-<目标>.efi.failed`;`journalctl -b -u keel-confirm.service` 有告警;`state` 的 pending 被清空并记 failed(详见 `update.md` §3.1) |
| 坏掉的载荷在哪 | 下载的载荷在 `/Volume/ota/`(§4.2);看完原因用 `os-update gc` 清理(保留最近 2 个版本 + 当前,§8) |
| 新版本"起来了但不对" | `os-update rollback` 回上一个已知良好的槽;当前槽确实坏了再 `os-rescue --mark-bad`,并先确认另一个槽是好的(见 `update.md` §3.2) |
| `stage` 报写不下 | 槽位尺寸装机时定死(不变量 9):只能重装,或在装机前留足 |
| `fetch` 校验失败 | 载荷不完整/被改过:重下;确认更新源 URL(`/Volume/keel/config`,见 `update.md` §6) |

```bash
os-status
bootctl list
ls -l /efi/EFI/Linux/
journalctl -b -u keel-confirm.service -u keel-firstboot.service -p warning
```

## 6. 怎么收集信息求助

```bash
os-status                     # 当前槽/版本/内核、/Volume 用量、schema、pending、上次结果
journalctl -b -p warning      # 本次启动的告警以上日志
bootctl status                # ESP、固件、引导条目、当前与下次启动的条目
lsblk -f                      # 分区标签 esp/root-a/root-b/volume、文件系统、挂载点
```

| 附加项 | 用途 |
|---|---|
| `/Volume/keel/state` | 机器可读的状态(pending、上次结果) |
| `/proc/cmdline` | 当前槽由 `root=PARTLABEL=root-<x>` 体现 |
| `/efi/EFI/Linux/` 目录列表 | UKI 的实际名字与计数,以及有没有 `.failed` |

发问题时把这些贴出来,并说明:是不是刚更新过、是不是刚回滚过、有没有手动改过 `/etc`。

## 7. 不要在运行中的系统上试图修改根分区

根分区以 `ro` 挂载,而且**改它会破坏 A/B 一致性**(不变量 1、3):每个槽的根文件系统与它自己的 UKI
是配对的,单独改一半就会出现"新内核 + 旧根"或"旧内核 + 新根",这正是回滚失效的经典成因。

| 不要做 | 改用 |
|---|---|
| `mount -o remount,rw /` 然后改 `/usr`、往里装东西 | 装软件用 **nix**;改系统行为用 `/etc`(overlay,可写且持久) |
| 直接 `dd` 或 `mount` 去写 `/dev/disk/by-partlabel/root-a` / `root-b` | `os-update`:它只写非活动槽,并记 pending |
| 手改 `/efi/EFI/Linux/keel-*.efi` 的文件名来"手动回滚" | `os-update rollback`,或 `bootctl set-preferred keel-<槽>.efi`(§5.3 ⑤) |
| 在正跑着的那块盘上执行 `os-install /dev/<自己>` | 会覆盖正在运行的槽;`os-install` 只在 U 盘 live 环境里对**目标盘**执行(§7.1 B) |

真的需要改根文件系统的内容(例如加一个基底包),正确路径是改仓库里的 mkosi 配置 →
`tools/build.sh` → 用 `os-update` 发一个新版本,而不是在运行中的系统上动手。
