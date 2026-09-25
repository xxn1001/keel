# keel 安装指南

> **本文描述的是设计目标行为。** 实现代码(mkosi 配置与 `mkosi.extra/usr/bin/os-*` 脚本)仍在编写中,实现完成前以
> [`architecture.md`](architecture.md) 和仓库里的实际脚本为准;标"待验证"的假设集中在 §13。

读者:要把 keel 装到真机上的人。流程很短,风险集中在两件事 ——
**目标盘会被整盘擦除**,以及**槽位尺寸装机时定死、以后改不了**。

## 1. 第一步永远是在 QEMU 里跑一遍

**任何真机操作之前,先把镜像在虚拟机里跑起来。** 这一步不碰任何真实磁盘,坏了删掉重来。

> ### ⚠️ 构建宿主不是 mkosi 支持的发行版(例如 NixOS)
>
> mkosi 要求**宿主本身**是它支持的发行版(dnf/apt/pacman/zypper 之一)。因为它要先**用宿主的包管理器**
> 建出一棵 tools tree(`apt`、`ukify`、`repart`、`qemu` 全在那棵树里),再用那棵树去构建 Debian 目标镜像。
> 在 NixOS 上你会看到:
>
> ```
> ‣ Distribution of your host can't be detected or isn't a supported target. Defaulting to Distribution=custom.
> ‣ Default tools tree requested but it is out-of-date or has not been built yet
> ```
>
> - 第一行是"镜像 `Distribution=` 的默认值取不到",**可以忽略** —— `mkosi.conf` 已经显式写了 `Distribution=debian`;
> - 第二行才是真正的拦路虎:**建不出 tools tree,就没法把 Debian 包装进镜像**。
>   这不是配置能绕过去的(构建 Debian 镜像本质上需要一个 Debian 系的包管理器),
>   设 `ToolsTreeDistribution=debian` 也没用 —— 建那棵树同样需要宿主上的 `apt`。
>
> **解法:把一个受支持发行版的容器当宿主。**
>
> ```bash
> sudo tools/build-container.sh          # 构建(verify + build.sh)
> sudo tools/build-container.sh vm       # 构建并在容器里起 QEMU(有 /dev/kvm 会自动传进去)
> sudo tools/build-container.sh shell    # 进容器手敲 mkosi,排错用
> ```
>
> 容器默认是 `debian:trixie`(mkosi 25.3,满足我们的 `MinimumVersion=25`,且与目标同发行版);
> `qemu`/`OVMF` 不用装 —— mkosi 建 tools tree 时会按需带上。产物落在宿主机的
> `mkosi.output/` 与 `dist/`(属主是 root)。需要 root,因为 mkosi 的构建沙箱要 `CAP_SYS_ADMIN`。
>
> NixOS 上没有容器引擎的话:`nix-shell -p podman`,或者打开 `virtualisation.podman.enable`。
> 若 Debian 的 mkosi 25.3 不认某个设置,换镜像即可:
> `KEEL_BUILD_IMAGE=docker.io/library/archlinux:latest sudo tools/build-container.sh`(Arch 的 mkosi 是 27)。
>
> 这个脚本**没有在 NixOS 上实测过**(开发环境里没有容器引擎)。出问题把命令与报错贴出来。

### 1.1 需要什么

| 项 | 说明 |
|---|---|
| 构建产物 | `tools/verify.sh && tools/build.sh` → `dist/keel-<version>/keel.raw` |
| **第一次要先 build** | `ToolsTree=default` 的 tools tree **只在 `build` 动作里**自动构建。tools tree 还没建时直接跑 `vm`,mkosi 会拒绝并提示你先 build(`AGENTS.md` 已知的坑 #19)。所以第一次是两条命令:`mkosi --profile install --profile test build`,成功之后 `mkosi --profile install --profile test vm`。`tools/build-container.sh vm` 已经替你做了这两步 |
| **`--force` 不是可选项** | mkosi 的 `build` 是"**没有才建**":`mkosi.output/keel.raw` 已存在时它只打印 `‣ Output path … exists already. (Use --force to rebuild.)` 然后**返回成功、什么都不建**。版本号只写在镜像内部(文件名里没有版本),所以不加 `-f` 的结果是"版本号是新的、内容是旧的",你会拿着一份旧镜像去开机/装机(`AGENTS.md` 坑 #23)。`-f` 只重建输出、不动增量缓存;连缓存一起删是 `-ff`,我们不用 |
| QEMU + OVMF | **不用手动装**:`ToolsTree=default`(推荐,`AGENTS.md` 坑 #10)时由 mkosi 的 tools tree 提供;mkosi 27 的 Debian runtime profile 里就是 `qemu-system` + `ovmf` |
| `/dev/kvm` | 有才快;没有会极慢,见 §1.2 |

### 1.2 启动、退出与追加 QEMU 参数

```bash
# -p 给 **admin** 设一个**临时密码**,才能从文本控制台登录(用户名 admin / 你给的那个密码)。
# 不加 -p 就没有密码:这时只能靠 authorized_keys 里的 SSH 公钥进(见 §2.5)。
# 密码只从这个命令行参数来,仓库里不存(公开仓库 = 密码公开);它会同时传给 build 与 vm 两步 —— 
# mkosi 的 vm 读的是上一次 build 的 history,只在 vm 上传会被忽略(AGENTS.md 坑 #30)。
sudo tools/build-container.sh -p <临时密码> vm     # = verify + --force build + vm

# 宿主本身是 Debian 系(不用容器)时,等价的原始命令是这两条:
sudo mkosi --profile install --profile test --root-password=<临时密码> --force build
sudo mkosi --profile install --profile test --root-password=<临时密码> vm
```

> **进虚拟机**:等 `keel login:`,输 `admin` / 你刚给的那个临时密码。
> root 是**锁定**的(凭密码和密钥都进不去,`PermitRootLogin no`,决策 D21);要提权用 `sudo`。
> (以前用 mkosi 的 `Autologin=yes`,因为镜像里缺 `/bin/login` 而变成死循环,见 `AGENTS.md` 坑 #26/#28;
> VSock ssh 那条路也去掉了,见坑 #27。)

虚拟机里就是一台完整的 keel:`esp` / `root-a` / `root-b` / `data` 四个分区都在,
可以在里面练 `os-update`、`os-rescue`、槽切换,不用等真机。

| 想做什么 | 怎么做 |
|---|---|
| 退出(nographic 串口控制台,默认) | 先按 `Ctrl-a`,再按 `x` |
| 退出(图形窗口,`--console=gui`) | 关掉窗口 |
| 进 QEMU 监控台 / 切回 | `Ctrl-a` 然后 `c`(监控台里 `quit` 也能退出) |
| 追加 QEMU 参数 | `sudo mkosi --profile install --profile test vm -- -m 4G -smp 4`(`vm` 后面 `--` 起的都交给 QEMU) |
| 换控制台模式 | `--console=gui` / `--console=headless`(默认 `native`:串口接在当前终端) |

**没有 `/dev/kvm` 时 QEMU 退化成纯软件模拟(TCG)**:启动要几分钟到十几分钟,`os-update stage`
写一整个 6 GiB 分区会慢到让人以为卡死 —— 长时间没有输出先等,别急着重启。

> 待验证:本仓库**没有在任何环境跑通过** `mkosi vm`(开发容器没有 `/dev/kvm`、没有 loop 设备、
> ext4 不支持 reflink)。首次真机构建预计还要 2–3 轮修,见 `architecture.md` §13.2 R8。

## 2. 装到真机:两条路径

### 2.1 路径 A:构建机直接烧盘(首选)

```bash
tools/verify.sh && tools/build.sh    # 产出 dist/keel-<version>/keel.raw
lsblk -o NAME,SIZE,MODEL             # 先确认设备名,认错盘不可逆
sudo tools/burn.sh /dev/nvme0n1      # 包装 mkosi burn:按目标盘修正 GPT + 写入 + 回读校验
```

`tools/burn.sh` 只做两件事:写入 `keel.raw`;把 `data` 分区扩到目标盘剩余空间(§3.1)——
适合目标盘能拆下来、能接到构建机上的场景。

### 2.2 路径 B:U 盘当 live,自己装自己

目标盘拆不下来(内置 NVMe)时:

```bash
# 1. 把同一个 keel.raw 写到 U 盘,先 lsblk 确认 /dev/sdX 是 U 盘
sudo tools/burn.sh /dev/sdX

# 2. UEFI 启动 U 盘 → 进 live 环境(keel 本身:文本控制台 + SSH,没有图形界面)

# 3. 在 live 环境里把系统装到目标盘
lsblk -f
sudo os-install /dev/nvme0n1
```

`os-install` 做的事(§7.1 B):用 repart 在目标盘建表 → 把**当前运行的根**写进目标 `root-a` →
挂目标 ESP 并把 live ESP 的内容整体拷过去(引导器 + UKI + `loader.conf`)→
格式化 `data` 分区并用镜像里的骨架初始化。

> **live 镜像里必须有 `/usr/lib/keel/repart-install.d`**:那是 `os-install` 建表用的分区定义,
> 由 `mkosi.postinst` 在构建时从仓库的 `repart/install/` 拷进去(并去掉 `CopyFiles=`,
> 原因见 `AGENTS.md` 坑 #31)。早于这个改动的产物没有它,敲 `os-install` 会直接报
> 「找不到 repart 定义目录」—— 重新构建即可。
>
> live 镜像里还必须带上格式化工具:`dosfstools`(`mkfs.vfat`,repart 格式化 ESP 用)与
> `e2fsprogs`(`mkfs.ext4`,repart 与 `os-install` 都用)—— 它们只在建表那一刻才被调用,
> 少了不会在构建期报错(见 `AGENTS.md` 坑 #32)。
>
> 这条路径 **尚未在真机/虚拟机上走通过**:2026-09 第一次在 VM 里演练,先后卡在上面那个缺目录、
> 以及镜像缺 `dosfstools` 两处(都已修),完整流程还需要再跑一遍(见 `AGENTS.md` §5 的待验证清单)。

> **没有 `--seed-b`**:live 手上只有 A 槽的 UKI,它的 cmdline 写死了 `root=PARTLABEL=root-a`,
> 复制一份改名成 `keel-b.efi` 会造出"B 的内核 + A 的根"的坏槽(违反不变量 3)。
> 备用槽第一次被填充,就是第一次真实更新(见 §5 的本地更新源做法)。

U 盘本身是一套完整系统,留着就是救援盘(见 `troubleshooting.md`)。路径 C(独立安装器 ISO)v1 不做。

### 2.5 让新装好的系统能登录(必做)

镜像里唯一的登录账号是 **`admin`**(决策 D21),它的凭据有两个来源 ——
**装机前至少要准备一个**,否则装完只能看着登录提示发呆(root 是锁定的,进不去):

| 方式 | 做法 | 效果 |
|---|---|---|
| **首启 SSH 公钥(推荐)** | 把你的公钥放到仓库根目录的 `authorized_keys`(已被 `.gitignore` 排除)。`mkosi.finalize` 会把它放进 `/data` 骨架的 `home/admin/.ssh/authorized_keys` | 装完开机就能 `ssh admin@<ip>`,然后 `sudo -i` 提权 |
| admin 初始密码 | 在仓库根目录建 `mkosi.rootpw`,内容写密码(mkosi 原生支持,同样被 gitignore 排除);或构建时 `-p <密码>` | 可以在文本控制台以 `admin` 登录(密码同样用于 `sudo`) |
| 仅本地测试 | `sudo tools/build-container.sh -p <临时密码> build` | 只适合虚拟机/临时排查;**真机别这么干** —— 密码会进 shell 历史,而且产物一旦泄露就是明文口令 |

> 公钥文件放在仓库根目录而不是 `mkosi.extra/` 里:因为镜像里的 `/home` 是 `/data/home` 的
> bind mount、骨架在首启用 `cp -a -n` 播种,往 `mkosi.extra/home/...` 放的东西不会到 `/data` 上
> (见 `AGENTS.md` 坑 #2/#3)。

**关于 root**:v1 里 root 是**完全锁定**的 —— `/etc/shadow` 里是 `!`、`PermitRootLogin no`、
连 mkosi 塞进 `/usr/lib/credstore/` 的那份 root 密码 credential 也在构建时删掉了
(不删的话 `systemd-firstboot` 每次启动都可能把它解开)。这么做的底气是:
admin 的账号与密码哈希都在**镜像的只读 `/etc`** 里,所以即使 `/data` 坏了、`/home` 是空的,
控制台照样能以 admin 登录(只是没有家目录)。**代价**:系统级后路只剩救援 U 盘(§7.1 B)。

## 3. 装之前必须确认

| 项 | 要求 | 不满足会怎样 |
|---|---|---|
| 固件 | **UEFI 模式启动**,关掉 CSM/Legacy | v1 只有 systemd-boot;槽切换与 boot counting 依赖 EFI 变量(§2) |
| 目标盘 | **会被完全擦除** | 盘上原有数据、其他系统全部消失 |
| 盘容量 | 至少放得下 `esp` 1 GiB + `root-a` 6 GiB + `root-b` 6 GiB + 可用的 `data` | 布局常量见 §3.1/§3.2 |
| Secure Boot | v1 关闭 | v1 不做 Secure Boot;关着也保住了引导菜单里 `e` 改 cmdline 的调试通道(§13.1 #5) |
| 先跑虚拟机 | 按 §1 在 `mkosi vm` 里过一遍 | 真机首次启动失败,只能靠 U 盘 live 救 |

## 4. 首次启动会自动发生什么

`keel-firstboot.service` 幂等地做六件事(§7.2):

| # | 动作 | 说明 |
|---|---|---|
| 1 | 校验/修复 `/data` 骨架 | 缺失就按镜像里的骨架重建 —— "手贱清空 data"的自愈入口 |
| 2 | **两步**扩容:`systemd-repart --dry-run=no` 扩 `data` **分区**,再 `systemd-growfs /data` 扩**文件系统** | repart 只扩分区、从不碰已存在分区的文件系统(`GrowFileSystem=` 只是个 GPT 标志位,只被 gpt-auto-generator 消费,而我们不走那条路)。**首启后请用 `df -h /data` 复核** |
| 3 | `bootctl install` 建立本机 NVRAM 启动项 | 装机镜像里不可能带;已有则跳过 |
| 4 | 创建并启用 swapfile(`/data/keel/swapfile`) | 不做休眠(决策 D9) |
| 5 | 记录 `/data/keel/state` 与 `schema-version` | 之后 `os-status` 从这里读 |
| 6 | 空间宽裕时预留 256 MiB 应急空间(`/data/keel/.reserve`) | `/data` 写满会连带 `/etc` 写不进去(坑 #37),这是留给"最后一次写入"的余量;由 `keel-data-guard` 在临界时交还(决策 D23) |

主机名 / 时区 / locale 不在这里设:它们是**构建期**由 mkosi 的 `Hostname=keel`、
`Timezone=Asia/Shanghai`、`Locale=C.UTF-8` 写进镜像 `/etc` 的(决策 D22),装好即生效 ——
`hostnamectl`、`timedatectl` 应该分别显示 `keel` 与 `Asia/Shanghai`。

> 同一次 `keel-mounts` 还会把 **ESP(`PARTNAME=esp`)以可写方式挂到 `/boot`** —— `os-status` 的
> 「ESP 挂载」与 UKI 列表都靠它;没挂上的话 `os-update` 会在写分区之前直接拒绝、槽确认也会失效
> (`AGENTS.md` 坑 #36、决策 D18;修法见 `docs/troubleshooting.md` §2.3)。
>
> 另外,比 firstboot 更早的 `keel-mounts.service` 会把 `/etc/machine-id` 从镜像里的占位符
> `uninitialized` 换成真正的 ID(幂等;首启复用 PID1 已经用的那个)。这不是可选项:
> machine-id 为空时 networkd 的 DHCPv4、IPv6 稳定隐私地址、resolved 的 DNSSEC 全部失效
> (`AGENTS.md` 坑 #29、`architecture.md` §4.3)。ID 落在 `/etc` overlay 的 upper 上 ⇒
> 在 `/data` 里、每台机器唯一、换槽与更新都不会丢。

### 预期看到什么

| 现象 | 说明 |
|---|---|
| UEFI 文本控制台 | `main` 不含 GPU 驱动/固件,靠内核 `simpledrm`/`efifb` 出文本;**没有图形界面是预期行为**(§7.3) |
| 启动日志 | v1 的 cmdline 不加 `quiet`(§5.1),第一次真机跑能看见全部日志比"干净"重要 |
| SSH | 镜像含 `openssh-server`;有线网络走 `systemd-networkd` + `systemd-resolved`(决策 D15) |
| 找 IP | 控制台里 `ip a`、`networkctl status`,或直接 `os-status`(有「网络」一节);拿到 IP 后从别的机器 `ssh admin@<ip>` |
| 主机名 / 时区 | `hostnamectl` → `keel`;`timedatectl` → `Asia/Shanghai`(决策 D22,构建期就写好了) |
| 登录 | 控制台与 SSH 都只用 `admin`;root 锁定(§2.5)。`sudo` 需要密码,规则在 `/etc/sudoers.d/10-keel-admin` |
| 失败单元 | 应为空(`systemctl --failed`)。`systemd-pcrlock*` 已被 mask(决策 D20),不再出现在这里 |
| `/data` 余量 | `os-status` 的「空间看门人」一节;`keel-data-guard.timer` 每天看一次,低于阈值会自动回收(决策 D23) |

> 进不去就用 U 盘 live 环境挂上来看(§7.1 B),或按 `docs/troubleshooting.md` §2.5 排查。

## 5. 装完之后的第一步

```bash
os-status     # 当前槽/版本/内核、/data 用量、schema 版本、pending、上次结果、槽位占用
ip a          # 确认网络,再看 sshd 能不能连
```

1. **看状态**:`os-status` 应显示当前槽 `a`、`/data` 已扩到整盘、`schema-version` 已写入。
2. **创建普通用户**:用系统工具 `useradd -m -s /bin/bash <name>` + `passwd <name>`。
   `/etc` 是可写 overlay(§4.3),账号、ssh 主机密钥这类东西会持久化在 `/data` 上。
   待验证:§11 的包清单没显式列出 `passwd` 包,若缺 `useradd` 就用 nix 临时提供,并把结论回写到 §11。
3. **测试槽切换**(现在不测,等真更新时才第一次用这套机制就太晚了)。
   备用槽是空的,所以第一次切换必须走一次真实的更新流程 —— 用本地目录当更新源即可:

```bash
# 在目标机器上:把发布目录里除了 keel.raw/install.md/update.md 之外的文件
# 放进一个本地目录(例如从 U 盘拷进 /data/ota/import),然后:
sudo mkdir -p /data/ota/import
sudo cp /path/to/release/manifest /path/to/release/slot-*.root.raw /path/to/release/slot-*.uki.efi \
     /data/ota/import/
sudo sed -i 's#^UPDATE_SOURCE=.*#UPDATE_SOURCE=file:///data/ota/import#' /data/keel/config

sudo os-update check          # 应认出这个版本
sudo os-update fetch          # 校验 sha256(没有 manifest.sig 会有醒目告警,v1 允许)
sudo os-update stage          # 写进非活动槽 + 把 UKI 放到 ESP + 设 preferred
sudo systemctl reboot
os-status                     # 起来后:当前槽变成 b,last_result=success
```

切回来:`sudo os-update rollback` 再重启(等价于切到另一个槽)。
只想切槽不重新写盘时,门面命令是 `sudo os-update switch a|b`。

> 幂等提示:`stage` 会拒绝重复安排同一个目标槽,除非加 `--force`。
> 失败时:**不要慌,等它自己回滚** —— 连续三次到不了 `boot-complete` 就会退回旧槽,
> 起来后 `os-status` 会显示 `last_result=failed`(详见 `update.md`)。

## 6. 常见坑

| 坑 | 后果 / 做法 |
|---|---|
| **槽位尺寸装机时定死** | `root-a`/`root-b` 各 6 GiB 是**布局常量**:GPT 不能在中间插入或搬移分区。以后想跑更大的变体(例如把完整 GNOME 塞进基底)只能**重装**(不变量 9、§3.2) |
| 没关 CSM / 用 Legacy 启动 | 引导器根本起不来;v1 不支持 BIOS |
| 在 U 盘 live 里认错设备名 | `os-install` 写错盘 = 擦掉别人的数据;先 `lsblk -f` 看分区标签再动手 |
| 首启就没网 | 有线网卡/存储固件在 `firmware-misc-nonfree`;无线网络 main 不做,留给 `desktop` profile |
| 指望图形界面 | main 没有图形栈,这是范围决定,不是 bug(§2) |
| `/data` 没挂上 | `/var`、`/root` 是悬空符号链接,`/home`、`/nix` 是空目录,系统看起来"到处都是空目录" —— 见 `troubleshooting.md` |
