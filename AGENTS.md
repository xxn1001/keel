# AGENTS.md — 接手必读

> 这份文件是给**后续接手的 agent / 未来的自己**看的。它写两件事:
> **哪些规则不能违反**(架构不变量)、**仓库怎么组织**。
> 40+ 条**已知的坑**在 [`docs/traps.md`](docs/traps.md)(太长,2026-09 拆出去了);
> 文中提到的「坑 #N」都是那里的编号。
> 完整方案见 `docs/architecture.md`,历史取舍见 `docs/decisions.md`,不要在这里堆流水账。

---

## 0. 这是什么

**keel** —— 一个 **不可变基座 + A/B 双槽 + nix 用户态** 的操作系统镜像项目,用
[mkosi](https://github.com/systemd/mkosi) 构建,基底是 **Debian stable (trixie)**。
它**不是** NixOS:基础系统由 Debian 包组成、只读、原子更新;nix 只负责用户态软件(装在 `/data/nix`)。

演进路径:

1. **目标平台是服务器**:长期在线、尽量不重装、升级要能原子回退;未来还要当**虚拟化宿主**
   (GPU 直通给 VM —— 宿主不需要显卡驱动,所以 `server` 变体比 `desktop` 更小)。
2. **笔记本是「顺带兼任」**:所有者还没有服务器,于是先装到天天用的笔记本上,提前暴露 bug。
   所以 `main` 保持「无桌面的最小系统」= 服务器形态;`desktop` profile 是可选加成,不是主线。

术语与标识,改代码前先对齐:

| 东西 | 值 |
|---|---|
| 项目 / 镜像标识 | `keel`(`ImageId=`) |
| 面向用户的命令 | `os-status`、`os-update`、`os-install`、`os-rescue` |
| 项目内部单元 | `keel-*.service` / `/usr/lib/keel/` |
| 持久状态目录 | `/data/keel/` |
| 分区标签 | `esp`、`root-a`、`root-b`、`data` |
| ESP 上的 UKI | `/efi/EFI/Linux/keel-a.efi`、`keel-b.efi`(带计数时 `keel-b+3.efi`);安装镜像里那份由 `UnifiedKernelImageFormat=keel-a` 钉住(坑 #44) |
| 唯一登录账号 | `admin`(uid 1000,`sudo` 需要密码);**root 锁定**,SSH 侧 `PermitRootLogin no` |

---

## 1. 架构不变量(NON-NEGOTIABLE)

改动代码前先确认没有违反下面任何一条。每一条都是有意为之,违反后会在某个不显眼的时刻炸掉。

1. **基础系统只读,状态全在 `/data`。**
   根分区是 **erofs 镜像**(v1.1 起;结构上不可写 + 压缩),cmdline 里带 `ro`;
   `/var`、`/root` 是指向 `/data` 的符号链接;
   **`/home` 与 `/nix` 是真目录 + bind mount**(由 `keel-mounts` 在启动早期挂上)。
   这两个为什么不能是符号链接:
   - `/home`:符号链接会破坏 `ProtectHome=` 之类的沙箱语义(服务仍能经 `/data/home` 摸到用户数据);
   - `/nix`:`nix` **硬性拒绝**符号链接的 store 路径(坑 #34),而 store 的位置又搬不动 ——
     二进制与脚本把 `/nix/store/…` 写死在 ELF interpreter 与 RPATH 里。
   其余目录能符号链接就符号链接 —— 少一层挂载、少一处启动期依赖。

2. **`/data` 必须在用户空间刚起来时就已挂好,且挂载过程不能依赖 udev。**
   符号链接与 bind mount 都无法参与挂载顺序约束,不能靠"启动后再挂" —— `/var` `/root` 是指向
   `/data` 的符号链接,`/home` `/nix` 要 bind 上去;挂晚了早期服务(random-seed、journald、tmpfiles)
   就会往悬空链接/空目录上写。
   **实现方式(踩过坑 #24,2026-09 真机实测后改的)**:由 `keel-mounts.service`(在 `sysinit` 之前)
   自己扫 `/sys/class/block/*/uevent` 里的 `PARTNAME=data` 找到分区并 `mount`。
   **不要**改回 kernel cmdline 的 `systemd.mount-extra=PARTLABEL=data:/data:...`:
   那会在主系统里生成 `data.mount`,它要等 udev 建出 `/dev/disk/by-partlabel/*`;
   而 udev 要等 `systemd-sysusers`,sysusers 要可写的 `/etc`,可写的 `/etc` 又是挂在 `/data`
   上的 overlay ⇒ 环形依赖 ⇒ systemd 丢掉 `local-fs-pre.target`、udev 被推到 emergency 之后、
   所有 by-partlabel 挂载 90 秒超时 ⇒ emergency mode。
   (当时的假设是"initrd 会帮忙挂" —— 实测**不会**:initrd 里根本没有我们的文件,也没挂 `/data`。)
   ESP 同理:**也是 `keel-mounts` 自己挂**(扫 `PARTNAME=esp`,以 rw 挂到 `/boot`;决策 D18),
   cmdline 里用 `systemd.gpt_auto=no` 让 `systemd-gpt-auto-generator` 完全退场 ——
   它挂 ESP 做得静默且不可靠(装机后的系统上实测压根没挂上,见坑 #36)。
   代码里一律用 `$KEEL_ESP` / `$KEEL_UKI_DIR`,并且**先看 `$KEEL_ESP_MOUNTED`**:
   没挂上时 `KEEL_ESP` 是空的,谁都不许把它当成真路径去读写(坑 #36 的教训就是"每步都成功")。
   **这条不变量的下游不止符号链接**:凡是"启动早期读 `/etc` / 写 `/var`"的单元都得排在
   `keel-mounts` 之后。目前的名单写在 `keel-mounts.service` 的 `Before=` 里:
   systemd-sysusers、systemd-tmpfiles-setup、systemd-machine-id-commit、systemd-random-seed、
   **systemd-sysctl、systemd-journald、systemd-journal-flush**(后三个是 2026-09 补的:
   不排的话用户 drop-in 不生效、**日志根本不落盘** —— 坑 #61)。新增这类单元时记得一起加。

3. **每个槽一个完整 UKI,内核与根文件系统永远配对。**
   切换槽 = 换整个 UKI(内核 + initrd + `root=` + 微码都在里面)。绝不允许"新内核 + 旧根"的组合 ——
   这是回滚可靠性的全部基础。因此**不要**用共享内核 + 两个 BLS entry 的方案。

4. **槽切换与回滚只用 systemd 现成机制,不自己发明。**
   `os-update` 是**门面**:对外子命令与状态语义稳定,底层可替换(决策 D8)。
   - 槽切换 = `bootctl set-oneshot`(候选槽只试一次)与 `bootctl set-default`(确认后固化);
     **不要**写 `set-preferred` —— Debian 的 systemd 257 没有这个动词(坑 #43),
   - 成功判定 = boot counting + `systemd-bless-boot.service`(它挂在 `boot-complete.target` 上,
     自动把 `keel-x+2-1.efi` 改名成 `keel-x.efi` 表示 good);
   - 失败回滚 = 引导器:one-shot 只试一次,引导器用完就把那个 EFI 变量删掉 ⇒ 起不来的
     下次启动自动回到持久默认(旧槽),不需要人工介入。**注意**:文档里承诺过的"连续三次
     才回退"在 systemd 257 上做不到(`set-preferred` 不存在,坑 #43),现在是"试一次就回退";
     等基底 systemd 到 ≥261 再换回来(见 `docs/roadmap.md`)。
     另外 cmdline 里的 **`panic=-1` 是这套机制的前提**(内核 panic ⇒ 立即重启 ⇒ 那次失败
     之后机器还会再启动;决策 D24、坑 #46),别删它。
     三类失败各有兜底,别删任何一个:panic ⇒ `panic=-1`;**冻住** ⇒ 运行时看门狗(D25);
     **停在 emergency/rescue 等人** ⇒ `keel-boot-failed-reboot.service`(D26,判据是
     `/run/keel/boot-complete` 标记,由 `keel-confirm` 写)。
   **v1 的底层是"直接写盘"**(`dd` 进目标分区),不是 `systemd-sysupdate` ——
   后者的 `Type=partition` 匹配语义还没在真机验证过,而写错分区是不可接受的失败模式。
   验证通过后再换底层,门面不动。

5. **`/etc` 必须可写,用 overlayfs,不用 bind mount。**
   lower = 只读镜像的 `/etc`,upper/work = `/data/overlayfs/etc/{upper,work}`。
   整体 bind 一个 `/data/etc` 会让新版本镜像的默认配置被旧副本永久遮蔽,这是 A/B 系统的经典坑。

6. **`/data` 的 schema 变更只能"只增不破",而且由旧系统在 stage 阶段执行。**
   新版本可以加目录/加文件,不能让旧版本读不懂 —— 回滚时旧系统会挂在同一个 `/data` 上。
   迁移必须**声明式**(manifest 里列出"建哪些目录/文件"),**不要执行下载来的脚本**。
   改动必须 bump `/data/keel/schema-version` 并在 `docs/update.md` 记录。

7. **基底里不放用户软件。**
   应用、开发工具、桌面环境、CUDA 一律走 nix。判据:
   **"是否需要在启动早期 / 以长期系统服务身份运行"** —— 是则进基底,否则进 nix。

8. **微码两个厂商都装,不按厂商分支。**
   `Packages=amd64-microcode,intel-microcode`;mkosi 会把 `/usr/lib/firmware/{amd,intel}-ucode`
   打成 microcode initrd **前置**到 UKI 的 initrd 里 —— 微码天然跟着槽走、随系统原子更新。
   **不要**用 `MicrocodeHost=yes`(只适合 VM 调试,会只保留构建机的 CPU 家族)。

9. **槽位大小是布局常量。**
   分区一旦安装就不能在中间插入/搬移,所以 `root-a`/`root-b` 的尺寸必须在**第一次装机前**就按
   "最大的变体"留足。main 默认每个槽 6 GiB(见 `docs/architecture.md` §3 的推算)。
   改这个数字意味着老机器要重装,不是一次普通更新。

10. **`/data` 写满 = `/etc` 也写不进去 —— 凡是"一次性写一大块"的东西都必须先问可用空间。**
   `/etc` 的 overlay upper 在 `/data` 上,所以持久分区满掉之后,machine-id 固化、SSH 主机密钥、
   sysusers/tmpfiles 会一起失败,而 machine-id 写不进去就等于 DHCP/IPv6/DNSSEC 全坏
   (坑 #29 复活;坑 #37 已经吃过一次,当时是 swapfile 干的)。
   现在的预算与看门人见决策 D23(journald drop-in、`keel-nix-gc.timer`、看门人
   `keel-data-guard.timer`、256 MiB 应急空间、`os-update fetch` 前的空间检查)。
   新增任何往 `/data` 写大块数据的代码(下载、镜像、日志、缓存)时:
   **先 `df` 问空间**,并且"先写临时文件、成功再改名",失败要清理。

---

## 2. 仓库结构约定:单主干 + 变体,不用分支

**`main` 是唯一主干,变体用 mkosi profile 表达,不用 git 分支。**

理由:分支用来表达"并行的**改动线**",不是表达"同一个东西的不同**形态**"。
若 desktop/server 各占一个分支,main 上每个修复都要往两个分支各合一次,三个月后必然漂移。
我们要的性质是"**一个 commit 能同时构建出所有变体**"——它们物理上不可能不一致。

分支只用两种:**短命的改动分支**(`feat/swapfile`,几天内合回 main 并删除)、
**可选的发布维护分支**(`release/13.x`,只有在需要同时维护两条发布线时才开)。

### 什么差异放哪里

| 差异类型 | 例子 | 放哪 |
|---|---|---|
| 所有机器共有 | A/B 布局、只读根、`/etc` overlay、nix 接入、更新/回滚 | `mkosi.conf`、`mkosi.conf.d/` |
| **产物形态** | 安装镜像、A 槽载荷、B 槽载荷 | `mkosi.profiles/{install,slot-a,slot-b}.conf` |
| **用途变体** | `desktop`、`server` | `mkosi.profiles/{desktop,server}.conf` |
| **硬件家族** | 按机型挑固件包、电源管理 | `machines/*.conf` |
| **单机运行期状态** | hostname、Wi-Fi 密码、vfio 绑哪块卡、VM 定义 | **`/data`(不进 git)** |

判定准则:**构建期差异进仓库,运行期状态进 `/data`。**

### 宿主适配:先看 `/etc/os-release`,**不要假设宿主是 NixOS**

keel 最早是在一台 NixOS 机器上开发的,于是文档与脚本里沉淀了一些"NixOS 专属"的做法
(最典型的是"脚本要 `bash tools/…` 显式跑",因为 NixOS 没有 `/bin/bash` —— 那条已经在
坑 #54 里修掉了:shebang 统一成 `#!/usr/bin/env bash`,两边都能直接执行)。
**接手时先自己判定,不要凭记忆**:

```bash
cat /etc/os-release        # 看 ID / ID_LIKE —— 判的是**构建宿主**,不是目标镜像
                           # (keel 自己的 os-release 是 ID=keel,别把它当成宿主)
```

| 宿主 `ID`/`ID_LIKE` | 该用什么 | 说明 |
|---|---|---|
| `debian` `ubuntu` `fedora` `centos` `rhel` `arch` `cachyos` `manjaro` `opensuse` … | `tools/build.sh`(**原生路径**) | mkosi 认这些发行版自带的包管理器(apt/dnf/pacman/zypper);宿主只需 mkosi + bubblewrap |
| `nixos` | `tools/build-container.sh`(**容器适配器**) | mkosi 不把 NixOS 当受支持的宿主(建不出 tools tree)⇒ 把构建放进 `debian:trixie` 容器 |
| 其它/认不出 | 先试原生;若报 `Distribution … can't be detected` 就换适配器 | 适配器里也有 `KEEL_BUILD_IMAGE=` 可以换容器镜像 |

脚本自己也会判:两个入口都用 `tools/lib-build-cli.sh` 里的 `keel_host_kind()`(读
`/etc/os-release`),报错时直接告诉你"该走哪条路"。**别在文档里写死"用 nix-shell …"这类
只对某一台机器成立的命令** —— 要写就写成"宿主是 X 时用 Y"。

### 开发/验证环境(2026-09 起):**服务器直接装 Debian 13**

构建与验证**不再借用开发者的个人电脑**,也不再套 incus 虚拟机:

| 项 | 值 |
|---|---|
| 机器 | 一台简易服务器(4 核 / 8 GiB / **盘 100 GB**)。**不是**将来要装 keel 的那台 |
| 系统 | **Debian 13(trixie)直接装在这台物理机上**(不做 LXC/incus/嵌套虚拟化) |
| 前提 | 固件里开了 VT-x/AMD-V ⇒ `/dev/kvm` 可用(`mkosi vm` 与 libvirt 两条路都要它)。装完先 `ls -l /dev/kvm` |
| 怎么干活 | agent 直接 SSH 进来构建/起 VM/跑演练;代码走 GitHub(仓库公开 ⇒ 机器上匿名 `git clone` / `git pull` 即可) |

**为什么是 Debian 13**:和目标镜像、构建容器同一代;Debian 仓库里的 **mkosi 是 25.3**,
正好与容器里那份同版本 ⇒ "原生路径 vs 容器路径"是干净的对照实验(见下一节)。
`docs/release-notes-v1.md` 里"原生 FHS 构建路径尚未实战"那条,就是这台机器要补的。

**这台机器上的三条纪律**(`/` 总共只有 100 GB,装完系统大约剩 80 GB 可用):

1. **一次只跑一件重活**:一次完整构建(3 个 mkosi profile)大概 20–35 分钟(有缓存后 ~7 分钟),
   期间不要同时起 VM(8 GiB 内存要同时装下构建进程与 2 GiB 的 guest,并行会先把盘写满再互相拖慢)。
   **注意 `tools/verify.sh` 会写 15 GiB 的逻辑镜像**:本机 `/tmp` 是 **tmpfs**,同时跑两份 verify
   (或边构建边 verify)会把内存/IO 拖死 —— 构建期的 verify 只跑一次,别手动叠一份。
2. **产物要勤清**:一次构建会产出 `mkosi.output/`(逻辑几十 GiB,稀疏文件实占小得多)和
   `dist/keel-<版本>/`(v1.1 起约 15 GiB **逻辑**,其中 14 GiB 是安装镜像 `keel.raw`;
   真正的更新载荷只有 **~401 MiB/槽**)。规矩是:**只留一份 `dist/`**,复制完 dist 后
   `rm -f mkosi.output/keel-slot-*`(保留 `keel.raw` 给 `mkosi vm` 用),`mkosi.cache/`、
   `mkosi.pkgcache/`、`mkosi.tools/` 不要删(它们省时间)。
3. **演练前先腾地方**:v1.1 起载荷是 **erofs**、一份只要 **1.1 GiB**(v1 是 13 GiB),要求已经宽很多;
   但演练仍会让 guest 真的写盘 ⇒ 先清旧 `dist/` 与旧 libvirt 镜像(`mkosi.output/libvirt/`)再跑。

**这不改变任何不变量**:这台机器只是"构建机",keel 仍然只跑在目标机(将来的服务器 /
现在的笔记本)上。

### 两条构建路径必须**对等**(CLI 只写一份)

keel 有两条构建路径,它们是**同一个东西的两个入口**,不是两个项目:

| 能力 | 原生(`tools/build.sh`) | 容器适配器(`tools/build-container.sh`) |
|---|---|---|
| 构建 install + A/B 载荷 → `dist/` | ✓(默认) | ✓(`build`,默认;内部就是调用 `build.sh`) |
| 初始密码 `-p/--password` | ✓ | ✓(经 `KEEL_ROOT_PASSWORD` 送进容器) |
| 变体/额外 profile `--profile <名字>` | ✓(可重复;也认 `KEEL_EXTRA_PROFILES`) | ✓(合并后经 `KEEL_EXTRA_PROFILES` 透传) |
| `-- <mkosi 额外参数>` | ✓(build 与 vm **两次调用都带**,坑 #30) | ✓(同上) |
| 构建完起一遍 QEMU | ✓(`--vm`) | ✓(`vm` 位置参数 或 `--vm`) |
| OTA 演练 | ✓(`--drill`,与容器共用同一份编排) | ✓(`drill`) |
| 进容器手敲 mkosi | ——(本来就在宿主机上,不需要) | ✓(`shell`,容器独有) |

**规则(踩过的教训)**:2026-09 审计发现两条路已经漂移出四处 —— `build.sh` 根本不解析参数
(`-p` 与 `--profile` 被**静默忽略**,敲了密码却得到没密码的产物)、容器没有 `--profile`、
容器漏传 `KEEL_EXTRA_PROFILES`(那条路加不了变体)、`--` 与 `-h` 只有容器有。

- **共用选项一律写在 [`tools/lib-build-cli.sh`](tools/lib-build-cli.sh) 里**,两个入口
  `source` 它。新增一个选项 = 改那一个文件,两条路自动都有。
- 确实只属于某一条路径的东西(容器引擎、`shell` 模式)留在各自脚本里,**并更新上面这张表**。
- `tools/verify.sh` 有一组"两条路径对等"的断言(共用解析器、`build.sh -h` 能跑、`-p` 全链路、
  profile 透传、演练共用编排、不许写死 `/work`、不许再出现「脚本必须用 bash 显式执行」这类过时话术)。
  **改构建入口之后先跑它。**

### 多 agent 协作:什么时候用,什么时候**不要**用

这份工作有**独占资源**:一台构建机(4 核 / 8 GB / 盘 100 GB)、一次只能跑一份构建或一台 VM、
端口与 `dist/` 只有一份。所以默认**串行**;能用多 agent 的地方是"只读、可独立验证"的活。

DSH 原生就带这些能力(`standard` preset 里已经 compose 好:`tool-subagent` /
`tool-subagent-fork` / `tool-subagent-control` / `tool-workflow` / `tool-ralph` /
`tool-goal` / `tool-skill` / `tool-todo`),**不需要装任何插件**。

| 适合外包给 subagent / workflow(只读、独立) | 必须留在主 agent(独占或有状态) |
|---|---|
| 调研与审计:读一堆文档/日志/代码出结论(`workflow` 的 `pipeline` 并行多份) | 构建、装机、起 VM、跑演练(独占机器,并行只会互相踩) |
| **对抗性复核**:专门去**推翻**"已验证"的结论(本项目的文化:没证据不许写"已验证") | **任何写仓库的动作** —— subagent 默认只读,改动由主 agent 统一落盘、统一跑 `tools/verify.sh` |
| 啃长日志(几千行的构建/启动日志 → 只把结论带回来,主上下文留给决策) | 跨步骤状态的调试(现在在哪个槽、哪台 VM 还开着) |
| 文档一致性扫描(过时话术、命令与实际不符) | 需要按顺序推进的验证(装机 → 更新 → 迁移) |

**约定**

- 给 subagent 的提示词必须**自包含**(它看不到主对话),并明确写"只读、不要改仓库、不要构建"。
- 需要跨长构建延续的目标用 **goal**(`create_goal`),而不是并行的 agent —— goal 是"同一会话里
  的长任务 + 自动轮次",正好对付 20–35 分钟一次的构建。
- 一个 objective 只挂在**主 agent** 手里;subagent 是它的工具,不是它的替代。

### `machines/` 目录

借鉴 NixOS 的 `hosts/<机器名>/` 惯例。**注意:main 里几乎没有真正需要按机器分支的东西** ——
微码两个厂商都装(不变量 8),KVM/VFIO 模块本来就在内核包里,固件按"硬件家族"挑几个包就够。
**在有真实需求之前,`machines/` 只放 README,不要预先造目录。**

---

## 3. 已知的坑(都搬到了 docs/traps.md)

**已移到 [`docs/traps.md`](docs/traps.md)。**

`AGENTS.md` 长到 65 KB 后会超出"工作区指令"的加载预算、末尾**静默截断**(实测丢过内容),
而不变量这份必须每次完整加载,所以坑清单单独成文件。用法:**改哪块代码就按关键词 grep**:

```bash
grep -n "machine-id\|ESP\|repart\|overlay\|mkosi" docs/traps.md
```

下面各节(以及仓库里其他地方)提到的「坑 #N」,一律指 `docs/traps.md` 里的编号。

---

## 4. 常用命令

```bash
# 静态校验(不需要 root、不需要 loop 设备,能在这里跑)
tools/verify.sh

# ── 产物构建:先判宿主(cat /etc/os-release),再选一条路;两条路的选项完全一致 ──
# 宿主是 Debian/Ubuntu/Fedora/Arch/CachyOS 等 mkosi 支持的发行版 → 原生路径
sudo tools/build.sh                          # 一次产出:安装镜像 + A/B 载荷 + manifest → dist/
sudo tools/build.sh -p <密码>                # 给 admin 设初始密码(root 始终锁定)
sudo tools/build.sh --profile desktop        # 叠加变体 profile(可重复)
sudo tools/build.sh --vm                     # 构建完直接在 QEMU 里起一遍
sudo tools/build.sh --drill                  # 完整 OTA 演练(载荷+引导镜像+HTTP 源+VM 自检)
#   演练的 guest 镜像默认放大到 **24G**(v1.1 ⑤ 起可配);想再压:
#   KEEL_DRILL_IMAGE_SIZE=20G sudo tools/build.sh --drill
#   下限 20G(布局 13 GiB + /data 基础占用 + 两份载荷 + fetch 的 2 GiB 余量),写小了会直接拒。

# 宿主是 NixOS 等 mkosi 不支持的发行版 → 容器适配器(选项同上,-p/--profile/--vm/--drill 都认)
sudo tools/build-container.sh                # 构建
sudo tools/build-container.sh -p <密码> vm   # 构建并在容器里起 QEMU
sudo tools/build-container.sh --drill        # OTA 演练
sudo tools/build-container.sh shell          # 进容器手敲 mkosi(容器独有)

# 两条路的对照表、以及"改一条必须改另一条"的规则:见本文 §2。

# 排错第一步:只看配置解析结果,不构建
mkosi --profile install summary
mkosi --profile install cat-config

# 单独校验 repart 布局(真跑分区表求解,不写盘)
systemd-repart --dry-run=yes --definitions=repart/install --empty=create --size=14G --json=pretty /tmp/t.raw

# 在 libvirt 里做「真机前」的验证(virt-manager / libvirtd;见 docs/install.md §8)
tools/libvirt-test.sh prepare && tools/libvirt-test.sh start
tools/libvirt-test.sh console          # 串口控制台(Ctrl+] 退出)
tools/libvirt-test.sh update-serve     # 在 libvirt 宿主上起本地更新源(guest 用 192.168.122.1:8000)

# 装机之后的体检(在目标系统里跑;libvirt 装完、真机装完都适用)
sudo ~/keel-check                      # 转发到 /usr/share/keel/keel-check(随系统更新)

# 烧到目标盘
sudo tools/burn.sh /dev/nvme0n1
```

## 5. 当前状态

- [x] 架构设计与决策固化(`docs/architecture.md`、`docs/decisions.md`)
- [x] 仓库骨架(README / AGENTS / .gitignore / schema-version)
- [x] `mkosi.conf` + `mkosi.conf.d/` + `mkosi.initrd.conf`
- [x] `mkosi.profiles/{install,slot-a,slot-b,test}.conf`
- [x] `repart/install/` + `repart/slot-{a,b}/`
- [x] `mkosi.extra/`、`mkosi.postinst`、`mkosi.finalize`
- [x] 单元:`keel-mounts`、`keel-firstboot`、`keel-confirm`、`keel-swapfile` +
      `keel-data-guard.timer`、`keel-nix-gc.timer` + preset
- [x] `mkosi.extra/usr/bin/`:`os-status`、`os-update`、`os-rescue`、`os-install`
- [x] `tools/`:`verify.sh`、`build.sh`、`burn.sh`、`build-container.sh`(给不被 mkosi 支持的宿主用)
- [x] `docs/`:`architecture.md`、`decisions.md`、`install.md`、`update.md`、`troubleshooting.md`、
      `roadmap.md`、`traps.md`
- [x] **账号模型 / 系统标识 / pcrlock / `/data` 预算(2026-09,决策 D20–D23)**:
      `admin` 是唯一交互账号(root 锁定)、`keel` + `Asia/Shanghai` + `C.UTF-8` 由构建期落地并回读断言、
      `systemd-pcrlock*` disable + mask、journald/nix/OTA 的磁盘预算 + `keel-data-guard` + 256 MiB 应急空间。
      静态校验 103 项全绿
- [x] **B 批的 VM 复验(2026-09,两轮 test profile 自检)**:`id admin` → uid=1000 + sudo 组、
      admin shadow 有哈希、**root shadow = `!`**、sudoers 0440、`PermitRootLogin no`、
      credstore 里没有 root 密码 credential;`/etc/hostname=keel`、
      `/etc/localtime → ../usr/share/zoneinfo/Asia/Shanghai`、`LANG=C.UTF-8`;
      pcrlock 全部 masked、**`systemctl --failed` = 0 个单元**(此前 6 个);
      `keel-data-guard.service` 手动拉起 → `success`,`state` = `verdict=small`;
      两个定时器已排期;无回归(ESP 挂 `/boot`、machine-id 32 位、`/etc` WRITE_OK、DHCP routable)
- [x] **OTA 演练 v1 走通(2026-09,VM,`tools/build-container.sh drill`)**:A→B→A 全链路实测通过 ——
      check(版本比较)→ fetch(13 GiB / 11 秒 / sha256 全对)→ stage(写 root-b + `keel-b+3.efi` +
      候选条目 one-shot)→ 重启进新槽(bless 成 `keel-b.efi`、`last_result=success`)→
      `os-update rollback` → 重启回槽 a(版本回退、`last_result=failed`)。
      演练顺带挖出并修掉坑 #41–#45(详见 `docs/traps.md` 与 `docs/update.md` §9)
- [x] **第一次真机构建 / 虚拟机启动 / 装机**(2026-09,VM:构建 → live 启动 → `os-install` → 目标盘首启 ✓;
      途中修掉坑 #31–#34。**真机(U 盘 + 笔记本)仍未做过**)
- [x] **装好的系统里跑体检(2026-09-25,libvirt,项目所有者实跑)**:`os-install` 装到整盘 → 目标盘首启
      (槽 a、ESP 上 `keel-a.efi`、`last_result=success`、`/data` 扩到整盘 49.9 GiB)→ `sudo ~/keel-check`
      → **49 ✓ / 1 ✗ / 3 ! / 1 -**。那条 ✗ 是**体检脚本自己的 bug**(`grep '^panic=-1' /proc/cmdline`
      永不匹配,坑 #52),三条 ! 是虚拟机里的正常情况(无微码行、无 vTPM、看门人 3 分钟后才写结论)——
      都已按"报出真实情况"修掉,`tools/verify.sh` 补了功能测试 + 静态断言(134 项全绿)
- [x] **libvirt「真装机路径」全链路复验(2026-09-25,B1/B2/B3,自动跑)**:构建 → live → `os-install --yes`
      → **只挂目标盘**启动(等价真机"拔掉 U 盘")→ `keel-check` **50 ✓ / 0 ✗ / 0 ! / 3 -**;
      更新 13 GiB(30–40 s)→ stage(dd 6 GiB / 11 s)→ 进槽 b(bless 成 `keel-b.efi`、`last_result=success`)
      → `rollback` 回槽 a(`last_result=failed`);`os-rescue` 五条路径 + `keel-data-guard` 三级
      (warn/critical/emergency,交还并重建 256 MiB 应急空间)+ 满盘 `fetch` 直接拒绝(HTTP 日志零产物请求)。
      这一轮(含准备)挖出并修掉坑 #54–#60,**共同点是"写下来了但从没跑过"** —— 其中最贵的是
      #57(工作区权限位 0600 让 networkd 读不到配置 ⇒ 网络静默失效)与 #59(演练差点把 live 系统的
      体检结论当成装好的系统的)。证据表见 `docs/update.md` §9.1
- [x] **v1 已打标签(2026-09-25)**:`git tag v1`(附注标签,指向当时已验证的源码树)。
      发布说明与**已知限制 22 条**在 [`docs/release-notes-v1.md`](docs/release-notes-v1.md),
      v1 之后的计划在 [`docs/roadmap.md`](docs/roadmap.md)。打标签时的实测证据写进了标签正文
      (装机 / 更新 / 回滚 / 坏槽三类兜底 / 救援五路径 / 写满 / 日志落盘 / 控制台日志级别)。
- [x] **开发/验证环境迁到独立机器(2026-09)**:一台 4 核 / 8 GiB / 盘 100 GB 的简易服务器,
      **直接装 Debian 13**(不再套 incus VM、不做嵌套虚拟化),agent 直接 SSH 进去构建与验证,
      代码走 GitHub(见 §2 那一节)。**v1.1 第一件任务是 erofs 只读根**(理由:磁盘最紧,
      erofs 一次压三处,见 `docs/roadmap.md` §0/§2.9)
- [x] **v1.1 第一件:erofs 只读根(2026-09-26 实测全过)** —— 载荷侧 `Format=erofs` + `Minimize=yes`
      并**解除 `SizeMaxBytes=6G` 的钉死**;安装侧仍钉死 6 GiB(不变量 9)。
      **一份载荷 6 GiB → 401 MiB**,`os-update fetch` 从 **13 GiB → 1.1 GiB**。三条验证全过:
      ① libvirt 整盘装机 → 首启 → `keel-check` **49 ✓ / 0 ✗**;② `os-update` 一轮含 `rollback`
      (a→b:erofs + bless + `success` → 回 a:`failed`);③ **老机器迁移** —— 一台根还是 ext4 的
      v1 机器,用**它自带的那份 v1 `os-update`** 更新后重启即进 erofs 槽(`findmnt /` = `/dev/vda3 erofs`)。
      途中挖出坑 #63(空 erofs **造不出来** / 运行时 repart 定义必须去掉 `Format=erofs` /
      "ext4 是内核内建"是个假前提)。完整证据见 `docs/roadmap.md` §2.9 与 §2.9.1
- [x] **v1.1 ②:ESP 余量 + `.failed` 清理(2026-09-26)** —— `os-update stage` 在**动根分区之前**
      先查 ESP 可用空间(判据 = 新 UKI ×2 + 50 MiB;不够就拒,否则会出现"根已换、UKI 没写进去"
      ⇒ 内核与根不配对,不变量 3),并顺手清掉**所有**槽的 `.failed`/`.bad` 墓碑;
      新增显式入口 **`os-rescue --clean-esp`**(只删墓碑与"已被正式条目取代"的计数条目,
      **跳过 pending 槽**;不碰正式条目、引导器文件与 NVRAM);`keel-check` 在 ESP 可用
      低于 400 MiB 时警告并给出清理命令。ESP=1 GiB 的余量结论写进 `architecture.md` §3.2
- [x] **v1.1 ①b:OTA 演练的坏槽构造支持 erofs(2026-09-26)** —— 原实现只用 `debugfs`
      (ext4 专用,而且它对打不开的文件也返回 0 ⇒ 会产出"假坏载荷"让回滚演练变假绿)。
      现在按**超级块魔数**分派:erofs 走 `fsck.erofs --extract` → 改树 → `mkfs.erofs` 重打包
      (**不用 mount/loop**),ext4 仍走 `debugfs`,认不出就明确失败。顺带更正一条错误笔记:
      `fsck.erofs --extract` 对 root **保留 setuid**(实测 `/usr/bin/sudo` 是 `-rwsr-xr-x`)
- [x] **v1.1 ⑥-原生:原生 FHS 构建路径已实战(2026-09-26)** —— 构建机本身是 Debian 13,
      `sudo tools/build.sh -p <密码>` 连跑三次全部 exit 0;`release-notes-v1.md` 的已知限制 #20
      已划掉(补了证据)。**仍未做的是 rootless(不带 sudo)那一半**
- [x] **v1.1 ③:更新检查(只 check + 通知,2026-09-26)** —— 新增 `keel-update-check.timer/.service`
      (开机 5 分钟后 + 每 6 小时,`Persistent=true`):只调**只读**的 `os-update check`
      (拉一个 manifest),结论写 `/data/keel/update-check.state`,`os-status` 与 `keel-check`
      各显示一行、journal 记一条。**绝不 fetch/stage** —— 硬约束 1:自动更新必须排在 v1.2 的
      更新签名之后;`tools/verify.sh` 有反向断言守着("脚本里每一处 `os-update` 都必须是 `check`")。
      巡检**永远 `exit 0`**(失败只写 `verdict=error`),否则 `keel-check` 的"失败单元为空"
      会被巡检噪音污染;没配更新源时**连网络都不碰**。用户视角见 `docs/update.md` §8
- [x] **v1.1 ④:两个 `os-install` TODO 结清(2026-09-26)** —— ① **根占用 vs 目标分区**:
      拷的是整块设备 ⇒ 判据是**分区容量**而不是文件系统占用;并且**读不到容量就拒绝**
      (旧写法两个变量都空时会静默放行 —— 坑 #36 的形态)。② **`keel-confirm` 的
      pending/running_slot 边界**:装机写的 `pending_slot=a` + 空的 `running_slot`/`last_result`
      现在被识别成"装机后首次启动",日志与"一次更新成功"分开报
- [x] **v1.1 ⑤:演练/开发磁盘收紧(2026-09-26)** —— `tools/ota-drill-container.sh` 不再硬编码
      `truncate -s 40G`,改成 `KEEL_DRILL_IMAGE_SIZE`(默认 **24G**,v1 的 40G 是 13 GiB 载荷
      时代的余量),并加了 **20G 下限检查**(布局 13 GiB + `/data` 基础占用 ~2.2 GiB + 两份载荷
      ~2.2 GiB + `fetch` 自己的 2 GiB 硬下限)。**顺带修掉 ③ 里的一个跨项回归**:`fetch` 的
      空间预算一度写成 6 GiB/10 GiB,20G 的演练盘(只剩 4.8 GiB)连演练自己都跑不起来 ⇒
      按实测载荷 1.1 GiB 改回 **2 GiB 硬下限 / 4 GiB 警告线**。`AGENTS.md` §4 与
      `docs/update.md` §9 都写了怎么调
- [ ] `server` profile(目标平台:虚拟化宿主,GPU 直通)
- [ ] `desktop` profile(可选:笔记本兼任时用,不是主线)

### 下一步要验证的事(结论回写到 `docs/architecture.md` §13.1)

1. ~~`root=PARTLABEL=` 与 `systemd.mount-extra=PARTLABEL=...` 在 initrd 里的解析~~
   **已实测(2026-09,VM)**:`root=PARTLABEL=` 在 initrd 里有效 ✓;
   `systemd.mount-extra=PARTLABEL=data:/data:…` 在 initrd 里**不会被挂载** ✗,
   在主系统里会挂但依赖 udev ⇒ 造成启动死锁。结论已回写到不变量 2 与坑 #24。
2. `systemd-sysupdate` 的 `Type=partition` transfer 对双槽布局的匹配语义(验证通过后换掉 v1 的直接写盘)。
3. `/usr/lib/modules/<kver>` 挂 overlay 后 `depmod` + 模块加载的实际行为(为"第三方内核模块外置"做准备)。
4. ~~**`os-install` 的完整流程**(在 VM 里对第二块盘演练)~~
   **已实测走通(2026-09,VM)**:repart 建表 → dd 根分区 → mkfs+铺 data 骨架 → 复制 ESP →
   写 pending → **目标盘首启成功**。途中修掉坑 #31(镜像里没有 `/usr/lib/keel/repart-install.d`)、
   #32(镜像里没有 `dosfstools`,repart 格式化 ESP 失败)、#33(建表后 `find_part` 查 `lsblk` 的
   PARTLABEL 扑空,已改成先扫 sysfs + 重试)。
5. **装机后 nix 真的能用**(`nix-shell -p vim` 等)—— 第一次跑就撞上坑 #34(`/nix` 是符号链接),
   已改成「真实目录 + bind mount」。**已复验(2026-09,由项目所有者在自己机器上实测)**:
   `nix-shell -p fastfetch` 能进 shell、能跑起来。**已补(2026-09-25,libvirt 整盘装机)**:
   40 GiB 目标盘首启后 `/data` = 27 GiB(分区与文件系统一致),`keel-check` 也会核对这两个数字。
6. ~~**ESP 在装机后的系统里没挂上**~~ **已修(2026-09,坑 #36 / 决策 D18)**:
   `keel-mounts` 自己扫 `PARTNAME=esp` 以 rw 挂到 `/boot`,cmdline 加 `systemd.gpt_auto=no`,
   `lib.sh` 只认真实挂载点(`KEEL_ESP_MOUNTED`),没挂上时 os-status / os-update / keel-confirm
   分别明确报错或自救。**已实测(2026-09,VM,test profile 自检)**:
   `findmnt /boot` → `/boot /dev/vdb1 vfat rw,relatime,fmask=0133,dmask=0022,…`,
   `bootctl --print-esp-path = /boot`,`/boot/EFI/Linux/` 里有 163 MB 的 UKI,
   `os-status` 打出 `ESP 挂载 : /boot(/dev/vdb1 vfat)`;同一轮里 `/data` 正常(
   swapfile 按 `/data` 的可用空间压到 471 MiB 并启用)、machine-id 32 位、DHCP `routable`。
   **已实测(2026-09-25,libvirt 真装机路径)**:`os-update stage` 往 ESP 写了 `keel-b+3.efi`
   (163 MB),重启后 `systemd-bless-boot` 把它改名成 `keel-b.efi`;ESP 用量 313 MiB / 1022 MiB
   (两个 UKI 之后还剩 710 MiB)。
   (当时记的"失败单元只剩 6 个 `systemd-pcrlock-*`,VM 没 TPM"**是错的**:mkosi 的 QEMU
   **默认带 vTPM**,那 6 个单元是"条件通过、真的跑了但拿不到固件测量结果"才失败的 ——
   见坑 #40。2026-09 已按决策 D20 把它们 disable + mask,所以现在的预期是**失败单元为空**。)
7. ~~**networkd 原生 DHCP 真能拿到租约**~~ **已实测通过(2026-09,VM,坑 #29 修好后)**:
   `keel-mounts` 日志 `已固化 machine-id(取自 PID1 本次启动使用的 ID)` + `machine-id = f9324ac0…`;
   `networkctl list` → `enp0s1 ether routable configured`,`networkctl status` →
   `Address: 10.0.2.15 (DHCPv4 via 10.0.2.2)`、`Gateway: 10.0.2.2`、`DNS: 10.0.2.3`、
   `DHCPv4 Client ID: IAID:0xf1f5dd7f/DUID`、`DHCPv6 Client DUID: DUID-EN/…`;
   `resolvectl` → `DNS Servers: 10.0.2.3` + `Default Route: yes`;
   networkd 日志 `enp0s1: DHCPv4 address 10.0.2.15/24, gateway 10.0.2.2 acquired from 10.0.2.2`,
   **全程没有 ENOPKG**,连跑 10 轮(200 秒)状态稳定。复验入口就是 test profile 里的
   `mkosi.extra-test/`(`keel-selftest.service` 把现场打到控制台)。
   同轮 VM 顺手抓到坑 #37(live 镜像 data 分区只有 1 GiB + swapfile 写满 ⇒ `/etc` 也写不进去),已修;
   **第三轮 VM 复验**:`请求的 swap 是 1906 MiB,但 /data 只有 943 MiB 可用 ⇒ 按 471 MiB 创建`
   → `已启用 swap` → `Finished keel-swapfile.service`,`/etc` 写探针 `WRITE_OK`。
   (当时记的"失败单元只剩 6 个 `systemd-pcrlock-*`,VM 没 TPM"**是错的** ——
   见坑 #40:mkosi 的 QEMU 默认带 vTPM;2026-09 已按决策 D20 把它们 disable + mask,
   现在的预期是**失败单元为空**,B 批两轮复验已确认。)
