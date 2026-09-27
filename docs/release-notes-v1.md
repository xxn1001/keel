# keel v1 发布说明

> 面向"拿到这个标签的人":v1 是什么、验过什么、**明确不做什么**、出事看哪里。
> 设计与取舍见 [`architecture.md`](architecture.md) / [`decisions.md`](decisions.md);
> v1 之后要做的事见 [`roadmap.md`](roadmap.md);踩过的坑见 [`traps.md`](traps.md)。

## 1. 这是什么

**不可变基座 + A/B 双槽 + nix 用户态**的操作系统镜像:基础系统由 Debian trixie 的包组成、
只读挂载、**整槽原子更新**;用户态软件交给 nix(装在 `/data/nix`),两者彻底解耦。

- 目标平台是**服务器**(长期在线、尽量不重装、升级要能原子回退、将来当虚拟化宿主);
- 笔记本装机是"顺带兼任",用来提前暴露 bug;`main` 保持无桌面的最小系统;
- 三个产物形态(install / slot-a / slot-b)由 mkosi profile 表达,**一个 commit 同时构建**。

## 2. v1 验过什么(全部有实测记录)

| 项 | 证据 |
|---|---|
| 构建 | 在 NixOS 宿主上走容器适配器构建(140+ 项静态校验先过);`dist/keel-<版本>/` 六个产物 + manifest(含 sha256)。**v1.1 补**:`tools/build.sh` 原生路径已在 **Debian 13(FHS 宿主)**上端到端跑通(连跑三次,含 `-p` 初始密码),见 `roadmap.md` §0 ⑥ |
| 装机(libvirt,整盘) | `os-install --yes /dev/vdb` → `esp 1G + root-a 6G + root-b 6G + data 27G`;**拔掉 U 盘式启动**(只挂目标盘)成功 |
| 装机后体检 | `sudo ~/keel-check` = **通过 50 / 失败 0 / 警告 0 / 跳过 3**(跳过项 = 虚拟机微码、无 vTPM、可选的 nix 装包测试) |
| 更新 | 13 GiB 载荷 30–40 秒下完(600–900 MB/s)、sha256 全对;写 6 GiB 根分区 11 秒;重启进新槽、条目被 bless 成 `keel-b.efi`、`last_result=success` |
| 回滚 | `os-update rollback` → 回旧槽、`last_result=failed` |
| 坏槽自动回退 | 候选槽起不来(panic / 冻住 / 停在 emergency 三类)→ 各自兜底后回到旧槽并留下 `.failed` 条目 |
| 救援 | `os-rescue` 五条路径(`--init-data` / `--reset-etc` / `--grow-data` / `--mark-bad` / `--repair-boot`)逐条实测 |
| `/data` 写满 | 看门人三级(warn / critical / emergency)+ 交还 256 MiB 应急空间 + 满盘时 `os-update fetch` 直接拒绝(HTTP 日志零产物请求) |
| 日志 | **落盘**(`/var/log/journal/` 有 `system.journal`,重启后能看到上一次启动);控制台只印 warning 及以上(`kernel.printk = 4 4 1 7`) |

**没验过**:真机(U 盘 + 笔记本)装机;
initrd 阶段的冻结(见下面限制);第三方内核模块;GPU 直通。
(**原生 FHS 宿主上的 `tools/build.sh` 已从这份"没验过"清单里移走 —— v1.1 在 Debian 13 上跑通了。**)

## 2.5 v1.1 发布前的压力测试(2026-09-27,`tools/stress-libvirt.sh`)

v1.1 之前的证据都是**单次**的(一次装机、一轮更新、一次坏载荷回滚)。发布前补了四个阶段,
共 **356 条断言、0 失败**,全部在 libvirt 的 40 GiB 目标盘上跑(装机后的系统,只挂目标盘):

| 阶段 | 做什么 | 断言 | 结果 |
|---|---|---|---|
| **A 循环 soak** | 在 a↔b 之间更新 **25 轮**(每轮 stage → 重启 → 确认) | 200 | 槽每轮交替、`last_result=success`、pending 清空、**ESP 可用恒定 710 MiB**、ESP 条目恒定 2、`/data/ota` ≤2 份、**正式条目 == 载荷里的 UKI** |
| **B 断电 torture** | 在 `stage` 写到一半时硬断电(`virsh destroy`)**6 次**(0.5/1/2/3/5/8 秒各一次) | 60 | 每次都回到可用槽、`/data` 与 ESP 挂好、state 可读、pending 清空、条目数不涨 |
| **C 满盘 + 并发** | `/data` 填到只剩 500 MiB;看门人三级;两个 `os-update` 同时跑 + 巡检定时器插进来 | 12 | 满盘 `fetch` 被拒且不落载荷;warn/critical/emergency 三级判定正确;并发之后 state 与 update-check.state 仍可读、仍能 check;折腾完还能正常更新一轮 |
| **D 幂等 + panic** | 连续重启 **20 次**;`sysrq` 强制内核 panic 一次 | 84 | firstboot 幂等(NVRAM 只建一次、ESP 条目集合不变、pending 始终为空);panic 后由 `panic=-1` 回到**同一个槽**,并确认串口日志里确有 `Kernel panic` |

**它抓出了两个只有"长期用 / 粗暴用"才会现形的问题**,都已修 + 补断言:

* **坑 #70:候选条目与正式条目是同一个条目 ID。** `stage` 把候选写成 `keel-<槽>+3.efi`,
  但 `bootctl` 认的条目 ID 是**去掉 `+N` 之后**的名字 —— 于是**从第 2 轮开始**引导器解析到
  "旧的正式条目"上:机器跑的其实是**上一轮的 UKI**,而根分区已经是新载荷(旧内核配新根,
  违反不变量 3),同时候选永远没人消费、**每次更新漏 156 MiB**(ESP 可用 710 → 398 MiB,
  低于 `keel-check` 自己的 400 MiB 警告线)。
  以前的测试全都漏了:演练每次只做**一轮**更新,而第 1 轮恰好是安全的(那时目标槽还没有正式条目);
  而 `keel-confirm` 判"更新成功"看的是**槽**与**版本号**,版本号又是从**新根的** os-release 读的
  —— 两样在"旧内核配新根"时**同时**是对的。
  修法:`stage` 在写候选之前先删掉目标槽的正式条目(它的根此刻已被新载荷覆盖,留着只会再漏 156 MiB)。
* **坑 #71:状态文件只 rename 不落盘。** `keel_state_set` 是 `mktemp` + 写入 + `mv` ——
  rename 保证"看不见半个文件",但**新文件的数据**可能还在页缓存里 ⇒ 硬断电之后留下一个**空文件**,
  下一次写入从空文件重建 ⇒ `pending_slot` / `last_result` / `first_boot` 一起消失(实测 6 刀里 5 刀)。
  修法:`mv` 之前 `sync "$tmp"`(实测:同样的一刀,修复前文件塌成 1~3 个键,修复后 8 个键全在)。

> 这一轮也正面回答了"这套 A/B 到底扛不扛得住":**6 次"写到一半"的硬断电,没有一次让机器起不来**;
> 25 轮循环更新之后,ESP 余量与 ESP 条目数都是**常数**。

## 3. 怎么装、怎么更新

```bash
# 装机:构建机直接烧盘,或用 U 盘启动同一个镜像后在 live 环境里装
sudo tools/burn.sh /dev/nvme0n1          # 会拒绝写到当前系统所在的盘
sudo os-install /dev/vdb                 # live 环境里装到目标盘(无人值守加 --yes)

# 更新(手动触发,v1 没有自动更新定时器)
sudo os-update check                     # 看远端/当前版本
sudo os-update fetch                     # 下载 + sha256 校验到 /data/ota/
sudo os-update stage                     # 写非活动槽 + 把 UKI 放进 ESP + 指向它
sudo systemctl reboot                    # 重启才生效;启动成功自动确认,失败自动回退
sudo os-update rollback                  # 主动回滚到另一个槽
```

更新源写 `/data/keel/config` 的 `UPDATE_SOURCE=`(http(s) / file:// / 挂载好的目录均可)。

## 4. 已知限制(v1 **明确不做**,按重要性排)

### 4.1 安全

1. **更新载荷没有签名**。`os-update fetch` 只校验 sha256(能防传输损坏,**防不住恶意更新源**)。
   没有 `manifest.sig` 时会打醒目告警但继续。⇒ **只指向自己控制的更新源。**
   (roadmap 1.1)
2. **没有 Secure Boot**,UKI 未签名 ⇒ 固件里必须**关掉 Secure Boot**;顺带也就没有"引导菜单里
   按 `e` 改 cmdline"之外的任何篡改防护。(roadmap 1.2)
3. **没有 measured boot / TPM 封印**:`systemd-pcrlock*` 被 disable + mask(决策 D20),
   vTPM 在 v1 里没用上。(roadmap 1.2/1.3)
4. **`/data` 不加密**(决策 D6):机器被拿走 = `/data` 上的 `/home`、`/etc` 改动、nix store 全部可读。
   服务器场景下这条同样是硬伤。(roadmap 1.3)
5. 根分区没有 dm-verity(决策 D19 否决):完整性靠"只读挂载 + A/B 校验和",不是密码学校验。

### 4.2 更新与 `/data`

6. **schema 迁移执行器不存在**:`/data` 布局**冻结在 schema 1**;带 `migrate=` 的载荷会被
   `fetch` **明确拒绝**(宁可拒绝,也不"假装迁移过")。改布局要等执行器 + 演练。(roadmap 2.8)
7. **候选槽只有一次机会**(不是"连续三次"):Debian 的 systemd 257 没有 `set-preferred`,
   现在用 `set-oneshot`。等基底 systemd ≥ 261 再换回三次语义。(roadmap 2.5b)
8. **没有自动更新**:没有定时器、没有"只下载不安装"的后台检查,一切手动。(roadmap 2.6)
9. **每次更新都是全量**:4 个产物约 13 GiB(两个 6 GiB 根镜像 + 两个 163 MB UKI),
   `/data` 至少要能放下一份载荷(实验盘 27 GiB 时刚好一份)。
   ESP 上累积的 `.failed` 条目目前**不会自动清理**(1 GiB ESP 大约能放 6 个 UKI)。
10. 底层是**直接写盘**(`dd` 进分区),不是 `systemd-sysupdate`(`Type=partition` 的匹配语义还没验)。
    `os-update` 是门面,底层以后可换。(roadmap 2.5)

### 4.3 启动与故障恢复

11. **initrd 阶段的冻结不覆盖**:候选槽的根镜像坏到"initrd 找不到可用的 init"时,机器会冻在
    那里;主系统的运行时看门狗救不了它(实测挂住 650+ 秒)。这是 v1 唯一**已知不兜底**的失败模式。
     (roadmap 3.0)
12. `panic=-1` 让 panic 立刻重启 ⇒ **现场一闪而过**(没有 pstore/ramoops);事后靠 journal(已落盘)、
     `os-status` 的 `last_result=failed` 与 ESP 上的 `.failed` 条目复盘。
13. `os-rescue --mark-bad` **只在带启动计数的启动里有意义**(候选槽那次尝试);槽一旦确认就没有计数
     可标记 —— 那时它会告诉你改用 `os-update switch <另一个槽>`。

### 4.4 平台与硬件

14. **真机(U 盘 + 笔记本)装机还没做过**;libvirt 挡掉了固件/驱动/物理介质那一类问题。
15. **`server` profile 未做**(虚拟化宿主:VFIO/GPU 直通、KVM 宿主侧配置)。(roadmap 2.2)
16. **`desktop` profile 未做**:`main` 里没有 Wi-Fi 固件(main 之外才有)、没有桌面、没有 GPU 驱动
    ⇒ 笔记本上只能有线 + 控制台 + nix 里的用户态软件。(roadmap 2.1、`install.md` §2)
17. **第三方内核模块外置未做**:`/usr/lib/modules` 没有 overlay,加模块要改基底重建。(roadmap 2.3)
18. **没有独立 cache 分区**:journal、nix store 与"不可丢的状态"共用 `/data`,
    靠预算 + 看门人(D23)而不是物理隔离。(roadmap 2.4)
19. 双系统:keel **不做 os-prober**,与其它系统共存时用**固件启动菜单**选(每块盘各自的 ESP)。

### 4.5 工程/流程

20. ~~**原生构建路径(`tools/build.sh`)还没在真正的 FHS 宿主上端到端跑过** —— 两条路径(原生 / 容器)
     的 CLI 与能力已对齐并有断言,但第一次实战是接下来在 CachyOS 上的那一轮。~~
     **已解决(v1.1,2026-09-26)**:构建机本身就是 Debian 13(FHS 宿主),`sudo tools/build.sh -p <密码>`
     连跑三次(两个 v1.1 载荷 + 一个引导镜像)全部 exit 0,产物、`dist/` 布局、`-p` 初始密码链路
     都与容器路径一致。
     **rootless(不带 sudo)那一半也补做了(2026-09-27),结论是"能跑通,但产物不等价 ⇒ 直接拒绝"**:
     不带 sudo 也能跑完三个 profile、exit 0、`dist/` 五个产物齐全(不需要 CAP_SYS_ADMIN;
     `tools/build.sh` 里原来那句"mkosi 的沙箱需要 CAP_SYS_ADMIN"是错的,已改),
     但**镜像里所有非 0 的 uid/gid 都会被压成 0** —— 把两次构建的 `slot-a.root.raw` 解出来逐条比:
     root 构建有 18 个 `gid≠0`、3 个 `uid≠0` 的条目,rootless 构建是 **0 和 0**。
     丢的正是"属主不是 root"的那批:`/etc/shadow`(shadow 组)、setgid shadow 的
     `unix_chkpwd`/`chage`/`expiry`、utmp 组的 `/var/log/{wtmp,btmp,lastlog}`、
     `nix/var/nix/daemon-socket`,以及 **`/usr/share/keel/data-skeleton/home/admin`(1000:1000 → 0:0)**
     ⇒ 装完机 admin 的家目录会归 root。原因是"非 root 用户只能创建属于自己的 uid/gid 的文件"
     (mkosi 源码里明写,它甚至为此把沙箱里的 `chown` 变成 noop),不是 keel 的 bug。
     产物**看起来一切正常**(exit 0、产物齐全),所以不是提示一句而是**直接拒绝**:
     `sudo tools/build.sh` 是原生路径的唯一形态(非 root 直接 `die`)。
     **没有 root 也要构建 → 走容器适配器** `tools/build-container.sh`:容器里是 root,而且 podman 会把
     宿主机的 subuid/subgid 映射进容器(实测:不用 sudo 的 rootless podman 容器里 `chown 0:42` 生效)。
     两种构建也**不要混用同一个 `mkosi.cache/`**(增量缓存是整棵树 move/copy,会把错误属主传染给
     下一次构建 —— 切换身份前 `rm -rf mkosi.cache/*.cache`,包缓存可以留)。见 `roadmap.md` §0 ⑥、坑 #66。
     同一轮还修掉两处"校验器自己说谎":非 root 时 PATH 里没有 `/usr/sbin` ⇒ `sfdisk` 看不见、
     verify 第 3 节 14 条断言**整节静默消失**(root 191 通过 vs 非 root 173 通过);shellcheck
     的输出写死在 `/tmp` 下的固定文件名 ⇒ root 跑过一次之后非 root 假红(坑 #67/#68)。
     修完之后 **root 与非 root 跑 verify 都是 0 失败**,并新增第 11 节专门给校验器自己上断言。
21. `os-install` 还留着两个 TODO:根镜像实际占用超过目标分区尺寸时的截断检查;
     `keel-confirm` 的 pending / running_slot 边界。(roadmap 2.7)
22. `docs/` 里的历史叙述偶尔还带着"当时还没做"的口气,发版后统一清一遍。(roadmap 3.3)

### 4.6 硬断电下的残留语义(压力测试划出的边界,v1.1)

23. **硬断电最多丢掉"最后一次状态写入"。** `keel_state_set` 现在是"先落盘、再改名",
    所以断电之后你拿到的要么是旧文件、要么是新文件,**不会**再出现"空文件 ⇒ 状态被整体重建"。
    但 rename 自身的持久性还依赖文件系统(shell 里做不到 dir fsync)⇒ 极端情况下最后写下的
    **那一个键**(例如刚写好的 `pending_slot`)可能没落盘。**更新与回退不受影响** ——
    oneshot 是在写状态**之前**设的,最坏情况只是 `last_result` 少记一次(`os-status` 显示"无记录")。
    真机上不必为此做任何事;实在在意,`stage` 跑完等一两秒再断电即可(这个窗口本身极小)。

## 5. 出问题先看哪里

```bash
os-status                       # 总览:槽、版本、/data、ESP、上次启动结果、失败单元
sudo ~/keel-check               # 装机后体检(九组检查,逐项 ✓/✗/!)
journalctl -b -1                # 上一次启动的日志(现在是真的落盘了)
journalctl -b -u keel-mounts    # /data 与 /etc overlay 挂载
bootctl list                    # ESP 上的条目(PARTLABEL=root-a/b 决定槽身份)
cat /data/keel/state            # pending_slot / last_result / entry_<槽>
```

`docs/troubleshooting.md` 按症状列了处置办法;`docs/update.md` §3 讲失败与回滚的语义。
