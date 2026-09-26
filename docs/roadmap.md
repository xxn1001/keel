# keel 路线图:v1 之后要做的事

> 这里只放**已经想清楚、但 v1 刻意不做**的事。每条都写清:为什么现在不做、做的时候要注意什么。
> v1 的已知限制写在 [`release-notes-v1.md`](release-notes-v1.md)(并随构建进入 `dist/keel-<版本>/`)。
> 决策与理由见 [`decisions.md`](decisions.md),踩过的坑见 [`AGENTS.md`](../AGENTS.md) §3。

## 0. 版本计划(v1.1 / v1.2 / v2.0,2026-09 拍板)

原则:**先把功能/运维的补齐(v1.1),再做安全(v1.2),最后动结构(v2.0)** —— 结构一动就要迁移,
而迁移执行器本身还没写,所以结构类的事必须排在最后、并且互相依赖。

| 版本 | 主题 | 内容(对应下面的条目) | 粗估 |
|---|---|---|---|
| **v1.1** | 功能与运维 | **① ✅ erofs 只读根(2.9,已完成:载荷 6 GiB → 401 MiB,`dist/`、演练 qcow2 增长一起变小)** → ② ESP 余量 + `.failed` 条目清理 → ③ 更新**检查**(默认只 check + 通知,**不自动装**)→ ④ `os-install` 两个 TODO(2.7)→ ⑤ 演练/开发的磁盘占用收紧(live 镜像 truncate 尺寸可配)→ ⑥ 原生/rootless 构建实测并写进文档 | 不赶时间,分多次 |
| **v1.2** | 安全 | **更新签名**(1.1)→ **Secure Boot**(1.2,含 UKI 签名、自己的密钥库、解封 `pcrlock`);initrd 冻结修复(3.0) | —— |
| **v2.0** | 结构与可信 | **迁移执行器**(2.8,先做,它是下面一切的前提)→ **`/data` 加密 + TPM 封印**(1.3)+ **dm-verity**(1.4)+ **早期启动重排**(把 `/etc` overlay 提到 initrd,见 D19 方案 A —— **它才是 #24/#29/#37/#61 四条的真正解法**)→ 可选:`systemd-sysupdate` 底层(2.5)、`cache` 分区(2.4)、`server` profile(2.2) | —— |
| 不排期 | 等上游 / 可选 | "连续三次"试用语义(2.5b,等 Debian 的 systemd ≥ 261)、`desktop` profile(2.1)、`/usr/lib/modules` 外置(2.3)、`machines/`(3.4) | —— |

**为什么 erofs 排在第一位**(2026-09 调整):验证用的服务器盘一共只有 100 GB,分给开发 VM 的是
80–90 GB,而**当前形态一次构建就会产出 60 GiB 逻辑(`mkosi.output/`)+ 27 GiB 逻辑(`dist/`)**、
演练时 guest 还会真写真占 13 GiB 载荷 —— 磁盘是这套流程里最紧的资源。erofs 一次改动同时缓解三处:
根载荷(6 GiB → 约 1.5–2 GiB)、`dist/` 与 `mkosi.output/`、演练里 qcow2 的增长。
**载荷压缩(`CompressOutput=zstd`)因此降级成备选**:如果 erofs 那条路被某个前置挡住,再回退到
"先压缩、后换格式"。

三条**顺序上的硬约束**(别调换):

1. **自动更新必须排在签名之后**:v1.1 的定时器只做"检查 + 通知";等 v1.2 有了签名,才谈得上
   自动 fetch/stage —— 否则等于让机器自动从"只靠 sha256"的源取货。
2. **verity 不能单独做**:dm-verity 的收益依赖"roothash/签名本身被信任"(Secure Boot)与
   "`/etc` 不可变"(D19 方案 A/B),必须和 v1.2/v2.0 那两件事合成一轮。
3. **erofs 要先于"slot 尺寸常量"的任何改动**:根换成 erofs 之后内容会小很多,那时再讨论
   "新机器要不要把 6 GiB 槽位改小"(老机器不变、两种尺寸都能吃同一份载荷)才有意义。

## 1. 安全(目前 v1 明确不做)

| # | 事项 | 现在为什么不做 | 动手时要一起改什么 |
|---|---|---|---|
| 1.1 | **更新载荷签名**(`manifest.sig` 真验签) | v1 的更新**手动触发**、源由用户自己配;先把"更新链路本身"跑通。代码里已经有接口:`os-update fetch` 见到 `manifest.sig` 就用 `/usr/share/keel/update-key.pub` 验签,公钥缺失时直接报错、不静默降级 | ① 决定密钥放哪(烤进 UKI 凭据区 / 单独一个小分区 / 首次配置);② 提供 `tools/sign.sh` 生成与轮换密钥;③ 密钥轮换路径(载荷里带 key id);④ 写进 `docs/update.md` §6 |
| 1.2 | **Secure Boot** | 需要自己的密钥 + 签名 UKI + 处理固件密钥库;开着还会关掉"引导菜单里按 `e` 改 cmdline"这条调试通道(`docs/traps.md` 坑 #4) | 引导链:用 `systemd-shiim`/自签 `db` 签 UKI;同时**解封** `systemd-pcrlock*`(决策 D20 把它们 mask 掉了 —— 解封是这一步的一部分);`tools/verify.sh` 要加"解封了没有"的断言 |
| 1.3 | **TPM 封印的密钥**(LUKS / `/data` 加密) | v1 的 `/data` 是**不加密**的(决策 D6):机器被拿走/退役,数据就没了(服务器上这条同样是硬伤) | 与 1.2 一起做:`systemd-cryptenroll` + `pcrlock`/`systemd-measure` 把密钥封印到启动链;`/data` 换 LUKS 会**改分区布局** ⇒ 必须按"只增不破"迁移(不变量 6) |
| 1.4 | **dm-verity 校验根分区** | 与"每台机器的 `/data` 迁移/机器专属字节"冲突(决策 D19 方案 D 已否决) | 需要先把"根镜像逐字节可校验"这条保住:任何往根里写机器专属数据的设计都要先排除 |

## 2. 系统功能

| # | 事项 | 说明 |
|---|---|---|
| 2.1 | **`desktop` profile(可选)** | **不是主线**:只在「笔记本兼任」这个场景下有用。笔记本日常用需要 Wi-Fi 固件 + NetworkManager(或 networkd 的 wpa_supplicant 路径)、GPU 固件/驱动、字体、桌面环境。桌面软件走 nix(不变量 7),但**固件与内核模块必须在基底**。做的时候顺手把 admin 加进 `video`/`audio`/`render` 组(决策 D21 里刻意留到那时) |
| 2.2 | **`server` profile** | 虚拟化宿主(GPU 直通):`vfio-pci` 绑定、KVM、libvirt 走 nix;cmdline 里的 `iommu=pt` 等已经是机器无关超集(§5.1) |
| 2.3 | **`/usr/lib/modules` 外置模块** | 为"第三方内核模块不进基底"做准备:把 `/usr/lib/modules/<kver>` 挂 overlay 后 `depmod` + 模块加载是否成立(`architecture.md` §13.1 待验证第 3 条) |
| 2.4 | **`cache` 分区** | 把"可丢弃的缓存"(`/nix` store、journal)与"不可丢的状态"(`/home`、`/etc` upper、`/data/keel`)物理分开。只增分区即可(不变量 6 允许);决策 D23 里先做了预算 + 看门人,等真机用一段时间看清增长曲线再定 |
| 2.5 | **`systemd-sysupdate` 换掉"直接写盘"** | `os-update` 是门面,底层可替换(决策 D8)。要先验证 `Type=partition` 对双槽布局的匹配语义,再换 |
| 2.5b | **恢复"连续三次"的试用语义** | 原设计用 `bootctl set-preferred`(感知 boot assessment),但 Debian trixie 的 systemd 257 没有这个动词,现在用 `set-oneshot` **只试一次**(坑 #43)。等基底 systemd ≥ 261(或 Debian 把补丁回移)再换回去:改 `lib.sh` 的 `keel_boot_candidate()`,并在 VM 里复验"连续失败三次才回退" |
| 2.6 | **自动更新定时器** | v1 刻意手动触发(`docs/update.md` §8),便于在笔记本上边用边观察;之后可以按"检查频率 + 只下载不安装"的保守策略加 |
| 2.7 | **`os-install` 的两个 TODO** | ① 根文件系统实际占用超过目标分区尺寸时的截断检查;② `keel-confirm` 的 pending/running_slot 边界 |
| 2.8 | **`/data` schema 迁移执行器**(v1 明确不做) | v1 的行为是:带 `migrate=` 的载荷被 `fetch` **拒绝**(坑 #48),布局冻结在 schema 1。要做的时候:① 定义 manifest 的迁移语法(只增不破的 mkdir/权限/文件);② 想清楚 `schema`(载荷要求的布局版本)与 `schema_min`(载荷还能读的最低版本)的区别 —— 现在 `fetch` 那句 `schema > 本机 ⇒ 拒绝` 与"由旧系统迁移"的语义是**互相矛盾**的,得先理顺;③ 在 VM 里按 §4 演练(含**回滚**到旧版本后旧系统仍能读 /data);④ 第一次真实迁移前不要动布局 |

## 2.95 已复核:控制台日志级别与日志落盘(D27 / 坑 #61)

| # | 事项 | 结果(2026-09-25,项目所有者在自己机器上实跑构建 + 首启) |
|---|---|---|
| V1-a | `kernel.printk = 4 4 1 7` 与 `keel-mounts` 的三个 `Before=` 在产物与运行系统里 | ✅ 产物 `slot-a.root.raw` 里两份文件都在(drop-in 权限 0644);运行中 `cat /proc/sys/kernel/printk` = `4 4 1 7` |
| V1-b | **日志落盘** | ✅ `/var/log/journal/*/` 有 `system.journal` + `user-1000.journal`;`journalctl --list-boots` 能看到 **-2 / -1 / 0** 三次启动 |

> 这两条是 v1 标签之前的最后一块证据;机制层面(手工 `sysctl -w` / `journalctl --flush`)与
> 端到端(构建产物 + 首启)现在都验过了。

## 2.9 erofs 只读根(v1.1 第一件;D2 的"升级 A")

**目标**:根分区从 `ext4` + cmdline `ro`(策略只读)换成 **erofs 镜像**(结构上不可写 + 压缩)。
顺带把载荷/产物/演练的磁盘占用压下来(见 §0 的说明)。

**要动的地方(已经想清楚的清单)**:

| # | 事项 | 状态 / 说明 |
|---|---|---|
| 1 | **载荷**侧(`repart/slot-{a,b}/10-root-*.conf`):`Format=ext4` → `Format=erofs` + 解除尺寸钉死 | ✅ **已做**:`Format=erofs` + `Minimize=yes` + `SizeMinBytes=64M`,**不写 `SizeMaxBytes`**。`SplitName`/`Label`/`Type=` 未动 |
| 1b | **安装布局**侧(`repart/install/10-root-a.conf`、`20-root-b.conf`)保持 `SizeMin=SizeMax=6G` | ⚠ **比原计划多一个约束**:`10-root-a.conf` 换成 `Format=erofs`(装出来的根才是 erofs);但 `20-root-b.conf` **不能写 Format=** —— systemd-repart 拒绝格式化没有源文件的 erofs:`Cannot format erofs filesystem without source files, refusing.`(空槽没有 `CopyFiles=`)。所以空槽**留未格式化**。这反而更好:第一次更新写 erofs 时分区里没有旧签名 |
| 1c | **运行时 repart 定义**(`mkosi.postinst` 装进镜像的那份) | ⚠ **新发现的硬约束**:它按坑 #31 去掉了 `CopyFiles=`,于是 root-a 的 `Format=erofs` 会让 **`os-install` 建表直接失败**。⇒ postinst 生成时**同时去掉 `Format=erofs`**;`tools/verify.sh` 的运行时模拟必须与 postinst 逐字同源,并断言两边一致(否则 verify 全绿、真实装机失败)。槽根不需要在这里格式化:root-a 被 live 根 dd 覆盖,root-b 等首次更新 |
| 2 | 构建侧要有 `mkfs.erofs` | ✅ 已确认:mkosi 的 Debian **tools tree 自带 `erofs-utils`**(构建期不用额外配置)。**但镜像里必须显式加 `erofs-utils`** —— 格式化发生在运行时的 `os-install`,与坑 #32(dosfstools)同一个形状。已加进 `mkosi.conf.d/20-packages.conf` + verify 断言 |
| 3 | **initrd 必须能挂 erofs** | ✅ **已实测确认**(不用起 VM):mkosi 默认 initrd 里带 `erofs.ko.xz`。方法见坑 #63:`objcopy --only-section=.initrd` + 按 zstd 魔数切帧(`.initrd` 是**多帧**的,`zstd -dc` 只解第一帧)+ `cpio -it`。另外 `docs/decisions.md` D2 里"ext4 是内核内建"的说法**是错的**(`CONFIG_EXT4_FS=m`,v1 靠 initrd 里的 `ext4.ko` 才起来),已更正 |
| 4 | `keel-check` / `os-status` / `os-update` 里对根文件系统的假设 | ✅ 已审计:唯一的"分区 vs 文件系统尺寸"比较是 **`/data`**(仍 ext4,不变);根只有一条"挂载选项含 `ro`"的断言,erofs 天然通过。**顺带**:`os-update fetch` 的空间预算原本按 13 GiB 写(两个 6 GiB 根镜像),已改成 erofs 的保守上限(硬下限 6 GiB / 警告线下 10 GiB) |
| 5 | slot 尺寸常量 | **本次不动**(不变量 9);等 erofs 落地后再讨论"新机器是否改小"(见 §0 硬约束 3) |
| 6 | 文档 | ✅ `architecture.md` §3.1/§3.2/§3.3、`decisions.md` D2(含"ext4 内建"更正)、`AGENTS.md` 不变量 1、`docs/install.md`、`docs/update.md`、`docs/traps.md` 坑 #63 |
| 7 | **遗留**:OTA 演练(`--drill`)的**坏槽构造** | ⚠ **未做**。它用 `debugfs` 删 PID1 / 改 `default.target`,而 `debugfs` 是 ext4 专用、对 erofs 打不开 —— 且它**对打不开的文件也返回 0**(坑 #47),会"成功"产出**根本没坏**的载荷 ⇒ 回滚演练变假绿。现在加了**守卫**:认到 erofs 超级块魔数(`e2e1f5e0`)就明确失败,不去猜。erofs 版坏槽构造要单独设计(提取/重打包会**丢 setuid 位**,不是加两行就行) |

**验证计划与结果(2026-09-26 全部实测通过;Debian 13 构建机 + libvirt 40 GiB 目标盘)**:

| # | 验证 | 结果 |
|---|---|---|
| 0 | **基线**(改前的 ext4 树) | `slot-{a,b}.root.raw` = **6,442,450,944 B = 6 GiB**(被 `SizeMaxBytes=6G` 钉死);一份载荷(2 根 + 2 UKI)= **13.2 GiB** |
| 1 | libvirt 整盘装机 → 首启 → `sudo ~/keel-check` | ✅ **49 通过 / 0 失败 / 1 警告 / 4 跳过**。`findmnt /` = `/dev/vda2 erofs ro,relatime,user_xattr,acl,cache_strategy=readaround`;ESP、`/etc` overlay、`/data`、失败单元为空全部照旧。那 1 条警告是"admin 家目录没有 authorized_keys"(构建用了 `-p`,与 erofs 无关) |
| 2 | `os-update` 一轮(含回滚) | ✅ `check`(0839 > 0826)→ `fetch` **1.1 GiB / sha256 全对** → `stage`(**401 MiB dd / 5.2 s** 进此前**未格式化**的槽 b)→ 重启进槽 b:`/dev/vda3 **erofs**`、`last_result=success`、`keel-b+3.efi` 被 bless 成 `keel-b.efi` → `rollback` → 重启回槽 a(版本回退、`last_result=failed`) |
| 3 | **老机器 ext4 → erofs 迁移** | ✅ 见 §2.9.1 |
| 4 | 体积前后对比 | ✅ `slot-<x>.root.raw`:**6 GiB → 401 MiB**(约 **15×** 小);一份载荷 **13.2 GiB → 1.1 GiB**;`os-update fetch` 实测从 13 GiB 降到 **1.1 GiB** |
| 5 | initrd 能挂 erofs(`root=` **不带** `rootfstype=`) | ✅ 两层证据:① 拆 UKI 的 `.initrd` 确认里面有 **`erofs.ko.xz`**(方法见坑 #63);② live 与装好后的系统都实测 `findmnt /` = `erofs`,cmdline 是 `root=PARTLABEL=root-{a,b}`,`grep -c rootfstype /proc/cmdline` = **0** |

### 2.9.1 迁移实测详情(本次最大的不确定点)

**担心的是什么**:`os-update stage` 是 `dd` 镜像进分区,只覆盖前 401 MiB;老机器那个 6 GiB 分区里
**残留着 ext4 的备份超级块**(块组边界,128 MiB 一个;镜像盖不到的那些还在)。
如果 udev/libblkid 按备份超级块把它认成 ext4,候选槽就挂不起来 ⇒ 迁移失败。

**实测分两步**:

1. **离线试验**(在构建机上,不用 VM):6 GiB 文件 `mkfs.ext4` → 上面 `dd` 一个只有 **200 MiB** 的
   erofs(远小于真实载荷 ⇒ 留下**更多** ext4 备份超级块,比实际情况更苛刻)⇒
   `blkid -p -o value -s TYPE` 报 **`erofs`**;`wipefs` 也只看到 `0x400 erofs`。
2. **端到端**:造一台**根还是 ext4** 的老机器(Build A / v1,版本 0755,`root-a` 与 `root-b`
   **都是 ext4**)⇒ 在它上面用**它自带的那份 v1 `os-update`**(`grep -c erofs /usr/bin/os-update` = 0,
   确认没有偷换新代码)`fetch` + `stage --reboot`,把 erofs 载荷写进 ext4 的 `root-b` ⇒
   重启后 `findmnt /` = **`/dev/vda3 erofs ro`**、cmdline `root=PARTLABEL=root-b`、版本 0839、
   `last_result=success`、`keel-b.efi` 已 bless。**`root-a` 仍是 ext4(没被碰),`root-b` 变成 erofs。**

**结论**:**不需要**给 cmdline 加 `rootfstype=erofs` —— 内核按魔数探测就够(erofs 的超级块在
offset 1024,正好覆盖掉 ext4 的**主**超级块;主块没了,ext4 的探测就失败)。
**同名(`Label=`)、尺寸更小的 erofs 载荷,老机器可以直接吃下去。**

## 2.10 **已否决**:用 `/usr/etc` + `/data/etc` 三方合并取代 `/etc` overlayfs(2026-09-26 评估 → **废案**)

**提案**(项目所有者):镜像的默认 `/etc` 生成到 `/usr/etc`;启动时把 `/data/etc` bind 到 `/etc`;
"用户改过的用用户的、没改过的用 `/usr/etc` 的默认值" —— 参考 Fedora CoreOS / rpm-ostree 的
`/etc` 三方合并,目标是消掉 overlayfs 带来的一堆坑。**下面只评估,不动代码。**

**结论(三句话)**

1. **overlayfs 其实已经是那个"合并"**:`lower = 当前部署的 /etc`(默认值)、
   `upper = /data/etc`(用户改动)⇒ "改过的用用户的、没改过的用当前默认值"这条语义**已经有了,
   而且不需要合并执行器**。所以提案的收益不在"合并",而在"**去掉 overlay 这个机制**"。
2. **按字面实现会重新引入 D5 否决过的坑**:bind 挂载**没有 lower**,未被改动的默认值必须
   **materialize** 到 `/data/etc`。若只是"装机时拷一份、以后缺什么补什么",那仍是一次性快照 ——
   新版本对默认值的**改动**会被旧副本永久遮蔽(正是 D5 否决 bind 的理由)。
   真要做到"用户没改过 ⇒ 采用新默认值",必须有**三方合并**(需要 base = **上一版部署的默认值**),
   也就是要**新写一个合并执行器** —— 正是 roadmap 2.8 那件还没做的事。
3. **最贵的四条坑不是 overlay 造成的**:见归因表 —— #24/#29/#37/#61 的根因是
   "可写 `/etc` 依赖 `/data`、而且挂得太晚(PID1 已经读过 /etc)"。**换成 bind 一模一样。**
   靠"去掉 overlay"能真正消掉的只有 #8 的机制部分与 `os-rescue --reset-etc` 那一套。

**坑的归因(逐条)**

| 坑 / 机制 | 根因 | 换 `/usr/etc` + bind 会消失吗 |
|---|---|---|
| #8 `/etc` overlay 挂载时机 + `daemon-reload` | overlay 机制(upper 里的 unit 要 reload) | **部分**:reload 的需求来自"PID1 先读了旧 /etc",bind 也一样要 |
| `os-rescue --reset-etc`(flag + `etc.bak-*` + workdir 重建 + 备份保留) | **纯 overlay**(upper/work 概念) | ✅ 消失(退化成 `rm -rf /data/etc`) |
| `keel-check`/`os-status` 的"`/etc` 是 overlayfs"断言、`/data/overlayfs` 骨架 | 纯 overlay | ✅ 消失(改成断言挂载点) |
| #24 早期启动环形依赖(`/etc` 可写 ⇒ `/data` ⇒ 不能依赖 udev) | **依赖顺序** | ❌ 不消失 |
| #29 / D19 machine-id(PID1 在挂载前读到 `uninitialized`) | **挂载太晚** | ❌ 不消失 |
| #37 / 不变量 10(`/data` 满 ⇒ `/etc` 写不进去) | upper 在 `/data` 上 | ❌ 不消失 |
| #61 sysctl/journald/journal-flush 必须排在 `keel-mounts` 之后 | **挂载太晚** | ❌ 不消失 |

**要动的东西(如果做 —— 这就是"跨度")**

- **构建期**:`mkosi.finalize` 把整棵 `/etc` 搬到 `/usr/etc`,镜像里 `/etc` 只剩一个 bind 点。
  量很小(实测:`/etc` = **150 个文件 + 425 个符号链接,共 3.6 MB**),**难的是** Debian 的
  postinst / debconf / ucf / `alternatives` 全都假设 `/etc`,而且必须在**所有会写 `/etc` 的步骤之后**搬。
- **启动期**:`keel-mounts` 改成 bind + **合并**;合并需要 base(`/data/keel/etc-base/<版本>` 或
  ostree 式的部署级快照),而且要在**挂载 `/etc` 之前**做完 —— 最难的代码就在这段。
- **更新期**:新槽的 `/usr/etc` 变了 ⇒ 合并必须**在切换前由旧系统**做(不变量 6 的"由旧系统在
  stage 阶段执行")—— 与 roadmap 2.8 的迁移执行器是同一件事。
- **回滚**:三方合并**不可逆**;回滚到旧槽时,`/data/etc` 里已按新默认值覆盖过的文件要能恢复,
  否则回滚语义被破坏。这是这套机制最容易出错的地方(ostree 靠自己的部署模型解决)。
- **断言/文档/不变量**:`keel-check`、`os-status`、`os-rescue`、D5、不变量 5 全部要改。

**最终结论(2026-09-26,业主拍板):废案 —— 不做。** 决策记录见 `decisions.md` **D28**。

**决定性证据(实测,不是推理)**:把一台走过完整生命周期(ext4 装机 → v1 `os-update` 迁移到
erofs → 重启)的机器起起来,看 overlay **upper 里实际被拷上去的东西**,只有 **11 个文件**:

```
/.updated  /machine-id  /.pwd.lock  /ld.so.cache  /kernel/entry-token
/ssh/ssh_host_{rsa,ecdsa,ed25519}_key{,.pub}
```

**`/etc/passwd`、`/etc/group`、`/etc/shadow` 都不在里面**(实测 `/etc/passwd` = 34 行,与镜像
完全一致 ⇒ 一直在读 lower)。upper 里只有两类东西:① 机器专属的秘密(SSH 主机密钥、machine-id)
—— **永远不该被默认值替换**;② 会被重新生成的缓存(`ld.so.cache` 每次启动由 `ldconfig.service`
重建,已实测;`.updated` / `entry-token` 同理)。
⇒ **三方合并在这台系统上找不到任何一个"用户没改过、却因被拷上来而遮蔽了新默认值"的案例。**
(原先设想的"最强反例" —— 账号数据库被拷上来导致新版本加的系统账号看不见 —— 实测**也不成立**;
即便成立,通用三方合并也治不了它:那需要**按行合并** passwd/group,ostree 是专门特判的。)

**真正值得做的是 D19 方案 A**(把 `/etc` 的挂载提到 initrd)—— 一次消掉 #24/#29/#37/#61 四条,
**已经在 v2.0 的清单里**。`/usr/etc` 那一半(保留 overlay、只把 `lowerdir` 换成 `/usr/etc`)功能收益
接近零,只在将来做 dm-verity、想让"默认值"与"机器状态"在镜像里物理分开时再考虑。

## 3. 顺手要还的技术债

| # | 事项 | 说明 |
|---|---|---|
| 3.0 | **initrd 阶段的冻结兜底**(v1 明确不覆盖) | 实测(坑 #50):候选槽的根镜像坏掉时 initrd 会停在 `Switch root target contains no usable init.` 并**冻结**;主系统的看门狗已生效(`RuntimeWatchdogUSec=1min`),但**没能救回这次冻结**(挂住 650+ 秒)。待查:① `mkosi.extra-initrd` 里的配置到底进没进 initrd(我们那个检查也可能误报);② initrd 里有没有 `/dev/watchdog`(没有就得把看门狗驱动/`softdog` 加进 initrd 的模块集);③ 或者给 initrd 加超时。查实之后再决定是修还是接受 |
| 3.1 | `--autologin` 秒退的根因 | 坑 #26/#28 只查清到"`/bin/login` 缺失"这一层;autologin 那条路径为什么秒退没再深挖(v1 不用它) |
| 3.2 | 微码是否真的进了 UKI | 目前只有"VM 能启动"这种间接证据;真机上 `dmesg | grep -i microcode` 可以直接确认 |
| 3.3 | 文档里的历史陈述 | `docs/*.md` 里还留着一些"尚未实现/待验证"的旧话术,发 v1 时统一清一遍 |
| 3.4 | `machines/` 目录 | 有真实按机型分支的需求(比如某台笔记本要特殊固件/电源参数)时再建,现在只有 README |
| 3.5 | **基底系统账号改由 `systemd-sysusers.d` 声明**(低优先级,来自 §2.10 的调查) | `/etc/passwd`/`group` 平时不在 overlay upper 里(实测,§2.10),所以新版本加的系统账号**默认**会被看见。唯一会破的路径:有人手动 `useradd`(或 `useradd -G`)⇒ 整个 `passwd`/`group` 被拷上 upper ⇒ **之后**新版本加的系统账号被遮蔽。对症做法是让基底系统账号都由 `/usr/lib/sysusers.d/*.conf` 声明 —— sysusers 每次启动读只读的那个目录并补齐缺失项(它已经排在 `keel-mounts` 之后),与"整文件遮蔽"无关。**注意**:Debian 包用 `adduser --system` 在 **postinst** 里建的账号(`nixbld1-10` 等)不在 sysusers.d 里,这是要补的部分 |
