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

- **决策**(2026-09 修订):`/var`、`/root` 用**符号链接**指向 `/Volume`;
  **`/home` 与 `/nix` 用真目录 + bind mount**。
- **理由**:尊重"根目录留软链接"的原始设计意图,能链接就链接(少一层挂载、少一处启动期依赖);
  但这两个目录**必须**是真实挂载点:
  - `/home`:符号链接会让 `ProtectHome=` 这类沙箱设置失效(服务仍能经 `/Volume/home` 摸到用户数据);
  - `/nix`:`nix` 硬性拒绝符号链接的 store 路径 ——
    `error: the path '/nix' is a symlink; this is not allowed for the Nix store and its parent directories`
    (装机后实测,见 `AGENTS.md` 坑 #34);而 store 位置搬不动(二进制与脚本把 `/nix/store/…`
    写死在 ELF interpreter 与 RPATH 里),只能让 `/nix` 本身是真目录。
- **关键约束**:符号链接无法参与挂载顺序约束 ⇒ `/Volume` 必须极早挂载(见 D4)。

## D4 `/Volume` 的挂载时机

- **决策(2026-09 修订)**:由 `keel-mounts.service`(initrd 之后、`sysinit` 之前)自己扫
  `/sys/class/block/*/uevent` 的 `PARTNAME=volume` 找到分区并挂载,`blkid -t LABEL=volume` 兜底。
  不经过 udev、不生成 `.mount` 单元。
- **原决策(已推翻)**:写进 UKI 的 kernel cmdline:
  `systemd.mount-extra=PARTLABEL=volume:/Volume:ext4:rw,noatime`。
  当时的理由是"`systemd-fstab-generator` 在主系统和 initrd 里都会解析它,initrd 里自动加 `/sysroot/` 前缀"。
- **推翻原因(真机 VM 实测,`AGENTS.md` 坑 #24)**:这两条理由都不成立 ——
  initrd 阶段根本没有生成 `/sysroot/Volume`(initrd 里连我们的文件都没有);
  主系统阶段它生成的 `Volume.mount` 要等 udev 建 `by-partlabel` 符号链接,而 udev 要等
  `systemd-sysusers`、sysusers 要可写的 `/etc`、可写的 `/etc` 又挂在 `/Volume` 上 ⇒ 环形依赖 ⇒
  systemd 丢掉 `local-fs-pre.target`、udev 被推到 emergency 之后、挂载 90 秒超时 ⇒ emergency mode。
- **仍然否决**:靠 `/etc/fstab` + `x-initrd.mount`(需要把 fstab 注入 initrd 树,多一层构建魔法);
  靠普通 systemd `.mount` 单元(依赖 udev,同一个环)。

## D5 `/etc` 必须可写,用 overlayfs

- **决策**:lower = 只读镜像的 `/etc`,upper/work = `/Volume/overlayfs/etc/{upper,work}`。
- **理由**:`/etc` 有大量必须可写的硬需求 —— `machine-id`、ssh 主机密钥、
  `passwd/group/shadow/subuid`、`nix.conf`(换镜像源是刚需)、NetworkManager/sysd-networkd 配置、
  `localtime`/`hostname`/`locale.conf`。只读 `/etc` 直接不可行。
- **否决**:把 `/Volume/etc` 整体 bind 到 `/etc` —— 那是一次性快照,新版本镜像里 `/etc` 的任何改进
  会被旧副本**永久遮蔽**,而且没有合并机制。
- **否决**:每槽独立的 `/etc` upper —— 每次更新都要重新配置一遍,体验不可接受。共享 upper 的代价
  (新版本可能写了旧版本不认识的 `/etc` 文件)用 `os-rescue --reset-etc` 兜底。

## D6 加密

- **决策**:不做。
- **理由**:当前是笔记本 + 未来是服务器,先不做;LUKS 会把 initrd 与 /Volume 的挂载链一并复杂化。
  要做的话是独立的一次设计(需要把密钥/TPM 纳入启动链)。

## D7 nix 的来源与位置

- **决策**:用 Debian 官方包 `nix-bin` + `nix-setup-systemd`;`/nix` 通过符号链接落在 `/Volume` 上;
  nixbld 用户与 `/nix` 骨架在**构建期**烤进镜像(不依赖首启时的网络或写 `/etc` 的时序)。
- **理由**:发行版打包 = 可直接由 mkosi 在构建期安装、可复现、带 systemd 单元与 sysusers/tmpfiles,
  比"构建时 curl 官方安装器"干净得多。
- **否决**:官方 curl 安装器(构建期联网、非幂等、把状态写进 /nix 之外)。

## D8 更新器:门面自研 + 机制用 systemd

- **决策**:`os-update` 是我们的**门面**(策略/迁移/保留/报告);下载、验签、版本比较、
  写分区交给 `systemd-sysupdate`;槽切换用 `bootctl set-preferred`;成功判定与回滚用
  boot counting + `systemd-bless-boot.service`。
- **理由**:"绝对不能出错"的部分(写分区、回滚判定)复用被大量发行版验证过的代码;
  "必须贴合本架构"的部分(schema 迁移、保留策略)自己写。门面模式还保证:
  若 sysupdate 的分区匹配语义不合适,只换底层,接口不变。
- **否决**:纯自研(下载/校验/回滚轮子自己造,bug 代价最大);
  RAUC(引入 daemon + bundle 格式 + 另一套状态机,与 systemd-boot 的回滚机制重复)。

## D9 swap

- **决策**:`/Volume/keel/swapfile`,首次启动创建并启用(mkswap + swapon)。**不做休眠**。
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
  机器差异进 `machines/*.conf`;单机运行期状态进 `/Volume`。
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
  运行时改不了(后门见 `AGENTS.md` 已知的坑 #4)。

## D14 GPU 驱动:不进 main,外置方案定为 v1.5

- **决策**:main **不带任何 GPU 驱动**;将来做 `desktop` profile 时,开源栈(i915/amdgpu + mesa +
  拆分的固件包)进基底,而 NVIDIA 专有驱动走"第三方内核模块外置"方案
  (把 `/usr/lib/modules/<kver>` 在启动早期叠一层 upper 在 `/Volume` 的 overlay,
  镜像里保留发行版模块作保命底线);`server` profile 则完全不需要驱动(GPU 直通给 VM)。
- **理由**:nix **装不了**内核模块 —— nixpkgs 的 `nvidia_x11` 是针对 nixpkgs 自己的内核编译的,
  与 Debian 内核的 vermagic/符号 CRC 不匹配,`modprobe` 会直接拒绝。所以"驱动怎么装"和"驱动放哪"
  是两个独立问题:驱动必须由镜像构建流水线产出(构建期 DKMS),但**放哪**可以自由设计。
  外置方案的额外好处:模块按内核版本分目录,回滚到旧槽时旧内核的驱动仍在 `/Volume` 上。
- **否决**:用 nix 装内核模块(原理上不可行);把整个 `/usr/lib/modules` 直接搬到 `/Volume`
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

## D16 命令命名

- **决策**:面向用户的命令用 `os-` 前缀:`os-status`、`os-update`、`os-install`、`os-rescue`;
  项目内部单元与目录用 `keel-` 前缀:`keel-*.service`、`/usr/lib/keel/`。
- **理由**:`os-` 好记、无 CLI 冲突;内部单元带项目前缀便于在 `systemctl` 输出里一眼认出归属。
