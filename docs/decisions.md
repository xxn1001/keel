# keel 决策记录(ADR)

按时间顺序记录**已经拍板**的决策,以及**被否决的方案和否决理由**。
被否决的理由比决策本身更有价值 —— 防止后来者重新提出同一个已经被否掉的方案。

格式:决策 / 理由 / 否决的替代方案。

---

## D1 基底发行版:Debian 13 stable(trixie)

- **决策**:`Distribution=debian`,`Release=trixie`,可选 `Snapshot=` 指向 snapshot.debian.org 做可复现构建。
- **理由**:稳定优先(明确排除 Arch 的滚动更新);排除 Ubuntu(不接受 snap);
  trixie 的 `systemd 257.13` 满足全部所需特性(`systemd.mount-extra=` 需 254、`repart --split` 需 252、
  `LoaderEntryPreferred` 需 240);Debian 官方打包了 `nix-bin 2.26.3` + `nix-setup-systemd`;
  固件/微码被拆成很多小包,正好配合 profile 精确挑选。
- **否决**:Arch(滚动、包太新);Ubuntu(snap);Fedora(生命周期只有 13 个月,不适合"装上就不动"的设备);
  openSUSE Leap(可以,但 nix 打包与 mkosi 支持都不如 Debian 顺)。

## D2 只读根的实现

- **决策**:v1 用 `ext4` + cmdline `ro`。
- **理由**:先要一个能跑通的系统。`ext4` 在 Debian 内核里是内建的,不依赖 initrd 里的模块,失败模式最少。
- **后续**:v2 考虑 `erofs`(从根上不可写、压缩更小)或 `dm-verity`(可篡改检测 + Secure Boot 链条)。
  注意 dm-verity 与"两个 root 分区"组合时,roothash 归属需要专门设计(见 D11)。

## D3 目录挂载方式

- **决策**(2026-09 修订):`/var`、`/root` 用**符号链接**指向 `/data`;
  **`/home` 与 `/nix` 用真目录 + bind mount**。
- **理由**:尊重"根目录留软链接"的原始设计意图,能链接就链接(少一层挂载、少一处启动期依赖);
  但这两个目录**必须**是真实挂载点:
  - `/home`:符号链接会让 `ProtectHome=` 这类沙箱设置失效(服务仍能经 `/data/home` 摸到用户数据);
  - `/nix`:`nix` 硬性拒绝符号链接的 store 路径 ——
    `error: the path '/nix' is a symlink; this is not allowed for the Nix store and its parent directories`
    (装机后实测,见 `docs/traps.md` 坑 #34);而 store 位置搬不动(二进制与脚本把 `/nix/store/…`
    写死在 ELF interpreter 与 RPATH 里),只能让 `/nix` 本身是真目录。
- **关键约束**:符号链接无法参与挂载顺序约束 ⇒ `/data` 必须极早挂载(见 D4)。

## D4 `/data` 的挂载时机

- **决策(2026-09 修订)**:由 `keel-mounts.service`(initrd 之后、`sysinit` 之前)自己扫
  `/sys/class/block/*/uevent` 的 `PARTNAME=data` 找到分区并挂载,`blkid -t LABEL=data` 兜底。
  不经过 udev、不生成 `.mount` 单元。
- **原决策(已推翻)**:写进 UKI 的 kernel cmdline:
  `systemd.mount-extra=PARTLABEL=data:/data:ext4:rw,noatime`。
  当时的理由是"`systemd-fstab-generator` 在主系统和 initrd 里都会解析它,initrd 里自动加 `/sysroot/` 前缀"。
- **推翻原因(真机 VM 实测,`docs/traps.md` 坑 #24)**:这两条理由都不成立 ——
  initrd 阶段根本没有生成 `/sysroot/data`(initrd 里连我们的文件都没有);
  主系统阶段它生成的 `data.mount` 要等 udev 建 `by-partlabel` 符号链接,而 udev 要等
  `systemd-sysusers`、sysusers 要可写的 `/etc`、可写的 `/etc` 又挂在 `/data` 上 ⇒ 环形依赖 ⇒
  systemd 丢掉 `local-fs-pre.target`、udev 被推到 emergency 之后、挂载 90 秒超时 ⇒ emergency mode。
- **仍然否决**:靠 `/etc/fstab` + `x-initrd.mount`(需要把 fstab 注入 initrd 树,多一层构建魔法);
  靠普通 systemd `.mount` 单元(依赖 udev,同一个环)。

## D5 `/etc` 必须可写,用 overlayfs

- **决策**:lower = 只读镜像的 `/etc`,upper/work = `/data/overlayfs/etc/{upper,work}`。
- **理由**:`/etc` 有大量必须可写的硬需求 —— `machine-id`、ssh 主机密钥、
  `passwd/group/shadow/subuid`、`nix.conf`(换镜像源是刚需)、NetworkManager/sysd-networkd 配置、
  `localtime`/`hostname`/`locale.conf`。只读 `/etc` 直接不可行。
- **否决**:把 `/data/etc` 整体 bind 到 `/etc` —— 那是一次性快照,新版本镜像里 `/etc` 的任何改进
  会被旧副本**永久遮蔽**,而且没有合并机制。
- **否决**:每槽独立的 `/etc` upper —— 每次更新都要重新配置一遍,体验不可接受。共享 upper 的代价
  (新版本可能写了旧版本不认识的 `/etc` 文件)用 `os-rescue --reset-etc` 兜底。

## D6 加密

- **决策**:不做。
- **理由**:目标平台是服务器,但 v1 先在笔记本上兼任验证;加密会把 initrd 与 /data 的挂载链一并复杂化,先不做。
  要做的话是独立的一次设计(需要把密钥/TPM 纳入启动链)。

## D7 nix 的来源与位置

- **决策**:用 Debian 官方包 `nix-bin` + `nix-setup-systemd`;`/nix` 通过符号链接落在 `/data` 上;
  nixbld 用户与 `/nix` 骨架在**构建期**烤进镜像(不依赖首启时的网络或写 `/etc` 的时序)。
- **理由**:发行版打包 = 可直接由 mkosi 在构建期安装、可复现、带 systemd 单元与 sysusers/tmpfiles,
  比"构建时 curl 官方安装器"干净得多。
- **否决**:官方 curl 安装器(构建期联网、非幂等、把状态写进 /nix 之外)。

## D8 更新器:门面自研 + 机制用 systemd

- **决策**:`os-update` 是我们的**门面**(策略/迁移/保留/报告);下载、验签、版本比较、
  写分区交给 `systemd-sysupdate`;槽切换用 `bootctl set-oneshot`(候选)/ `set-default`(固化)
  —— 原设计写的 `set-preferred` 在 Debian 的 systemd 257 里不存在,见坑 #43;成功判定与回滚用
  boot counting + `systemd-bless-boot.service`。
- **理由**:"绝对不能出错"的部分(写分区、回滚判定)复用被大量发行版验证过的代码;
  "必须贴合本架构"的部分(schema 迁移、保留策略)自己写。门面模式还保证:
  若 sysupdate 的分区匹配语义不合适,只换底层,接口不变。
- **否决**:纯自研(下载/校验/回滚轮子自己造,bug 代价最大);
  RAUC(引入 daemon + bundle 格式 + 另一套状态机,与 systemd-boot 的回滚机制重复)。

## D9 swap

- **决策**:`/data/keel/swapfile`,首次启动创建并启用(mkswap + swapon)。**不做休眠**。
- **理由**:根只读 ⇒ swap 文件必须放在可写分区;休眠需要 `resume=` + `resume_offset=` 且偏移会变,
  在 A/B 布局下不可靠。
- **否决**:分区 swap(占用宝贵的 GPT 槽位,且 A/B 布局下没有地方放);纯 zram(内存小的机器不够用)。

## D10 镜像里不留发行版包管理器

- **决策**:不保留 `apt`/`dpkg` 的用户可用性,装软件只能走 nix。
- **理由**:根只读 + `/var` 是符号链接 ⇒ 包管理器的数据库在运行时本来就不可见/不可用,
  留着只会让用户误以为能装。
- **实现注意**:mkosi 的 manifest 生成依赖包管理器查询,**移除动作必须晚于 manifest 生成**;
  若冲突,则保留 `dpkg` 但去掉 `apt`。

## D11 分支策略:单主干 + profile

- **决策**:`main` 单一主干;`desktop`/`server` 是 **mkosi profile**,不是 git 分支;
  机器差异进 `machines/*.conf`;单机运行期状态进 `/data`。
- **理由**:分支表达"并行的改动线",不表达"同一东西的不同形态"。三分支会导致 main 上每个修复
  都要重复合并、三个月后必然漂移。profile 方案的杀手性质是"一个 commit 同时构建出所有变体,
  物理上不可能不一致"。
- **否决**:`main`/`desktop`/`server` 三分支。

## D12 每槽一个完整 UKI,不用共享内核

- **决策**:每个槽一个独立的 UKI(含自己的内核、initrd、`root=PARTLABEL=`、微码)。
- **理由**:回滚时内核与根文件系统永远配对;共享内核 + 两个 BLS entry 虽然省空间,
  但回滚会变成"新内核 + 旧根",模块不匹配,不可接受。
- **注**:mkosi 的 `UnifiedKernelImageProfiles` **不能**用来做这件事 —— 它产出的是 PE addon
  (源码 `build_uki_profiles()` 用的是 addon stub),不是可独立引导的 UKI。两个槽 = 跑两次构建。

## D13 微码与 KVM/VFIO 归属

- **决策**:微码两个厂商都装(`amd64-microcode` + `intel-microcode`),打进 UKI 的 initrd;
  KVM/VFIO 模块不做任何特殊处理(它们本来就在内核包里)。
- **理由**:微码是安全相关、应与系统一起原子更新的东西,而且 mkosi 会自动把两个厂商的微码
  组装成 microcode initrd 前置进 UKI(`MicrocodeHost=yes` 只适合 VM 调试,会砍掉另一个厂商)。
  "按 CPU 厂商分支"在这个项目里**不是真实的差异维度**。
- **机器特有的部分**:IOMMU 参数用"对所有机器都无害的超集"(`amd_iommu=on intel_iommu=on iommu=pt`);
  `vfio-pci ids=` 这类放 `/etc/modprobe.d/`(经 `/etc` overlay 持久化)。理由:cmdline 烧在 UKI 里,
  运行时改不了(后门见 `docs/traps.md` 坑 #4)。

## D14 GPU 驱动:不进 main,外置方案定为 v1.5

- **决策**:main **不带任何 GPU 驱动**;将来做 `desktop` profile 时,开源栈(i915/amdgpu + mesa +
  拆分的固件包)进基底,而 NVIDIA 专有驱动走"第三方内核模块外置"方案
  (把 `/usr/lib/modules/<kver>` 在启动早期叠一层 upper 在 `/data` 的 overlay,
  镜像里保留发行版模块作保命底线);`server` profile 则完全不需要驱动(GPU 直通给 VM)。
- **理由**:nix **装不了**内核模块 —— nixpkgs 的 `nvidia_x11` 是针对 nixpkgs 自己的内核编译的,
  与 Debian 内核的 vermagic/符号 CRC 不匹配,`modprobe` 会直接拒绝。所以"驱动怎么装"和"驱动放哪"
  是两个独立问题:驱动必须由镜像构建流水线产出(构建期 DKMS),但**放哪**可以自由设计。
  外置方案的额外好处:模块按内核版本分目录,回滚到旧槽时旧内核的驱动仍在 `/data` 上。
- **否决**:用 nix 装内核模块(原理上不可行);把整个 `/usr/lib/modules` 直接搬到 `/data`
  (会让"可写分区故障"升级成"整机没有驱动",所以改为 overlay + 保留镜像内模块作底线);
  做成 sysext(sysext 的 `extension-release` 必须匹配基底版本 ⇒ 每次基底更新都要重建 sysext,
  而 NVIDIA 的更新节奏比基底还快,耦合方向是反的)。

## D15 网络栈

- **决策**:main 用 `systemd-networkd` + `systemd-resolved`(有线 DHCP);
  `desktop` profile 再切换/追加 `NetworkManager`(Wi-Fi、图形化管理)。
- **理由**:main 只保证有线可用,用 systemd 原生栈可以省掉 dbus/polkit/NetworkManager 一大串依赖;
  桌面场景才真正需要 NetworkManager。
- **补充(2026-09,坑 #29)**:DHCP **必须**由 networkd 自己做,不要再引第二个客户端(dhcpcd)。
  networkd 的 DHCPv4 曾经在本镜像里起不来,报 `Failed to configure DHCPv4 client: Package not installed`
  (= `-ENOPKG`),当时的临时办法是装 `dhcpcd-base` 顶替;根因已查清 —— 镜像里
  `/etc/machine-id` 是 mkosi 写的占位符 `uninitialized`,而 PID1 首启用的 transient bind mount
  又被我们随后挂的 `/etc` overlay 盖住,于是 machine-id 永远是空的,networkd 生成 DUID 时拿到 `-ENOPKG`。
  现在由 `keel-mounts` 在挂完 overlay 后立刻把 PID1 本次启动的 `/run/machine-id` 固化进
  `/etc/machine-id`(不能只调 `systemd-machine-id-setup`:它对 `uninitialized` 内容是**故意空转**的),
  `DHCP=yes` 交回 networkd,
  dhcpcd 已从镜像里彻底移除(它同时也会喂 DNS 给 resolved,现在这一步由 networkd 直接做)。

## D19 machine-id:PID1 内存里的 ID 与 `/etc/machine-id` 不一致 —— **接受**(方案 C)

- **现状**(坑 #29 的残留):`/etc/machine-id` 是我们固化的、稳定唯一的值(networkd、
  resolved、journald、tmpfiles 都读它);而 PID1 每次都读到只读 lower 里那句
  `uninitialized`,于是每次启动另生成一个 transient ID 放进 `/run/machine-id` ——
  所以 **PID1 内存里的 ID ≠ `/etc/machine-id`**,只有 `%m` 展开这类极少数场景会看到差别。
- **决策(2026-09,由项目所有者拍板)**:**暂不处理**,把这条当作已知的、不影响功能的残留记录在案。
- **考虑过并否决的方案**:
  - **A. 把 `/etc` overlay 提到 initrd 里挂**(根治):PID1 一上来就读到持久化的 ID,不一致
    连同"PID1 早期写 /etc 被盖掉"这一整类问题一起消失。**代价**:initrd 出错 = 起不来,
    那阶段没有持久日志;要确认 `mount`/`findmnt`/`blkid` 在 initrd 的包集里;失败要有优雅回退;
    `reset-etc` 与 overlay 的挂载逻辑会在两处重复;并且推翻坑 #24 里"initrd 不帮我们挂"的结论,
    得整体重排"早期启动谁挂什么"。**结论**:值得做,但要单独排一轮,不和别的改动混在一起。
  - **B. cmdline 加 `systemd.machine_id=firmware`**(一行):PID1 改用 SMBIOS/DMI 的 product UUID,
    与固化的值天然一致。**代价**:依赖固件 UUID 唯一且稳定 —— 有些主板给全 0/全 F 或一批机器
    共用的默认值,那样多台机器会共用同一个 machine-id(DUID 撞车、DNSSEC 密钥共用);
    UUID 读不到时静默退回随机,又回到今天的状态;换主板/刷固件即换 ID;而且是烧进两个槽 UKI 的
    cmdline(承重墙),以后容易被忘掉。
  - **D. 安装/更新时把 machine-id 写进目标槽的根文件系统**:PID1 从根就读到有效 ID。
    **代价**:根镜像不再与构建产物逐字节一致(每个槽多一份机器专属字节)⇒ 将来的 dm-verity /
    镜像签名校验直接废掉,而"完整 UKI + 可校验根"是本项目的长期方向;还给两条安全关键的写盘
    路径各加一步挂载+写入。
- **什么情况下重新考虑**:① 真要做 TPM 密封 / Secure Boot / verity 那一档(那时 A 或 B 必须选一个);
  ② 出现任何真正读 PID1 内存 ID 的功能需求;③ 顺手做早期启动重排时,把 A 一起做掉。
- **注意**:`keel-mounts` 里那段"固化 machine-id"是**必须保留**的 —— 它才是让 DHCP/IPv6/DNSSEC
  能工作的那一环;D19 说的只是"不再追求 PID1 与文件完全一致"。

## D17 持久分区统一叫 `data`

- **决策**:`data` 分区(2026-09 从 `volume` 改名)挂到 **`/data`**;GPT 标签、文件系统标签、
  骨架目录(`/usr/share/keel/data-skeleton`)、救援子命令(`os-rescue --init-data` /
  `--grow-data`)一起统一成 `data`。
- **理由**:挂载点、标签、目录、子命令各叫一个名字是最容易出错的状态(改一处漏一处);
  统一之后"看到 data 就是同一件事"。`/data` 也比 `/Volume` 直白,少一次"Volume 是什么"的解释。
- **为什么这次敢动标签**:标签写在已经做好的分区表里,装机之后就不会再变 —— 老机器、以及
  **另一个槽里的旧镜像**都按标签找分区,标签一改它们就找不到,回滚直接起不来(不变量 6 的
  "只增不破")。2026-09 时所有装机都只是虚拟机实验(没有物理机),所以一次性改干净;
  **v1(真机装过机)之后再动标签,必须按"只增不破"设计迁移**。
- **边界**:分区内的目录结构(`keel/ var/ overlayfs/ home/ nix/`)一个都没动 ⇒ 换槽/改名不丢状态;
  早期文档与旧日志里的 `/Volume` / `volume` 指的都是现在这套名字。

## D18 ESP 由我们自己挂,`systemd-gpt-auto-generator` 退场

- **决策**:`keel-mounts` 在启动早期扫 `PARTNAME=esp` 把 ESP 以 **rw** 挂到 `/boot`;
  kernel cmdline 加 `systemd.gpt_auto=no`;`lib.sh` 只承认"挂载表里的 ESP"或"确实是挂载点的路径",
  `bootctl --print-esp-path` 降级成兜底参考。
- **理由**:装机后的系统上实测 ESP 压根没挂上,而 `keel_esp()` 把 bootctl 的**猜测路径**
  (`/boot` 目录存在就报 `/boot`)当真 ⇒ 后面所有 UKI/bootctl 操作都在一个空目录上"成功":
  `os-status` 看不到任何 UKI、`os-update` 写不进新 UKI、`bootctl` 切不了槽、
  `keel-confirm` 确认不了槽 —— A/B 更新这条链整条是断的,而且**没有一处报错**。
  gpt-auto 挂 ESP 的前置条件有好几条(fstab 里有 `/boot` 条目、`/boot` 不为空、
  能读到 EFI 变量 `LoaderDevicePartUUID`…),任何一条不满足都只是"静默不挂" ——
  这种依赖不该由一个需要 100% 可用的功能来承担。
- **否决**:
  - 继续用 gpt-auto(静默失败模式太多,排查一次的成本已经证明不划算);
  - 给 ESP 打 `NoAuto=` GPT 标志位(systemd-repart 确实支持,但 `gpt_partition_type_knows_no_auto()`
    的白名单里**没有 ESP**,设了只会打印一行 warning);
  - 用 `/etc/fstab` 挂 ESP(fstab 会生成依赖 udev 设备单元的 `boot.mount` —— 正是坑 #24 的形状)。
- **代价**:ESP 路径固定成 `/boot`(gpt-auto 原来可能在 `/efi`);手工把 ESP 挂到别处的系统
  仍然靠 bootctl 兜底那一支。关掉 gpt-auto 后也不再有"根分区自动 rw 重挂/扩容"——
  我们的根是**故意**只读且定长的,不需要它。

## D16 命令命名

- **决策**:面向用户的命令用 `os-` 前缀:`os-status`、`os-update`、`os-install`、`os-rescue`;
  项目内部单元与目录用 `keel-` 前缀:`keel-*.service`、`/usr/lib/keel/`。
- **理由**:`os-` 好记、无 CLI 冲突;内部单元带项目前缀便于在 `systemctl` 输出里一眼认出归属。

## D20 v1 不做 Secure Boot / measured boot:`systemd-pcrlock` 单元 mask 掉

- **决策**:把 9 个 `systemd-pcrlock*` 单元(7 个服务 + socket + `@` 模板)
  **disable + mask 成 `/dev/null`**(preset 里 disable,`mkosi.postinst` 里建 mask)。
- **背景(2026-09 查清)**:这些是 systemd 上游单元,由**发行版自己的 preset** 挂进
  `sysinit.target.wants`(构建日志里能看到那 7 条 `Created symlink …`),不是我们启用的。
  它们预测/校验 TPM2 各 PCR 的测量值(固件代码/配置、Secure Boot 策略、文件系统、machine-id),
  给"把密钥封印到启动链上"(配合 `systemd-measure`)用。
- **为什么它们在实验环境里是红的**:mkosi 起的 QEMU **带 vTPM**(`qemu.py`:`TPM=auto` +
  tools tree 里有 swtpm ⇒ `-tpmdev emulator -device tpm-tis`),所以单元上的
  `ConditionSecurity=measured-uki` 通过、它们**真的执行**,又因为拿不到固件测量的
  event log / PCR 值而失败(6 个失败,只有不需要 PCR 值的 `lock-secureboot-authority` 成功)。
  即:这条红字与"有没有 TPM"无关,是"vTPM 没有真实测量链"。
- **理由**:v1 既没有 Secure Boot,也没有 TPM 封印的密钥,**没有任何东西依赖它们**;
  留着只会污染"启动后 `systemctl --failed` 应为空"这条检查项,而真机上的行为
  (可能成功、可能往 TPM NV 里写策略)完全未知。
- **代价**:将来做 Secure Boot / measured boot 时要记得解封 —— 已写进
  `docs/roadmap.md`,并在 `mkosi.postinst` 的注释里标了"解封是那个工作项的一部分"。
- **否决**:留着当"预期噪音"(会让"失败单元为空"这条检查失去意义);
  加更严的 `Condition`(条件已经是上游给的最严的那条,再收紧就会挡住将来合法的用法)。

## D21 账号模型:`admin` 是唯一交互账号,root 锁定

- **决策**:镜像里只建一个交互账号 `admin`(uid 1000,组 `sudo` + `video`/`audio`/`render`
  留待 desktop profile,家目录 `/home/admin`,shell `/bin/bash`);
  **初始密码 = 构建时 `-p <密码>` / 仓库根目录 `mkosi.rootpw` 给的那个值**;
  SSH 公钥(仓库根目录 `authorized_keys`)进 `/data` 骨架的 `home/admin/.ssh/`;
  **root 完全锁定**(`/etc/shadow` 里是 `!`)+ `PermitRootLogin no`;`sudo` **需要密码**。
- **实现要点**(顺序很关键):账号由 `mkosi.extra/usr/lib/sysusers.d/keel.conf` 交给
  `systemd-sysusers` 建(它在 finalize 之前跑);密码与公钥在 `mkosi.finalize` 里处理 ——
  mkosi 的 `--root-password=` 写在 **root** 的 shadow 条目里(并往 `/usr/lib/credstore/` 放
  `passwd.hashed-password.root`),所以最后一步把那个哈希**搬给 admin**、把 root 置成 `!`、
  再**删掉 credstore 里的 root credential**(不删的话 `systemd-firstboot.service` 每次启动
  都可能把 root 又解开 —— 它就是靠 `ImportCredential` 拿那个名字的;见 docs/traps.md 坑 #39)。
- **为什么敢把 root 完全锁掉**:`admin` 的账号在**镜像的 `/etc/passwd`(只读 lower)**里,
  它的密码哈希也在 lower 的 `/etc/shadow` 里 ⇒ 即使 `/data` 坏了、`/home` 是空的、`/etc`
  overlay 都没挂上,控制台**照样能以 admin 登录**(只是没有家目录、会有告警)。
  root 平时没有任何用途,留着只是多一个可被爆破的口令。
- **代价(要记住的)**:① 系统级后路只剩救援 U 盘(那是设计里本来就有的);
  ② 忘记在仓库里放 `authorized_keys`、又不给 `-p` 时,产物**登不进去** ——
  `mkosi.finalize` 会为这两种情况各打一条明确警告(选择"警告 + 继续"而不是"拒绝构建",
  因为"故意构建一个只能靠串口/救援盘进的无凭据镜像"是合法需求)。
- **否决**:
  - 保留 root 的控制台密码(与"禁用 root"相悖,而且上面那条已经证明不需要);
  - NOPASSWD(项目所有者拍板:sudo 要密码);
  - 首启用 credential 动态建号(绕远;而且密码不会落在 lower 的 `/etc/shadow` 里 ⇒
    丢掉"`/data` 坏掉也能登录"这条性质)。

## D22 系统标识:hostname `keel` / 时区 `Asia/Shanghai` / locale `C.UTF-8`

- **决策**:三个都用 mkosi 的原生设置(`Hostname=` / `Timezone=` / `Locale=`)写在
  `mkosi.conf.d/30-content.conf`;`mkosi.finalize` **逐个回读断言**(`/etc/hostname`、
  `/etc/localtime`、`/etc/locale.conf`),不对就让构建失败。
- **理由**:mkosi 在构建期用 `systemd-firstboot --force` 落地这三个文件(在 finalize 之前),
  所以它们和别的 `/etc` 内容一样在只读 lower 里 —— 机器专属的改动仍然走 `/etc` overlay。
  回读断言是必须的:坑 #29 的教训是 systemd 那批工具**把"我什么都没干"也当成功**。
- **locale 为什么是 `C.UTF-8`**:glibc 自带,不需要 `locales` 包、不需要 `localedef`,
  而 UTF-8 文件名/输出照常。`zh_CN.UTF-8` 要额外装包生成 locale 数据,留给 desktop profile。
- **时区依赖 `tzdata`**:`/usr/share/zoneinfo` 不在 Essential 里、也不被 systemd 依赖带进来,
  必须显式写进包清单;少了它时区会**静默**落回 UTC(所以 finalize 里那条断言是必要的,不是多余的)。
- **验证注意**:在 `mkosi vm` 里看时区**不能作为证据** —— mkosi 的 `qemu.py` 会往 guest 注入
  `firstboot.timezone=<宿主时区>` 与 `firstboot.locale=C.UTF-8` 两个 credential。
  判据是 `/etc/localtime` 指向哪、`/etc/locale.conf` 里写了什么。

## D23 `/data` 的磁盘预算、看门人与应急空间

- **决策**:
  1. **给每个消费者写死预算**:journald(`Storage=persistent`、`SystemMaxUse=256M`、
     `SystemKeepFree=2G`、`MaxRetentionSec=1month`);nix 由 `keel-nix-gc.timer` 每周
     `nix-collect-garbage --delete-older-than 30d` + `nix-store --gc --max-freed=2G`;
     `os-update stage` 成功后自动清旧载荷(保留最近 2 个版本 + pending);
     `os-rescue --reset-etc` 的 `etc.bak-*` 只留最近一份;`os-update fetch` 前先查可用空间。
  2. **看门人** `keel-data-guard.timer`(启动 3 分钟后 + 每天一次):把结论写进
     `/data/keel/data-guard.state`,`os-status` 显示。分级**按绝对字节数**:
     `< 2 GiB` 警告并回收 journal + nix;`< 512 MiB` 交还应急空间;`< 128 MiB` 连 OTA
     载荷也只留最新一份。小于 4 GiB 的 `/data`(live 镜像)只看不治。
  3. **应急空间**:`keel-firstboot` 在空间宽裕时 `fallocate` 256 MiB 到
     `/data/keel/.reserve`,临界时由看门人删掉它,换一次"还能把 machine-id / SSH 主机密钥
     写下去"的机会;用掉后留一条 `/data/keel/reserve-consumed` 记录,空间恢复后自动重建。
- **理由**:坑 #37 已经证明 **`/data` 写满 = `/etc` 也写不进去**(overlay 的 upper 在同一个
  文件系统上)⇒ machine-id 固化失败 ⇒ DHCP/IPv6/DNSSEC 一起坏(坑 #29 复活),
  SSH 主机密钥、sysusers、tmpfiles 一起失败。所以这不是"省空间",是**可用性**问题。
- **为什么按绝对字节而不是百分比**:在 500 GB 的盘上"剩余 2%"是 10 GB,根本不算紧张 ——
  百分比会骗人。
- **边界**:看门人只清**可再生**的东西(旧日志、nix 垃圾、下载回来的 OTA 载荷);
  `/home`、`/etc` overlay 的 upper、`/data/keel` 一律不碰。
- **否决 / 留待以后**:
  - ext4 project quota(要 `prjquota`、动 mkfs 参数与挂载选项,复杂度不值);
  - 现在就加一个 `cache` 分区把 `/nix` 与 journal 挪出去(结构性做法,只增分区可以后加;
    已写进 `docs/roadmap.md`,等真机用一段时间、看清增长曲线再定);
  - 用百分比阈值(见上)。

## D24 cmdline 加 `panic=-1`(自动回滚的前提)

- **决策**:`KernelCommandLine=` 里加 `panic=-1` —— 内核 panic 时立即重启,而不是停下来等人。
- **理由**(2026-09 演练确认):v1 的回退机制是"候选槽那次启动失败 ⇒ 下次启动回到持久默认
  (旧槽)",其中"下次启动"必须**真的发生**。没有这一行时,新槽 panic 会让机器停在黑屏,
  一次失败就变成一次停机;而 A/B 的承诺是"新版本起不来就自己退回旧版本"。
  候选槽只用 `set-oneshot` 试**一次**(坑 #43),所以"这次失败还会再启动"就更加关键 ——
  one-shot 在引导时被引导器消费掉,只要机器还能再启动,就一定会回到旧槽。
- **代价**:panic 的现场一闪而过(屏幕/串口来不及看)。要留证据得靠 pstore/ramoops(以后的事);
  日常定位靠三样东西:那次启动在 journal 里留下的记录、`os-status` 的 `last_result=failed`、
  ESP 上被改名成 `keel-<槽>+N.efi.failed` 的 UKI。
- **否决**:不加、靠人工按电源键(那就不是"自动"回滚了);
  用 `panic=<秒数>` 留观察窗口(能看一眼,但"自动"变成了"几秒后才自动",而且屏幕上的字
  在真机上通常来不及看清——真要看现场,正确的工具是 pstore 而不是延迟重启)。

## D25 启用运行时看门狗(`RuntimeWatchdogSec=60`),覆盖"挂住"这一类失败

- **决策**:主镜像与 **initrd** 各放一份 `systemd.conf.d` 配置(`RuntimeWatchdogSec=60`、
  `RebootWatchdogSec=10min`),并加载内核软件看门狗 `softdog` 兜底没有硬件看门狗的设备。
- **理由**(2026-09 演练实测,坑 #50):自动回滚依赖"失败之后机器**还会再启动**",而失败分两类:
  * **panic** ⇒ `panic=-1` 立即重启(决策 D24)✓;
  * **挂住**(卡死/冻结/等一个永远不来的东西)⇒ 没有任何代码会跑,**只有看门狗能复位**。
  演练里的坏槽正好是第二类:根镜像坏掉时 initrd 停在
  `[!!!!!!] Switch root target contains no usable init.` 然后**永久冻结** ——
  不 panic、不重启、不返回;机器就停在黑屏,回退永远不会发生。
- **实现要点**:冻结的是 **initrd 里的 PID1**,而 initrd **不读主镜像的 `/etc`**
  (mkosi 的 `mkosi.extra/` 不进 initrd,坑 #1 的旁证)⇒ 必须在 `mkosi.initrd.conf` 里
  用 `ExtraTrees=mkosi.extra-initrd` 单独塞一份。两份内容靠 `tools/verify.sh` 核对一致。
- **代价**:正常启动的早期阶段要在 60 秒内喂到第一次狗(远用不到),卡住时人要等一分钟;
  看门狗复位**不写 journal**(相当于硬断电),所以"那次失败"的证据仍然只有
  引导计数/`.failed` 条目与 `last_result=failed`。
- **实测结果(2026-09,分两半说)**:
  * 主系统这一半**生效**:演练快照里 `RuntimeWatchdogUSec = 1min`、
    `/dev/watchdog /dev/watchdog0 /dev/watchdog1` 都在 ⇒ 用户态的挂死/卡住会被复位;
  * **initrd 这一半没生效**:把候选槽做成"没有可用 init"之后,initrd 冻结,
    机器挂住 **650+ 秒没有被复位**(那次演练只能人工终止)。
    原因是配置没真正进 initrd,还是 initrd 里没有 `/dev/watchdog` **还没查清**
    —— 我们那份"从 UKI 抽 `.initrd` 再查文件名"的检查本身也可能误报(和坑 #47 同一类问题)。
  ⇒ 结论:**v1 不承诺覆盖 initrd 阶段的冻结**;这条已知限制记在 `docs/roadmap.md` 3.0,
  下一步是先把"配置到底进没进 initrd / initrd 里有没有看门狗设备"这两件事查实。
- **否决**:只依赖 `panic=-1`(覆盖不到挂住;这正是演练暴露的问题);
  不启用看门狗、靠人发现(那就不是"自动"回滚)。

## D26 启动失败看门狗:没到 `boot-complete` 就自动重启(第三类失败的兜底)

- **决策**:新增 `keel-boot-failed-reboot.service`(`WantedBy=emergency.target rescue.target`):
  如果这次启动**没到过 `boot-complete`**(判据:`/run/keel/boot-complete` 标记,由
  `keel-confirm` 在达成时写下),就在控制台醒目提示、等 **60 秒**、然后 `systemctl reboot`
  ⇒ 引导器走持久默认(旧槽)⇒ 旧槽上的 `keel-confirm` 判定"更新失败已回滚"。
- **理由**:"新槽起不来"有三类,兜底机制完全不同(2026-09 实测,坑 #50):
  1. **panic** ⇒ `panic=-1`(决策 D24)✓
  2. **冻住**(PID1 不再喂狗)⇒ 运行时看门狗(决策 D25)✓(主系统实测生效)
  3. **进 emergency/rescue 等人按键** ⇒ **本决策**。这一类系统是"活的":PID1 健康、还在喂狗,
     所以前两道都不会动作 —— 机器停在 `Press Enter for system maintenance` 前,
     回退永远不会发生。而它恰恰是**最常见**的软失败(某个单元坏了、文件系统没挂上、配置写坏)。
- **可干预**:提示里明确写了取消方式(`systemctl stop keel-boot-failed-reboot`)——
  emergency 里本来就有 shell,所以"停下来排查"这条路依然走得通,只是需要**明确说一声**;
  60 秒的等待窗口也是为这个留的。
- **代价**:真出问题时机器默认会重启(而不是停在提示符等你)。这是项目所有者拍板的取向:
  目标是服务器(无人值守、尽量避免手工重装),所以"自己退回上一个好版本"优先于"停下来等人"。
- **不覆盖**:initrd 阶段的冻结(`Switch root target contains no usable init.`)——
  那时根里的单元根本还没机会跑,已记 `docs/roadmap.md` 3.0。
