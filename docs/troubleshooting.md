# keel 排错手册

> **本文描述的是设计目标行为。** mkosi 配置与 `mkosi.extra/usr/bin/os-*` 尚未实现,实现完成前以
> [`architecture.md`](architecture.md) 和实际脚本为准。标"待验证"的点见 `architecture.md` §13。

按**症状**组织,先判断自己在哪一类:

| 症状 | 去哪节 |
|---|---|
| **构建就失败了 / 开虚拟机起不来** | **§0** |
| 完全进不了系统(看不到引导、控制台没反应) | §1 |
| 起来了,但某些功能不对 | §2 |
| `/data` / 持久状态有问题 | §3 |
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
| 修 | `mkosi.conf` 里**不要**设 `WorkspaceDirectory=`;容器场景由 `tools/build-container.sh` 把 `mkosi.workspace/` 绑到容器的 `/var/tmp`(`docs/traps.md` 坑 #22) |
| 注意 | 第一行不是错误:它是 `build` 那一步"产物已存在、直接跳过"的提示(坑 #23),三条来自两次 mkosi 调用 |

### 0.2 `Output path … exists already. (Use --force to rebuild.)` 之后什么都没发生

| 项 | 说明 |
|---|---|
| 含义 | mkosi 的 `build` 是"**没有才建**":产物已存在 → 打印这行 → **返回 0**,不构建 |
| 后果 | 版本号只写在镜像内部,所以你会拿到"版本号是新的、内容是旧的"镜像,而且没有任何报错 |
| 修 | 改了配置/换了 profile(例如加 `--root-password=`)之后必须 `mkosi … --force build`;`tools/build.sh` 与 `tools/build-container.sh` 已经带上 |
| 怎么确认拿到的是新镜像 | `mkosi.output/keel.manifest` 里的时间戳,或进系统后 `os-status`(`docs/traps.md` 坑 #23) |

### 0.3 其它构建期报错

| 报错 | 去哪 |
|---|---|
| `Default tools tree requested but it is out-of-date or has not been built yet` | `docs/traps.md` 坑 #19:先 `build` 再 `vm` |
| `A cache directory must be configured in order to use --incremental` | 坑 #16:mkosi 25.x 必须显式配 `CacheDirectory=`(已配好) |
| `systemd-stub not found at /usr/lib/systemd/boot/efi/linuxx64.efi.stub` | 坑 #18:缺 `systemd-boot-efi` |
| `Failed to make loopback device …: Device or resource busy` | 坑 #17:容器里 repart 要 `--offline=yes` |
| `Distribution of your host can't be detected …` | 坑 #15:宿主不受支持,用 `tools/build-container.sh` |

## 1. 完全进不了系统

按代价从低到高试:

| # | 手段 | 做法 |
|---|---|---|
| 1 | 换槽启动 | 开机时按 `space` 呼出 systemd-boot 菜单,选另一个槽的条目(`keel-a.efi` / `keel-b.efi`) |
| 2 | 追加内核参数 | 菜单里选中条目按 `e` 编辑 cmdline:**仅在未启用 Secure Boot 时有效**(v1 没启用;这条路径本身也待验证,§13.1 #5)。常用 `systemd.unit=rescue.target`(单人维护模式)、`rd.break`(在 initrd 里停下,查 `/data` 挂载问题)、`systemd.log_level=debug`。改动只影响这一次启动 |
| 3 | 读条目名 | 菜单里像 `keel-b+2-1.efi` 这样的名字 = 新槽已尝试并失败过;计数归零后引导器会跳过它(§5.3 ⑩) |
| 4 | U 盘 live 环境 | 把同一个 `keel.raw` 写到 U 盘、UEFI 启动:它就是一套完整 keel,可以直接 `os-rescue`、翻日志、重装系统(§7.1 B) |
| 5 | 连菜单都没出来 | 主板固件可能清了 EFI 变量(R4):系统会走 fallback 路径 `EFI/BOOT/BOOTX64.EFI`;进系统后 `bootctl install` 重建 NVRAM 启动项(`keel-firstboot` 也是这么做的,§7.2 ③) |

在菜单里选另一个槽能起来 ⇒ 这就是自动回滚已经发生过(或即将发生),按 §5 收集证据。

### 1.1 落到 `emergency mode`(而且换槽也一样)

先看**是哪条依赖先断的**——第一行 `[DEPEND] Dependency failed for …` 通常就是根因,
后面的失败都是它的连锁反应:

```bash
systemctl --failed                        # 失败的单元清单
journalctl -b -p warning --no-pager | tail -40
journalctl -b | grep -E 'Dependency failed|Timed out|Ordering cycle'
findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS   # /data 到底挂上没有
lsblk -o NAME,SIZE,TYPE,PARTLABEL,FSTYPE  # 分区标签对不对
```

两个已经踩过、**已在 2026-09 修掉**的早期启动连环故障(供对照,见 `docs/traps.md` 坑 #24/#25):

| 症状 | 原因 |
|---|---|
| `Timed out waiting for device dev-disk-by-partlabel-data.device` → `data.mount` 依赖失败 → `local-fs.target` 失败 | cmdline 的 `systemd.mount-extra=PARTLABEL=…` 需要 udev 建符号链接,而 udev 又要等可写的 `/etc`,`/etc` overlay 又要等 `/data` ⇒ 环形依赖。日志里会有一行 `[ SKIP ] Ordering cycle found, skipping local-fs-pre.target` |
| `systemd-random-seed.service` / `systemd-timesyncd.service` 失败 | 它们是往 `/var`(→ `/data`)写的,而 `/data` 那时还没挂上 |

现在 `/data` 由 `keel-mounts.service` 自己挂(不依赖 udev),ESP 由 gpt-auto 按需挂载。
如果你在别的机器上看到这两类失败,先确认跑的是不是 2026-09 之后的镜像(`os-status` 里的版本号)。

> **VM 测试的一个坑**:`mkosi vm` 会往 cmdline 追加 `rw`,所以虚拟机里根分区是**可写**的 ——
> 只读根相关的 bug(以及 `/etc` overlay 没挂上时的写入行为)在虚拟机里**看不见**,真机才会暴露。

## 2. 能进系统,但行为不对

### 2.1 没有图形界面 / 登录不了

| 症状 | 结论 |
|---|---|
| 只有文本控制台 | **预期行为**:`main` 不含 GPU 驱动/固件,靠 `simpledrm`/`efifb` 出文本(§7.3)。要图形界面得等 `desktop` profile |
| 控制台登录不了 | 初始凭据尚未在 `architecture.md` 中规定(待验证);用 U 盘 live 环境进去看 `/etc/passwd` 与 `/data/keel/state` |
| SSH 连不上 | `systemctl status sshd`;`ip a` 确认有 IP;`journalctl -b -u sshd -p warning`。用户的公钥要自己放进 `~/.ssh/authorized_keys`(`/home` 在 `/data` 上,会持久化) |

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

**DHCP 拿不到时先看 `/etc/machine-id`**(这是坑 #29,曾经害我们上了 dhcpcd 顶替):

```bash
cat /etc/machine-id        # 必须是 32 位十六进制;打印 "uninitialized" 就是这个问题
os-status                  # 「网络」一节会直接告警(机器 ID 无效 + 没有 IPv4 地址)
journalctl -b -u systemd-networkd | grep -iE 'DHCP|ENOPKG'
```

`/etc/machine-id` 是 `uninitialized`/空时,networkd 生成 DUID(默认 `DUIDType=uuid`)会拿到
`-ENOPKG`,日志里的文字是误导性的 `Failed to configure DHCPv4 client: Package not installed`
(新版本报的是 `Failed to start DHCPv4 client: …`,同一个 errno);
同一个原因还会让 IPv6 稳定隐私地址、resolved 的 DNSSEC 密钥一起失效。
正常流程由 `keel-mounts` 在挂完 `/etc` overlay 之后立刻**把 PID1 本次启动的
`/run/machine-id` 固化进 `/etc/machine-id`**(写进 overlay 的 upper ⇒ 在 `/data` 上,
换槽/更新都不丢)。手动修:

```bash
# ⚠ 光跑 systemd-machine-id-setup 是**没用的**:文件内容是 "uninitialized" 时它故意什么都不做
#   (而且返回 0)。先清空,再让它生成:
: > /etc/machine-id
systemd-machine-id-setup
cat /etc/machine-id                  # 应该是 32 位十六进制
systemctl restart systemd-networkd   # 让 networkd 重新配 DUID/DHCP
```

> 历史教训(别再走回头路):我们一度用 `dhcpcd-base` + `DHCP=no` 绕过它 ——
> 根因修掉之后 dhcpcd 已从镜像移除。**不要**为了"先有网"再挂第二个 DHCP 客户端:
> 两个客户端抢一块网卡只会互相打架,而 `/etc/machine-id` 该修就得修 —— 它影响的不只是 DHCP。

### 2.3 `os-status` 说「ESP 挂载: 没有挂上」/ 看不到任何 UKI

```bash
os-status                      # 「ESP 挂载」那一行是不是「没有挂上」
findmnt /boot                  # 期望:vfat,源是 /dev/...;不是挂载点就是没挂上
ls -l /boot/EFI/Linux/         # 这里必须有 keel-a.efi / keel-b.efi(可能带 +N 计数)
journalctl -b -u keel-mounts | grep -i esp
```

ESP 由 `keel-mounts` 在启动早期扫 `PARTNAME=esp` 自己挂到 `/boot`
(`systemd-gpt-auto-generator` 已被 cmdline 的 `systemd.gpt_auto=no` 关掉,决策 D18)。
它没挂上时,**别的都不会报错**:`os-update` 会拒绝写(它在写根分区之前先检查 ESP),
`bootctl set-oneshot`/`set-default`、boot counting 改名、`keel-confirm` 确认槽全部失效
(表现:`os-status` 的 `上次启动结果: 无记录` 长期不变)。修:

```bash
sudo os-rescue --repair-boot   # 会先确保 ESP 挂上,再 bootctl install
sudo systemctl restart keel-mounts   # 只是想把挂载重做一遍
```

还不行就按顺序查:

| 检查 | 期望 |
|---|---|
| `lsblk -o NAME,SIZE,PARTLABEL /dev/vda` | 有 `PARTLABEL=esp` 的分区 |
| `dmesg | tail`(挂载时) | 没有 vfat 的 I/O 报错(FAT 损坏时会挂不上) |
| `systemctl status keel-mounts --no-pager` | 没有失败;日志里有「已把 ESP(PARTNAME=esp)挂到 /boot」 |

> 旧文档/旧日志里的 `/Volume` 就是现在的 `/data`(2026-09 改名,决策 D17);
> 分区标签就是 `data`,所以 `lsblk` 里 `PARTLABEL` 也是 `data`。

### 2.4 ESP 写不进去 / `os-update stage` 说「ESP 可用空间只有 … MiB」

ESP 只有 1 GiB,而一个 UKI 约 157 MiB。`systemd-bless-boot` 会把"起不来"的槽留成
`keel-<槽>.efi.failed` 墓碑,反复失败/反复更新还会留下旧的计数条目 —— 它们**不参与启动、
只吃空间**。

```bash
df -h /boot                     # ESP 的可用空间(低于 ~400 MiB 就该清)
ls -l /boot/EFI/Linux/          # 有哪些 keel-* 条目
sudo os-rescue --clean-esp      # 清墓碑 + 已被正式条目取代的计数条目
```

`--clean-esp` **只删残留**:`.failed`/`.bad` 墓碑,以及"同槽已有 `keel-<槽>.efi` 正式条目"的
旧计数条目(`+N.efi`)。正式条目、**正在等待确认(pending)的那个候选条目**、引导器文件与
NVRAM 都不动;删前删后都会把清单和回收的空间打出来。

正常的更新路径会自己收敛:`os-update stage` 在**动根分区之前**就检查 ESP 空间(不够直接拒,
提示里带 `--clean-esp`),并顺手清掉所有槽的墓碑。`keel-check` 在 ESP 可用低于 400 MiB 时
会给出警告。

### 2.5 登录不了(`keel login:` 上输什么都不对)

镜像里唯一的账号是 **`admin`**,root 是**锁定**的(决策 D21)—— 所以"用 root 试一下"永远不会成功。

| 现象 | 原因 | 修 |
|---|---|---|
| 输 `root` + 任何密码都失败 | 预期行为:root 的 `/etc/shadow` 字段是 `!`,`PermitRootLogin no`,连 mkosi 塞进 credstore 的那份 root 密码 credential 都在构建时删了 | 用 `admin` 登录;要 root shell 就 `sudo -i` |
| `admin` 也没密码(登录时提示密码错误) | 构建时既没给 `-p` / `mkosi.rootpw`,也没放 `authorized_keys` —— `mkosi.finalize` 在构建日志里为此打过明确警告 | 只能从 U 盘 live 环境挂上目标盘处理;或者重新构建一个带凭据的产物再装 |
| SSH:`Permission denied (publickey)` | `authorized_keys` 放的位置不对,或者放晚了(它必须**在构建前**就在仓库根目录,`mkosi.finalize` 才会把它写进 `/data` 骨架的 `home/admin/.ssh/`) | 确认仓库根目录有 `authorized_keys` 后**重新构建**;已经装好的机器可以直接把公钥写到 `/data/home/admin/.ssh/authorized_keys`(`/data` 坏了才需要救) |
| 有 `admin`、也有密码,但 `sudo` 报 `admin is not in the sudoers file` | `/etc/sudoers.d/10-keel-admin` 丢了,或权限不对(sudo 会忽略组/其他人可写的文件) | `ls -l /etc/sudoers.d/10-keel-admin` 应为 `0440 root root`;丢了就 `os-rescue --reset-etc` 从镜像重新播种(会丢本机 `/etc` 改动,先备份) |
| `/data` 坏掉时登录提示"could not chdir to home directory" | 预期行为:账号在镜像的只读 `/etc` 里,但 `/home/admin`(=`/data/home/admin`)没挂上 | 能登进去就先用着;按 §3 修 `/data` |

线上自查(不用登录也能看):`os-status` 的「登录账号」一节会打印 admin 是否存在、
密码字段是不是哈希、root 是否锁定、sudoers 文件在不在。

### 2.6 装机时 `os-install` 报错

| 现象 | 原因 | 修 |
|---|---|---|
| `找不到 repart 定义目录:/usr/lib/keel/repart-install.d(这个镜像不完整?)` | 这个产物里没装安装用的 repart 定义:`os-install` 要靠镜像内的 `/usr/lib/keel/repart-install.d` 在目标盘上建表,它由 `mkosi.postinst` 在构建时从 `repart/install/` 拷进去(`docs/traps.md` 坑 #31)。2026-09 之前的产物都没有这个目录 | 重新构建(`sudo tools/build-container.sh -p <临时密码>`)并重写 U 盘/虚拟盘 |
| 建表阶段:`mkfs binary for vfat is not available.` | 镜像里缺 `dosfstools`(`mkfs.vfat`)—— repart 要在目标盘上把 ESP 格式化成 vfat,而构建时那次 repart 用的是 tools tree,所以构建全绿(`docs/traps.md` 坑 #32) | 重新构建(包清单已补 `dosfstools`) |
| 建表成功后:`建表后找不到目标盘上的 root-a 分区` | 刚写完分区表时 `lsblk` 的 `PARTLABEL`(来自 udev 数据库)可能还是空的 —— 旧版 `find_part` 只查它,于是 repart 建好了分区却「一个都找不到」(`docs/traps.md` 坑 #33) | 新版已改成**先扫 sysfs 的 `PARTNAME`**、失败则重读分区表重试约 10 秒,并把 `lsblk` / `/proc/partitions` 现场打出来;重新构建后重试。若仍失败,把现场那几行发出来 |
| 建表成功但后面的步骤报错 | `os-install` 这条路径 **尚未在真机上验证过**(脚本头部的声明) | 把报错原文 + `lsblk -f` 现状贴出来,不要盲目重试 |

> 注意:`os-install` 会**擦除整块目标盘**。在 VM 里演练时,目标盘要是另一块盘
> (`qemu-img create -f raw keel-target.raw 30G` 挂成 vda/vdb),别指向启动盘。

## 3. `/data` 相关

`/data` 由 `keel-mounts.service` 在启动早期挂载(不变量 2:扫 `/sys` 的 `PARTNAME=data`,
不依赖 udev)。`/var`、`/root` 是指向它的符号链接,`/home`、`/nix` 由它 bind 上来。
所以 `/data` 一出问题,表现就是"到处都是空目录、机器像刚装好一样"。

```bash
findmnt /data                          # 挂上了吗(由 keel-mounts 挂,见 docs/traps.md 坑 #24)
ls /data                               # var home nix overlayfs ota keel ...
systemctl status keel-mounts.service     # 挂 /data + bind /home + 挂 /etc overlay
systemctl status keel-firstboot.service  # 首启六件事:骨架 / 扩容 / NVRAM / swapfile / state / 应急空间
systemctl status keel-data-guard.timer   # /data 空间的看门人(启动 3 分钟后 + 每天一次,决策 D23)
cat /data/keel/data-guard.state          # 它上次看到的结论:verdict / avail / reserve
lsblk -o NAME,SIZE,TYPE,PARTLABEL,FSTYPE,LABEL   # PARTLABEL=data 的分区在不在
du -xh -d1 /data | sort -h             # 空间去哪了
journalctl --disk-usage                  # journal 占了多少(上限由 journald.conf.d/keel.conf 定)
```

| 症状 | 处理 |
|---|---|
| 骨架不见了(目录缺失、`/var/log` 空) | `sudo os-rescue --init-data`(幂等重建/修复骨架,§9) |
| `/etc` 被改坏、回滚后行为异常 | `sudo os-rescue --reset-etc`:清空 overlay upper,下次启动从镜像重新播种。**先备份**:它会丢掉 ssh 主机密钥、machine-id、账号、网络配置 —— 把要留的东西复制到 `/data/home/<user>/` 下(那不在 upper 里)。旧的可写层会被保留成**一份**备份(`/data/overlayfs/etc.bak-<时间戳>`,更早的自动清理) |
| 装机后 `/data` 还是很小 | 正常应由首启的 `keel-firstboot` 自动扩盘(§7.2 ②);没扩成就用手动入口 `sudo os-rescue --grow-data`,再 `lsblk` 确认 |
| `/data` 快满了 | 先看 `os-status` 的「空间看门人」:低于 2 GiB 时 `keel-data-guard` 已经自动回收过 journal 与 nix;手动版本是 `os-update gc`(清旧载荷)、`journalctl --vacuum-size=128M`、`nix-store --gc`。低于 512 MiB 时它会交还 `/data/keel/.reserve`(256 MiB 应急空间),并留下 `/data/keel/reserve-consumed` 记录 |
| `/data` 已经写满,`/etc` 也写不进去(服务开始报 ENOSPC) | 这是坑 #37 的形状。应急顺序:① `rm -f /data/keel/.reserve`;② `journalctl --vacuum-size=32M`;③ `os-update gc` 删掉 `/data/ota` 里的旧载荷;④ `nix-store --gc`。**别删 `/data/overlayfs/etc/upper`** —— 那里面是账号、SSH 主机密钥、machine-id |

## 4. nix 相关

| 症状 | 排查 |
|---|---|
| `nix` 命令不存在 | 基底包是 `nix-bin` + `nix-setup-systemd`(决策 D7);`command -v nix` 都没有说明镜像不对 |
| `/nix` 空 / 没挂上 | `findmnt /nix` 应该看到一个 bind 挂载(源 `/data/nix`);`ls -ld /nix` 必须是**目录**(不能是符号链接,坑 #34);再看 `findmnt /data` 与 `ls /data/nix`。`/data` 没挂 ⇒ 回到 §3 |
| `error: the path '/nix' is a symlink; this is not allowed for the Nix store and its parent directories` | 这个系统装的是**旧镜像**:那时 `/nix` 还是指向 `/data/nix` 的符号链接。nix 硬性拒绝符号链接的 store 路径,改 store 位置也没用(二进制与 RPATH 里写死了 `/nix/store/…`)。新版已改成「真实目录 + bind mount」(`docs/traps.md` 坑 #34) | ① 正路:换到新槽(`os-update`)或重装 —— 新根文件系统里的 `/nix` 就是真目录;② 想马上用,按下面热修 |
| `nix-daemon` 不工作 | 它的单元带 `ConditionPathIsReadWrite=/nix/var/nix/daemon-socket`,所以 **`/data` 没挂好时它根本不会启动**:`systemctl status nix-daemon` 会写 condition 未满足被跳过,而不是失败。先把 `/data` 修好,再 `systemctl restart nix-daemon` |
| `nix` 报数据库 schema 太新 | 回滚造成的:基底升级过 nix,旧槽的 nix 读不了新 DB(§13.2 R3)。见 `update.md` §5 —— 要么回到新槽用新版 nix,要么按 R3 处理,别在旧版上反复跑 nix 试图"修好"它 |
| 换到另一个槽后 nix 里的包"消失" | 不应该发生:`/nix` 在 `/data` 上,两个槽共用同一个 store。真发生了说明 `/data` 挂载或符号链接有问题,回到 §3 |

**旧系统的热修**(只在 `error: the path '/nix' is a symlink` 那条上需要;新镜像不需要):

```bash
# 1. 把根文件系统里的 /nix 从符号链接换成真目录(根是 ro 挂的,先临时放开)
mount -o remount,rw /
rm -f /nix && install -d -m 0755 /nix
mount -o remount,ro /

# 2. 立刻 bind 一次并验证
mount --bind /data/nix /nix
findmnt /nix && nix --version

# 3. 让每次启动都自动做(单元写在 /etc overlay 里,持久保存在 /data 上)
cat >/etc/systemd/system/keel-nixbind.service <<'EOF'
[Unit]
Description=keel:/nix bind mount(hotfix;正式镜像由 keel-mounts 做)
After=local-fs.target
RequiresMountsFor=/data

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/mount --bind /data/nix /nix

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload && systemctl enable --now keel-nixbind.service
```

> 注意热修只改**当前这一槽**的根文件系统(下一次 `os-update` / 换槽会换成新镜像的根,那时
> `/nix` 本来就是真目录,`keel-nixbind.service` 留着也无害 —— 它是幂等的 `mount --bind`)。

```bash
systemctl status nix-daemon.service
journalctl -b -u nix-daemon -p warning
```

## 5. 更新相关

| 症状 | 排查 |
|---|---|
| 更新后卡住 / 反复重启 | 看 `bootctl list` 的条目名:`keel-b+2-1.efi` 这种计数递减 = 新槽连续启动失败,即将自动回滚(§5.3 ⑩) |
| 怎么确认回滚了 | `os-status` 里槽/版本没变;ESP 上有 `keel-<目标>.efi.failed`;`journalctl -b -u keel-confirm.service` 有告警;`state` 的 pending 被清空并记 failed(详见 `update.md` §3.1) |
| 坏掉的载荷在哪 | 下载的载荷在 `/data/ota/`(§4.2);看完原因用 `os-update gc` 清理(保留最近 2 个版本 + 当前,§8) |
| 新版本"起来了但不对" | `os-update rollback` 回上一个已知良好的槽;当前槽确实坏了再 `os-rescue --mark-bad`,并先确认另一个槽是好的(见 `update.md` §3.2) |
| `stage` 报写不下 | 槽位尺寸装机时定死(不变量 9):只能重装,或在装机前留足 |
| `fetch` 校验失败 | 载荷不完整/被改过:重下;确认更新源 URL(`/data/keel/config`,见 `update.md` §6) |

```bash
os-status
bootctl list
ls -l "$(bootctl --print-esp-path)/EFI/Linux/"
journalctl -b -u keel-confirm.service -u keel-firstboot.service -p warning
```

## 6. 怎么收集信息求助

```bash
os-status                     # 当前槽/版本/内核、/data 用量、schema、pending、上次结果
journalctl -b -p warning      # 本次启动的告警以上日志
bootctl status                # ESP、固件、引导条目、当前与下次启动的条目
lsblk -f                      # 分区标签 esp/root-a/root-b/data、文件系统、挂载点
```

| 附加项 | 用途 |
|---|---|
| `/data/keel/state` | 机器可读的状态(pending、上次结果) |
| `/proc/cmdline` | 当前槽由 `root=PARTLABEL=root-<x>` 体现 |
| `$(bootctl --print-esp-path)/EFI/Linux/` 目录列表 | UKI 的实际名字与计数,以及有没有 `.failed` |

发问题时把这些贴出来,并说明:是不是刚更新过、是不是刚回滚过、有没有手动改过 `/etc`。

## 7. 不要在运行中的系统上试图修改根分区

根分区以 `ro` 挂载,而且**改它会破坏 A/B 一致性**(不变量 1、3):每个槽的根文件系统与它自己的 UKI
是配对的,单独改一半就会出现"新内核 + 旧根"或"旧内核 + 新根",这正是回滚失效的经典成因。

| 不要做 | 改用 |
|---|---|
| `mount -o remount,rw /` 然后改 `/usr`、往里装东西 | 装软件用 **nix**;改系统行为用 `/etc`(overlay,可写且持久) |
| 直接 `dd` 或 `mount` 去写 `/dev/disk/by-partlabel/root-a` / `root-b` | `os-update`:它只写非活动槽,并记 pending |
| 手改 `$(bootctl --print-esp-path)/EFI/Linux/keel-*.efi` 的文件名来"手动回滚" | `os-update rollback`,或 `bootctl set-default keel-<槽>.efi`(§5.3 ⑤;候选槽试一次用 `set-oneshot`) |
| 在正跑着的那块盘上执行 `os-install /dev/<自己>` | 会覆盖正在运行的槽;`os-install` 只在 U 盘 live 环境里对**目标盘**执行(§7.1 B) |

真的需要改根文件系统的内容(例如加一个基底包),正确路径是改仓库里的 mkosi 配置 →
`tools/build.sh` → 用 `os-update` 发一个新版本,而不是在运行中的系统上动手。
