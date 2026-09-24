# AGENTS.md — 接手必读

> 这份文件是给**后续接手的 agent / 未来的自己**看的。它只写三件事:
> **哪些规则不能违反**(架构不变量)、**仓库怎么组织**、**哪些坑已经踩过**。
> 完整方案见 `docs/architecture.md`,历史取舍见 `docs/decisions.md`,不要在这里堆流水账。

---

## 0. 这是什么

**keel** —— 一个 **不可变基座 + A/B 双槽 + nix 用户态** 的操作系统镜像项目,用
[mkosi](https://github.com/systemd/mkosi) 构建,基底是 **Debian stable (trixie)**。
它**不是** NixOS:基础系统由 Debian 包组成、只读、原子更新;nix 只负责用户态软件(装在 `$VOLUME/nix`)。

演进路径:

1. **现在**:装在一台笔记本上,边用边改(`main` = 无桌面的最小系统,`desktop` profile 紧随其后)。
2. **未来**:装到一台"不可变基座 + 虚拟化宿主"上,GPU 直通给 VM ——
   宿主**不需要**显卡驱动,所以 `server` 变体反而比 `desktop` 变体更小。

术语与标识,改代码前先对齐:

| 东西 | 值 |
|---|---|
| 项目 / 镜像标识 | `keel`(`ImageId=`) |
| 面向用户的命令 | `os-status`、`os-update`、`os-install`、`os-rescue` |
| 项目内部单元 | `keel-*.service` / `/usr/lib/keel/` |
| 持久状态目录 | `/Volume/keel/` |
| 分区标签 | `esp`、`root-a`、`root-b`、`volume` |
| ESP 上的 UKI | `/efi/EFI/Linux/keel-a.efi`、`keel-b.efi`(带计数时 `keel-a+3.efi`) |

---

## 1. 架构不变量(NON-NEGOTIABLE)

改动代码前先确认没有违反下面任何一条。每一条都是有意为之,违反后会在某个不显眼的时刻炸掉。

1. **基础系统只读,状态全在 `/Volume`。**
   根分区以 `ro` 挂载;`/var`、`/root` 是指向 `/Volume` 的符号链接;
   **`/home` 与 `/nix` 是真目录 + bind mount**(由 `keel-mounts` 在启动早期挂上)。
   这两个为什么不能是符号链接:
   - `/home`:符号链接会破坏 `ProtectHome=` 之类的沙箱语义(服务仍能经 `/Volume/home` 摸到用户数据);
   - `/nix`:`nix` **硬性拒绝**符号链接的 store 路径(坑 #34),而 store 的位置又搬不动 ——
     二进制与脚本把 `/nix/store/…` 写死在 ELF interpreter 与 RPATH 里。
   其余目录能符号链接就符号链接 —— 少一层挂载、少一处启动期依赖。

2. **`/Volume` 必须在用户空间刚起来时就已挂好,且挂载过程不能依赖 udev。**
   符号链接与 bind mount 都无法参与挂载顺序约束,不能靠"启动后再挂" —— `/var` `/root` 是指向
   `/Volume` 的符号链接,`/home` `/nix` 要 bind 上去;挂晚了早期服务(random-seed、journald、tmpfiles)
   就会往悬空链接/空目录上写。
   **实现方式(踩过坑 #24,2026-09 真机实测后改的)**:由 `keel-mounts.service`(在 `sysinit` 之前)
   自己扫 `/sys/class/block/*/uevent` 里的 `PARTNAME=volume` 找到分区并 `mount`。
   **不要**改回 kernel cmdline 的 `systemd.mount-extra=PARTLABEL=volume:/Volume:...`:
   那会在主系统里生成 `Volume.mount`,它要等 udev 建出 `/dev/disk/by-partlabel/*`;
   而 udev 要等 `systemd-sysusers`,sysusers 要可写的 `/etc`,可写的 `/etc` 又是挂在 `/Volume`
   上的 overlay ⇒ 环形依赖 ⇒ systemd 丢掉 `local-fs-pre.target`、udev 被推到 emergency 之后、
   所有 by-partlabel 挂载 90 秒超时 ⇒ emergency mode。
   (当时的假设是"initrd 会帮忙挂" —— 实测**不会**:initrd 里根本没有我们的文件,也没挂 `/Volume`。)
   ESP 同理:交给 `systemd-gpt-auto-generator` 自动挂(`/boot` 或 `/efi`,取决于镜像里哪个目录存在),
   代码里一律用 `$KEEL_ESP` / `$KEEL_UKI_DIR`(`lib.sh` 里用 `bootctl --print-esp-path` 现问,坑 #25)。

3. **每个槽一个完整 UKI,内核与根文件系统永远配对。**
   切换槽 = 换整个 UKI(内核 + initrd + `root=` + 微码都在里面)。绝不允许"新内核 + 旧根"的组合 ——
   这是回滚可靠性的全部基础。因此**不要**用共享内核 + 两个 BLS entry 的方案。

4. **槽切换与回滚只用 systemd 现成机制,不自己发明。**
   `os-update` 是**门面**:对外子命令与状态语义稳定,底层可替换(决策 D8)。
   - 槽切换 = `bootctl set-preferred`(只写 EFI 变量,不碰 ESP 上的 `loader.conf`);
   - 成功判定 = boot counting + `systemd-bless-boot.service`(它挂在 `boot-complete.target` 上,
     自动把 `keel-x+2-1.efi` 改名成 `keel-x.efi` 表示 good);
   - 失败回滚 = 引导器:连续三次到不了 `boot-complete` 就把条目标成 bad,
     `LoaderEntryPreferred` 会跳过它、退回另一个槽。
   **v1 的底层是"直接写盘"**(`dd` 进目标分区),不是 `systemd-sysupdate` ——
   后者的 `Type=partition` 匹配语义还没在真机验证过,而写错分区是不可接受的失败模式。
   验证通过后再换底层,门面不动。

5. **`/etc` 必须可写,用 overlayfs,不用 bind mount。**
   lower = 只读镜像的 `/etc`,upper/work = `/Volume/overlayfs/etc/{upper,work}`。
   整体 bind 一个 `/Volume/etc` 会让新版本镜像的默认配置被旧副本永久遮蔽,这是 A/B 系统的经典坑。

6. **`/Volume` 的 schema 变更只能"只增不破",而且由旧系统在 stage 阶段执行。**
   新版本可以加目录/加文件,不能让旧版本读不懂 —— 回滚时旧系统会挂在同一个 `/Volume` 上。
   迁移必须**声明式**(manifest 里列出"建哪些目录/文件"),**不要执行下载来的脚本**。
   改动必须 bump `/Volume/keel/schema-version` 并在 `docs/update.md` 记录。

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
| **单机运行期状态** | hostname、Wi-Fi 密码、vfio 绑哪块卡、VM 定义 | **`/Volume`(不进 git)** |

判定准则:**构建期差异进仓库,运行期状态进 `/Volume`。**

### `machines/` 目录

借鉴 NixOS 的 `hosts/<机器名>/` 惯例。**注意:main 里几乎没有真正需要按机器分支的东西** ——
微码两个厂商都装(不变量 8),KVM/VFIO 模块本来就在内核包里,固件按"硬件家族"挑几个包就够。
**在有真实需求之前,`machines/` 只放 README,不要预先造目录。**

---

## 3. 已知的坑(都是踩过的,别重踩)

1. **脚本类设置可能被默认 initrd 镜像继承,必须防两道。**
   mkosi 的脚本设置(`FinalizeScripts` / `PostInstallationScripts` / …)默认值是按
   "源目录里有没有 `mkosi.<名字>` 文件"解析的,而默认 initrd 镜像与主镜像**共用同一个源目录**
   ⇒ 我们的 finalize 有可能被作用到 initrd 上,把它弄坏,报错还会很莫名其妙。
   两道防护:
   - `mkosi.initrd.conf` 里清空这些设置 —— **必须写在 `[Content]` 段**。写成 `[Config]` 时
     mkosi 会报"Setting X should be configured in [Content]"然后**静默不生效**(这个坑真踩过);
   - 两个脚本开头都 `[ -e "$BUILDROOT/etc/initrd-release" ] && exit 0`。

2. **符号链接必须在最后一步(`mkosi.finalize`)才创建。**
   如果镜像树里 `/var` 提前变成符号链接,包管理器安装、`systemd-sysusers`、`systemd-tmpfiles`、
   `systemd-firstboot` 全都会顺着链接写到**镜像树外面**去。顺序:装包 → 所有会写 `/var` `/etc` 的步骤
   → 最后才换链接。

3. **镜像里 `/var` 的内容在运行时看不见。**
   因为 `/var` 是符号链接,运行时看到的是 `/Volume/var`。所以:
   - `/Volume` 骨架必须**显式**提供,不能指望镜像里的 `/var`(构建时从镜像的 `/var` 快照生成,
     但剔除包管理器状态目录);
   - 尤其别忘 `/var/lib/dbus/machine-id -> /etc/machine-id`(Debian 是 dbus 包 postinst 建的,
     而 `/var` 是新的 ⇒ 这个链接会消失);
   - 预建 `/var/log/journal`,否则第一次启动的日志是易失的。

4. **kernel cmdline 烧进 UKI,但有两条官方后门(按需用,别乱用)。**
   主策略仍然是"cmdline 保持机器无关的超集(如 `iommu=pt`)+ 把硬件配置挪进 `/etc`"
   (例如 `vfio-pci.ids=` 用 `/etc/modprobe.d/vfio.conf` 的 `options` 代替)。后门:
   - **菜单里改(未启用 Secure Boot 时有效)**:systemd-boot 按 `e` 可编辑选中条目的 cmdline;
     但 `systemd-stub` 文档明确说,**一旦启用了 Secure Boot,`.cmdline` 非空时任何外部传入都会被忽略**
     —— 也就是说 Secure Boot 开启后这条调试路径自动关闭。
   - **UKI addon**:`<uki>.efi.extra.d/*.addon.efi` 可以给 UKI 追加 cmdline/initrd/微码,不需要重建 UKI。
     适合"某台机器的专属参数",代价是这份差异只存在于 ESP 上、不参与镜像校验,而且 a/b 槽各要一份。

5. **repart 的分区名 = 配置文件去掉数字前缀的文件名。**
   `repart/install/10-root-a.conf` → PARTLABEL `root-a`。槽的身份就靠它,
   所以 cmdline 用 `root=PARTLABEL=root-a|root-b`,不用 PARTUUID(不依赖 UUID 派生规则)。
   另外:`SplitArtifacts=partitions` 只对声明了 `SplitName=` 的分区吐出独立分区镜像。

6. **安装镜像里不要把 B 槽也声明成 `Type=root-*`。**
   两个 root 类型分区会让 mkosi "which is the root partition" 的判定产生歧义
   (`root=PARTUUID` 替换、verity roothash 注入都受影响)。B 槽用 `linux-generic`,靠 PARTLABEL 认。

7. **`UnifiedKernelImageProfiles` 不是"A/B 两个可引导 UKI"。**
   它产出的是 PE **addon**(`build_uki_profiles()` 用的是 addon stub),不是独立 UKI。
   要两个槽 = 跑两次构建(两个 profile),别想用它省事。

8. **`/etc` overlay 的挂载时机很敏感。**
   必须排在 `systemd-sysusers.service`、`systemd-tmpfiles-setup.service`、
   `systemd-machine-id-commit.service` 之前(它们要读/写 `/etc`),
   且挂完必须补一次 `systemctl daemon-reload` —— 否则 PID1 看不到只存在于 upper 里的 unit 文件。

9. **Debian 的 `non-free-firmware` 组件要显式打开。**
   mkosi 的 Debian 代码是 `components = ("main", *context.config.repositories)`,
   所以微码/固件包需要 `Repositories=non-free-firmware`。

10. **`ToolsTree=default` 是推荐的构建方式。**
    mkosi 内置了各发行版的 tools tree 配置,其中 `debian-kali-ubuntu/systemd-ukify.conf`
    会装 `systemd-ukify`,`systemd-repart.conf` 会装 `systemd-repart` —— 于是"Debian trixie 有没有 ukify"
    这个问题不影响构建:**ukify/repart 由 tools tree 提供,不是由目标镜像提供**。

11. **不要在 `mkosi.conf` 里给 `Profiles=` 设默认值。**
    mkosi 的集合型设置是**追加**语义:`Profiles=install` + `--profile slot-b` 会让 install 被解析两次,
    KernelCommandLine 里同时出现 `root=PARTLABEL=root-a` 和 `root=PARTLABEL=root-b`
    —— 静默产出一个 cmdline 自相矛盾的 UKI,而且要到真机启动才暴露。
    两道守卫:`mkosi.finalize` 断言 `$MKOSI_CONFIG` 里恰好一个 `root=PARTLABEL=root-<槽>`;
    `tools/verify.sh` 逐 profile 检查。
    (也不能用 `[Assert] Profiles=`:它在 `mkosi.conf` 里是**在 profiles 之前**求值的,永远不满足。)

12. **SSH 主机密钥绝不能烤进镜像。**
    `openssh-server` 的 postinst 会在构建时生成它们,所以 `mkosi.conf.d/20-packages.conf` 里
    有 `RemoveFiles=/etc/ssh/ssh_host_*`,首启由 `keel-firstboot` 用 `ssh-keygen -A` 重新生成
    (写进 `/etc` overlay 的 upper,换槽和更新都不丢)。漏了这一步 = 所有装机实例共用同一套主机密钥。

13. **开发容器里能验证的比想象的多,但仍然有限**:没有 `/dev/kvm`、没有 loop 设备、ext4 不支持 reflink,
   但是 **systemd-repart 能真跑**(它格式化到临时文件,不需要 loop):
   分区名、尺寸、类型、`CopyFiles` 全都能在这里验证;加上 mkosi 配置解析、单元语法、shellcheck,
    就是 `tools/verify.sh` 的全部内容。**跑不了的只有真机构建与启动。**

14. **`GrowFileSystem=yes` 只扩分区,不扩文件系统。**
    systemd-repart 从不改动**已存在**分区的文件系统(源码 `context_mkfs()` 对已存在分区直接 continue);
    `GrowFileSystem=` 只是打一个 GPT 标志位,而那个标志只被 `systemd-gpt-auto-generator` 消费 ——
    我们的 `/Volume` 是自己用 `mount` 挂的(不变量 2),**根本不过 gpt-auto-generator**。
    ⇒ 扩容必须两步:`systemd-repart` 扩分区 + `systemd-growfs /Volume` 扩文件系统
    (两处都已实现:首启的 `keel-firstboot` 与 `os-rescue --grow-volume`)。
    另外 `systemd-growfs` 对 ext4 会调 `resize2fs`,所以 `e2fsprogs` **必须**在包清单里。
    首次真机启动后请用 `df -h /Volume` 复核这一点。

15. **宿主必须是一个 mkosi 支持的发行版,否则连 tools tree 都建不出来。**
    mkosi 要先**用宿主的包管理器**建一棵 tools tree(`apt`/`ukify`/`repart`/`qemu` 都在那里面),
    再用那棵树构建 Debian 目标镜像。NixOS 不在支持列表里(它只认 dnf/apt/pacman/zypper),于是报:
    "Distribution of your host can't be detected … Defaulting to Distribution=custom"
    + "Default tools tree requested but it is out-of-date or has not been built yet"。
    第一行可以忽略(`mkosi.conf` 已显式写了 `Distribution=debian`);
    第二行是真问题,而且**配置绕不过去**(设 `ToolsTreeDistribution=debian` 也得先有宿主上的 `apt`)。
    ⇒ 解法是把构建放进受支持发行版的容器:`tools/build-container.sh`(默认 `debian:trixie`)。

16. **mkosi 25.x 要求显式配置缓存/产物目录,27.x 有内建默认值。**
    同一份 `mkosi.conf`,在 27 上 `mkosi summary` 一路通过,在 Debian trixie 的 mkosi 25.3 上直接失败:
    `A cache directory must be configured in order to use --incremental`
    —— 因为 25.x 的规则是"`mkosi.cache/` 存在才拿它当缓存目录",而 git 仓库里不可能有一个空目录。
    同类还有 `OutputDirectory=`(不写就是"`mkosi.output/` 存在才用它,否则写当前目录",
    于是产物落在哪取决于一个目录恰不存在)。
    ⇒ `mkosi.conf` 里现在把 `OutputDirectory=` / `CacheDirectory=` / `PackageCacheDirectory=` 全部写死。
    **教训**:`tools/verify.sh` 的覆盖范围受限于你用的那个 mkosi 版本 ——
    本地 27 全绿不等于容器里的 25.3 也能跑。所以两边的版本差异要么用同一个容器固定下来,
    要么在两边都跑一遍 verify。
    **同一个教训还包括 verify.sh 自己**:它有一处断言最初写成解析 `mkosi summary --json` 的固定结构
    (27 是把各镜像嵌在 `Images: [...]` 里,25.x 是平铺),结果在 25.3 上自己误报。
    现在改成"按 key 名扫、不看嵌套结构"。写检查脚本时同样不要依赖某个版本的具体输出格式。

17. **容器里跑 repart 必须显式 `--offline=yes`,否则会撞 loop 设备。**
    `systemd-repart` 自己的默认是 `--offline=auto` = "能建 loop 设备就用 loop",
    只有在 loop **完全不可用**时才回退到 offline。
    `tools/build-container.sh` 用了 `--privileged`(mkosi 的构建沙箱要 CAP_SYS_ADMIN),
    这会把宿主机的 `/dev` 暴露进容器 ⇒ repart **看得见** loop 设备但用不了,
    于是不回退、直接报:
    `Failed to make loopback device of future partition 0: Device or resource busy`。
    两个后果:
    - mkosi 的实际构建**不受影响** —— 它的 `RepartOffline=` 默认就是 `yes`,根本不会走 loop;
    - 但 `tools/verify.sh` 是**直接调 systemd-repart** 的,所以它必须自己带上 `--offline=yes`。
    另外 `mkosi.conf` 里也把 `RepartOffline=yes` 显式写出来了,不依赖版本默认值。
    开发容器里没有 `/dev/loop*`,repart 会静默回退到 offline ⇒ 这个坑在那里永远看不见,
    所以只能在文档里记下来。
    **补充证据(来自真机构建日志)**:repart 会打印
    `Configured GrowFileSystem=yes for partition type 'd605065b-…' that doesn't support it, ignoring.`
    —— 对我们的私有类型它连那个 GPT 标志位都不设。所以 `GrowFileSystem=yes` 已从两个定义里删掉,
    只留注释说明,免得每次构建都多一行看着像警告的输出。

18. **Debian 把 `systemd-boot` 拆成三个包,少一个的后果分别是"构建失败"和"启动后才炸"。**
    | 包 | 提供 | 缺了会怎样 |
    |---|---|---|
    | `systemd-boot` | 集成与服务 | — |
    | `systemd-boot-efi` | `/usr/lib/systemd/boot/efi/linuxx64.efi.stub`、`systemd-bootx64.efi` | **构建失败**:`Unified kernel image(s) requested but systemd-stub not found at /usr/lib/systemd/boot/efi/linuxx64.efi.stub` |
    | `systemd-boot-tools` | `/usr/bin/bootctl` | **构建能过,启动后才炸**:`keel-firstboot` / `keel-confirm` / `os-update` / `os-rescue` 全都调不到 `bootctl` |
    我们一开始只装了 `systemd-boot`,两个都缺 —— 第一个在构建最后一步炸出来,第二个本来会等到
    真机首启才暴露。`tools/verify.sh` 现在有断言:包清单缺任何一个都会报错。

19. **`ToolsTree=default` 的 tools tree 只在 `build` 动作里自动构建。**
    mkosi 源码里的守卫是:
    ```python
    if tools and not have_cache(tools):
        if (args.rerun_build_scripts or args.verb != Verb.build) and args.force == 0:
            die("Default tools tree requested but it is out-of-date or has not been built yet")
    ```
    也就是说:直接跑 `mkosi … vm`(或 `shell`/`boot`)而 tools tree 还没建时,
    mkosi **不会顺手帮你建**,而是让你先 build:
    `‣ (Make sure to (re)build the image first with 'mkosi build' or use '--force')`。
    第一次接触这个项目很容易在这里卡住(看起来像错误,其实只是顺序问题)。
    ⇒ `tools/build-container.sh vm` 已经改成"先 build 再 vm";手动跑的话就是两条命令:
    `mkosi --profile install --profile test build` → `mkosi --profile install --profile test vm`
    (要控制台登录就两边都加 `--root-password=<密码>`,见坑 #26/#30)。
    (这里曾经写着"别用 `--force` 图省事",**那是错的**:`-f` 不删增量缓存,而且换了 profile
    之后不加 `-f` 反而会静默复用旧镜像 —— 见坑 #23。)

20. **`RepartDirectories=` 会被 mkosi 的隐式默认值"追加",光在 profile 里覆盖是不够的。**
    mkosi 把"源目录里存在 `mkosi.repart/`"当作 `RepartDirectories=` 的默认值,而这个设置是
    **集合型(追加语义)** ⇒ 只要源码树里有个叫 `mkosi.repart` 的目录,`--profile slot-b` 里设的目录
    就会和它**同时生效**,两套分区布局一起交给 repart。真机上的表现:
    ```
    repart: ".../mkosi.repart-slot-b/10-root-b.conf and .../mkosi.repart/20-root-b.conf
             have the same resolved split name ..., refusing."
    ```
    ⇒ 修法:三个布局目录现在叫 `repart/{install,slot-a,slot-b}`,源码树里**没有** `mkosi.repart` 了,
    隐式默认值随之消失;`tools/verify.sh` 另外断言"每个 profile 解析出的 RepartDirectories 恰好一个"。
    **这是同一个家族的第 4 次**:`Profiles=`(追加语义)、`CacheDirectory=` / `OutputDirectory=`
    (目录存在才有默认值)、`RepartDirectories=`(两者叠加)。规律:
    **凡是 mkosi 用"源目录里某个文件/目录是否存在"来定默认值的设置,只要我们要用 profile 覆盖它,
    就必须先把那个默认路径消灭掉(改名/移走),只赋值是不够的。**

21. **不要用"构建时会被修改"的文件当仓库里的单一事实来源。**
    反面教材:`mkosi.version` 原本是静态文件,靠 `mkosi -B`(auto-bump)推进版本号 ——
    而 `-B` 会**改写一个被 git 跟踪的文件** ⇒ 每次构建后工作区都是脏的,下次 `git pull` 直接冲突。
    真机上因此连续两轮"修复后测试"跑的都是**旧代码**,排查成本极高(看起来像修复没生效)。
    ⇒ 现在 `mkosi.version` 是**可执行脚本**:mkosi 官方支持"可执行时运行它、用 stdout 当版本号"
    (见 mkosi 手册 SCRIPTS 节),脚本打印 UTC 时间戳。不落盘、不冲突、天然唯一;
    `tools/build.sh` 不再用 `-B`,而是把同一个 `--image-version` 显式传给三个 profile。
    排查提示:**在别人机器上"改完再让人测"之前,先确认对面真的拉到了新代码**
    (`git pull` 的输出 + `git log --oneline -1`),否则可能白折腾两轮。

22. **`WorkspaceDirectory=` 不能指向任何 `BuildSources=` 之内,而 `BuildSources=` 的默认值就是配置目录。**
    为了让 workspace 和 `mkosi.output/` 落在同一个文件系统上(避免跨设备 rename 降级成复制 14 GiB),
    曾经在 `mkosi.conf` 里写 `WorkspaceDirectory=mkosi.workspace`。结果真机上**连构建都起不来**:
    ```
    ‣ Output path /work/mkosi.output/keel.raw exists already. (Use --force to rebuild.)
    ‣ The workspace directory (/work/mkosi.workspace) cannot be a subdirectory of any source directory (/work)
    ‣ (Set BuildSources= to the empty string or use WorkspaceDirectory= to configure a different workspace directory)
    ```
    (`build` 那次因为坑 #23 直接返回了,所以三条是两次调用拼起来的:`build` 打印第一条,
    随后 `vm` 撞上后两条。)mkosi 的检查是纯词法的:`wd.is_relative_to(tree.source)`,
    而 `build_sources` 的默认值是 `[ConfigTree(<配置目录>)]` ⇒ 只要 workspace 在仓库里就必然踩中。
    两个选项的代价:
    - `BuildSources=`(空):`$SRCDIR`(`/work/src`)不再挂载 ⇒ `mkosi.postinst` 装文档、
      `mkosi.finalize` 装 `schema-version` / `authorized_keys` 全部**静默降级**(它有 `-f` 守卫,
      不报错,只是不干活)。用一个路径换三个静默失败,不划算。
    - `WorkspaceDirectory=` 别处:默认 `/var/tmp`;在容器里那是容器自己的文件系统 ⇒ 产物只能复制。
    ⇒ 现在的做法:仓库里**不设** `WorkspaceDirectory=`(保持默认 `/var/tmp`),由
    `tools/build-container.sh` 把宿主机仓库里的 `mkosi.workspace/` **绑到容器的 `/var/tmp`** ——
    workspace 仍在宿主机的文件系统上(rename + reflink 都能用),而 mkosi 看到的路径是
    `/var/tmp/…`,不触发那条校验。`tools/verify.sh` 断言 `mkosi.conf` 里没有这个设置。

23. **mkosi 的 `build` 是"没有才建":少了 `--force` 会静默复用旧产物。**
    产物路径已存在时,mkosi 只打印一行 info 然后**返回 0**:
    ```
    ‣ Output path /work/mkosi.output/keel.raw exists already. (Use --force to rebuild.)
    ```
    版本号(`mkosi.version` 的时间戳)只写在镜像**内部**,产物文件名里没有它 ⇒
    拿到的是"版本号是新的、内容是旧的"镜像,而且**没有任何错误**。
    真机上已因此白测一轮:`build-container.sh vm` 里那步 `--profile install --profile test build`
    因为没带 `-f` 被跳过,随后 `vm` 开的是**上一次构建的、没有登录密码**的旧镜像。
    ⇒ 规则:**任何"要产生新产物"的地方都必须写 `--force`**(`tools/build.sh` 三次构建、
    `tools/build-container.sh` 的 build 步骤),`tools/verify.sh` 里有对应断言。
    顺带纠正一个曾经的错误说法:`-f` **不是**"删掉已构建的镜像重来",它只重建输出、
    保留增量缓存(`mkosi.cache/`);要连缓存一起删才是 `-ff`。
    (与坑 #19 的关系:那条说的是"跑 `vm` 前要先 `build`",这条说的是"`build` 得真的建东西"。)

24. **`systemd.mount-extra=PARTLABEL=…` 会让早期启动死锁:它依赖 udev,而 udev 依赖可写的 `/etc`,可写的 `/etc` 又依赖 `/Volume`。**
    这是**第一次真机(VM)启动**抓到的,整条链是:
    ```
    keel-mounts(Before=sysusers,需要可写的 /etc,而 /etc overlay 的 upper 在 /Volume)
        → RequiresMountsFor=/Volume → Volume.mount
        → Requires/After dev-disk-by-partlabel-volume.device(要 udev 建符号链接)
        → systemd-udevd(After=systemd-sysusers)
        → systemd-sysusers(要写 /etc)
        → 回到 keel-mounts  ✗ 环
    ```
    systemd 破环时丢掉了 `local-fs-pre.target`(启动日志里就是那行
    `[ SKIP ] Ordering cycle found, skipping local-fs-pre.target`),于是 udev 被推迟到
    **emergency 之后**才启动,所有 `by-partlabel` 挂载等满 90 秒超时:
    ```
    [ TIME ] Timed out waiting for device dev-disk-by-partlabel-volume.device - /dev/disk/by-partlabel/volume.
    [DEPEND] Dependency failed for Volume.mount - /Volume.
    [DEPEND] Dependency failed for local-fs.target - Local File Systems.
    [DEPEND] Dependency failed for keel-mounts.service …
    ```
    ⇒ local-fs 失败 ⇒ **emergency mode**;连带 `systemd-random-seed`(往悬空的 `/var` 符号链接写)、
    `systemd-timesyncd` 一起失败。
    顺带证伪了两个曾经的假设:
    - **initrd 并不会帮我们挂 `/Volume`**:cmdline 里的 `systemd.mount-extra` 在 initrd 阶段没有生成
      `/sysroot/Volume`(把 initrd 从 UKI 里抽出来看,里面根本没有我们的文件,也没有任何 `/Volume` 挂载动作);
    - 而 `root=PARTLABEL=root-a` 在 initrd 里**是**有效的(`Found device …root-a.device` ✓)。
    ⇒ 现在的做法见不变量 2:keel-mounts 自己扫 `/sys` 的 `PARTNAME=` 挂 `/Volume`(不经过 udev、
    不生成 `.mount` 单元),`keel-mounts.service` 里加 `Before=systemd-random-seed.service`,
    cmdline 里**不再有** `systemd.mount-extra`。`tools/verify.sh` 有正反两条断言守着。
    **教训**:早期启动里任何"要等 udev"的东西,都要先问一句"udev 自己能不能起来"。

25. **ESP 挂在哪由 gpt-auto 决定,不要硬编码 `/efi`。**
    ESP 是 Discoverable Partitions 类型,`systemd-gpt-auto-generator` 会自动挂载它 ——
    挂到 `/boot` 还是 `/efi` 取决于镜像里哪个目录存在(规则是 `/boot` 优先)。
    我们的镜像里两个空目录都有(构建期 mkosi 用 `/efi`,finalize 又建了 `/boot`),
    实测 gpt-auto 选了 **`/boot`**(而且它建的是 `boot.automount`,按需挂载、不会拖垮 local-fs ✓)。
    于是原来 cmdline 里那条 `systemd.mount-extra=PARTLABEL=esp:/efi:vfat:ro` 不但多余,
    还因为依赖 udev 符号链接而失败(坑 #24 的受害者之一),并且它是 `ro` 的 ——
    而 boot counting / `bootctl set-preferred` / `os-update` 都需要**可写**的 ESP。
    ⇒ 现在:cmdline 不挂 ESP;`lib.sh` 用 `bootctl --print-esp-path` 现问路径并导出
    `KEEL_ESP` / `KEEL_UKI_DIR`,所有脚本只用这两个变量(`tools/verify.sh` 会检查没有脚本
    硬编码 `/efi/EFI`)。

26. **mkosi 的 `Autologin=yes` 在本镜像里会变成"登录成功但 shell 秒退"的死循环。**
    现象(VM 控制台):`Debian GNU/Linux 13 localhost hvc0` + `localhost login: root (automatic login)`
    每两秒重复一次,**从来不出现 shell 提示符**,也没有任何报错;`journalctl -p warning` 里
    没有 pam/logind 告警 ⇒ 认证是成功的,死的是登录之后那个 shell 会话。
    更麻烦的是这个循环会**顶掉**手动输密码的机会(getty 每两秒重开一次)⇒ 一旦出现,控制台就废了。
    ⇒ 曾经的做法是在 `mkosi.profiles/test.conf` 里写 `RootPassword=keel`;现在**不再往仓库里
    硬编码任何密码**(公开仓库 = 密码公开),改成从命令行传:
    `sudo tools/build-container.sh -p <密码>` → mkosi 的 `--root-password=<密码>`。
    它同样走 systemd 的 `passwd.hashed-password.root` credential、由 systemd-firstboot 在首启时应用
    —— 和真机用仓库根目录 `mkosi.rootpw` 是**同一条路径**,所以在虚拟机里验证控制台登录 = 验证真机路径。
    不加 `-p` 就是没有密码(root 锁定),这时进虚拟机只能靠 `authorized_keys` 里的公钥走 SSH。
    `tools/verify.sh` 有两条断言:配置里不许出现 `RootPassword=`/`Autologin=`;
    `-p` 必须**同时**传给 build 与 vm 两次调用(否则被 history 吃掉,见坑 #30)。
    (未查清:autologin 那条路径的 shell 为什么秒退。真机不受影响 —— 正式产物不带这个 profile。)

27. **虚拟机的 SSH(曾用 VSock)已移除 —— 容器里那条路是死的。**
    背景:mkosi 的 `ssh` 动词用 VSock 连 guest 的 `sshd-vsock.socket`,本意是绕开 guest 网络
    (guest 里 DHCP 还没修)。实测 mkosi 25.3 的 `run_ssh` 会去 flock
    `$XDG_RUNTIME_DIR/mkosi/machine`,容器里没有 `/run/mkosi` ⇒ `FileNotFoundError`。
    既然控制台密码登录已经可用(`tools/build-container.sh -p <密码>` → mkosi 的 `--root-password=`),这条路就不值得维护,
    已从 `tools/build-container.sh` 移除(vm-bg/ssh 两个模式一起删)。
    真机的 SSH 是 sshd + 公钥(不变量 7、docs/install.md §2.5),和这里无关。

28. **Debian 13 把 `/bin/login` 拆成独立包 `login`:包清单里少了它,控制台登录完全不可用。**
    现象:VM 控制台上一行行刷 `Debian GNU/Linux 13 localhost hvc0` + `localhost login: …`,
    **每两秒重开一次,没有任何报错**,换密码登录也一样(`agetty` exec `/bin/login` 失败后退出,
    报错只进 journal,不进控制台)。诊断证据(用一次性诊断单元打到控制台):
    ```
    ls: cannot access '/bin/login': No such file or directory
    grep: /etc/pam.d/login: No such file or directory
    login rc=127                     ← timeout: failed to run command '/bin/login'
    BASH_OK  uid=0(root)             ← tty/会话/shell 都是好的,只差 login 这个二进制
    ```
    ⇒ `mkosi.conf.d/20-packages.conf` 里加 `login`(它会把 `libpam-runtime` 一起带进来);
    `tools/verify.sh` 加了断言。**注意**:`util-linux` 不再提供 `/bin/login`,
    `openssh-server` 也不会拉它 ⇒ 只装"看起来相关"的包是查不出来的(我们正是这么漏掉的)。
    这也解释了坑 #26 的 autologin 死循环:`--autologin` 同样要经 `/bin/login`。

29. **networkd 的 DHCPv4 客户端在本镜像里起不来(`-ENOPKG` / "Package not installed");已用 dhcpcd 顶替。**
    症状(VM 里,`systemd-networkd` 正常启动、接口也认到了):
    ```
    systemd-networkd[556]: enp0s1: Failed to configure DHCPv4 client: Package not installed
    ```
    装到笔记本前必须解决(SSH/更新/nix 都要网)。**诊断方法(下次直接照这个做)**:
    * **不要**用 drop-in 把 `systemd-networkd.service` 的 ExecStart 换成 `strace …` —— 实测两头都堵死:
      单元沙箱让 `/tmp` 只读(`Can't fopen '/tmp/nd.trace': Read-only file system`),
      并且拒绝 ptrace(`PTRACE_TRACEME: Operation not permitted`),结果 networkd 直接 crash-loop,
      连网络管理都没了(踩过)。
    * 正确做法:在 VM 里**手工**停掉服务再跑一份带 strace 的实例(手工跑就没有单元沙箱):
      ```bash
      systemctl stop systemd-networkd
      strace -f -o /tmp/nd.trace /usr/lib/systemd/systemd-networkd &
      sleep 3; networkctl reconfigure enp0s1; sleep 3
      grep -nE 'ENOPKG|dhcp|openat.*ENOENT' /tmp/nd.trace | tail -30
      ```
      (`ENOPKG` 在 Linux 上也来自内核的 `request_module()` —— 即"想要一个不存在的模块/文件",
      所以要看它到底在 open 什么。)
    * 备选(不改设计也能先有网):加 `dhcpcd-base`,让 dhcpcd 负责 DHCP,
      网络配置从 networkd 挪过去(代价:DNS 的交接要处理,resolved 的 stub 不能再被覆盖)。
    * **现状(2026-09)**:走的就是这个备选 —— `dhcpcd-base` + `20-wired.network` 里 `DHCP=no`
      + `/etc/dhcpcd.conf` 的 `nohook resolv.conf`
      + `dhcpcd-hooks/20-keel-resolved` 把 DNS 交给 resolved(`resolvectl dns/domain/default-route`),
      所以 `/etc/resolv.conf` 仍然指向 resolved 的 stub ✓。`tools/verify.sh` 有三条断言守着。
      **ENOPKG 的根因仍未查清** —— strace 里没有任何 `ENOPKG` 系统调用失败(全是无关 ENOENT),
      说明是 networkd 内部判定"DHCP 实现不可用"(编译期开关或运行期条件)。哪天要换回 systemd 原生栈,
      从这里接着查。

30. **`mkosi vm`(以及 `shell`/`boot` 这类"操作已构建镜像"的动作)不解析配置文件,它读上一次 build 的 history;与 history 不同的 CLI 设置只警告、不生效。**
    mkosi 25.3 的 `parse_config`(27 同):
    ```python
    if have_history(args):                      # 有 .mkosi-private/history/latest.json 就为真
        prev = Config.from_json(Path(".mkosi-private/history/latest.json").read_text())
        for s in SETTINGS:
            if s.section in ("Include", "Runtime"):   # 只有这两段允许现场改
                continue
            if hasattr(context.cli, s.dest) and getattr(context.cli, s.dest) != getattr(prev, s.dest):
                logging.warning(f"Ignoring {s.long} from the CLI. Run with -f to rebuild the image with this setting")
            setattr(context.cli, s.dest, getattr(prev, s.dest))
        context.only_sections = ("Include", "Runtime", "Host")
    ```
    ⇒ `vm` 用的是**上一次 build 时**的配置,命令行上写的 Content 段设置(比如 `--root-password=`)
    会被 history 里的值覆盖,只在日志里留一行 `Ignoring --root-password from the CLI` ——
    **看起来像成功,其实密码没生效**。真机排查时很容易在这里绕圈(镜像里 root 还是锁的)。
    规则:**"先 build 再 vm"的东西,两边的 Content 设置必须一致**;
    `tools/build-container.sh vm` 就是把同一个 `$ROOTPW_Q` 同时拼进两次调用,`tools/verify.sh` 有断言。
    另一个后果:手工 `mkosi --profile install vm` 时,如果上次 build 用的是别的 profile/设置,
    你开起来的就是**上次那个镜像** —— 这是坑 #23 的另一面(改了配置就得 `--force build`)。
    附带一条安全注意:`.mkosi-private/history/latest.json` 存的是配置里的**原始值**,
    `--root-password=` 传的密码很可能是明文 ⇒ 它**绝不能进 git**(已在 `.gitignore` 里)。

31. **给 repart 的定义要分"构建时"和"运行时"两份:`CopyFiles=` 只在构建时成立。**
    装机 U 盘里 `os-install <目标盘>` 跑的是
    `systemd-repart --empty=force --definitions=/usr/lib/keel/repart-install.d <盘>`,
    也就是说这份定义必须**装进镜像**;而 mkosi 构建时用的是仓库里的 `repart/install/`。
    第一版只做了后者,于是在 VM 里敲 `os-install /dev/vda` 得到:
    ```
    keel: 错误:找不到 repart 定义目录:/usr/lib/keel/repart-install.d(这个镜像不完整?)
    ```
    (`os-install` 的注释里原本写着"由父 agent 提供" —— 结果谁也没提供。)
    ⇒ 现在 `mkosi.postinst` 在构建时把 `repart/install/*.conf` 拷进
    `$R/usr/lib/keel/repart-install.d/`,并**删掉所有 `CopyFiles=` 行**。原因:
    repart 的 `CopyFiles=` 源在既没有 `--root=` 也没有 `--copy-source=` 时解析到
    **宿主机的真实 /** —— mkosi 构建时传了 `--root=<镜像树>`,所以构建时 `CopyFiles=/`
    指的是"镜像里的 /";运行时(没有 `--root=`)它会把 `/proc` `/sys` `/run` `/Volume`
    一起卷进来,而 `os-install` 本来就会自己 dd 根分区、mkfs volume、复制 ESP,
    根本不需要 repart 代劳。
    分区名/类型/尺寸仍是**同一份来源**(只删 CopyFiles),所以两张表必然一致:
    `tools/verify.sh` 会把两份定义各 `systemd-repart --dry-run` 一次,逐个字段对比名字/
    尺寸/volume 类型,并断言运行时那份里没有残留的 `CopyFiles=`。
    **教训**:凡是"构建脚本产出的文件还会在运行时被消费一遍"的东西,都要多问一句
    "里面的路径和默认值在运行时还成立吗"。

32. **repart 在目标盘上格式化分区要用 `mkfs.<类型>`,而缺了它只会在"真要格式化"那一刻炸 —— 构建时那次 repart 用的是 tools tree,镜像里没有也照样全绿。**
    真机(VM)装机走到 `os-install` 建表那一步才出现:
    ```
    Formatting future partition 0.
    mkfs binary for vfat is not available.
    keel: 错误:systemd-repart 建表失败。…
    ```
    注意**分区表本身是对的**(日志上方那张 `esp 1G / root-a 6G / root-b 6G / volume 剩余` 的表
    与设计一致),失败的只是"把 ESP 格式化成 vfat"这一步 —— `mkfs.vfat` 在 Debian 里属于
    **dosfstools**,而我们只装了提供 `mkfs.ext4`/`resize2fs` 的 e2fsprogs。
    ⇒ 包清单里补 `dosfstools`;`tools/verify.sh` 现在成对断言 `dosfstools` + `e2fsprogs`。
    **通用做法:凡是"只在运行时才被调用"的工具(格式化 / 挂载 / dd / 压缩 …),都要拿运行时
    脚本里实际用到的命令去核对镜像里到底有没有。** 最省事的核对入口是 mkosi 写出的 manifest:
    ```bash
    python3 - <<'PY'
    import json; d = json.load(open("mkosi.output/keel.manifest"))
    print(len(d["packages"]), sorted(p["name"] for p in d["packages"]))
    PY
    ```
    再对着 `mkosi.extra/usr/bin/os-*` 与 `mkosi.extra/usr/lib/keel/*` 里出现的命令逐个点名。
    (2026-09 用这个办法过了 30 个候选命令:只有 `dosfstools` 一个真缺 —— 但就是它把装机卡住了。
    `passwd`(useradd/passwd)、`mawk`(awk)、`hostname`、`systemd-repart` 都在,不用再补。)

33. **刚写完分区表的设备,别指望 `lsblk` 立刻能看到 `PARTLABEL` —— 它那一列来自 udev 的数据库,而 udev 还没跟上。**
    真机(VM)装机:repart 明明打印了 `Adding new partition 0..3 to partition table` +
    `Telling kernel to reread partition table` 然后 `All done.`,紧接着 `os-install` 的
    `find_part root-a` 却什么都没找到:
    ```
    keel: 错误:建表后找不到目标盘上的 root-a 分区(检查 /usr/lib/keel/repart-install.d 里的分区名)
    ```
    当时的实现只查 `lsblk -no PARTLABEL,PATH,PKNAME <目标盘>`。
    ⇒ 现在的 `find_part` 两道保险:
    1. **先扫 sysfs**:`/sys/class/block/*/uevent` 里的 `PARTNAME=` 是内核直接给的,不经过 udev
       (同一个思路见不变量 2 里 `/Volume` 的挂载);父设备用
       `basename "$(dirname "$(readlink -f /sys/class/block/vda1)")"` 判断,不靠 `lsblk` 的 PKNAME;
    2. 查不到就 `blockdev --rereadpt` + `udevadm settle` 后**重试约 10 秒**,
       仍然没有就把现场(`lsblk -o NAME,SIZE,TYPE,PARTLABEL,PKNAME` + `/proc/partitions`)打到 stderr ——
       免得只看到一句"找不到",还要人再猜。
    `tools/verify.sh` 用一棵**假 sysfs 树**(含另一块盘上的同名分区)把这段逻辑真跑一遍:
    必须命中目标盘、忽略同名盘、查不到时 stdout 为空。
    **教训**:`lsblk` 的 PARTLABEL/PARTTYPE 这些列是 udev 的产物,不是内核的;
    对"刚刚才发生"的设备变化要用 sysfs(`/sys/class/block/*/uevent`)或 `/proc/partitions`。
    (根因未最终确认:也可能是内核当时拒绝了 `BLKRRPART`(比如 repart 的 loop 设备还没放手),
    所以现在额外显式做一次 `blockdev --rereadpt`;真机现场见 `docs/troubleshooting.md` §2.3。)

34. **`/nix` 不能是符号链接 —— nix 硬性拒绝,装好的系统上所有 nix 命令立刻失败。**
    现象(装机后第一次用 nix):
    ```
    # nix-shell -p vim
    error: the path '/nix' is a symlink; this is not allowed for the Nix store and its parent directories
    ```
    这是 nix 的硬性检查(store 及其父目录都不能是符号链接),不是配置能绕过去的;
    **也不能**改成"把 store 放到 `/Volume/nix`" —— store 里的二进制与脚本把 `/nix/store/…`
    写死在 ELF interpreter 与 RPATH 里,位置搬不动。
    ⇒ `/nix` 和 `/home` 一样改成**真实目录 + bind mount**(不变量 1):
    `mkosi.finalize` 建空目录、`/usr/lib/keel/mounts` 里 `mount --bind /Volume/nix /nix`。
    `/Volume/nix`(含 `store/` 与 `var/nix/…`)本来就在骨架里,所以 `/Volume` 的 schema 不用动;
    但**已经装好的旧系统**要等新槽生效(`os-update` 会换掉整个根文件系统)才会拿到真实目录,
    在那之前可以热修(见 `docs/troubleshooting.md` §4)。
    `tools/verify.sh` 有断言:finalize 不许 `ln -s …/nix`,且 mounts 里必须有 `/home` 与 `/nix`
    两条 bind。
    **教训**:判断"某个路径能不能是符号链接"时别只看 POSIX 语义 —— 具体工具有硬性要求
    (nix 要 store 是真目录,systemd 的 `ProtectHome=` 要 `/home` 是真挂载点,坑 #26 的 autologin
    则是 `/bin/login` 得存在)。

35. **"系统版本"必须读 os-release 的 `IMAGE_VERSION`,不是 Debian 的 `VERSION_ID`。**
    装机后 `os-status` 报 `系统版本: 13`,state 里 pending 也写 `版本 13` —— 因为 `keel_version()`
    读的是 `/etc/os-release` 的 `VERSION_ID`,而在 Debian 基底上那是**发行版号**。
    后果不只是显示难看:`os-update` 用版本号判断"这是不是同一个版本 / 要不要更新",
    两边恒等于 `"13"` 会让这个判断**永远说"已经是最新"**;pending / last_result 里的版本也失去意义
    (回滚判定、`os-status` 的历史记录全都分不清是哪一版)。
    ⇒ mkosi 会把 `--image-version` 写进 `/usr/lib/os-release` 的 `IMAGE_VERSION=`
    (`write_os_release`,25.x/27 都有;`/etc/os-release` 是指向它的符号链接),
    所以 `keel_version()` 改成先读 `IMAGE_VERSION`、读不到才退回 `VERSION_ID`。
    `tools/verify.sh` 有断言。**教训**:基底发行版的 os-release 字段(`VERSION_ID`/`ID`)描述的是
    **基底**,不是我们的产品 —— 凡是"我们自己的版本/标识"都要用 mkosi 注入的 `IMAGE_ID`/`IMAGE_VERSION`,
    或者干脆自己写一份文件。
---

## 4. 常用命令

```bash
# 静态校验(不需要 root、不需要 loop 设备,能在这里跑)
tools/verify.sh

# 产物构建(建议 ToolsTree=default;宿主机只需要 mkosi + bubblewrap + 一个包管理器)
tools/build.sh                       # 一次产出:安装镜像 + A/B 载荷 + manifest → dist/
tools/build.sh --profile desktop     # 变体

# 宿主不是 mkosi 支持的发行版时(NixOS 等):把构建放进容器(见已知的坑 #15)
sudo tools/build-container.sh               # 构建(产物里 root 无密码)
sudo tools/build-container.sh -p <密码> vm  # 构建并在容器里起 QEMU(控制台用 root / 该密码登录)
sudo tools/build-container.sh shell         # 进容器手敲 mkosi

# 排错第一步:只看配置解析结果,不构建
mkosi --profile install summary
mkosi --profile install cat-config

# 单独校验 repart 布局(真跑分区表求解,不写盘)
systemd-repart --dry-run=yes --definitions=repart/install --empty=create --size=14G --json=pretty /tmp/t.raw

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
- [x] 单元:`keel-mounts`、`keel-firstboot`、`keel-confirm`、`keel-swapfile` + preset
- [x] `mkosi.extra/usr/bin/`:`os-status`、`os-update`、`os-rescue`、`os-install`
- [x] `tools/`:`verify.sh`、`build.sh`、`burn.sh`、`build-container.sh`(给不被 mkosi 支持的宿主用)
- [x] `docs/`:`architecture.md`、`decisions.md`、`install.md`、`update.md`、`troubleshooting.md`
- [x] **第一次真机构建 / 虚拟机启动 / 装机**(2026-09,VM:构建 → live 启动 → `os-install` → 目标盘首启 ✓;
      途中修掉坑 #31–#34。**真机(U 盘 + 笔记本)仍未做过**)
- [ ] `desktop` profile(笔记本用)
- [ ] `server` profile(虚拟化宿主,GPU 直通)

### 下一步要验证的事(结论回写到 `docs/architecture.md` §13.1)

1. ~~`root=PARTLABEL=` 与 `systemd.mount-extra=PARTLABEL=...` 在 initrd 里的解析~~
   **已实测(2026-09,VM)**:`root=PARTLABEL=` 在 initrd 里有效 ✓;
   `systemd.mount-extra=PARTLABEL=volume:/Volume:…` 在 initrd 里**不会被挂载** ✗,
   在主系统里会挂但依赖 udev ⇒ 造成启动死锁。结论已回写到不变量 2 与坑 #24。
2. `systemd-sysupdate` 的 `Type=partition` transfer 对双槽布局的匹配语义(验证通过后换掉 v1 的直接写盘)。
3. `/usr/lib/modules/<kver>` 挂 overlay 后 `depmod` + 模块加载的实际行为(为"第三方内核模块外置"做准备)。
4. ~~**`os-install` 的完整流程**(在 VM 里对第二块盘演练)~~
   **已实测走通(2026-09,VM)**:repart 建表 → dd 根分区 → mkfs+铺 volume 骨架 → 复制 ESP →
   写 pending → **目标盘首启成功**。途中修掉坑 #31(镜像里没有 `/usr/lib/keel/repart-install.d`)、
   #32(镜像里没有 `dosfstools`,repart 格式化 ESP 失败)、#33(建表后 `find_part` 查 `lsblk` 的
   PARTLABEL 扑空,已改成先扫 sysfs + 重试)。
5. **装机后 nix 真的能用**(`nix-shell -p vim` 等)—— 第一次跑就撞上坑 #34(`/nix` 是符号链接),
   已改成「真实目录 + bind mount」。**待复验**:新镜像里 `/nix` 是真目录、bind 生效、
   `nix-shell -p …` 能装能跑;以及 `df -h /Volume` 确认首启把 volume 扩到了整盘(不变量 14)。
