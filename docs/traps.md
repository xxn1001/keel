# keel 已知的坑(77 条,都是真踩过的)

> 这份清单原来在 `AGENTS.md` §3。2026-09 拆出来,是因为 `AGENTS.md` 长到 65 KB 之后
> **超出"工作区指令"的加载预算、末尾会被静默截断**(实测被砍掉过"下一步要验证的事"那一段),
> 而"架构不变量"那份必须每次完整加载。
>
> **怎么用**:改哪块代码,就按关键词 grep 这个文件 —— 比从头读一遍有效得多。
>
> ```bash
> grep -n "machine-id\|ESP\|repart\|overlay\|mkosi" docs/traps.md
> ```
>
> 仓库其他地方提到的「坑 #N」指的都是这里的编号;与代码/实测冲突时以代码为准,并回来改这条。

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
   因为 `/var` 是符号链接,运行时看到的是 `/data/var`。所以:
   - `/data` 骨架必须**显式**提供,不能指望镜像里的 `/var`(构建时从镜像的 `/var` 快照生成,
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
     适合"某台机器的专属参数",代价是这份差异只存在于 ESP 上、不参与镜像校验,而且 a/b 槽各要一份;
     Secure Boot 下 addon 本身也必须被信任的密钥签过。
   **v1.2 更新(2026-09-28)**:keel 现在真的开了 Secure Boot(`mkosi.conf` 的 `SecureBoot=yes`,
   自签 `mkosi.key`/`mkosi.crt`),所以**按 e 这条路已经关闭**;要么用签名的 UKI addon,
   要么临时在固件里关掉 Secure Boot 再调试。

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
    我们的 `/data` 是自己用 `mount` 挂的(不变量 2),**根本不过 gpt-auto-generator**。
    ⇒ 扩容必须两步:`systemd-repart` 扩分区 + `systemd-growfs /data` 扩文件系统
    (两处都已实现:首启的 `keel-firstboot` 与 `os-rescue --grow-data`)。
    另外 `systemd-growfs` 对 ext4 会调 `resize2fs`,所以 `e2fsprogs` **必须**在包清单里。
    首次真机启动后请用 `df -h /data` 复核这一点。

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

24. **`systemd.mount-extra=PARTLABEL=…` 会让早期启动死锁:它依赖 udev,而 udev 依赖可写的 `/etc`,可写的 `/etc` 又依赖 `/data`。**
    这是**第一次真机(VM)启动**抓到的,整条链是:
    ```
    keel-mounts(Before=sysusers,需要可写的 /etc,而 /etc overlay 的 upper 在 /data)
        → RequiresMountsFor=/data → data.mount
        → Requires/After dev-disk-by-partlabel-data.device(要 udev 建符号链接)
        → systemd-udevd(After=systemd-sysusers)
        → systemd-sysusers(要写 /etc)
        → 回到 keel-mounts  ✗ 环
    ```
    systemd 破环时丢掉了 `local-fs-pre.target`(启动日志里就是那行
    `[ SKIP ] Ordering cycle found, skipping local-fs-pre.target`),于是 udev 被推迟到
    **emergency 之后**才启动,所有 `by-partlabel` 挂载等满 90 秒超时:
    ```
    [ TIME ] Timed out waiting for device dev-disk-by-partlabel-data.device - /dev/disk/by-partlabel/data.
    [DEPEND] Dependency failed for data.mount - /data.
    [DEPEND] Dependency failed for local-fs.target - Local File Systems.
    [DEPEND] Dependency failed for keel-mounts.service …
    ```
    ⇒ local-fs 失败 ⇒ **emergency mode**;连带 `systemd-random-seed`(往悬空的 `/var` 符号链接写)、
    `systemd-timesyncd` 一起失败。
    顺带证伪了两个曾经的假设:
    - **initrd 并不会帮我们挂 `/data`**:cmdline 里的 `systemd.mount-extra` 在 initrd 阶段没有生成
      `/sysroot/data`(把 initrd 从 UKI 里抽出来看,里面根本没有我们的文件,也没有任何 `/data` 挂载动作);
    - 而 `root=PARTLABEL=root-a` 在 initrd 里**是**有效的(`Found device …root-a.device` ✓)。
    ⇒ 现在的做法见不变量 2:keel-mounts 自己扫 `/sys` 的 `PARTNAME=` 挂 `/data`(不经过 udev、
    不生成 `.mount` 单元),`keel-mounts.service` 里加 `Before=systemd-random-seed.service`,
    cmdline 里**不再有** `systemd.mount-extra`。`tools/verify.sh` 有正反两条断言守着。
    **教训**:早期启动里任何"要等 udev"的东西,都要先问一句"udev 自己能不能起来"。

25. **ESP 是我们自己挂的(`/boot`);`systemd-gpt-auto-generator` 已被关掉。**
    曾经的做法是"让 gpt-auto 自动挂 ESP,`bootctl --print-esp-path` 现问路径"(那是坑 #25 的原文)。
    2026-09 装机后的系统上实测:**ESP 压根没挂上**,而 bootctl 只是在按 gpt-auto 的规则**猜**
    (`/boot` 目录存在就报 `/boot`),于是所有 UKI 操作都落在一个空目录上,而且**每一步都"成功"**
    —— 详见坑 #36。现在:
    * `keel-mounts` 扫 `/sys/class/block/*/uevent` 的 `PARTNAME=esp`,以 **rw** 挂到 `/boot`
      (`fmask=0133,dmask=0022`,对齐 systemd 给 ESP 的默认值);已经是挂载点就绝不重复挂
      (先按"源设备 == PARTNAME=esp"在挂载表里找,gpt-auto 以前可能把它挂在 `/efi`);
    * `lib.sh` 的 `keel_esp()` 只承认两种来源:① 挂载表里的 ESP;② `bootctl --print-esp-path`
      给的路径**确实是挂载点**。都不成立就输出空,并把 `KEEL_ESP_MOUNTED` 置成 `no`;
    * `KEEL_ESP_MOUNTED=no` 时:**`os-update` 在写根分区之前就拒绝**(只换根不换内核 = 违反不变量 3)、
      `os-status` 明说"看到的是空目录"、`keel-confirm` 记一条"没做 set-preferred"、
      `keel-firstboot` / `os-rescue --repair-boot` / `os-install` 会**自己先试着挂一次**;
    * 仍然**不要**硬编码 `/efi` 或 `/boot/EFI`:一律走 `$KEEL_ESP` / `$KEEL_UKI_DIR`
      (`tools/verify.sh` 有断言)。

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
    (当时的理由之一是 guest 里 DHCP 还是坏的 —— 那条已由坑 #29 修掉,
    但 VSock ssh 在容器里依旧是坏的,所以移除这个决定不变)。实测 mkosi 25.3 的 `run_ssh` 会去 flock
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

29. **networkd 的 DHCPv4 起不来(`-ENOPKG` / "Package not installed")—— 根因是 `/etc/machine-id` 永远是 `uninitialized`,已修(2026-09)。**
    症状(VM 里,`systemd-networkd` 正常启动、接口也认到了):
    ```
    systemd-networkd[556]: enp0s1: Failed to configure DHCPv4 client: Package not installed
    ```
    **根因(读源码定位的,不用再猜)**:
    * `ENOPKG` 在这条路径上只有一个来源:`sd_id128_get_machine()` 读到的 `/etc/machine-id`
      内容是字符串 `uninitialized` —— `id128-util.c` 专门为这个内容返回 `-ENOPKG`(不是 `ENOENT`)。
      "Package not installed" 只是 `strerror(ENOPKG)` 的字面翻译,**跟"缺包"毫无关系**,
      这也正是当初被带偏的地方。
    * 调用链:`dhcp4_configure()` → `dhcp4_set_client_identifier()` → DUID 默认 `DUIDType=uuid`
      → `sd_dhcp_duid_set_uuid()` → `sd_id128_get_machine_app_specific()` → `-ENOPKG`。
      所以当年 strace 里"没有任何 ENOPKG 系统调用失败"完全正常:失败来自**文件内容判定**,
      不是某次系统调用。
    * 为什么它永远是 `uninitialized`:mkosi 写进镜像的就是这个占位符;而 PID1 首启做
      machine-id 初始化时,我们的 `/etc` overlay **还没挂**、根还是只读的 ⇒ 它判定"只能 transient":
      真 ID 写进 `/run/machine-id`,再 bind mount 到 `/etc/machine-id`;紧接着 `keel-mounts`
      把 overlay 挂到 `/etc`,**那个 bind mount 被整个盖住**(overlay 的 lower 看不到挂在里面的
      子挂载)⇒ `/etc/machine-id` 永远是 lower 里那句 `uninitialized`。
      `systemd-machine-id-commit.service` 也救不了:它要求 `/etc/machine-id` 是**挂载点**
      (已被盖掉),而 `/etc` 可写那条路又依赖我们的 overlay。
    * 影响面不止 DHCP:IPv6 稳定隐私地址、resolved 的 DNSSEC 密钥、任何 `%m` 展开一起废。
    ⇒ **修法**:`/usr/lib/keel/mounts` 在挂完 `/etc` overlay 之后**立刻**把 PID1 本次启动
      **已经在用**的那个 ID(`/run/machine-id`)原样写进 `/etc/machine-id` —— 此时 `/etc` 已经是
      overlay,内容落进 upper ⇒ 在 `/data` 上、每台机器唯一、换槽与更新都不丢
      (`docs/architecture.md` §4.3);`/run/machine-id` 不可用时才清空文件、让
      `systemd-machine-id-setup` 生成一个。写完回读校验,不对就大声报。
      `DHCP=yes` 交回 networkd,`dhcpcd-base` / `keel-dhcpcd.service` / dhcpcd hook /
      `/etc/dhcpcd.conf` 全部删除。`tools/verify.sh` 三条断言守着它(DHCP=yes;mounts 里的固化
      且在挂 overlay 之后;没有 dhcpcd 残留)。
    **⚠ 这个坑有第二层,第一版就栽在这里**:`systemd-machine-id-setup` **不能直接用**。它的 `main()`:
      ```c
      } else if (id128_get_machine(arg_root, NULL) == -ENOPKG) {
              if (arg_print) puts("uninitialized");     // ← 什么都不做,返回 0
      } else { ... machine_id_setup(...) ... }
      ```
      也就是**内容恰好是 `uninitialized` 时它故意空转**(那被当成"首启标记",留给 PID1 的 transient
      机制),而且**退出码是 0** ⇒ "调用成功"什么也证明不了。第一版就写了这一句,VM 里日志打出
      `已生成 machine-id(uninitialized)`,一轮构建白跑。要它干活必须**先把文件清空**
      (空文件是 `-ENOMEDIUM` 而不是 `-ENOPKG`,它才会走生成路径)。它还有 `--print`
      (只打印自己眼里的 ID、不改动),排查时比 `cat` 更能说明问题。
    **教训**:① `-ENOPKG` 别按字面理解成"缺包" —— systemd 里它表示"功能需要的东西没配好",
      machine-id 未初始化是最常见的一种;② **PID1 在挂我们的 overlay 之前对 `/etc` 做的任何写入
      都会被盖掉**(它写的是 lower 那份),凡是 PID1 早期写 /etc 的东西,重启后都要问一句"它还在吗";
      ③ **"退出码 0" ≠ "事情做成了"** —— systemd 里那些"先看状态再决定动不动手"的工具
      (`systemd-machine-id-setup`、`systemd-firstboot`、`preset-all`…)**把"我什么都没干"也当成功**。
      对它们要么回读校验,要么用 `--print`/`-v` 确认,别只看返回值。
    **已知残留(不影响功能,先记着)**:PID1 每次启动读到的都是只读 lower 里那句 `uninitialized`,
      所以它会一次次生成新的 transient ID 放进 `/run/machine-id` —— **PID1 内存里的 ID ≠
      `/etc/machine-id`**;而真正去读文件的功能(networkd、resolved、journald、tmpfiles)拿到的
      都是固化的那个,稳定。要彻底消除只有两条路:把 `/etc` overlay 提到 initrd 里挂(PID1 一开始
      就读到持久化的 ID),或者 cmdline 加 `systemd.machine_id=firmware`(用硬件 UUID;代价是
      依赖 DMI 可靠)。**两条都先别动** —— 改 cmdline = 动承重墙(`mkosi.conf.d/30-content.conf`)。
    (当时的诊断弯路:用 drop-in 把 networkd 的 `ExecStart` 换成 `strace …` —— 单元沙箱让 `/tmp`
      只读、还拒绝 ptrace,networkd 直接 crash-loop;要在 VM 里手工停掉服务再跑 strace 才行。
      另外现在有个现成的诊断口子:`mkosi.extra-test/` 里的 `keel-selftest.service`,
      它会把 machine-id 现场、`/etc` 可写性探针、networkd 日志、失败单元全打到 VM 控制台上。)

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
    指的是"镜像里的 /";运行时(没有 `--root=`)它会把 `/proc` `/sys` `/run` `/data`
    一起卷进来,而 `os-install` 本来就会自己 dd 根分区、mkfs data 分区、复制 ESP,
    根本不需要 repart 代劳。
    分区名/类型/尺寸仍是**同一份来源**(只删 CopyFiles),所以两张表必然一致:
    `tools/verify.sh` 会把两份定义各 `systemd-repart --dry-run` 一次,逐个字段对比名字/
    尺寸/类型,并断言运行时那份里没有残留的 `CopyFiles=`。
    **教训**:凡是"构建脚本产出的文件还会在运行时被消费一遍"的东西,都要多问一句
    "里面的路径和默认值在运行时还成立吗"。

32. **repart 在目标盘上格式化分区要用 `mkfs.<类型>`,而缺了它只会在"真要格式化"那一刻炸 —— 构建时那次 repart 用的是 tools tree,镜像里没有也照样全绿。**
    真机(VM)装机走到 `os-install` 建表那一步才出现:
    ```
    Formatting future partition 0.
    mkfs binary for vfat is not available.
    keel: 错误:systemd-repart 建表失败。…
    ```
    注意**分区表本身是对的**(日志上方那张 `esp 1G / root-a 6G / root-b 6G / data 剩余` 的表
    与设计一致),失败的只是"把 ESP 格式化成 vfat"这一步 —— `mkfs.vfat` 在 Debian 里属于
    **dosfstools**,而我们只装了提供 `mkfs.ext4`/`resize2fs` 的 e2fsprogs。
    ⇒ 包清单里补 `dosfstools`;`tools/verify.sh` 现在断言 `dosfstools` + `e2fsprogs` + `erofs-utils`。
    (**v1.1 续集**:根换成 erofs 之后同一个坑又出现一次 —— 缺 `erofs-utils`/`mkfs.erofs`。
    那次是**提前按这条规律核对**发现的,不是装机时炸出来的:见坑 #63。)
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
       (同一个思路见不变量 2 里 `/data` 的挂载);父设备用
       `basename "$(dirname "$(readlink -f /sys/class/block/vda1)")"` 判断,不靠 `lsblk` 的 PKNAME;
    2. 查不到就 `blockdev --rereadpt` + `udevadm settle` 后**重试约 10 秒**,
       仍然没有就把现场(`lsblk -o NAME,SIZE,TYPE,PARTLABEL,PKNAME` + `/proc/partitions`)打到 stderr ——
       免得只看到一句"找不到",还要人再猜。
    `tools/verify.sh` 用一棵**假 sysfs 树**(含另一块盘上的同名分区)把这段逻辑真跑一遍:
    必须命中目标盘、忽略同名盘、查不到时 stdout 为空。
    **教训**:`lsblk` 的 PARTLABEL/PARTTYPE 这些列是 udev 的产物,不是内核的;
    对"刚刚才发生"的设备变化要用 sysfs(`/sys/class/block/*/uevent`)或 `/proc/partitions`。
    (根因未最终确认:也可能是内核当时拒绝了 `BLKRRPART`(比如 repart 的 loop 设备还没放手),
    所以现在额外显式做一次 `blockdev --rereadpt`;真机现场见 `docs/troubleshooting.md` §2.6。)

34. **`/nix` 不能是符号链接 —— nix 硬性拒绝,装好的系统上所有 nix 命令立刻失败。**
    现象(装机后第一次用 nix):
    ```
    # nix-shell -p vim
    error: the path '/nix' is a symlink; this is not allowed for the Nix store and its parent directories
    ```
    这是 nix 的硬性检查(store 及其父目录都不能是符号链接),不是配置能绕过去的;
    **也不能**改成"把 store 放到 `/data/nix`" —— store 里的二进制与脚本把 `/nix/store/…`
    写死在 ELF interpreter 与 RPATH 里,位置搬不动。
    ⇒ `/nix` 和 `/home` 一样改成**真实目录 + bind mount**(不变量 1):
    `mkosi.finalize` 建空目录、`/usr/lib/keel/mounts` 里 `mount --bind /data/nix /nix`。
    `/data/nix`(含 `store/` 与 `var/nix/…`)本来就在骨架里,所以 `/data` 的 schema 不用动;
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

36. **装机后的系统里 ESP 没挂上 ⇒ `os-status` 看不到 UKI、`keel-confirm` 确认不了槽(2026-09 发现并修好)。**
    现象(VM 里 `os-install /dev/vda` 装出来的系统,`os-status` 输出):
    ```
    ESP 上的 UKI(目录 /boot/EFI/Linux)
      目录不存在:/boot/EFI/Linux            ← 一个 UKI 条目都没有
    上次启动结果: 无记录
    ```
    但**这台机器确实是从那块盘启动起来的**(当前槽 a、pending 也是装机时写的)⇒ ESP 上的
    loader 与 UKI 一定都在。所以"看不见"不是 ESP 空了,而是**它根本没挂到 `/boot`**。
    更坑的是**没有一处报错**:`keel_esp()` 把 `bootctl --print-esp-path` 的输出当路径用,
    而 bootctl 只是按 gpt-auto 的规则猜(`/boot` 目录存在就报 `/boot`),**从不验证它是不是挂载点**
    ⇒ 之后所有 `$KEEL_UKI_DIR` / bootctl 操作都在空目录上"成功":
    `os-update` 写不进新 UKI、`bootctl set-preferred` 切不了槽、boot counting 改名做不了
    ⇒ **A/B 更新与槽确认这条链整条是断的**。
    为什么不再用 gpt-auto(源码 `process_loader_partitions()` / `add_partition_esp()`,
    这些条件**任何一条不满足都只是静默跳过**):
    1. `/etc/fstab` 里但凡有 `/boot` 或 `/efi` 下的条目 ⇒ 整个 ESP/XBOOTLDR 逻辑不生成;
    2. `/boot` 必须是"没被占用"的目录(`path_is_busy()`:是挂载点、或**目录里有文件**都算占用)
       —— 否则退到 `/efi`;`/efi` 也被占用就什么都不挂;
    3. 固件这次启动的**必须就是这块 ESP**:它读 EFI 变量 `LoaderDevicePartUUID`
       (`efi_loader_get_device_partuuid()`,要求 efivarfs 已挂载);变量读不到时打印
       `EFI loader partition unknown, skipping ESP and XBOOTLDR mounts.` 就放弃,
       变量指向的分区 UUID 与磁盘上的 ESP 不一致时同样放弃。
    ⇒ **修法(2026-09,决策 D18)**:把这件"必须 100% 可用"的事收回来自己做 ——
      `keel-mounts` 扫 `PARTNAME=esp` 以 rw 挂到 `/boot`;cmdline 加 `systemd.gpt_auto=no`
      让它彻底退场;`lib.sh` 只承认"挂载表里的 ESP"或"确实是挂载点的路径",
      没挂上就 `KEEL_ESP_MOUNTED=no`,由调用方**明确报错或自救**(见坑 #25);
      `os-update` 还多一道保险:先确认 ESP 可用,再 dd 根分区(顺序反了会留下"新根 + 旧内核"的槽)。
      `tools/verify.sh` 有 5 条断言守着(自己挂 ESP、状态变量三处接线、os-update 的顺序、
      cmdline 里的 `systemd.gpt_auto=no`、bootctl 只作兜底)。
    **教训**:① **"命令返回 0 / 目录存在 / 函数返回了路径"都不等于"事情成了"** ——
      一个需要 100% 可用的依赖,不要建立在"一堆静默跳过条件"之上(坑 #29 的 machine-id 是同一个形状);
      ② 排查这类问题要**先看挂载表**(`findmnt /boot`)再看目录内容 —— 空目录和"没挂上"看起来一模一样。

37. **live 镜像的 `/data` 只有 1 GiB,而 swapfile 的大小是按内存算的 ⇒ 半个 swapfile 把 `/data` 填满,`/etc` overlay 跟着写不进去。**
    现象(2026-09,VM 自检里看到的):
    ```
    swapfile[664]: keel: 创建 /data/keel/swapfile(1999101952 字节),这一步可能要几十秒
    swapfile[696]: dd: error writing '/data/keel/swapfile': No space left on device
    systemd[1]: Failed to start keel-swapfile.service …
    # 紧接着自检的 /etc 可写性探针也失败:
    selftest: WRITE_FAIL(/etc 写不进去,keel-mounts 挂的 overlay 有问题)
    ```
    原因:14 GiB 的安装镜像里 `esp 1G + root-a 6G + root-b 6G`,留给 `data` 的只剩 1 GiB,
    而 `keel-firstboot` 的扩容在 live 环境里没得扩(镜像自己没剩余空间)⇒ `/data` 一直 1 GiB。
    swapfile 默认 `min(内存, 8G)`(VM 里 1.9G)直接写下去,dd 写到一半 ENOSPC,`set -e` 让单元失败,
    **半截文件留在盘上把 /data 占满** —— 而 `/etc` overlay 的 upper 就在同一个文件系统上
    ⇒ 之后往 `/etc` 写任何东西都 ENOSPC(机器专属配置、SSH 主机密钥全会静默失败)。
    更糟的是下一轮启动还在这坑里打转:文件已存在 ⇒ 跳过创建 ⇒ 直接 `swapon` 一个没有签名的
    半截文件 ⇒ 又失败,而且不清理。
    ⇒ 现在的 `/usr/lib/keel/swapfile`:
    1. 创建前用 `df -P -B1 /data` 取可用空间,**最多用一半**;请求值超过上限就压到上限并记日志;
    2. 可用空间连 256 MiB 都不到就**正常退出**(只记一笔),不让单元变红 ——
       1 GiB 的 live data 分区本来就不该有 swap,装到真机、data 分区扩到整盘后会自动建;
    3. 先写 `$SWAP.new`、`mkswap` 成功后才 `mv` 成正式文件;任何一步失败都 `rm -f` 半截文件;
       已存在的文件若没有 swap 签名(上次失败的遗留)先删掉重建。
    `tools/verify.sh` 有断言。**教训**:① 只读根 + overlay 的系统里 **`/data` 写满 = `/etc` 也写不进去**,
    任何"一次性写一大块"的脚本(swapfile、下载、日志)都必须先问可用空间;
    ② "创建大文件"要"先写临时文件、成功再改名",否则失败会留下垃圾并且**每次启动都继续坏下去**。

38. **持久分区从 `/Volume` 改名成 `/data`(2026-09):挂载点、GPT 标签、骨架目录、救援子命令一起改。**
    * 挂载点:`/Volume` → `/data`(所有路径、符号链接目标、`/data/keel/state`、单元里的
      `ConditionPathIsMountPoint=`、断言、文档一起改);
    * **GPT 标签 / 文件系统标签**:`volume` → `data` —— 分区名就是 repart 定义文件名去掉数字前缀,
      所以 `repart/install/30-volume.conf` 改名成 `30-data.conf`,`Label=volume` → `Label=data`;
      查找键随之变成 `keel_part_dev data`,`os-install` 的 `mkfs.ext4 -L data`、
      `os-rescue` 的 `/dev/disk/by-partlabel/data` 一起改;
    * 骨架目录:`/usr/share/keel/volume-skeleton` → `data-skeleton`(纯构建期路径);
    * 救援子命令:`os-rescue --init-volume` / `--grow-volume` → `--init-data` / `--grow-data`。
    **为什么这次敢动标签**:标签写在已经做好的分区表里,装完就不会再变;老机器、以及**另一个槽里的
    旧镜像**都按标签找这个分区(坑 #24 那套 `PARTNAME=` 扫描),标签一改它们就找不到 ⇒ 回滚直接
    起不来(违反不变量 6 的"只增不破")。2026-09 做这件事时所有装机都还只是虚拟机实验,所以一次改干净;
    **v1(真机装过机)之后再想改标签,必须按"只增不破"设计**(比如同时认新旧两个名字,或提供迁移步骤)。
    **教训**:分区标签是**磁盘上的事实**,挂载点/目录名/子命令名是**镜像里的事实** ——
    改后者随时可以,改前者要先问"外面有没有按旧名字做好的盘"。
    **已实测(2026-09,VM,test profile 自检)**:改名后 live 镜像正常起来 ——
    `keel-mounts` 扫到 `PARTNAME=data` 并挂到 `/data`(`/data/home`、`/data/nix` 的 bind 与
    `/etc` overlay 都建起来了)、machine-id 固化、ESP 挂在 `/boot`、DHCP `routable`、
    keel-swapfile 正常;`tools/verify.sh` 里 repart 的两次真跑也确认分区名是 `data`。
    **注意**:改名**之前**装好的实验盘(标签还是 `volume`)在新镜像下找不到分区,要重新装机。

39. **`--root-password` 落在 root 名下,而 `systemd-firstboot.service` **每次启动**都会跑 —— 只改 shadow 是
    改不干净的(2026-09,做 D21「admin 账号 + 锁 root」时发现)。**
    链条:mkosi 的 `-p` / `mkosi.rootpw` → 构建期 `systemd-firstboot --root=<镜像树>
    --root-password-hashed` 写进 **root** 的 shadow 条目,同时把
    `passwd.hashed-password.root` 放进镜像的 `/usr/lib/credstore/`;而镜像里的
    `systemd-firstboot.service` 是**开机就跑**的(VM 日志里每次启动都有
    `Starting systemd-firstboot.service - First Boot Wizard` + `first-boot-complete.target`),
    它通过 `ImportCredential=passwd.hashed-password.root` 拿那份 credential,
    "发现 root 没设密码"时会**把它设上** —— 也就是把我们锁掉的 root 又解开。
    ⇒ 所以 `mkosi.finalize` 里锁 root 的最后一步是
    `rm -f $R/usr/lib/credstore/passwd.hashed-password.root`(plaintext 那份一并删)。
    `tools/verify.sh` 有断言(删 credential 那一行必须在 finalize 里)。
    **教训**:① mkosi 的"首启设置"是**双份**的(镜像里的文件 + credstore 里的 credential),
    改一份要问另一份会不会把改动撤销;② 判断"某个单元的密码/配置从哪来"时,
    先看它的 `ImportCredential=`,`/usr/lib/credstore/` 是最容易被忘掉的第二来源。

40. **别以为实验虚拟机"没有 TPM",也别拿虚拟机里的时区/locale 当证据(2026-09,pcrlock 排查得到)。**
    两件事都来自 mkosi 的 QEMU 启动参数,不看源码猜不到:
    * **vTPM 是默认开的**:`qemu.py` 里 `config.tpm == auto`(默认值)且 tools tree 里有 `swtpm` 时,
      会 `start_swtpm` + `-tpmdev emulator -device tpm-tis`。所以 guest 里 `tpm2.target` 会到达、
      `systemd-tpm2-setup{,-early}` 会成功 —— 于是那些带 `ConditionSecurity=measured-uki` 的
      `systemd-pcrlock*` 单元**会真的执行**(它们在没有 TPM 的机器上是"条件不满足直接跳过"),
      并在 QEMU 的 vTPM 上因为拿不到固件测量结果而失败(决策 D20 把它们 mask 掉了)。
      排查这类"预期不该跑却跑了/预期该失败却成功了"的单元时,**先看 `Condition…` 是不是被满足了**,
      不要先假定环境里没有 TPM。
    * **首启 credential 会被注入**:`qemu.py` 的 `finalize_credentials()` 会往 guest 传
      `firstboot.timezone=<宿主时区>` 与 `firstboot.locale=C.UTF-8`。
      所以 VM 里 `timedatectl` 显示宿主时区**不代表镜像里的 `Timezone=` 生效了** ——
      判据是 `/etc/localtime` 指向哪、`/etc/locale.conf` 里写了什么(决策 D22,
      `mkosi.finalize` 会回读断言)。

---

41. **`WantedBy=boot-complete.target` 的单元在"非计数启动"上永远不会跑 —— 而回滚恰恰发生在非计数启动上(2026-09,准备 OTA 演练时发现)。**
    现象:VM 里 `keel-confirm.service` 明明被启用了(构建日志里有
    `boot-complete.target.wants/keel-confirm.service` 那条 symlink),却**从来没有运行过**——
    `os-status` 的「上次启动结果」永远是"无记录",journal 里找不到它的任何输出,
    启动日志里也从来**没有** `Reached target boot-complete.target`(只有
    `first-boot-complete.target`,那是 systemd-firstboot 的,完全另一回事)。
    原因(读 systemd 的单元文件与 generator 得到的):
    * `boot-complete.target` 是个**被动目标**:没有任何 unit 默认拉它;
    * 只有 `systemd-bless-boot-generator` 在"boot counting 生效"时才会把
      `systemd-bless-boot.service` 放进 `boot-complete.target.wants/`,而那个 service
      `Requires=boot-complete.target` ⇒ **只有计数启动**才会把目标带进事务;
    * 更新失败自动回滚后,引导器启动的是**旧槽**:旧槽条目早就被 bless 成 `keel-a.efi`
      (名字里没有 `+tries` 计数器)⇒ 那次启动不是"计数启动" ⇒ 目标到不了 ⇒ `keel-confirm` 不跑
      ⇒ `state` 里的 pending 永远挂着、坏 UKI 不会被挪成 `.failed`、
      `LoaderEntryPreferred` 也不会被改回旧槽的正式名字。**机器能用,但状态是错的** ——
      这正是"自动回滚"这条承诺里最容易漏掉的一半。
    ⇒ 修法:`keel-confirm.service` 的 `[Install]` 同时写
      `WantedBy=boot-complete.target multi-user.target`。它本身
      `Requires=boot-complete.target`,所以被 multi-user 拉起时会把目标一起带进事务;
      `After=systemd-bless-boot.service` 保持不变 ⇒ 计数启动时我们仍然等 bless 改完名。
      `tools/verify.sh` 有断言(两个 `WantedBy` 都必须在)。
    **教训**:凡是"挂在某个 target 上"的单元,先问一句**谁拉这个 target**。
    systemd 里 `boot-complete.target` / `first-boot-complete.target` 这类**被动目标**不会自己出现,
    它们只被特定的 generator/单元按条件拉进事务 —— 条件不成立时,你的单元就**静默不执行**
    (和坑 #36 的"每步都成功"、坑 #29 的"退出码 0"是同一个形状:**没跑 ≠ 跑成功了**)。

42. **`systemd-growfs` 对"自己 `mount(8)` 挂的"挂载点会失败 —— 现象是"分区扩了、文件系统没扩"(2026-09,用 40G 假盘复现)。**
    现象(把 15 GB 的安装镜像 `truncate -s 40G` 之后再启动,首启本该把 `data` 扩到整盘):
    ```
    NAME   SIZE TYPE FSTYPE MOUNTPOINTS
    vdb     40G disk
    ├─vdb1   1G part vfat   /boot
    ├─vdb2   6G part ext4   /
    ├─vdb3   6G part ext4
    └─vdb4  27G part ext4   /nix /home /data     ← 分区**扩到了** 27G
    data 分区 = /dev/vdb4,大小 = 28989960192 字节
    firstboot: keel: 注意:data 文件系统没能扩容(镜像/实验环境里通常因为已经没有剩余空间)
    ```
    而 `df -h /data` 仍然是 **974 MiB** ⇒ 文件系统根本没扩。也就是说
    **repart 那一步是对的**(分区长到了 27G),失败的是 `systemd-growfs /data`。
    原因(把错误打出来之后一眼就看到了,**和一开始的推断不一样**):
    ```
    keel: systemd-growfs /data 失败:/usr/lib/keel/firstboot: line 92: systemd-growfs: command not found
    keel: 改用 resize2fs 直接扩 /data(ext4 在线扩容;坑 #42)
    keel: resize2fs 成功:… The filesystem on /dev/vdb4 is now 7077627 (4k) blocks long.
    keel: data 尺寸:分区 28989960192 字节 / 文件系统 28495839232 字节
    ```
    也就是:**Debian 的 systemd 包根本不带 `systemd-growfs` 这个二进制**(我们也没显式装它),
    旧写法把 `command not found` 和别的失败一起被 `>/dev/null 2>&1` 吞掉了。
    (一开始我按 systemd 的文档猜是"它要求挂载点背后有 `.mount` 单元" —— 那条也可能是真的,
    但**不是这里的实际原因**;这就是为什么要把工具的输出原样留下来。)
    ⇒ 修法(`keel-firstboot` 与 `os-rescue --grow-data` 都改):
    1. `command -v systemd-growfs` 有就先试它,并**把它的错误原样打进日志**;
    2. 然后**总是**跑 `resize2fs <data 设备>`(ext4 在线扩容,挂载状态下直接扩;
       已经到顶时返回 0)—— 它才是真正干活的那一步,`e2fsprogs` 本来就在包清单里;
    3. 每次把"分区字节数 / 文件系统字节数"都打出来;**但不要要求两者相等** ——
       ext4 的元数据/保留块让 `df` 看到的 Size 天然比设备小 1~2%(实测 471 MiB / 27 GiB),
       所以只在"小于 5% 以上"时才告警(第一版按相等写,自己误报了一次)。
    **教训**:① 一个"看一眼就知道结果"的动作(扩了多少)必须把**数字**打出来,
    别只打"成功/失败";② 吞掉工具的输出(`>/dev/null 2>&1`)等于扔掉唯一的线索 ——
    live 镜像里那句"没能扩容"曾经被当成"实验环境的预期噪音"蒙混过关,直到有人把盘放大
    才暴露出来(这正是"退出码 0 / 日志说成功 ≠ 事情做成了"的又一个变体,见坑 #29/#36)。

43. **`bootctl set-preferred` 在 Debian 的 systemd 257 里**根本不存在** —— 槽切换那一步从写下来就没生效过(2026-09 演练实测)。**
    现象(OTA 演练 p0 阶段的 `os-update stage`,第一次真的走到"切槽"这一步):
    ```
    keel: 根分区写入完成
    keel: UKI 已写入 /boot/EFI/Linux/keel-b+3.efi(名字里的 +3 是 boot counting 的 tries-left)
    Unknown command verb 'set-preferred'.
    keel: 错误:bootctl set-preferred keel-b+3.efi 失败:引导器不接受这个条目……
    ```
    根因:`set-preferred` 是 systemd **后来**才加的动词(语义 = 感知 boot assessment 的
    `set-default`,会跳过 tries-left 归零的条目;我本地 systemd 261 的 man 与二进制里都有)。
    Debian trixie 带的是 systemd **257**,它不认识这个动词 ⇒
    `docs/architecture.md` §5.3 ⑤ 那条"槽切换"从来没成功过,
    而因为 `os-update stage` 是**新增**功能(以前从没跑过),这个错误一直没机会暴露。
    (同一次演练里 `systemd-bless-boot.service` 倒是跑起来了 —— 因为候选条目名带 `+3`,
    计数生效,generator 把 bless 拉进了事务;也就是说"起新槽"实际是靠**文件名+one-shot**
    的自动选择完成的,不是靠我们设的 preferred。)
    ⇒ 修法(`lib.sh` 里收敛成两个 helper,调用点全部改用它们):
    * 候选槽 = `bootctl set-oneshot <条目>`(257 就有)—— 只试**一次**;
    * 已确认的槽 = `bootctl set-default <条目>` —— 持久默认;
    * `keel-confirm` 启动成功后用 `set-default` 把新槽固化,回滚时也是 `set-default`。
    **代价要写清楚**:原文档承诺的"连续三次到不了 boot-complete 才回退"在 257 上做不到,
    现在是"试一次就回退"(one-shot 在引导时就被引导器消费掉)。条目名里的 `+3`
    仍然有用:它让 bless-boot 参与进来,成功时把条目改名成 good。
    等基底 systemd 提供 `set-preferred` 再把三次的语义换回来(已记 `docs/roadmap.md`)。
    **教训**:① 文档里"我们用 X 做 Y"的每一句都要有一次**真的执行过**的记录 ——
    这一条(以及坑 #41 的 target、坑 #42 的 growfs)都属于同一类:
    **代码写对了、逻辑也自洽,但那个 API 在你用的版本里不存在**;
    ② 报错信息要**原样留着**(`Unknown command verb` 一眼就能定位),别急着包装成
    "引导器不接受这个条目"这种听起来像硬件问题的解释。

44. **ESP 里那份 UKI 的名字由 mkosi 的 `UnifiedKernelImageFormat` 决定,默认是 `&e-&k` —— 和"槽名"没有关系(2026-09 演练实测)。**
    现象(演练 p1 更新成功、`os-update rollback` 却什么都没做,p2 还停在槽 b):
    ```
    keel-ota-drill[p1]: 判定:**更新成功** —— 当前槽 b、last_result=success
    keel-ota-drill[p1]: ========== os-update rollback(手动回滚到旧槽)==========
    keel-ota-drill[p2]: 判定:当前槽=b,版本=2026.09.25.0703,last_result=failed
    ```
    而 p0 的快照里,`bootctl list` 与 `ls /boot/EFI/Linux` 显示安装镜像里那份 UKI 其实是:
    ```
    id: keel-6.12.107+deb13-amd64.efi   (selected)
    source: /boot/EFI/Linux/keel-6.12.107+deb13-amd64.efi
    ```
    也就是说:mkosi 按 `&e-&k`(entry token + 内核版本)给 UKI 命名,
    **安装镜像里那份叫 `keel-<内核版本>.efi`,不是 `keel-a.efi`**。而
    `os-update` / `os-rescue` / `keel-confirm` 全都按"槽名"找条目
    (`keel_uki_path` = `$KEEL_UKI_DIR/keel-<槽>.efi`,架构文档 §5.3 也是这么写的)⇒
    在一台**刚装好**的机器上:
    * `os-update rollback` / `switch a` 会拒绝执行(找不到 `keel-a.efi`);
    * `keel-confirm` 的 `set-default` 那一步会被 `if [ -e ... ]` 静默跳过(默认条目没人设)。
    (槽 b 那边一直没问题,因为它的条目名是 **os-update 自己写 UKI 时起的** ——
    我们复制产物到 ESP 时才决定叫 `keel-b+3.efi`,所以"更新"路径反而是对的,
    只有"安装镜像自带的那个槽"名字对不上。)
    ⇒ 修法:
    1. `mkosi.profiles/install.conf` 里钉死 `UnifiedKernelImageFormat=keel-a`
       —— 安装镜像的那份 UKI **就是槽 a**(cmdline 里写死 `root=PARTLABEL=root-a`);
    2. `keel-confirm` 加兜底:如果 `keel-<槽>.efi` 不存在,就问引导器
       "这次启动用的是哪个条目"(`bootctl list` 里标着 `(selected)` 的那个)并把它设成默认,
       同时把用过的名字记进 `state`(`entry_<槽>=…`),下次不用再猜;
    3. `os-update switch/rollback` 的报错里明确提示"条目名不一定等于槽名,
       先 `bootctl list` 看实际名字再 `set-default`"。
    **教训**:① "名字"是接口。凡是"按名字去磁盘上找东西"的逻辑,都要在**第一次真的执行**
    时验证那个名字确实存在(我们的 `keel_uki_path` 用了几年,直到演练才第一次真被调用);
    ② 同一个东西有两个命名者(构建期 mkosi 一份、运行期 os-update 一份)时,
    必须显式对齐 —— 否则一半路径对、一半路径错,而错的那半恰好只有"装机后第一次"才会走到。

45. **`bootctl` 认的"条目 ID"= 文件名**去掉**计数后缀 —— 传错时 one-shot 被静默忽略,还会被误判成"更新失败已回滚"(2026-09 演练实测)。**
    现象(演练第 4 轮,和上一轮只差"安装镜像的 UKI 改名"这一处):p1 期待"跑在槽 b、更新成功",
    实际却是:
    ```
    keel-ota-drill[p1]: 当前槽=a 版本=2000.01.01.0001
    keel-ota-drill[p1]:     keel-a.efi  <== 当前槽的正式条目
    keel-ota-drill[p1]:     keel-b+3.efi.failed
    keel-confirm[669]: keel: 检测到更新失败并已回滚:现在运行在槽 a;失败的槽是 b(版本 2026.09.0713)
    ```
    而控制台里那次启动的 cmdline 显示它**从头到尾起的就是 `root=PARTLABEL=root-a`** ——
    新槽根本没被尝试过,这是一次**假回滚**。
    原因:`os-update stage` 写进 ESP 的文件名是 `keel-b+3.efi`(带计数后缀,引导器靠它计数),
    但 `bootctl set-oneshot` 需要的是**条目 ID**:`bootctl list` 显示得明明白白 ——
    ```
    id: keel-b.efi
    source: /boot//EFI/Linux/keel-b+3.efi
    ```
    也就是说 ID 是"文件名去掉 `+tries[-done]` 后缀"。传 `keel-b+3.efi` 时引导器找不到匹配条目,
    **那次 one-shot 被静默丢掉**(不报错),于是回到持久默认(= 上一轮 keel-confirm 刚设好的
    `keel-a.efi`)⇒ 起的是旧槽,而 keel-confirm 看到"跑在旧槽 + pending 是新槽",很合理地
    推断"新槽失败、已自动回滚",把好端端的新 UKI 改名成 `.failed`。
    (上一轮之所以"看起来成功",是因为那轮安装镜像里没有 `keel-a.efi`,keel-confirm 的
    set-default 被跳过、根本没有持久默认,引导器于是用**它自己的排序**挑中了候选条目 ——
    偶然对了。也就是说:一次成功掩盖了一个错误。)
    ⇒ 修法:`os-update stage` 里把两个名字分开 ——
    * **文件名** `keel-<目标>+3.efi`(写盘、计数用);
    * **条目 ID** `keel-<目标>.efi`(给 `bootctl set-oneshot`/`list` 用)。
    `keel-confirm` 的兜底本来就是从 `bootctl list` 取 `id:`,所以那边是对的。
    **教训**:① 同一个对象有两个标识符时(文件名 vs 条目 ID),**两个都要在真机上验证一次** ——
    "文件确实写进去了"不代表"引导器能按这个名字找到它";
    ② **静默无效**比报错危险得多:one-shot 没生效不会报错,表现却是"新版本自己失败了",
    于是我们的代码很自信地写下一个**错误的结论**(把好 UKI 标成 `.failed`)。
    凡是"设一个变量,期望别人以后按它行事"的地方,事后都要回读确认(这里就是 `bootctl list`)。

46. **"自动回滚"的前提是机器还会再启动 —— 没有 `panic=-1`,panic 就是一次停机,不是一次失败(2026-09,设计演练时想清楚并拍板)。**
    回退链条是:`os-update stage` 把候选槽设成 one-shot ⇒ 重启时引导器**用完即弃**那个变量 ⇒
    候选槽那次启动失败(panic / initrd 失败 / PID1 起不来)⇒ **下一次启动**回到持久默认(旧槽)⇒
    旧槽上的 `keel-confirm` 发现"跑在旧槽 + pending 是新槽",记 `last_result=failed`、
    把坏 UKI 改名成 `.failed`。
    这条链里唯一没有代码、也没有开关的一环是"**下一次启动真的会发生**":内核 panic 的默认行为是
    **停下来等人**(`panic=0` 永不重启),于是"新版本起不来"变成"机器黑屏等人按电源键" ——
    对一个装在笔记本上、用户不在跟前的系统来说,这和"变砖"差不多。
    ⇒ 修法:`KernelCommandLine=` 里加 `panic=-1`(负值 = 立即重启;决策 D24)。
    **代价与边界**:panic 现场一闪而过 ⇒ 定位改用三样东西 —— journal 里那次启动的记录、
    `os-status` 的 `last_result=failed`、ESP 上 `keel-<槽>+N.efi.failed`。
    **教训**:凡是"自动 X"的设计,都要把链条里**不在我们代码里的那一环**单独列出来问一句
    "它真的会自动发生吗"(这里:内核的 panic 行为;坑 #41 的 `boot-complete.target`、
    坑 #43 的 `set-preferred`、坑 #45 的 one-shot 都是同一个形状)。

47. **`debugfs` 的命令**永远**返回 0 —— 判断文件在不在只能看输出文本(2026-09,做坏载荷时踩到,而且是我自己写的检查反过来把好结果判成坏了)。**
    背景:"坏载荷"的制作方式是用 `debugfs` 删掉目标槽根镜像里的 PID1 与 init 兜底。
    删完之后我加了一步"回读确认"(这是对的 —— 坑 #29/#36/#42 的教训),
    但写法是:
    ```bash
    if debugfs -R "stat /usr/lib/systemd/systemd" "$IMG" >/dev/null 2>&1; then
        echo "错误:还在" >&2; exit 1        # ← 误报
    fi
    ```
    实测(`debugfs 1.47.2`):
    ```
    存在的文件   stat → exit=0
    不存在的文件 stat → exit=0,stdout 里是 "/no/such/file: File not found by ext2_lookup"
    ```
    ⇒ **删除其实成功了**,是我的检查把结果判成了失败,整轮演练在第 6/7 步就退出(还没起 VM)。
    ⇒ 修法:判据改成输出文本 `debugfs -R "stat $target" … 2>&1 | grep -q 'File not found'`;
    失败时把 `stat` 的输出原样打出来(别再 `>/dev/null`)。
    **教训**:① "退出码 0 ≠ 事情做成了"(坑 #29)这条**对检查脚本自己同样适用** ——
    写回读检查时,要先确认**判据本身**是可靠的(这里 `stat` 的退出码根本没有区分度);
    ② 一个可靠的检查必须"正反两面都试过":能用不存在的路径试出"该报错时报不报错",
    才算验证过这个检查。

48. **`/data` 的 schema 迁移:文档写了、`migrate=` 字段留了,但**执行器根本不存在**(2026-09 查证)。**
    现象:查"迁移到底做了什么"时发现 —— `os-update` 里**一行迁移代码都没有**,
    连 `migrate=` 这个字段都没人读;`tools/build.sh` 只是往 manifest 里写一行空的 `migrate=`。
    而文档(`docs/update.md` §4「最重要的一节」、§2 的 stage 步骤表、`architecture.md` §5.3 ②)
    把它写成了既成事实:"由旧系统在 stage 阶段按 manifest 声明执行,成功后 bump schema-version"。
    更糟的是**语义自相矛盾**:`fetch` 那句"manifest 的 schema > 本机 ⇒ 拒绝安装"与
    "由旧系统执行迁移"是冲突的 —— 如果旧系统连装都不肯装,迁移永远没有机会发生。
    ⇒ v1 的处置(不新造机制,先把话说准 + 加一道守门):
    1. `os-update fetch` 见到 `migrate=` 非空 ⇒ **拒绝**该载荷,并说清"v1 没有迁移执行器";
       这比"假装迁移过、装上新版本,等回滚时旧系统读不懂 /data"安全得多(后者会静默毁数据);
    2. 文档全部改成"v1 布局冻结在 schema 1;迁移是 v2 的工作",并把上面那处语义矛盾写进 roadmap;
    3. 演练里加一项:造一个 `migrate=mkdir:/data/keel/migtest:0755` 的载荷,
       验证它**确实被拒绝**(而不是被静默接受)。
    **教训**:① "文档里写着"不等于"代码里有" —— 尤其是**负面能力**(拒绝、失败、清理)最容易被漏;
    ② 声明式迁移这种"安全关键但平时用不到"的机制,最少也要有一个**守门**:
    要么能执行,要么明确拒绝,不能装作没看见。

49. **一份 OTA 载荷 13 GiB,而实验盘的 `/data` 只有 27 GiB ⇒ 第二份下不下来;更坑的是 `fetch` 失败后 `stage` 会静默装回旧载荷(2026-09,破坏性演练里踩到)。**
    现象(演练 p2 想下"坏载荷",结果 p3 判定出一台**好端端跑在槽 b** 的机器):
    ```
    keel: 警告:/data 可用空间只有 12383 MiB,而这次要下约 13 GiB —— 下完可能就满了;建议先 os-update gc
    keel: 取 slot-b.root.raw
    keel: 错误:下载失败:http://10.0.2.2:8000/bad/slot-b.root.raw     ← 真正的原因是 ENOSPC
    …
    keel: 当前槽 a → 目标槽 b(版本 2026.09.25.0747)                  ← 没有 .bad!装的是**旧**载荷
    ```
    两个独立的问题:
    ① **空间**:`/data` 27 GiB,里面已经躺着上一份 13 GiB 的载荷 ⇒ 第二份写不下。
       `fetch` 的空间检查阈值是"低于 2 GiB 才拒绝、低于 16 GiB 只警告",12.4 GiB 只触发警告,
       然后 curl 撞 ENOSPC —— 而**错误信息只说"下载失败"**,看起来像网络问题。
       (**2026-09-26 现状**:载荷降到 1.1 GiB 后,阈值改成 **低于 2 GiB 拒绝 / 低于 4 GiB 警告**;
       警告线压到 4 GiB 正是为了不再出现本文这种"只警告、然后 ENOSPC"。)
    ② **`stage` 装哪一版**:它取 `/data/ota/` 下**版本号最大**的那份已下载载荷。
       `fetch` 失败时 `stage` 不会报错,而是**静默装回更旧的那一份** —— 一次"我要装坏载荷"
       的尝试,结果变成"把好载荷又装了一遍"。演练里这个错误被"p3 判定与预期不符"抓住,
       但在真机上很容易被误读成"更新成功了"。
    ⇒ 修法:
    * `os-update fetch`:下载失败且 `/data` 剩余 < 3 GiB 时,错误信息直接点出"大概是空间不够" +
      给出 `os-update gc` / 删旧版本的下一步(别再让人猜网络);
    * `docs/update.md` §2 新增两行:"stage 装的是哪一版"(版本号最大者)与"空间账"(一份 13 GiB);
    * 演练 p2:下坏载荷之前先 `rm -rf /data/ota/*` 腾空间,并**检查 fetch 的退出码**
      (失败就停下、不再 stage),stage 之后核对装进去的版本号必须是 `….bad`。
    **教训**:① "警告但继续"的检查等于没有检查 —— 要么在能判断的地方就拒绝,要么把失败信息
    写到能一眼看出根因;② `fetch` 与 `stage` 之间**没有隐式契约**:`stage` 只看"最大版本号",
    所以任何"我 fetch 了 X 然后 stage"的脚本都必须自己确认 stage 装的是 X(演练现在会核对)。

50. **"起不来"有两种:panic 会被 `panic=-1` 重启,**挂住**不会 —— 坏槽实测是**永久冻结**(2026-09 演练)。**
    现象(把候选槽的根镜像做成"没有可用 init"之后再启动,期待 panic ⇒ 自动回退):
    ```
    [  OK  ] Reached target initrd-switch-root.target - Switch Root.
             Starting initrd-switch-root.service - Switch Root...
    [!!!!!!] Switch root target contains no usable init.
    [  107.224858] systemd-journald[244]: Failed to send WATCHDOG=1 notification message: Connection refused
    [  217.224736] systemd-journald[244]: Failed to send WATCHDOG=1 notification message: Transport endpoint is not connected
    [  287.224712] …(每 70 秒一条,永不停止)
    ```
    也就是说:initrd 里的 systemd 发现新根"没有可用的 init"之后**故意冻结**(让人能看现场),
    **不 panic、不退出、不重启** ⇒ `panic=-1`(决策 D24)完全帮不上忙,
    持久默认(旧槽)永远不会被用到,机器就停在黑屏 —— 对一台放在桌上的笔记本来说等于变砖。
    ⇒ 修法(决策 D25):启用**运行时看门狗** —— `RuntimeWatchdogSec=60`,
    PID1 每 30 秒喂一次 `/dev/watchdog`;PID1 冻住 ⇒ 到点硬件复位 ⇒ 下次启动走旧槽 ⇒
    `keel-confirm` 判定"更新失败已回滚"。
    **实测只说对了一半**:主系统的看门狗确实生效(`RuntimeWatchdogUSec=1min`、
    `/dev/watchdog0` 在)⇒ **用户态**的挂死能恢复;但**这次 initrd 冻结并没有被复位**
    —— 机器挂住 650+ 秒,最后只能人工终止。配置是不是真进了 initrd 还没查实
    (我们那个"抽 `.initrd` 查文件名"的检查自己也可能误报,同一个坑 #47 的形状)。
    ⇒ v1 的口径:**不承诺覆盖 initrd 阶段的冻结**,已记 `docs/roadmap.md` 3.0。

    **补记(同一天的第三次演练,第三种失败)**:把候选槽根里的 `/etc/systemd/system/default.target`
    换成**悬空符号链接**之后,根里的 systemd 起来了、PID1 健康、还在正常喂看门狗,但永远到不了
    默认目标 ⇒ 进 emergency 并在控制台等人按键:
    ```
    system logs, "systemctl reboot" to reboot, or "exit" to continue bootup.
    Press Enter for system maintenance
    (or press Control-D to continue):
    ```
    ⇒ `panic=-1` 不会触发(没有 panic);看门狗也**不会**复位(PID1 是健康的,喂狗正常 ——
    这是看门狗的正确行为,不是 bug)。机器就这么停着,回退永远不会发生。
    而这一类(进 emergency/rescue)恰恰是最常见的软失败。
    ⇒ 兜底:`keel-boot-failed-reboot.service`(决策 D26)—— `WantedBy=emergency.target rescue.target`,
    发现"这次启动没到过 boot-complete"就提示 + 等 60 秒 + 重启;
    想手工排查的人按提示 `systemctl stop keel-boot-failed-reboot` 即可取消。
    **教训**:"失败"要按**兜底机制**分类,而不是按"看起来是不是坏了"分类 ——
    panic / 冻住 / 停在提示符,三者需要的机制完全不同(重启指令、看门狗、超时看门狗);
    把这三类列出来之后,"自动回滚"这句话才站得住。
    **教训**:① 说"失败会自动回滚"之前,先把"失败"**分类** —— 能自己重启的(panic)
    和不能的(挂住/冻结/等设备),它们的兜底机制完全不同;
    ② "没有任何代码运行"的故障只能靠**外部**(看门狗/人)处理,
    这类机制必须显式设计出来并演练,不能默认它不存在;
    ③ 改这类"兜底"配置时注意**它跑在哪个 PID1 上**:initrd 的 PID1 与主系统的 PID1
    读的是**两份不同的 /etc**。

51. **便宜的检查要放在"动大钱"之前 —— 迁移/schema 校验写在下载之后,结果 13 GiB 下完(或撞 ENOSPC)才轮到拒绝(2026-09 演练实测)。**
    现象:演练里造了一个"声明了 /data 迁移"的载荷(v1 明确不支持,`fetch` 应该**直接拒绝**)。
    期望是一行错误信息,实际日志是:
    ```
    keel: 从 http://10.0.2.2:8000/mig 取 manifest
    keel: 取 slot-a.root.raw        ← 开始下 6 GiB
    keel: 取 slot-a.uki.efi
    keel: 取 slot-b.root.raw
    curl: (23) Failure writing output to destination …      ← /data 先满了
    ```
    也就是说"拒绝带迁移的载荷"这条守门**根本没走到**:它被放在 sha256/签名/schema 那一串
    检查里,而那一串都在**下载之后**。演习里更巧的是空间先不够,于是报的是"下载失败",
    看起来像网络问题(坑 #49 的同一个形状)。
    ⇒ 修法:把"迁移"与"schema 兼容性"两项挪到**读完 manifest、还没下载任何产物**的位置 ——
    它们只需要 manifest 里的字段。顺带把这条写成规矩:
    **任何"只看元数据就能判定"的拒绝,都要排在"下载/写盘"之前**。
    `tools/verify.sh` 有断言(迁移检查的行号必须小于下载循环的行号)。
    (同一次演练里 p3 的结论是**自动回滚成立**:坏槽进 emergency → `keel-boot-failed-reboot`
    提示 + 60 秒 + 重启 → 回到旧槽、`last_result=failed`、坏 UKI 归入 `.failed` —— 决策 D26 验证通过。)

52. **体检脚本自己会说谎:`grep '^panic=-1' /proc/cmdline` 永远匹配不上 —— 一台好机器被判成硬失败(2026-09,项目所有者第一次在 libvirt 装好的系统里跑 `sudo ~/keel-check`)。**
    现象:装好、能启动、能更新、能回滚的机器,体检报告最后一行是
    ```
    ✗ cmdline 里没有 panic=-1 ⇒ panic 会停在黑屏
    汇总: 通过 49,失败 1,警告 3,跳过 1
    ```
    而这台机器的 UKI 里**确实有** `panic=-1`(同一个 commit 的产物,`grep -a -o 'panic=[^ ]*' keel-a.efi`
    能直接看到)。判据本身写错了:
    ```bash
    grep -qs '^panic=-1' /proc/cmdline      # ← 错的
    ```
    **`/proc/cmdline` 是一整行**:`ro amd_iommu=on … panic=-1 console=tty0 …`。
    `^` 锚的是**整行**开头,所以除了第一个 token,别的永远匹配不上 —— 这条检查从写下的
    那一刻起就注定失败,只是**从来没有人在"运行时"跑过它**(构建产物那边我们是用
    `grep -a -o` 直接抽字符串验的,那条路径没问题)。去掉 `^` 也不够:子串匹配会让
    `foo=root=PARTLABEL=root-a` 冒充 `root=PARTLABEL=root-a`。
    ⇒ 修法:`lib.sh` 里加 `keel_cmdline_has <token> [文件]`(按空白切 token + `grep -qx`),
    所有 cmdline 判据一律走它;`tools/verify.sh` 里补**功能测试**(在一个假 cmdline 上验证
    "非首个 token 命中 / `panic=0` 与 `nopanic=-1` 不误命中")+ 静态断言(禁止再出现
    `grep '^…' /proc/cmdline` 这种形状)。
    **教训**:
    ① 同一个事实有两条读取路径时(**构建产物** vs **运行时**),两条都要有证据 ——
       我们验了产物里的字符串,却没验"运行时读它的那段代码";
    ② **假阳性比假阴性更坏**:体检脚本一旦冤枉好机器,人就开始不信任它,下次真出问题会被
       当成"又是脚本的毛病"。所以体检脚本的每一条判据都要能被测试,报告里"没有结论"
       要和"结论是坏"分开(看门人还没到点、虚拟机里没 vTPM 都不是故障);
    ③ 这条和坑 #41/#47/#50 是**同一个形状**:判据、退出码、兜底机制的**证据来源**都要亲自看过,
       别拿"代码写了"当成"事情发生了"。

53. **没有 `authorized_keys` 的构建会在写 `keel-check` 转发文件那步失败 —— 因为那个目录是"可选步骤"建的(2026-09,被"让判据说真话"的那次改动顺带抓出来)。**
    现象:`mkosi.finalize` 里
    ```bash
    install -d -m 0700 "$SKEL/home/admin/.ssh"      # ← 只在有 authorized_keys 时才跑
    …
    cat >"$SKEL/home/admin/keel-check" <<'WRAPPER'  # ← 无条件写这里
    ```
    仓库根目录的 `authorized_keys` 被 `.gitignore` 排除(它是**每台构建机自己的**首启公钥,
    见 docs/install.md §2.5)⇒ 一份干净的克隆(或任何没放过公钥的构建机)上,
    `$SKEL/home/admin` 根本不存在,`cat >` 报 `No such file or directory`,`set -e` 直接让构建失败。
    我们一直没撞上,只是因为**我们自己的仓库根目录里恰好放着公钥**(已装机的机器都这么来的)。
    ⇒ 修法:在写任何东西之前先 `install -d -m 0755 "$SKEL/home/admin"`(属主后面按镜像里的
    admin uid/gid 重设)。
    **教训**:① "可选步骤里创建的目录,不能当成后续无条件步骤的前提" —— 顺序和依赖要显式;
    ② 这条和坑 #47/#51/#52 是同一条:**检查/构建能不能跑通,不能只看"我这台机器上过不过"**,
    要有一棵树把可选输入**去掉**再跑一遍。现在 `tools/verify.sh` 的第二棵假镜像树就是这样:
    它故意**不给** `authorized_keys`,同时把 hostname 写错 —— 只有"转发文件写成功 + hostname
    断言真的拦住"两件事同时成立,那条检查才会绿。

54. **NixOS 宿主上**没有** `/bin/bash`** —— 脚本写死 `#!/bin/bash` 就等于"直接执行必失败"(2026-09,在项目所有者机器上实测)。**
    现象:`sudo tools/build-container.sh -p keel-tmp` 报
    ```
    sudo: unable to execute tools/build-container.sh: No such file or directory
    ```
    文件明明在、`ls -l` 也明明有 x 位 —— 这是 `execve` 找不到**解释器**时的报错(不是找不到脚本)。
    根因:NixOS 只提供 `/bin/sh`(`environment.binsh`),**不提供 `/bin/bash`**:
    ```
    $ ls -l /bin/bash
    ls: cannot access '/bin/bash': No such file or directory
    $ ./tools/build-container.sh
    bash: ./tools/build-container.sh: /bin/bash: bad interpreter: No such file or directory
    ```
    `bash tools/build-container.sh` 却能跑 —— 因为那条路把解释器换成了 PATH 里的 bash,
    所以这个坑**只在"直接执行"时出现**,而 `AGENTS.md`/文档里的命令恰好都是直接执行。
    ⇒ 修法:全仓库脚本的 shebang 一律改成 `#!/usr/bin/env bash`(NixOS 上有 `/usr/bin/env`);
    `tools/verify.sh` 加断言禁止再出现 `#!/bin/bash`。
    **教训**:① 我们把"宿主是 NixOS"写进了文档,却一直用"Debian 的常识"写 shebang ——
    **目标环境的一句话,要能落到具体的一行代码上**;
    ② 报错信息("No such file or directory")指向的是**解释器**,不是文件本身 ——
    看到"文件在、权限也对"就先怀疑 shebang / 动态链接器;
    ③ 这条和坑 #15(`ToolsTree=default`,宿主只需要 mkosi + bubblewrap)是同一类:
    宿主越"非主流",越要把能被宿主直接执行的东西(脚本、`mkosi.version`)写成人畜无害的形式。

55. **"找不到固件"被报成 `unbound variable`:两处判据同时说谎(2026-09,第一次在 libvirt 上跑装机演练时)。**
    现象:`tools/libvirt-test.sh prepare` 在项目所有者的机器上直接崩:
    ```
    keel-libvirt: 安装镜像:dist/keel-2026.09.25.1329/keel.raw
    tools/libvirt-test.sh: line 141: ovmf[0]: unbound variable
    ```
    两个独立的问题叠在一起:
    ① **固件命名**:脚本只找 `OVMF_CODE*.fd`(Debian/发行版常见命名),而 NixOS 的
       `/run/libvirt/nix-ovmf/` 里是 QEMU 那套 `edk2-x86_64-code.fd` + `edk2-i386-vars.fd`
       (virt-manager 生成的域 XML 也正是这套)⇒ 那台机器上**必然**找不到;
    ② **死代码判据**:`readarray -t ovmf < <(find_ovmf) || die "找不到 OVMF 固件"` ——
       进程替换 `< <(...)` 的退出码**不会**传给 `readarray`,所以 `|| die` 永远不执行,
       真正报出来的是 `set -u` 下的 `unbound variable`。人看到的是"脚本有 bug",
       而不是"这台机器没有那种命名的固件"。
    ⇒ 修法:两套命名都认;把"取固件"抽成 `load_ovmf()` 并**显式检查条数**
    (`[ "${#OVMF[@]}" -ge 2 ] || die …`);`tools/verify.sh` 加两条断言
    (认 edk2 命名 + 不许再出现 `readarray … || die`)。
    **教训**:① 又一次"目标环境的一句话没落到代码上"(坑 #54 是 `/bin/bash`,这条是固件命名);
    ② **`cmd < <(f)` 不传退出码**是个通用陷阱:`mapfile`/`readarray`/`while read` 全一样,
       凡是要知道"子命令成没成",就得自己去检查结果(文件在不在、数组是不是空的);
    ③ 报错信息指向的位置(`ovmf[0]`)不是错误的位置 —— 顺着它修只会把 `set -u` 关掉,
       那等于把判据彻底拆了。

56. **域 XML 里 `os/boot` 与"每设备 boot order"不能混用 —— 现代 libvirt 直接拒绝定义(2026-09,第一次跑 libvirt 演练,连着坑 #55 撞上)。**
    现象:`tools/libvirt-test.sh start` 里 `virsh define` 失败:
    ```
    error: Failed to define domain from mkosi.output/libvirt/keel-test.xml
    error: unsupported configuration: per-device boot elements cannot be used together with os/boot elements
    ```
    我们的 XML 从写下的第一天起就同时有两套启动顺序:`<os><boot dev='hd'/></os>` 和磁盘上的
    `<boot order='1|2'/>`。老 libvirt 容忍这种组合,现在直接拒绝 —— 而脚本**没有检查
    `virsh define` 的退出码**,于是接着往下走,第二句报的是
    `Failed to start domain 'keel-test' which is not defined`,把注意力引到"域不存在"上。
    ⇒ 修法:删掉 `os/boot`,只用 per-device `boot order`(记 boot_target 的那套本来就更精确);
    `virsh define` 加 `|| die`。`tools/verify.sh` 加两条断言。
    **教训**:① 和坑 #54/#55 一模一样的形状:**"写下来"不等于"跑过"** —— 这份 XML 写了很久,
    却是在第一次真的调用它的时候才第一次被 libvirt 解析;
    ② 一条命令失败后**必须立刻停**,否则下一句会用一个更误导的错误盖住真正的原因
    (`define` 被拒 → "域未定义")。

57. **仓库里的权限位会原样进镜像 —— `0600` 的 `/etc/systemd/network/*.network` = 网络静默失效(2026-09,第一次在 libvirt 里跑装机演练时)。**
    现象:libvirt 里的 live 系统**完全没有网络**:串口上没有任何报错,networkd "Started" 了,
    但 `virsh domifstat` 显示 `tx_packets 0` —— guest 一个包都没发出去,自然也没有 DHCP 租约,
    自动化脚本就卡在"等 SSH"上。
    根因:仓库里 `mkosi.extra/etc/systemd/network/20-wired.network` 的权限位是 **0600**,
    mkosi 把它原样拷进镜像 ⇒ **systemd-networkd(以 `systemd-network` 身份运行)读不到自己的配置**,
    于是"没有匹配的 .network" ⇒ 不配置接口 ⇒ 不发 DHCP。串口日志里唯一的线索是 systemd 那句
    ```
    Configuration file /usr/lib/systemd/system/keel-mounts.service is marked world-inaccessible.
    ```
    (**单元文件也是 0600**;systemd 自己是 root,还能读,所以只是警告 —— 它把"网络为什么不通"这个
    真问题藏在了"看起来只是权限风格问题"后面。)
    为什么以前没事:**git 只跟踪可执行位**(100644/100755),根本存不了 `r` 位。
    项目所有者机器上的工作区是 git checkout 出来的(umask 022 ⇒ 0644),一切正常;
    而 2026-09 那次我用 `tar` 把沙箱里的工作区整体同步过去,把沙箱里那套被 umask 弄坏的
    0600/0711 **一起带了过去** ⇒ 下一次构建就产出了一个"没有网"的镜像。
    `git diff` 里完全看不见这个变化(权限位不在 diff 里),`ls -l` 也不会有人天天看。
    ⇒ 修法:① 仓库工作区权限归一到 0644/0755;② `mkosi.postinst` 构建期把
    systemd 单元 / networkd 配置 / motd / sshd drop-in **掰成 0644** 并**回读断言**
    ("其他用户可读"这一位必须在),这样坏 umask 再也产不出没网的镜像;
    ③ `tools/verify.sh` 加断言:`mkosi.extra*/` 里不许有"其他用户不可读"的文件。
    **教训**:① 权限位是镜像内容的一部分,而**版本控制对它几乎无感** —— 这类"只在产物里
    体现的差异"必须有构建期归一化 + 回读断言,不能靠"大家 checkout 时 umask 都对";
    ② 这次是"我自己的同步工具把宿主环境改坏了" —— **跨机器同步工作区时,mode 是要一起想清楚的东西**
    (同理还有属主、sparse 文件、符号链接);
    ③ 排查顺序值得记:串口无报错 → `domifstat` 看 tx=0 → 怀疑 guest 侧没发包 →
    回头看"谁读这个配置、以什么身份读",比在宿主网络栈上瞎找快得多。

58. **两次 `virsh define` 撞名 + 演练脚本里"子 shell 里设的变量传不出来"(2026-09,libvirt 装机演练的同一轮)。**
    两个都是"自己写的自动化脚本"的毛病,但形状不同:
    ① **域 XML 没有 uuid**:`render_xml` 会被调用两次(先 live、再 `--boot target` 换启动顺序),
       不带 `<uuid>` 时 libvirt 认为第二次是"新建同名域",直接拒绝:
       ```
       error: operation failed: domain 'keel-test' already exists with uuid d420e6c6-…
       ```
       ⇒ 修法:第一次生成 UUID 写进 `$WORK/$DOMAIN.uuid`,之后一直复用;`prepare` 重新开始时
       先 `virsh destroy` + `virsh undefine --nvram`(顺带把引用旧盘的僵尸域清掉)。
    ② **`LIVE_IP=$(wait_ssh 900)`**:`wait_ssh` 里既 `echo` 又给全局 `IP` 赋值,而命令替换
       `$( )` 是**子 shell** ⇒ 父 shell 里的 `IP` 仍然是空的。脚本随后用 `$IP` 去 ssh,
       报的是 `Could not resolve hostname :`(注意冒号前是空的)——
       看起来像 DNS 问题,其实是"变量没传出来"。
       ⇒ 修法:`IP=$LIVE_IP` 显式接一下(或者在函数里只回显、不在函数里改全局)。
    **教训**:① 演练脚本本身也是要"被演练"的代码 —— 这一轮里它自己贡献了 4 个坑(#55–#58),
       全都是"写的时候没跑过"的典型;
    ② **`$( )` 里的赋值不会出来**,这是 shell 最容易骗人的地方之一(同类的还有管道
       `cmd | while read` 里的变量);看到"变量莫名其妙是空的",先想这一条;
    ③ 报错信息里的空格也是信息:`Could not resolve hostname :` 那个空位就是"变量是空的"。

59. **装机演练差点把"live 系统"的体检结论当成"装好的系统"的 —— 两块盘都在时,固件按 NVRAM 里的旧条目又启动了 live 盘(2026-09,libvirt 演练)。**
    这一轮里其实有两个独立的坑,合起来会**静默给出错误结论**:
    ① `os-install` 在**没有终端**时拒绝执行("需要交互确认,但标准输入不是终端。确认设备名无误后用
       `--yes` 重跑"),这是它的安全设计,是对的 —— 但自动化脚本必须显式 `--yes`:
       第一次跑 B1 时它就静默失败了(退出码 1),脚本没检查 ⇒ 下面的步骤全部在对着一个**空目标盘**跑。
    ② 更阴的:目标盘装好之后,`start --boot target` 让固件优先启动 vdb,但 **vda(live 盘)还挂在
       机器上**,而固件 NVRAM 里 live 那次的启动项仍在 ⇒ 它**又启动了 live 盘**。
       于是"装机后体检"看到的是一台 live 机器(证据:报告里 `/nix` 绑的是 `/dev/vda4`,
       root 在 vda2),而报告本身**全绿** —— 一份看起来完美、实际上什么都没验证的结论。
    ⇒ 修法(两手都要):① 演练脚本里 `os-install --yes`,并且**检查退出码**;
    ② `render_xml` 在 `--boot target` 时把 vda **整个摘掉** —— 真机上这一步就是"拔掉 U 盘再重启",
       顺带这也是唯一能验证"装好的系统能独立启动"的做法;
    ③ 体检之前先断言**自己在哪台机器上**(`findmnt -no SOURCE /` 必须是 `/dev/vdb2`),
       不满足就让演练失败,而不是继续生成好看的数字。
    **教训**:① 自动化演练最危险的失败不是"报错",而是"**跑错了对象还全绿**" ——
    凡是跨重启的演练,每一步都要重新确认"我现在在哪";
    ② 交互确认这类保护在无人值守场景下会变成"静默不执行",脚本必须**查退出码**;
    ③ 真机流程里那些"顺手做掉的物理动作"(拔 U 盘、改启动顺序)在虚拟化里必须显式建模,
    否则测的就不是同一条路径。

60. **"命令在不在"要用对判据:`systemd-bless-boot` 在 `/usr/lib/systemd/` 下,不在 `PATH` 里(2026-09,演练跑 `os-rescue --mark-bad` 时)。**
    现象:`sudo os-rescue --mark-bad` 直接报
    ```
    keel: 错误:找不到 systemd-bless-boot(systemd-boot 包没装?)
    ```
    而同一台机器上:
    ```
    # ls -l /usr/lib/systemd/systemd-bless-boot
    -rwxr-xr-x 1 root root 31224 … /usr/lib/systemd/systemd-bless-boot
    # grep ExecStart /usr/lib/systemd/system/systemd-bless-boot.service
    ExecStart=/usr/lib/systemd/systemd-bless-boot good
    ```
    二进制在、单元文件按绝对路径调它、boot counting 也确实在工作 —— 只有我们那句
    `command -v systemd-bless-boot`(PATH 查找)是错的。systemd 故意把内部工具放在
    `/usr/lib/systemd/` 下不暴露给 PATH,所以这类判断**必须按绝对路径**。
    ⇒ 修法:先试 `/usr/lib/systemd/systemd-bless-boot`,再退回 `command -v`;
    并且**失败时给出可执行的替代方案**:不是所有启动都有 boot counting(槽一旦被确认,
    就没有 LoaderBootCountPath 了),那种情况下"标记 bad"没有落点,想弃用某个槽应该
    `sudo os-update switch <另一个槽>`(把持久默认指过去)再重启 ——
    原来那句"多半是这次启动没有 boot counting"只说对了一半,用户看完还是不知道该干什么。
    `tools/verify.sh` 加断言:绝对路径必须出现在 `command -v` 之前。
    **教训**:① `command -v` / `which` 只查 PATH —— 判"这个工具在不在"时,先想清楚
    **发行版/上游把它放在哪**(systemd 的内部工具是最常见的例外);
    ② 报错信息要**替用户走完下一步**(这条命令为什么没意义、那该用什么),否则等于把
    "实现细节"丢给用户翻译。

61. **日志根本没落盘:journald 与 journal-flush 都跑在 `keel-mounts` 之前(2026-09,查"控制台日志太吵"时顺带挖出)。**
    起因很小 —— 项目所有者说图形控制台(SPICE)上时不时刷一屏 `audit: type=1100 …`
    (`kauditd_printk_skb: N callbacks suppressed`),串口上没这么多。查下去发现两件事:
    ① 控制台吵,是因为**内核 console_loglevel 是出厂的 7** 而我们的 cmdline 里刻意没有 `quiet`
       (想让串口还能看到启动进度)⇒ 所有 info/notice 都上控制台,包括每条 PAM 认证的 audit 记录。
       ⇒ 修法:`/etc/sysctl.d/10-keel-console.conf` 里 `kernel.printk = 4 4 1 7`。
       实测(装好的系统):`printk=4` 时登录 3 次,控制台 audit 增量 **0**,而 dmesg/journal 里
       同一次登录的 **119 条** audit 记录一条不少;systemd 的 `[ OK ]` 启动进度照旧(它不是 printk)。
    ② 顺手核对 `Storage=persistent` 有没有生效,发现 **`/data/var/log/journal/` 是空的**、
       `journalctl --list-boots` 只有当前这一次启动 —— **日志从来没落过盘**。
       实测时间线:journald 在 **1.7s** 启动、`systemd-journal-flush` 在 **3.0s** "成功"结束,
       而 `keel-mounts`(挂 `/data` + `/etc` overlay)在 **4.4s** 才完成 ⇒
       * journald 启动时 `/var/log/journal` 还不存在 ⇒ 只用易失的 `/run/log/journal`;
       * journal-flush 想搬的时候同样没有目标目录 ⇒ 它什么也没搬、什么也没报;
       * **journald 不会自己回头**:重启它、删掉 `/run/log/journal` 都没用(实测);
         只有在 `/data` 就绪后执行一次 `journalctl --flush`,它才切成
         `System Journal (/var/log/journal/…,max 256M)` 并把已有日志搬过去。
       ⇒ 修法:`keel-mounts.service` 追加 `Before=systemd-sysctl.service systemd-journald.service
       systemd-journal-flush.service`(同类问题里 sysctl 那条也一样:用户写进 overlay upper 的
       drop-in 在启动时根本不生效)。
    **教训**:① 不变量的第 2 条("`/data` 必须在用户空间刚起来时就挂好")**不是只针对符号链接与
    bind mount** —— 凡是"启动早期读 `/etc` / 写 `/var`"的单元都是它的下游,新增这类单元时要
    主动把它排到 `keel-mounts` 之后(现在这份名单:sysusers、tmpfiles、machine-id-commit、
    random-seed、sysctl、journald、journal-flush);
    ② "配置写了"和"配置生效了"是两件事:`Storage=persistent` 写在配置里已经很久了,
    而 `journalctl --list-boots` 只有一行才是事实 —— **日志这类"沉默的失败"要用它的消费端去验**
    (能不能看到上一个启动?那份日志到底在哪个目录?);
    ③ 又一次是"用户报的小毛病"牵出真问题(A/B 起不来那次也是)——小毛病值得顺着查到底。

62. **两套入口各写各的 ⇒ 必然漂移:`build.sh` 静默忽略参数、容器漏传 profile(2026-09,项目所有者要求"善后"时做的一次审计)。**
    背景:keel 有两条构建路径 —— 原生 `tools/build.sh`(FHS 宿主)与适配器 `tools/build-container.sh`
    (NixOS 等)。它们本该是"同一个东西的两个入口",实际却各写各的参数解析,审计出四处漂移:
    * **`build.sh` 完全不解析参数**(`$@` 从没被读过)⇒ `tools/build.sh -p <密码>` 与
      `tools/build.sh --profile desktop` 都被**静默忽略**。最危险的是 `-p`:敲了密码却得到
      "没有密码"的产物,然后装完机登不进去 —— 而且不会有任何提示。
      (AGENTS.md 里还写着 `tools/build.sh --profile desktop`,文档与代码一起说谎。)
    * 容器没有 `--profile`:变体只能靠 `KEEL_EXTRA_PROFILES` 环境变量,而这个变量**没有被 `-e`
      传进容器** ⇒ NixOS 那条路上**根本加不了** profile(desktop / server / test 都不行)。
    * `-- <mkosi 额外参数>` 与 `-h` 只有容器路径有。
    * 演练(`drill`)只有容器有,而编排脚本里写死了 `/work`(容器里的仓库路径)。
    ⇒ 修法(结构性的,不是补丁):
    ① **共用解析器** `tools/lib-build-cli.sh`:两个入口 `source` 同一份,共用选项只定义一次
       (`-p/--password`、`--profile`(可重复)、`--vm`、`--drill`、`--`、`-h`),顺带带一个
       `keel_host_kind()`(读 `/etc/os-release` 判宿主,报错时直接说"该走哪条路");
    ② `build.sh` 补上原生路径缺的能力:`--vm`(构建+起 QEMU)与 `--drill`(与容器共用同一份
       演练编排);演练脚本改用 cwd 定位仓库(容器里 cwd=/work,行为不变);
    ③ 容器把 `KEEL_EXTRA_PROFILES` 一起 `-e` 送进去;
    ④ `tools/verify.sh` 加**一组对等断言**:共用解析器、`build.sh -h` 真能跑并列出全部共用选项、
       `-p` 全链路到 `--root-password=`、profile 透传、演练两条路可用、不许写死 `/work`、
       不许再出现"要用 `sudo bash tools/…`"这种过时话术。改构建入口不跑它就别提交。
    ⑤ AGENTS.md 新增两节:**"宿主适配:先看 /etc/os-release,不要假设宿主是 NixOS"** 与
       **"两条构建路径必须对等(CLI 只写一份)"**(含能力对照表 + 上面这条规则)。
    **教训**:① **同一件事有两个入口时,把"共用的部分"抽出来是唯一可靠的防漂移手段** ——
    靠"记得两边都改"必然失败(这条和文档/代码漂移是同一类:承诺写在一处、实现散在两处);
    ② 静默忽略参数比报错危险得多:`-p` 被忽略不会报错,只会让你在装完机之后发现登不进去;
    ③ 审计要**看代码怎么读参数**,不能只看 `-h` 里写了什么(容器有 `-h`,原生连 `-h` 都没有,
    而文档把两者写得一样)。

63. **空文件系统 + erofs:systemd-repart 拒绝"没有源文件的 erofs",而且"ext4 是内核内建"是个假前提(2026-09,v1.1 erofs 改动)。**
    两件事一起记,因为它们是同一轮里挖出来的:
    **(a) 空 erofs 造不出来。** 把安装侧 `repart/install/20-root-b.conf`(空 B 槽)的
    `Format=ext4` 直接换成 `Format=erofs`,`tools/verify.sh` 立刻红:
    ```
    repart/install/20-root-b.conf:1: Cannot format erofs filesystem without source files, refusing.
    ```
    v1 能写 `Format=ext4` 是因为**空 ext4 合法**;erofs 需要一个源目录,空槽没有 `CopyFiles=`。
    更隐蔽的是**运行时那份定义**:`mkosi.postinst` 按坑 #31 把 `CopyFiles=` 全删掉再装进镜像,
    于是 root-a 的 `Format=erofs` 也会让 `os-install` 建表**直接失败** ——
    而构建期那次 repart 有源文件,照样全绿。
    ⇒ 三处一起改:① 空槽 root-b **不写 Format=**(留未格式化,反而给首次更新一个没有旧签名的干净起点);
    ② `mkosi.postinst` 生成运行时定义时**同时删 `Format=erofs`**;③ `tools/verify.sh` 的运行时
    模拟必须与 postinst **逐字同源**(去 `CopyFiles=` + 去 `Format=erofs`),并断言两边一致 ——
    否则会出现最坏的一种:verify 全绿、真实 `os-install` 建表失败。
    **(b) "ext4 在 Debian 内核里是内建的"是错的。** 决策 D2 从 v1 起就这么写着(`CONFIG_EXT4_FS=m`),
    v1 之所以能启动,是因为 mkosi 的默认 initrd 里带了 `ext4.ko.xz`。实测方法(不用起 VM):
    ```bash
    ukify inspect mkosi.output/keel-slot-a.efi      # 看 .initrd 的大小
    objcopy -O binary --only-section=.initrd keel-slot-a.efi /tmp/i.bin
    # ⚠ .initrd 是**多个 zstd 帧串起来的**(基础 initrd + 模块 initrd),`zstd -dc` 只解第一帧就报错;
    #   要按魔数 28 b5 2f fd 切帧逐个解,再 `cpio -it` 找 .ko
    ```
    结论:同一个 initrd 里**也带 `erofs.ko.xz`** ⇒ "换 erofs 要先改 initrd"这条前置其实是现成的
    (initrd 第二个帧共 4229 个模块)。**教训**:① "内核内建"这类断言要拿 `CONFIG_*` 与产物**实测**核对,
    不能靠"能启动"反推;② 同一个改动要同时检查"构建期路径"和"运行期路径"——
    它们对同一个设置的要求可能**正好相反**(这里就是:构建期必须有 `Format=erofs`,运行期必须没有)。

64. **`build.sh --drill` 重定向到文件时,VM 会把日志**从第 0 字节覆盖**掉 —— 于是"哪一步失败"看不见(2026-09-26,v1.1 扫尾跑 drill 时)。**
    现场:在原生路径上跑 `sudo tools/build.sh --drill -p … > drill.log 2>&1`,drill 退出码 0、
    VM 里的演练也全过;但 `drill.log` **从第 0 字节就是 OVMF/QEMU 的串口输出**,
    `1/7 静态校验`…`6/7 准备坏载荷`这一整段(含坏槽构造的 `已确认:default.target -> …` 回读证据)
    **一个字都不在**。文件末尾的 `=== DRILL EXIT=0 ===` 在,说明重定向本身是对的。
    **根因(2026-09-26 在 mkosi 25.3 的源码里查到)**:`mkosi/qemu.py` 给 QEMU 一个
    "私有的 stdio 副本"时用的是
    ```python
    os.open(f"/proc/self/fd/{sys.stdout.fileno()}", os.O_WRONLY)   # 没有 O_APPEND!
    ```
    打开 `/proc/self/fd/N` 会得到**同一个文件的全新描述符、偏移 0**;没有 `O_APPEND` 就从 0 开始写。
    于是 QEMU 的串口输出把前面几百 KB 的日志**逐字节盖掉**(文件大小取两者的 max,
    所以看起来"只剩 VM 输出")。
    **怎么办**:
    - **要留完整日志就用管道**,别用 `>`:`sudo tools/build.sh --drill -p … 2>&1 | tee -a drill.log`
      —— fd 1 变成管道(没有"偏移"这回事),QEMU 的写入只会追加,`tee` 两边都拿到。
    - 或者把 VM 那段单独收(它本来也有 `mkosi.output/libvirt/console.log` 这类 guest 日志)。
    - **这条坑真正伤人的地方**:drill 失败时你**最需要**的恰恰是"卡在哪一步 / 坏载荷怎么造的",
      而它们正好是被盖掉的那一段 —— 所以才记在这里,别再以为是"drill 没输出"。
    (本次 ①b 的 erofs 坏槽构造因此没能留下 drill 现场的 step 6 输出;补的办法是把那四个函数
    从脚本里按 `^fs_kind()`…`^}` 原样抽出来单独跑一遍 —— 它确实走了 `槽载荷的文件系统:erofs`
    → `解包 erofs` → `重打包 mkfs.erofs` → `回读确认`。) 

65. **"某个键为空"这种判据会被**别的单元先填上** —— 首启的 `running_slot` 就是(2026-09-26,v1.1 ④ 结清 os-install 的 TODO 时)。**
    v1 留的 TODO 是"`keel-confirm` 对**pending 存在但没有 `running_slot` 历史**的处理"。
    装机器上,`os-install` 3b 写的 state 是:
    ```
    pending_slot=a / pending_version=X / running_slot= / last_result= / …
    ```
    于是很自然地写成 `[ -z "$(keel_state_get running_slot)" ] && [ -z "$(keel_state_get last_result)" ]`
    ⇒ "没有历史 = 装机首启"。**逻辑看着没错,静态断言也拦不住**。
    实测(装机 → 首启)打出来的是 `更新成功:槽 a 上的 … 已确认`,不是"首次启动确认"。
    **原因**:`keel-firstboot.service` 跑在 `keel-confirm.service` **之前**(前者 `Before=multi-user.target`,
    后者挂在 `boot-complete.target` 上),而它第 58–59 行正是:
    ```bash
    if [ -z "$(keel_state_get running_slot)" ]; then
        keel_state_set running_slot "$(keel_current_slot)"
    fi
    ```
    —— 轮到 confirm 时,`running_slot` 早就被填上了,那个判据永远为假。
    **修法**:别用"某键为空"表达"没有历史"(它是个**共享可变状态**,谁都能先动);
    改成**显式标记** —— `os-install` 写 `first_boot=1`,`confirm` 读到就报"首次启动确认"
    并**用完即清**(`keel_state_set first_boot ""`),这样只生效一次,也不会被别的单元误碰。
    **教训**:① 判"是不是第一次"要用**一次性标记**,不要用"某个字段恰好为空";
    ② 单元之间的**执行顺序**(`firstboot` 早于 `confirm`)是判据的一部分 —— 看代码时要连
    `Before=`/`After=` 一起看,光看函数体永远看不出这个 bug;
    ③ 同一类的还有 `last_result`:它只会被 confirm 写,所以作为"有没有跑过确认"的判据是安全的,
    `running_slot` 不是 —— **同样是"状态键",写入者不同,可信度就不同**。

66. **不带 sudo 也能构建,但**产物不等价**:镜像里非 0 的 uid/gid 全被压成 0(2026-09-27,v1.1 ⑥ 的 rootless 实测)。**
    起因是 ⑥ 里那句"原生路径 rootless 那一半还没做" —— 实测结论分两半,两句都要记住:
    **① 能跑通**:`tools/build.sh` 以普通用户跑完三个 profile、exit 0,`dist/` 五个产物齐全
    (mkosi 25.3 会用用户命名空间 + `/etc/subuid`/`subgid`,不需要 CAP_SYS_ADMIN;
     这条也顺手纠正了 `build.sh` 里原来那句"mkosi 的沙箱需要 CAP_SYS_ADMIN"的旧说法)。
    **② 但产物是坏的**:把两次构建的 `slot-a.root.raw` 都 `fsck.erofs --extract` 出来,
    按 `%P %y %m %U %G %s` 比一遍:
    ```
    root 构建    : 17563 个条目,gid≠0 的 18 个、uid≠0 的 3 个
    rootless 构建: 17563 个条目,gid≠0 的  0 个、uid≠0 的 0 个   ← 全被压成 0
    ```
    差的 21 个文件正好是"属主不是 root"的那批:`/etc/shadow`/`gshadow`(shadow 组 42)、
    setgid 的 `unix_chkpwd`/`chage`/`expiry`(42)、`ssh-agent`(101)、
    `dbus-daemon-launch-helper`(996)、`/var/log/{wtmp,btmp,lastlog}`(utmp 43)、`/var/mail`(8)、
    `nix/var/nix/daemon-socket`(989)、`var/lib/systemd/network`(998)、`/var/log/journal`(999),
    以及 **`/usr/share/keel/data-skeleton/home/admin`(1000:1000 → 0:0)** —— 最后这条是功能性的:
    它会被首启 `cp -a -n` 到 `/data/home/admin`,于是 **admin 的家目录归 root**,用户写不了自己的家目录。
    **原因**(不是 keel 的 bug,是"非 root 用户本来就做不到"):普通用户只能创建属于自己的 uid/gid
    的文件。mkosi 自己的源码里写得很直白(`sandbox.py:seccomp_suppress_chown`):
    > There's still a few files and directories left in distributions in /usr and /etc that are not
    > owned by root. … Unfortunately, non-root users can only create files owned by their own uid.
    > To still allow non-root users to build images, if requested we install a seccomp filter that
    > makes calls to chown() and friends a noop.
    实测里对应的现场就是 dpkg 装 `passwd` 时 chown 不到 shadow 组、`systemd-tmpfiles` 那一行
    `fchownat() of /buildroot/nix/var/nix/daemon-socket failed: Invalid argument`(EINVAL =
    目标 gid 在用户命名空间里没有映射)。**换过一次缓存重跑,24 个文件的差异一字不差** ⇒ 不是缓存脏,
    是这条路径的固有性质。
    **规矩**:① 开发/自测/CI 用 rootless 没问题(它还快);**发布产物必须 `sudo tools/build.sh`**,
    `build.sh` 现在会在非 root 时把这句话打出来;② **别把两种构建混在同一个 `mkosi.cache/` 上** ——
    增量缓存是"整棵树 move/copy"(`move_tree` 是 rename,`copy_tree` 用
    `cp --preserve=…,ownership`),身份一变,那棵树就把错误属主**传染**给下一次构建
    (实测:rootless 跑完之后 `mkosi.cache/debian~trixie~x86-64.cache` 里 18429/18429 个文件的
    属主都变成了构建者;根构建只在 `tools.cache` 里留 2/28065 个非 root 属主)。切换身份之前:
    `rm -rf mkosi.cache/*.cache`(`mkosi.pkgcache/` 是 .deb 缓存,可以留着,省下载)。

67. **校验器会"静默少跑":非 root 时 PATH 里没有 `/usr/sbin`,第 3 节整节消失(2026-09-27,同一次 rootless 实测)。**
    同一个仓库、同一份 `tools/verify.sh`,root 跑是 **191 通过 / 0 跳过**,非 root 跑是
    **173 通过 / 4 跳过** —— 差的 14 条全在第 3 节(repart 分区布局:分区名/尺寸/类型/erofs/空槽…),
    而它给出的理由是一行不起眼的 `- 缺 systemd-repart 或 sfdisk,跳过`。
    **真相**:`sfdisk` 装在 `/usr/sbin`(fdisk 包),而 Debian 普通用户的默认 PATH 是
    `/usr/local/bin:/usr/bin:/bin:…` —— **没有 sbin**;root 的 PATH 里有。所以 `have sfdisk` 为假,
    而那一节是"要么全跑、要么整节跳过"的结构 ⇒ 十几条断言凭空消失,汇总行还写着"0 失败"。
    **这是最坏的一类坏法**:门自己残了,却报一切正常。**修法**:① 门面 `tools/verify.sh` 自己把
    `/usr/sbin:/sbin` **追加**进 PATH(只追加,不遮蔽调用者的);② 缺工具时**报失败**而不是跳过
    (缺工具是"宿主没装全",不是"这台机器上没这项检查"),并在消息里说清怎么装;
    ③ 容器适配器里补装 `fdisk`(容器里原本也没有 ⇒ 容器路径同样整节消失);
    ④ 第 11 节给"门自己"上断言(见 `tools/lib/verify/97-gate-env.sh`)。
    **教训**:凡是"缺东西就跳过"的分支,跳过的**不是一条检查,而是一整节**;写这种分支时要问
    "跳掉了几条?"——数量要能被看见。

68. **写死的临时路径会让门"看人下菜":root 跑过一次,非 root 再跑就假红(2026-09-27,同一次实测)。**
    非 root 跑 `tools/verify.sh` 时第 5 节报 `shellcheck 有问题:`,细节却是一行
    `/tmp/keel-shellcheck.log: Permission denied` —— 校验器把 shellcheck 的输出重定向到一个
    **写死的、世界可写目录下的固定文件名**;那个文件被 root 跑过一次,属主就是 root,普通用户再也写不动。
    (顺带的安全面:固定名字 + 世界可写目录,预先放个符号链接就能让下一次 root 跑去截断它指向的文件。)
    **修法**:走 `tmpd`(=`mktemp -d`,`$TMPDIR` 下的随机名,退出时由 trap 清掉)——
    仓库里别的地方早就这么做了,只有这一处漏了。第 11 节现在有一条断言扫这个模式。
    **教训**:临时文件的两条铁律 —— **随机名字**、**别假设下一次是谁在跑**;
    "root 跑过"会留下普通用户动不了的东西,这类残留会让同一份代码对不同的人给出不同的答案。

69. **断言自己会说谎:`grep -v` 一次喂**多个文件**会给每行加前缀,`^`/空白锚点全失效(2026-09-27,P3 的反向断言)。**
    P3 把 `/data` 扩容收进 lib.sh 之后,加了一条反向断言:"firstboot / os-rescue 里不许再有
    repart·growfs·resize2fs 的**调用**"(注释里提到这些命令不算,所以先 `grep -v '^[[:space:]]*#'`
    再按"命令位置 + 后面跟参数"匹配)。
    第一版写成了:
    ```bash
    drift=$(grep -vE '^[[:space:]]*#' file1 file2 | grep -nE '(^|[[:space:]])(resize2fs|…)[[:space:]]+("?\$|-|/dev/)' || true)
    ```
    `grep -v` 一次收到**两个**文件时会输出 `file1:行内容` —— 于是待匹配的行以
    `…firstboot:resize2fs "$vol"` 开头,`(^|[[:space:]])` 两边都不成立 ⇒ **永远匹配不到**。
    验证方式:往 firstboot 末尾塞一行 `resize2fs "$vol"`,断言照样全绿。
    **修法**:逐个文件跑(或者给第一个 grep 加 `-h`);顺便把文件名带进失败消息里,更好定位。
    **教训**:① 反向断言(断言"**没有**某种东西")必须**做一次定向变异**才算验过 ——
    正向断言"字符串在不在"通过就等于验过了,反向断言不是:它可能因为模式写错而永远为真;
    ② `grep -v`/`grep -l`/`-r` 的文件名前缀、`-r` 的路径前缀,都会悄悄改变锚点语义;
    ③ 这条和坑 #52(对着 `/proc/cmdline` 用 `^` 锚定)、#67/#68(门静默少跑/假红)是同一族:
    **判据本身要能被证伪,否则"全绿"两个字没有意义。**
    **最终策略(2026-09-27 拍板)**:**原生路径直接拒绝非 root** —— `build.sh` 见到 `id -u != 0`
    就 `die`,并在消息里指向容器适配器;不是"警告一句继续跑"。理由:产物**看起来完全正常**
    (exit 0、五个产物齐全),一句提示会被几千行构建日志埋掉,而这类"每步都成功、结果是错的"
    正是本项目最忌讳的形态(同 `os-update fetch` 拒绝带 `migrate=` 的载荷)。
    **没有 root 也要构建 → 走容器适配器**:容器里是 root,而且 podman 会把宿主机的 subuid/subgid
    映射进容器(`podman run --privileged` 里实测 `chown 0:42` 落地就是 gid 42)⇒ 那条路的产物不受限。
    `tools/verify.sh` 第 11 节有一条断言守着这句 `die`(防止有人把它改回"只警告")。

70. **候选条目与正式条目是**同一个条目 ID** ⇒ 引导器选中旧的正式条目:旧内核配新根(不变量 3)+ 每次更新漏 156 MiB(2026-09-27,v1.1 发布前的循环 soak,第 2 轮就现形)。**
    现象:在 a↔b 之间反复更新,**ESP 可用空间每轮掉 ~156 MiB**(710 → 554 → 398 MiB),
    条目数 2 → 3 → 4,而且**第 2 轮以后机器启动的其实是上一轮/装机时的 UKI**。
    现场(同时存在、哈希不同):
    ```
    keel-a+3.efi  751b6020…   ← stage 刚写的候选(= 载荷里的 slot-a.uki.efi)
    keel-a.efi    dc29ac23…   ← 安装时那份 UKI,一直没被替换
    keel-b.efi    1b3b702f… = keel-b+3.efi(第 1 轮留下的;那时还没有正式条目抢 ID)
    ```
    机制:`os-update stage` 把候选写成 `keel-<槽>+3.efi`(boot counting 的 tries-left),
    然后 `bootctl set-oneshot keel-<槽>.efi` —— 而 **bootctl 认的"条目 ID"是文件名去掉 `+N` 后缀**,
    也就是**和已经存在的正式条目同一个 ID**。ID 唯一时(第 1 轮:目标槽还没有正式条目)一切正常;
    正式条目一旦在,引导器就解析到**旧的正式条目**:
    `LoaderBootCountPath` 为空、`systemd-bless-boot` 一行日志都没有(bless 无事可做),
    候选没人消费 ⇒ 永远留在 ESP 上(每槽一个,共 312 MiB)。
    而根分区**已经被 dd 成新载荷** ⇒ 实际启动的是**旧 UKI + 新根**,直接违反不变量 3。
    **为什么以前的测试全都漏了**:① 演练/drill 每次只做**一轮**更新,而第 1 轮恰好是"ID 唯一"的安全情形
    —— **第一次做对最容易骗过测试**;② `keel-confirm` 判"更新成功"看的是**槽**与**版本号**,
    而版本号是从**新根的** `/etc/os-release` 读的 ⇒ 旧内核配新根时它照样报 success;
    ③ 老机器 erofs 迁移那次也一样(旧 UKI + 新 erofs 根恰好都能起来)。
    **修法**:`stage` 在写候选之前先 `rm -f "$KEEL_UKI_DIR/keel-<目标槽>.efi"` —— 目标槽的根此刻
    已经被新载荷覆盖,旧条目指向的内容早就不存在,留着只会再漏 156 MiB;而此刻持久默认仍指向
    **正在运行**的槽,所以删掉之后的任何一个断电窗口都不会让机器"没得选"。
    修完 soak 25 轮:ESP 恒定 710 MiB、条目恒定 2、每轮都断言"正式条目 == 载荷里的 UKI"。
    **教训**:① **"名字"和"ID"不是一回事** —— 依赖外部工具的解释规则时,去读它**怎么解析**,
    别假设(boot counting 的 `+N` 在 ID 层被抹掉);② 不变量要**直接**断言("启动的 UKI == 载荷的 UKI"),
    别用"槽对了 + 版本对了"间接推断 —— 那两样在"旧内核配新根"时**同时**是对的;
    ③ 循环 N 轮的 soak 值钱就值在这里:第一轮和第 2..N 轮走的根本不是同一条路。

71. **状态文件只 rename 不落盘:硬断电会留下**空文件**,整个 state 被打回原形(2026-09-27,压力测试的断电 torture)。**
    现象:6 刀(在 `os-update stage` 进行中 `virsh destroy`)之后,5 刀的 `/data/keel/state`
    只剩 `entry_a/entry_b/running_slot` 三个键 —— `pending_slot`、`last_result*`、`first_boot`
    一起消失(`os-status` 于是显示"上次启动结果: 无记录")。
    定位:关键证据是**键的集合在缩小**,而不是某次写入丢失 —— `keel_state_set` 的读-改-写只替换
    一个键、不会删别的键,所以文件一定是**被从头重建**过。真正的写入模式是
    `mktemp` → 写入 → `chmod` → **`mv -f`(rename)**:rename 保证"看不见半个文件",
    但**新文件的数据**可能还在页缓存里 ⇒ 硬断电之后目录项在、内容是空的 ⇒
    下一次 `keel_state_set` 从空文件重建,其余键一起没了。
    确定性复现:写完 state **0.3 秒后**硬断电 → 文件塌成 1~3 个键;**先 `sync` 再 rename** 之后,
    同样的一刀 → 文件保持 8 个键,只有"最后一次写入"本身丢掉(干净地回退到上一个完整版本)。
    **修法**:`keel_state_set` 与 `keel_update_check_state` 在 `mv` 之前 `sync "$tmp"`
    (coreutils ≥ 8.24 的 `sync FILE` 只刷这个文件;老版本退回全量 `sync`)。
    **留下的语义**(已写进 release notes 的已知限制):硬断电最多丢掉**最后一次**状态写入
    (例如刚写下的 `pending_slot`),但文件不会被打回原形;更新/回退仍然成立 ——
    因为 oneshot 是在写状态**之前**设的,最坏情况只是 `last_result` 少记一次。
    **教训**:① 原子 rename ≠ 持久:要"新内容一定在",就得 fsync **数据**(严格说还要 fsync 目录,
    shell 里做不到;但"旧文件或新文件"这个语义已经够用);② 这类 bug **只在硬断电下出现**,
    所有"正常重启"的测试都测不到,只有 `virsh destroy` / 拔电才现形;
    ③ 它也不会在任何日志里报错 —— 那几次 confirm 一句话都没说(因为没有 pending)。

72. **"发行版的包太老"这件事要**先量再定**:钉 sid 的 nix 实测解不开,而 trixie 的 nix 背着 4 条 no-DSA(2026-09-27,v1.2 评估 nix 来源时)。**
    起因:镜像里的 nix 是 trixie 的 **2.26.3**,上游已经 **2.35.2**,于是很自然会想"从 sid/backports 拿个新的"。
    **实测把这条路堵死了**(方法可复用,值得记下来):
    ① 在 `debian:trixie` 容器里加 sid 源直接装 ⇒ apt 会把 **libc6 2.43 / systemd 262 / bash 5.3 /
       perl-base / openssl 3.6** 一起从 unstable 拖进来(apt 默认取**每个依赖的最高版本**);
    ② 按规矩钉住(只有 `nix-bin`+`nix-setup-systemd` 走 sid,其余留 trixie)⇒ **解不开**:
       ```
       nix-bin 2.34.8 Depends libcurl4-gnutls (>= 8.20.0-3~)
       trixie 的 libcurl = 8.14.1-2+deb13u5      ⇒ held broken packages
       ```
    ③ 查 Debian pool 里的版本分布:`nix-bin` 只有 **2.3.7 / 2.8.0 / 2.26.3 / 2.34.8**
       —— **没有**"修了洞又兼容 trixie"的中间版本(2.26.3 之后直接跳到 2.34.8);
    ④ 查 backports:**trixie-backports 里根本没有 nix 这个包**;
    ⑤ 查 `security-tracker.debian.org/tracker/source-package/nix`(权威,别只看别人转述):
       trixie 有 **4 条 "no DSA"(Debian 不打算在 trixie 修)**,其中三条 root 级、修在 **2.34.7**,
       第四条修在 **2.35.0**。**只升客户端没用** —— 洞在 daemon 侧(NAR 解析、输出注册)。
    结论与去向:**决策 D29**(v1.2 用上游固定版本+哈希的 tarball 进数据骨架,加性同步),
    当前(未升级)的纪律写进 `keel-check` 的警告与 release notes。
    **教训**:① "包太老"要先分清是**功能**还是**安全**问题 —— 功能上 nixpkgs 是现取的(客户端老不影响装到新软件),
    安全上才是真债;② "从 sid 拿一个包"在 Debian 上**不是**一条配置级捷径:先看依赖链(尤其 libcurl/libc/systemd),
    再看 pool 里的版本分布,再看 backports,最后看 security-tracker 的**逐发行版状态**;
    ③ 别用二手转述判断 CVE(这次转述里的"NAR 解析栈溢出"和"≥2.28.7"对上了,但条数与具体描述对不上),
    `security-tracker.debian.org` 上一眼就能看全,连"no DSA"这种态度信息都在。

73. **`openssl -out` 会写穿符号链接 —— 演练把自己的发布产物签成了别人的清单(2026-09-28,第一次 v1.2 签名演练,由只读对抗复核 subagent 抓出)。**
    现象:演练在 p0 就打印「**与预期不符** —— 好载荷 fetch 失败」然后 poweroff,而宿主打印
    「VM 退出码:0(0 = 演练跑到 p2 并自己 poweroff)」—— 看起来全绿,实际上 stage/重启/回滚/
    自动回滚整段都没跑。更糟的是 `dist/keel-<版本>/manifest.sig` 被换成了 **mig 清单的签名**
    (拿它发布,所有 v1.2 机器都会拒绝这个更新)。
    根因:演练 step 6 构造 `/tmp/drill-serve/bad`、`/mig` 时,把 good 载荷目录里"除 manifest 与
    目标根镜像之外的所有文件"都 `ln -sfn` 过去 —— **包括 manifest.sig**;随后
    `tools/sign.sh sign /tmp/drill-serve/bad` 用 `openssl dgst -sha256 -sign -out "$dir/manifest.sig"`,
    而 openssl 打开输出文件时**跟随符号链接**(实测:截断并覆盖目标文件,链接本身保留)⇒
    "给 bad/mig 签名"实际签的是 good 的 dist。讽刺的是同一段代码对 `badsig` 特意用 `cp` 并注释了
    "符号链接会让 dd 顺着改到 good 的签名上",bad/mig 两处却漏了。
    **修法**:`tools/sign.sh sign` 一律先写 `$dir/.manifest.sig.XXXXXX` 再 `mv -f` 到
    `manifest.sig`(rename 替换的是**链接本身**,永远不碰目标);`tools/verify.sh` 加了一条
    功能断言:让 `manifest.sig` 指向一个诱饵文件,签名后诱饵内容必须不变、目录里必须是普通文件。
    **教训**:① `-out`/`dd`/`tee` 这类"按名字打开写"的工具**默认跟随符号链接**,凡是往
    "可能是链接的目标名"写东西,要么先写临时文件再 rename,要么先 `rm` 掉链接;
    ② 演练里"用符号链接省空间"很方便,但**被签/被改的文件绝不能是链接** —— 省下的那点空间
    远不及一次假绿 + 一个被污染的发布产物。

74. **guest 干净 poweroff ⇒ `mkosi vm` 返回 0 —— 宿主只看退出码的演练永远不会失败(同一次演练暴露)。**
    现象:guest 的 ota-drill 把每一步结论写成 `keel-ota-drill[...] 判定:...` 日志,判错了也只是
    `systemctl poweroff`;宿主把 `timeout mkosi vm` 的 rc=0 解释成"演练跑到 p2 并自己 poweroff",
    于是 **p0 就中止的演练照样全绿**(当时静态门 `tools/verify.sh` 222 通过 / 0 失败,也抓不到)。
    **修法(两层)**:① `tools/ota-drill-container.sh` 把 VM 控制台 `tee` 到文件,逐个 `grep -F`
    必须出现的关键判定(三条签名路径 / 更新成功 / 回滚 / 自动回滚 / migrate 拒绝),出现
    「与预期不符」或没跑到「演练结束」时 `exit 1`;② 静态门断言那些关键判定在 guest 脚本里
    真的存在(改了文案不改断言时 verify 会提醒)。
    **教训**:判定"只打印不返回"等于没判 —— 特别是当**正常路径与失败路径的退出码相同**
    (都是 poweroff)时。任何自动化验证都要有一条宿主侧判据:"关键产物/关键字符串必须出现,否则失败"。

76. **`mkosi.initrd.conf` 是个死文件:mkosi 25.3 根本不读它 —— v1 的 initrd 看门狗配置从未生效,那两条断言一直是空断言(2026-09-28,v1.2 3.0 调查)。**
    现象:坏槽在 initrd 阶段冻结(`Switch root target contains no usable init.`)时,机器挂 650+ 秒
    没人复位(坑 #50)。v1.1 的 drill 里那个"抽 .initrd 查 keel-watchdog.conf"的检查打印过警告,
    但被当成"检查方式可能误报";verify 里两条断言只看 `mkosi.initrd.conf` 里有没有
    `ExtraTrees=mkosi.extra-initrd` —— 全绿。
    查实:① 在 mkosi 源码里 grep,`mkosi/*.py` **没有 `mkosi.initrd.conf` 这个文件名**,默认
    initrd 是用内置 `--include=mkosi-initrd` 构建的;② 拆开安装镜像 UKI 的 `.initrd`
    (`objcopy --only-section=.initrd`),里面是**两段 zstd**(默认 initrd 31.4M + 内核模块 initrd),
    base 段 184 个 `/etc` 文件里**没有**任何 keel 的东西;模块段里倒是有 `softdog.ko.xz`。
    ⇒ 配置从未进过 initrd。素材改放 `mkosi.initrd-extra/`(`tools/mkinitrd-extra.sh` 打成 cpio),
    等找到正确的注入出口再接(见 #77)。**在那之前不要相信任何"配置在不在"的静态断言** ——
    只有证明它进了 `.initrd` 才算数。
    **教训**:① "我写了个配置文件"和"它真的到了目标"之间隔着一个**别人家的加载机制**,
    而那个机制可能根本不认识你的文件名;② 这次是**拆开产物**才看见真相,grep 源码永远看不出来。

77. **`mkosi --initrd` 追加一个未压缩 cpio 会打破 initramfs 链:内核 `VFS: Unable to mount root fs`,连正常槽都起不来(2026-09-28,修 #76 时踩到)。**
    做法:把 `mkosi.initrd-extra/` 打成 newc cpio,`build.sh` 给 mkosi 加
    `--initrd mkosi.output/keel-initrd-extra.cpio`。构建、签名、postinst 全绿,但 drill 一启动
    就是 panic 循环:`/dev/root: Can't open blockdev` → `mount_root_generic` → panic → 重启,
    **一个 keel-ota-drill 阶段都没跑到**(连 p0 都没进)。根因:`.initrd` 是多个 initrd 拼接的,
    原有两段都是 **zstd 压缩帧**,而我们追加的是**未压缩 cpio** —— 内核的 initramfs 解包器在
    这种混合拼接下没有继续解后面的压缩帧 ⇒ 找不到 `/init` ⇒ 内核直接去 mount root ⇒ panic。
    **现状**:3.0 的修复**没有接进构建**(reverse 断言守着,防止有人再偷偷接上);
    `tools/mkinitrd-extra.sh` 与 `mkosi.initrd-extra/` 作为素材保留,等正确的注入出口。
    **教训**:① "构建成功"不能证明"能启动" —— 这次唯一抓住它的是 drill 的**启动**;
    ② 往别人的产物里追加东西之前,先看清那个产物的**格式约定**(是不是同一种压缩);
    ③ 下次先本地拼一个混合 `.initrd` 用 QEMU 单测,比花 25 分钟跑整条 drill 便宜得多。

75. **`Before=... sysinit.target` 的早期单元忘了 `DefaultDependencies=no` ⇒ 依赖环,systemd 丢掉的是**别的**单元(2026-09-28,v1.2 nix B1 的第一次演练)。**
    现象:drill 的 guest 在 p0 就"与预期不符"——三个更新源全部被拒,报的却是
    `/data 可用空间只有 409 MiB,放不下更新载荷(预算 2 GiB)`;三个签名守卫也全部"消息不含关键字"。
    根因:新加的 `keel-nix-sync.service` 要排在 `keel-firstboot` 之前(先做带空间检查的加性同步),
    于是写了 `Before=keel-firstboot.service`,但**忘了**它同时还有 `DefaultDependencies=yes`
    (隐含 `Requires/After=sysinit.target`),而 `keel-firstboot` 是 `Before=sysinit.target` ⇒
    nix-sync → firstboot → sysinit → nix-sync 成环。systemd 破环时丢掉的不是新单元,而是
    **keel-firstboot**(以及 `nix-daemon.socket`、`systemd-pcrphase-sysinit`):/data 从未扩容,
    24G 演练盘上的 live `/data` 仍只有 ~1 GiB,再被 114 MiB 的 nix 闭包一占,就只剩 409 MiB。
    日志里只有一行 `[ SKIP ] Ordering cycle found, skipping keel-firstboot.service`,而症状出现在
    完全另一处("更新源被拒")—— 典型的"症状离原因很远"。
    **修法**:凡是 `Before=... sysinit.target` 的早期单元,一律 `DefaultDependencies=no` +
    显式 `Conflicts=shutdown.target`(`WantedBy=sysinit.target`),头部照抄 keel-mounts /
    keel-firstboot;socket 也不必再叠 `After=keel-nix-sync.service`(容易把环引到 socket 上)。
    **教训**:① systemd 破环时会**静默丢掉环里的某个单元**,被丢的往往不是你以为的那个 ——
    遇到"某单元没跑"先 `journalctl -b | grep -i 'ordering cycle'`;② 关键路径上的单元
    (挂载、扩容)要有人替它报警:这次是 drill 的宿主侧判定 + `fetch` 的空间检查把"假绿"挡住,
    否则会被当成"签名代码坏了"去查(第一次演练确实先怀疑了签名)。
