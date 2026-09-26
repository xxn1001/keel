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
     都与容器路径一致。**仍未做的是 rootless(不带 sudo)那一半** —— 见 `roadmap.md` §0 ⑥。
21. `os-install` 还留着两个 TODO:根镜像实际占用超过目标分区尺寸时的截断检查;
     `keel-confirm` 的 pending / running_slot 边界。(roadmap 2.7)
22. `docs/` 里的历史叙述偶尔还带着"当时还没做"的口气,发版后统一清一遍。(roadmap 3.3)

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
