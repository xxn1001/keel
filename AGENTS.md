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
   根分区以 `ro` 挂载;`/var`、`/root`、`/nix` 是指向 `/Volume` 的符号链接,`/home` 是真目录 + bind mount
   (符号链接会破坏 `ProtectHome=` 的沙箱语义,所以 `/home` 是唯一的例外)。

2. **`/Volume` 必须由 initrd 挂载,且早于 switch_root。**
   符号链接无法参与挂载顺序约束,不能靠"启动后再挂"。做法是写进 UKI 的 kernel cmdline:
   `systemd.mount-extra=PARTLABEL=volume:/Volume:ext4:rw,noatime`
   (`systemd-fstab-generator` 在主系统和 initrd 里都会解析它,initrd 里自动加 `/sysroot/` 前缀。)

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
    我们的 `/Volume` 是 cmdline 里 `systemd.mount-extra=` 显式挂载的,**根本不过 gpt-auto-generator**。
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
    `mkosi --profile install --profile test build` → `mkosi --profile install --profile test vm`。
    别用 `--force` 图省事:`-f` 会把已构建的镜像删掉重来。

---

## 4. 常用命令

```bash
# 静态校验(不需要 root、不需要 loop 设备,能在这里跑)
tools/verify.sh

# 产物构建(建议 ToolsTree=default;宿主机只需要 mkosi + bubblewrap + 一个包管理器)
tools/build.sh                       # 一次产出:安装镜像 + A/B 载荷 + manifest → dist/
tools/build.sh --profile desktop     # 变体

# 宿主不是 mkosi 支持的发行版时(NixOS 等):把构建放进容器(见已知的坑 #15)
sudo tools/build-container.sh        # 构建
sudo tools/build-container.sh vm     # 构建并在容器里起 QEMU
sudo tools/build-container.sh shell  # 进容器手敲 mkosi

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
- [ ] **第一次真机构建 / 虚拟机启动**(由人类做:见 `docs/install.md` §1)
- [ ] `desktop` profile(笔记本用)
- [ ] `server` profile(虚拟化宿主,GPU 直通)

### 下一步要验证的事(结论回写到 `docs/architecture.md` §13.1)

1. `root=PARTLABEL=` 与 `systemd.mount-extra=PARTLABEL=...` 在 initrd 里的解析(有把握,但要真跑一次)。
2. `systemd-sysupdate` 的 `Type=partition` transfer 对双槽布局的匹配语义(验证通过后换掉 v1 的直接写盘)。
3. `/usr/lib/modules/<kver>` 挂 overlay 后 `depmod` + 模块加载的实际行为(为"第三方内核模块外置"做准备)。

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
