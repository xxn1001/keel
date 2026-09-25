# keel 已知的坑(43 条,都是真踩过的)

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
