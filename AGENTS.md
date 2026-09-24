# AGENTS.md — 接手必读

> 这份文件是给**后续接手的 agent / 未来的自己**看的。它只写两件事:
> **哪些规则不能违反**(架构不变量)和**哪些坑已经踩过**(别再踩)。
> 具体实现细节看 `docs/`,不要在这里堆流水账。

---

## 0. 这是什么

一个 **不可变基座 + A/B 双槽 + nix 用户态** 的操作系统镜像项目,用 [mkosi](https://github.com/systemd/mkosi)
构建,基底是 **Debian stable**。它**不是** NixOS —— 基础系统由 Debian 包组成、只读、原子更新;
nix 只负责用户态软件(装在 `/Volume/nix` 上)。

目标演进路径:

1. **现在**:装在一台笔记本上,边用边改(main = 无桌面的最小系统,`desktop` profile 紧随其后)。
2. **未来**:装到一台"不可变基座 + 虚拟化宿主"上,GPU 直通给 VM —— 宿主**不需要**显卡驱动,
   所以 server 变体反而比 desktop 变体更小。

项目名/仓库名是 `common-os`(暂定,待改名;镜像标识集中在 `mkosi.conf` 的 `ImageId=`,改名是 sed 级操作)。

---

## 1. 架构不变量(NON-NEGOTIABLE)

改动代码前先确认没有违反下面任何一条。每一条都是有意为之,违反后会在某个不显眼的时刻炸掉。

1. **基础系统只读,状态全在 `/Volume`。**
   根分区以 `ro` 挂载;`/var`、`/root`、`/nix` 是指向 `/Volume` 的符号链接,`/home` 是真目录 + bind mount
   (用符号链接会破坏 `ProtectHome=` 的沙箱语义,所以 `/home` 是唯一的例外)。

2. **`/Volume` 必须由 initrd 挂载,且早于 switch_root。**
   符号链接无法参与挂载顺序约束,所以不能靠"启动后再挂"。做法是把它写进 UKI 的 kernel cmdline:
   `systemd.mount-extra=PARTLABEL=volume:/Volume:ext4:defaults`
   (`systemd-fstab-generator` 在主系统和 initrd 里都会解析它,initrd 里会自动加 `/sysroot/` 前缀。)

3. **每个槽一个完整 UKI,内核与根文件系统永远配对。**
   切换槽 = 换整个 UKI。绝不允许出现"新内核 + 旧根"的组合 —— 这是回滚可靠性的全部基础。
   因此**不要**用共享内核 + 两个 BLS entry 的方案。

4. **槽切换与回滚只用 systemd 现成机制,不自己发明。**
   `common-os-update` 是**门面**:下载/校验/写分区/版本比较交给 `systemd-sysupdate`,
   "下次启动用哪个槽"用 `bootctl set-preferred`,成功判定用 boot counting + `systemd-bless-boot.service`
   (它挂在 `boot-complete.target` 上自动把 UKI 改名成 "good")。策略(QoS、迁移、报告)才是我们自己写的。

5. **`/etc` 必须可写,用 overlayfs,不用 bind mount。**
   lower = 只读镜像的 `/etc`,upper/work = `/Volume/overlayfs/etc/{upper,work}`。
   整体 bind 一个 `/Volume/etc` 会让新版本镜像的默认配置被旧副本永久遮蔽,这是 A/B 系统的经典坑。

6. **`/Volume` 的 schema 变更只能"只增不破"。**
   新版本可以加目录/加文件,不能让旧版本读不懂。原因:回滚时旧系统会挂在同一个 `/Volume` 上。
   改动必须同步 bump `/Volume/common-os/schema-version`,并在 `docs/update.md` 里记录。

7. **基底里不放用户软件。**
   应用、开发工具、桌面环境、CUDA 这类东西一律走 nix。判据:
   **"是否需要在启动早期/以长期系统服务身份运行"** —— 是则进基底,否则进 nix。

8. **微码两个厂商都装,不按厂商分支。**
   `Packages=amd64-microcode,intel-microcode`;mkosi 会自动把 `/usr/lib/firmware/{amd,intel}-ucode`
   打成 microcode initrd 并**前置**到 UKI 的 initrd 里 —— 也就是说微码天然跟着槽走、自动更新。
   **不要**用 `MicrocodeHost=yes`(那只适合 VM 调试,会只保留构建机的 CPU 家族)。

---

## 2. 仓库结构约定:单主干 + 变体,不用分支

**`main` 是唯一主干,变体用 mkosi profile 表达,不用 git 分支。**

理由:分支是用来表达"并行的改动线"的,不是用来表达"同一个东西的不同形态"。
如果 desktop/server 各开一个分支,那么 main 上每一个修复都要往两个分支合并,三个月后必然漂移。
"我一个 commit 能同时构建出 desktop 和 server 两个镜像"才是我们要的性质。

分支只用两种:**短命的改动分支**(`feat/swapfile`、`fix/etc-overlay-ordering`,几天内合回 main 并删除)
和**可选的发布维护分支**(`release/13.x`,只有在需要同时维护两条发布线时才开)。

### 什么差异放哪里

| 差异类型 | 例子 | 放哪 |
|---|---|---|
| 所有机器共有 | A/B 布局、只读根、`/etc` overlay、nix 接入、更新/回滚 | `mkosi.conf`、`mkosi.conf.d/` |
| **产物形态** | 安装镜像、A 槽载荷、B 槽载荷 | `mkosi.profiles/{install,slot-a,slot-b}.conf` |
| **用途变体** | `desktop`(桌面)、`server`(虚拟化宿主) | `mkosi.profiles/{desktop,server}.conf` |
| **硬件家族** | 笔记本电源管理、按机型挑固件包 | `machines/*.conf` |
| **单机运行期状态** | hostname、Wi-Fi 密码、vfio 绑定哪块卡、VM 定义 | `/Volume`(不进 git);可选导出成 `machines/<host>.conf` 做备份 |

判定准则:**构建期差异进仓库,运行期状态进 `/Volume`。**
一个东西如果"换台机器就不一样,但不是构建出来的",它就不属于这个仓库。

### `machines/` 目录

借鉴 NixOS 的 `hosts/<机器名>/` 惯例(所有人都熟悉这个心智模型,不用重新发明):

```
machines/
├── README.md          # 说明:能进这里的只有"构建期"差异
├── cpu-amd.conf       # AMD 专属的构建期差异(如果将来真有)
├── cpu-intel.conf
├── laptop-generic.conf
└── host-<机器名>.conf # 单机构建差异(可选)
```

**注意:目前 `main` 里几乎没有真正需要按机器分支的东西。** 微码两个厂商都装(见不变量 8),
KVM/VFIO 的内核模块本来就在内核包里,固件包按"硬件家族"选几个就够。
所以在有真实需求之前,`machines/` 只放 README,不要预先造目录。

---

## 3. 已知的坑(都是踩过的,别重踩)

1. **`mkosi.finalize` 会对默认 initrd 镜像也执行一次。**
   `FinalizeScripts` 的 scope 是 `inherit`(mkosi v27 源码 `config.py` 确认),
   而"把 `/var /root /nix` 换成符号链接"的脚本会在构建 initrd 时再跑一遍,把 initrd 弄坏,
   报错还会很莫名其妙。**缓解**:脚本开头 `[ -f /etc/initrd-release ] && exit 0`,
   并在 `mkosi.initrd.conf` 里显式清空 `FinalizeScripts=`。

2. **符号链接必须在最后一步(`mkosi.finalize`)才创建。**
   如果镜像树里 `/var` 提前变成符号链接,包管理器安装、`systemd-sysusers`、`systemd-tmpfiles`、
   `systemd-firstboot` 全都会顺着链接写到**镜像树外面**去。顺序是:
   装包 → 所有会写 `/var` `/etc` 的步骤 → 最后才换链接。

3. **镜像里 `/var` 的内容在运行时是看不见的。**
   因为 `/var` 是符号链接,运行时看到的是 `/Volume/var`。所以:
   - `/Volume` 的初始骨架必须显式提供,不能指望镜像里的 `/var`;
   - 尤其别忘 `/var/lib/dbus/machine-id -> /etc/machine-id`(Debian 是 dbus 包 postinst 建的,
     而 `/var` 是新的 ⇒ 这个链接会消失);
   - 建议 `/var/log/journal` 也预建,否则第一次启动的日志是易失的。

4. **kernel cmdline 被烧进 UKI ⇒ 机器特有的内核参数无法在运行时修改。**
   应对:cmdline 保持"机器无关的超集"(通用且无害的参数,如 `iommu=pt`),
   把硬件配置挪进 `/etc`(例如 `vfio-pci.ids=` 用 `/etc/modprobe.d/vfio.conf` 的 `options` 代替)。

5. **repart 的分区名 = 配置文件去掉数字前缀的文件名。**
   `mkosi.repart/10-root-a.conf` → PARTLABEL `root-a`。槽的身份就靠这个标识,
   所以 UKI 的 cmdline 用 `root=PARTLABEL=root-a|root-b`,不用 PARTUUID(不依赖 UUID 派生规则)。
   另外:`SplitArtifacts=partitions` 只对声明了 `SplitName=` 的分区吐出独立分区镜像文件。

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
   mkosi 的 Debian 代码里是 `components = ("main", *context.config.repositories)`,
   所以微码/固件包需要 `Repositories=non-free-firmware`(需要 `contrib`/`non-free` 时一并写)。

10. **本容器没法做真实验证**:没有 `/dev/kvm`、没有 loop 设备、ext4 不支持 reflink。
    所以这里只能做静态校验,构建和启动验证由人类在别的机器上做。

---

## 4. 常用命令

```bash
# 静态校验(不需要 root、不需要 loop 设备、能在这里跑)
tools/verify.sh

# 产物构建(需要能跑 mkosi 的机器;建议带 ToolsTree=default)
tools/build.sh                      # 一次产出:安装镜像 + A/B 载荷 + manifest
tools/build.sh --profile desktop    # 变体

# 单独看配置解析结果(排错第一步)
mkosi --profile install summary
mkosi --profile install cat-config

# 单独校验 repart 布局(真跑分区表求解,不写盘)
systemd-repart --dry-run=yes --definitions=mkosi.repart --empty=create --size=9G --json=pretty /tmp/t.raw

# 烧到目标盘
sudo tools/burn.sh /dev/nvme0n1
```

## 5. 当前状态

- [x] 架构设计与决策固化(见上面的不变量)
- [ ] `mkosi.conf` / profiles / repart 定义
- [ ] `mkosi.extra/` 里的单元:`etc-overlayfs`、`common-os-mounts`、`firstboot`、`confirm`
- [ ] `in-image/`:`common-os-update`(门面)、`common-os-install`、`common-os-status`
- [ ] `tools/`:`verify.sh`、`build.sh`、`burn.sh`
- [ ] `docs/`:architecture / install / update / decisions / troubleshooting
- [ ] `desktop` profile(笔记本用)
- [ ] `server` profile(虚拟化宿主,GPU 直通)

### 开写后第一批要验证的事(写进 `docs/decisions.md`)

1. `root=PARTLABEL=` 与 `systemd.mount-extra=PARTLABEL=...` 在 initrd 里的解析。
2. `systemd-sysupdate` 的 `Type=partition` transfer 对双槽布局的匹配语义(门面要接它)。
3. Debian trixie 是否单独打包 `ukify`;若没有就用 `ToolsTree=default` 让 tools tree 提供。
4. `/usr/lib/modules/<kver>` 挂 overlay 后 `depmod` + 模块加载的实际行为(为"第三方内核模块外置"做准备)。
