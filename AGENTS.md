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

1. **现在**:装在一台笔记本上,边用边改(`main` = 无桌面的最小系统,`desktop` profile 紧随其后)。
2. **未来**:装到一台"不可变基座 + 虚拟化宿主"上,GPU 直通给 VM ——
   宿主**不需要**显卡驱动,所以 `server` 变体反而比 `desktop` 变体更小。

术语与标识,改代码前先对齐:

| 东西 | 值 |
|---|---|
| 项目 / 镜像标识 | `keel`(`ImageId=`) |
| 面向用户的命令 | `os-status`、`os-update`、`os-install`、`os-rescue` |
| 项目内部单元 | `keel-*.service` / `/usr/lib/keel/` |
| 持久状态目录 | `/data/keel/` |
| 分区标签 | `esp`、`root-a`、`root-b`、`data` |
| ESP 上的 UKI | `/efi/EFI/Linux/keel-a.efi`、`keel-b.efi`(带计数时 `keel-a+3.efi`) |
| 唯一登录账号 | `admin`(uid 1000,`sudo` 需要密码);**root 锁定**,SSH 侧 `PermitRootLogin no` |

---

## 1. 架构不变量(NON-NEGOTIABLE)

改动代码前先确认没有违反下面任何一条。每一条都是有意为之,违反后会在某个不显眼的时刻炸掉。

1. **基础系统只读,状态全在 `/data`。**
   根分区以 `ro` 挂载;`/var`、`/root` 是指向 `/data` 的符号链接;
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

# 产物构建(建议 ToolsTree=default;宿主机只需要 mkosi + bubblewrap + 一个包管理器)
tools/build.sh                       # 一次产出:安装镜像 + A/B 载荷 + manifest → dist/
tools/build.sh --profile desktop     # 变体

# 宿主不是 mkosi 支持的发行版时(NixOS 等):把构建放进容器(见已知的坑 #15)
sudo tools/build-container.sh               # 构建(产物里 admin 无密码,只能靠 authorized_keys 进)
sudo tools/build-container.sh -p <密码> vm  # 构建并在容器里起 QEMU(控制台用 admin / 该密码登录;root 锁定)
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
- [x] **第一次真机构建 / 虚拟机启动 / 装机**(2026-09,VM:构建 → live 启动 → `os-install` → 目标盘首启 ✓;
      途中修掉坑 #31–#34。**真机(U 盘 + 笔记本)仍未做过**)
- [ ] `desktop` profile(笔记本用)
- [ ] `server` profile(虚拟化宿主,GPU 直通)

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
   `nix-shell -p fastfetch` 能进 shell、能跑起来。**仍待补**:`df -h /data` 确认首启把 data
   分区扩到了整盘(不变量 14)—— 这条并进下一轮装机演练。
6. ~~**ESP 在装机后的系统里没挂上**~~ **已修(2026-09,坑 #36 / 决策 D18)**:
   `keel-mounts` 自己扫 `PARTNAME=esp` 以 rw 挂到 `/boot`,cmdline 加 `systemd.gpt_auto=no`,
   `lib.sh` 只认真实挂载点(`KEEL_ESP_MOUNTED`),没挂上时 os-status / os-update / keel-confirm
   分别明确报错或自救。**已实测(2026-09,VM,test profile 自检)**:
   `findmnt /boot` → `/boot /dev/vdb1 vfat rw,relatime,fmask=0133,dmask=0022,…`,
   `bootctl --print-esp-path = /boot`,`/boot/EFI/Linux/` 里有 163 MB 的 UKI,
   `os-status` 打出 `ESP 挂载 : /boot(/dev/vdb1 vfat)`;同一轮里 `/data` 正常(
   swapfile 按 `/data` 的可用空间压到 471 MiB 并启用)、machine-id 32 位、DHCP `routable`。
   **仍未实测**:`os-update` 真正往 ESP 写一个新 UKI(要凑一趟 OTA 载荷)—— 不过它现在写之前会
   remount rw 并检查挂载点,所以"写到空目录还报成功"这条已经堵住了。
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
