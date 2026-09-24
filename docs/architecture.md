# keel 架构与实施方案(main 分支)

> 这是 **main 分支的定稿方案**,实现代码按 §12 的顺序提交。
> 所有**还没在真机上验证过**的假设都集中在 §13,不要把它们当成既成事实。
> 术语、命令、分区标签见 [`../AGENTS.md`](../AGENTS.md) 的 §0。

---

## 1. 一句话

用 Debian stable 组成一个最小只读系统,以 **A/B 双槽 + 每槽一个完整 UKI** 做原子更新与回滚;
**所有可写状态集中在单个 `/Volume` 分区**;用户软件由 **nix** 提供(`/nix` 也在 `/Volume` 上)。

---

## 2. main 的范围

**包含**

| 能力 | 说明 |
|---|---|
| 只读根 + A/B 双槽 | 卡槽身份靠 PARTLABEL,切换靠 UKI |
| 原子更新 + 自动回滚 | boot counting + `systemd-bless-boot` + `LoaderEntryPreferred` |
| `/etc` 可写 | overlayfs(lower = 镜像,upper = `/Volume`) |
| `/Volume` 状态分区 | `/var`、`/home`、`/root`、`/nix` 全部落在这里;含 swapfile |
| nix 可用 | Debian 包 `nix-bin` + `nix-setup-systemd`;flakes 打开 |
| 远程可用 | sshd + 有线网络(systemd-networkd)+ systemd-resolved |
| 装机 / 自救命令 | `os-install`、`os-rescue`、`os-status`、`os-update` |
| 静态校验工具 | `tools/verify.sh`(在本容器就能跑) |

**不包含(v1 明确不做)**

- 桌面环境 / 显卡驱动 / 无线网络 → 留给 `desktop` profile
- 虚拟化宿主(libvirt/qemu/vfio)→ 留给 `server` profile
- 加密(LUKS)、Secure Boot、dm-verity
- BIOS/GRUB 引导(只支持 UEFI,因为 boot counting 与槽切换依赖 EFI 变量)
- 休眠(只做 swapfile)
- 图形化安装器
- `/Volume` 快照/备份

---

## 3. 磁盘布局

### 3.1 安装镜像(profile `install`)

| # | PARTLABEL | GPT 类型 | 文件系统 | 大小 | 挂载 | 内容 |
|---|---|---|---|---|---|---|
| 1 | `esp` | `esp` | vfat | 1 GiB | `/efi`(ro) | systemd-boot + `EFI/Linux/keel-a.efi` |
| 2 | `root-a` | `root-x86-64` | ext4 | **6 GiB** | `/`(ro) | 系统树 + 符号链接 |
| 3 | `root-b` | `linux-generic` | ext4 | **6 GiB** | — | 空槽,首次更新写入 |
| 4 | `volume` | `linux-generic` | ext4 | 剩余全部 | `/Volume`(rw) | 全部可写状态 |

镜像总大小 ≈ 13 GiB + volume 最小尺寸;`mkosi burn` / `os-install` 会按目标盘容量修正 GPT 并把
`volume` 扩到整盘。

### 3.2 为什么是 6 GiB / 为什么 B 槽在镜像里就存在

- **6 GiB 是"布局常量",不是随手定的。** GPT 分区不能在中间插入或搬移,所以槽位尺寸必须在
  **第一次装机前**就按"这台机器将来可能跑的最大变体"留足 —— 改这个数字意味着重装。
  main 自身大约只用 1.5–2 GB;6 GiB 的余量是留给 `desktop` profile(固件 + mesa + 音频 + 轻量会话)
  和未来增长的。**如果将来决定把完整 GNOME/KDE 塞进基底,需要重新评估这个数字。**
- **B 槽在安装镜像里就存在(空 ext4)。** 代价是镜像大 6 GiB(全零,压缩后几乎不占空间),
  换来的是:首次开机后**不需要任何分区手术**就能立刻测试槽切换。
  (systemd-repart 官方支持"装机时只有 A 槽、首启自动创建 B 槽"这个模式,可以省 6 GiB 镜像体积,
  但需要给 B 预留空隙 + 首启跑 repart,多一个失败点。留作将来的优化项。)

### 3.3 更新载荷(profile `slot-a` / `slot-b`)

| 产物 | 内容 |
|---|---|
| `slot-<x>.root.raw` | 该槽的根文件系统分区镜像(repart `--split` 产物,写入 `PARTLABEL=root-<x>`) |
| `slot-<x>.uki.efi` | 该槽的完整 UKI(`root=PARTLABEL=root-<x>`,含内核 + initrd + 微码) |

同一个 profile 也产出完整 `.raw`(用于验证),但发版只发上面两个文件。

---

## 4. 镜像内布局

### 4.1 符号链接与挂载点

```
/var   -> /Volume/var           (符号链接)
/root  -> /Volume/home/root     (符号链接)
/nix   -> /Volume/nix           (符号链接)
/home  =  真实空目录,启动早期 bind mount 到 /Volume/home
/etc   =  overlayfs 挂载点(lower = 镜像 /etc,upper/work = /Volume/overlayfs/etc)
```

**这三条符号链接在 `mkosi.finalize`(构建的最后一步)才创建** —— 否则包管理器、
`systemd-sysusers`、`systemd-tmpfiles` 会顺着链接写到镜像树外面去(`AGENTS.md` 已知的坑 #2)。

### 4.2 `/Volume` 骨架

骨架在构建期由 `mkosi.finalize` 从镜像的 `/var` 快照生成(剔除包管理器状态目录),
再由 repart 的 `CopyFiles=/usr/share/keel/volume-skeleton:/` 写进 volume 分区;
同一份骨架留在镜像里供 `os-rescue --init-volume` 做自愈。

```
/Volume/
├── var/
│   ├── log/journal/                  ← 预建,保证第一次启动的日志就持久
│   ├── lib/dbus/machine-id -> /etc/machine-id   ← 必须显式重建(见坑 #3)
│   ├── lib/systemd/  cache/  spool/  tmp/  opt/  local/
├── home/                             ← /home 的 bind 源
│   └── root/                         ← /root 的目标
├── nix/                              ← nix store(首启由 nix 的 tmpfiles 补齐子目录)
├── overlayfs/etc/{upper,work}/       ← /etc 的 overlay 层
├── modules/                          ← 预留:将来"第三方内核模块外置"用,main 留空
├── ota/                              ← 下载的更新载荷(按版本分目录)
└── keel/
    ├── schema-version                ← /Volume 布局版本,迁移用
    ├── state.json                    ← 当前槽、pending 更新、上次结果
    ├── config                        ← 更新源 URL、swapfile 大小等
    └── swapfile                      ← 首启创建
```

### 4.3 `/etc` overlay

```
lowerdir = /etc                    (只读镜像)
upperdir = /Volume/overlayfs/etc/upper
workdir  = /Volume/overlayfs/etc/work
```

由 `keel-mounts.service` 挂载,排序要求见 §10。**`/etc` 是唯一的"配置层"**:
所有需要持久化的系统配置都写在这里(经 overlay 落到 `/Volume`),包括将来 `/etc/ld.so.conf.d/nvidia.conf`
这类为"外置驱动"准备的钩子。

### 4.4 构建顺序上的硬约束

```
装包 → postinst → sysusers → tmpfiles → preset-all → depmod → firstboot → hwdb
     → RemovePackages/RemoveFiles
     → mkosi.finalize:①快照 /var 生成骨架 ②把 /var /root /nix 换成符号链接
     → 生成 UKI
     → systemd-repart 生成最终镜像(此时骨架才被写进 volume 分区)
```

---

## 5. 引导链

### 5.1 kernel cmdline(烧在 UKI 里,每槽一份)

```
ro
root=PARTLABEL=root-a
systemd.mount-extra=PARTLABEL=volume:/Volume:ext4:rw,noatime
systemd.mount-extra=PARTLABEL=esp:/efi:vfat:ro
amd_iommu=on intel_iommu=on iommu=pt
```

- `ro`:根只读。第二条 `systemd.mount-extra` 让 initrd 在 switch_root 前就挂好 `/Volume`,
  符号链接从用户空间第一个瞬间起就有效(不变量 2)。
- `amd_iommu=on` / `intel_iommu=on` / `iommu=pt`:对没有对应硬件的机器**无害**,
  但为将来的 GPU 直通铺好路 —— 这正是"cmdline 机器无关超集"策略的示范(`AGENTS.md` 坑 #4)。
- v1 **不加 `quiet`**:首次在真机上跑,能看见启动日志比"干净"重要。

### 5.2 引导器与命名

- `systemd-boot` 装在 ESP:`EFI/systemd/systemd-bootx64.efi` + **fallback 路径 `EFI/BOOT/BOOTX64.EFI`**
  (`bootctl install` 两处都装,并把启动项加到固件列表顶部)。
- UKI 放在 `EFI/Linux/`:`keel-a.efi`、`keel-b.efi`;进入尝试计数时命名为 `keel-b+3.efi` → `+2-1` → …
- 首启由 `keel-firstboot` 调 `bootctl install` 补上本机的 NVRAM 启动项(装机镜像里不可能带)。

### 5.3 槽切换与回滚的完整时序

```
os-update stage
 ① 读 /proc/cmdline 判断当前槽 → 目标槽 = 另一个
 ② 迁移 /Volume(声明式,由**旧系统**执行,只增不破,成功后 bump schema-version)
 ③ 把 slot-<目标>.root.raw 写进 /dev/disk/by-partlabel/root-<目标>;sync + blockdev --flushbufs
 ④ mount -o remount,rw /efi;把 slot-<目标>.uki.efi 写成 /efi/EFI/Linux/keel-<目标>+3.efi
 ⑤ bootctl set-preferred keel-<目标>+3.efi          (只写 EFI 变量,不动 loader.conf)
 ⑥ 写 /Volume/keel/state.json 的 pending 块
 ⑦ 提示重启(os-update stage --reboot 直接重启)

重启
 ⑧ systemd-boot 选中 preferred → 文件名退化为 keel-<目标>+2-1.efi → 启动

成功路径
 ⑨ 到达 boot-complete.target:
    - systemd-bless-boot.service 自动把 UKI 改名为 keel-<目标>.efi(good)
    - keel-confirm.service:bootctl set-preferred keel-<目标>.efi;state.json 记 success;清 pending

失败路径(连续 3 次没到 boot-complete:内核 panic / initrd 失败 / systemd 起不来都算)
 ⑩ tries-left 归零 → 条目标记 bad → LoaderEntryPreferred 感知并跳过 → 回退到旧槽启动
 ⑪ 旧槽起来后 keel-confirm.service 发现"跑在旧槽,但 state 说 pending 新槽" → 判定失败:
    清空 preferred、把坏 UKI 挪成 keel-<目标>.efi.failed、state.json 记 failed 并 journal 告警
```

**为什么迁移要由旧系统执行**(不变量 6):如果让新系统在首启时迁移 `/Volume`,而它随后启动失败,
回滚后的旧系统面对的是一份"被新系统改过"的 `/Volume`。反过来,旧系统自己做的迁移按定义就是
它自己能读懂的。迁移只允许"加目录/加文件/设权限",由 `os-update` 按 manifest 里的声明执行,
**不执行下载来的任意脚本**。

---

## 6. 交付物

| profile | 产物 | 用途 |
|---|---|---|
| `install` | `keel.raw` | 安装镜像(§3.1 的完整磁盘) |
| `slot-a` | `slot-a.root.raw` + `slot-a.uki.efi` | 写入 A 槽的更新载荷 |
| `slot-b` | `slot-b.root.raw` + `slot-b.uki.efi` | 写入 B 槽的更新载荷 |

`tools/build.sh` 一次跑三个 profile,组装出发布目录:

```
dist/keel-<version>/
├── manifest.json         版本、构建时间、Debian 快照、内核版本、槽位尺寸、
│                         schema 版本、声明式迁移步骤、每个产物的 sha256
├── manifest.json.sig     签名(v1 先留接口,只做 sha256)
├── keel.raw
├── keel.raw.sha256
├── slot-a/{root.raw,uki.efi}
├── slot-b/{root.raw,uki.efi}
└── install.md            从 docs/install.md 生成的人类可读说明
```

版本号由 `mkosi.version` + 构建时 `-B` 自动 bump 管理。

---

## 7. 安装流程

### 7.1 三条路径

**A. 构建机直接烧盘(首选,最省事)**
```bash
tools/verify.sh && tools/build.sh
sudo tools/burn.sh /dev/nvme0n1      # 包装 mkosi burn:按目标盘修正 GPT + 写入 + 回读校验
```

**B. 目标盘拆不下来:U 盘当 live,自己装自己**
把同一个 `keel.raw` 写到 U 盘,UEFI 启动后在 live 环境里:
```bash
sudo os-install /dev/nvme0n1
```
`os-install` 做的事:用 repart 在目标盘建表 → 把当前运行的根写进目标 `root-a` →
把当前 UKI 写到目标 ESP → 用镜像里的骨架初始化 `volume` → 可选 `--seed-b` 顺手把当前版本也填进 B 槽。
U 盘本身也是一套完整系统,顺便当救援盘。

**C. 独立安装器 ISO** —— v1 不做。

### 7.2 首次启动自动完成(`keel-firstboot.service`,幂等)

1. 校验/修复 `/Volume` 骨架(缺失就按镜像里的骨架重建 —— 这是"手贱清空 volume"的自愈入口);
2. 用 `systemd-repart --dry-run=no` 把 `volume` 扩到整盘剩余空间(定义在 `/usr/lib/keel/repart.d/`);
3. `bootctl install` 建立本机 NVRAM 启动项(已有则跳过);
4. 首启创建并启用 swapfile(`/Volume/keel/swapfile`);
5. 记录 `/Volume/keel/state.json` 与 `schema-version`。

### 7.3 装完之后的预期

**只有 UEFI 文本控制台 + SSH**,没有图形界面(main 不含任何显卡驱动/固件)。
UEFI 机器靠内核的 `simpledrm`/`efifb` 就能显示文本,不需要显卡固件。

---

## 8. 更新流程

```bash
os-status                  # 先看:当前槽、版本、/Volume 用量、schema、pending、上次结果
os-update check            # 查询更新源有没有新版本
os-update fetch            # 下载到 /Volume/ota/<ver>/,校验 sha256 + 签名 + schema 兼容性
os-update stage            # 写入非活动槽(§5.3 的 ①–⑦)
os-update stage --reboot   # 同上并立即重启
os-update rollback         # 手动把 preferred 指回上一个已知良好的槽
os-update gc               # 清理旧载荷(保留最近 2 个版本 + 当前)
```

更新源由 `/Volume/keel/config` 里的 URL 决定,支持 `https://`、`file://` 和挂载的 U 盘目录。
**v1 不做自动更新定时器**(手动触发,便于在笔记本上观察)。

---

## 9. 命令集

| 命令 | 子命令 | 作用 |
|---|---|---|
| `os-status` | — | 当前槽/版本/内核、`/Volume` 用量、schema 版本、pending 状态、上次更新结果、槽位占用 |
| `os-update` | `check` / `fetch` / `stage` / `rollback` / `gc` | 更新门面(§8) |
| `os-install` | `<device>` `[--seed-b]` | 从 live 环境装到目标盘(§7.1 B) |
| `os-rescue` | `--init-volume` | 重建/修复 `/Volume` 骨架(幂等) |
| | `--reset-etc` | `/etc` 恢复出厂:清空 overlay upper,下次启动重新播种 |
| | `--mark-bad` | 把当前槽标记为 bad(`systemd-bless-boot bad`) |
| | `--grow-volume` | 手动扩展 `volume` 分区 |
| | `--seed-slot a\|b` | 用当前运行版本填充另一个槽(装完即可测试切换) |

`os-update` 是**门面**:下载/验签/版本比较/写分区交给 `systemd-sysupdate`,
槽切换交给 `bootctl`;我们写的是策略、迁移、保留、报告(决策 D8)。

---

## 10. 单元清单

| 单元 | 作用 | 关键排序 |
|---|---|---|
| `keel-mounts.service` | bind `/home`;挂 `/etc` overlay;`systemctl daemon-reload` | `DefaultDependencies=no`、`After=systemd-remount-fs.service Volume.mount`、`Before=sysinit.target systemd-sysusers.service systemd-tmpfiles-setup.service systemd-machine-id-commit.service` |
| `keel-firstboot.service` | §7.2 的五件事 | `After=keel-mounts.service`、`Before=multi-user.target` |
| `keel-swapfile.service` | 创建/启用 swapfile | `After=keel-mounts.service` |
| `keel-confirm.service` | 启动成功后确认/回滚更新,写 state | `After=boot-complete.target systemd-bless-boot.service`、`WantedBy=boot-complete.target` |

辅助脚本放 `/usr/lib/keel/`,不要散在 `/usr/bin`。

---

## 11. 包清单(main 的起点)

```
[Distribution]
Distribution=debian
Release=trixie
Repositories=non-free-firmware        # 微码/固件必需(见 AGENTS.md 坑 #9)

[Content]
Packages=
    linux-image-amd64
    systemd systemd-sysv systemd-boot systemd-repart
    systemd-resolved systemd-timesyncd
    amd64-microcode intel-microcode   # 两个厂商都装(不变量 8)
    bash coreutils util-linux kbd
    iproute2 iputils-ping ca-certificates curl
    less nano
    openssh-server
    nix-bin nix-setup-systemd
    firmware-misc-nonfree             # 有线网卡/存储控制器固件
RemovePackages=
    initramfs-tools                   # mkosi 自己造 initrd,留着只会生成多余文件
    apt apt-utils                     # 运行时不留包管理器(决策 D10)
```

网络用 `systemd-networkd` + `systemd-resolved`(决策 D15);`/etc/resolv.conf` 在 postinst 里
指向 `/run/systemd/resolve/stub-resolv.conf`。

**这份清单是起点不是终点** —— 第一次真机构建时按报错调整,调整结果回写到这里。

---

## 12. 仓库结构与实施顺序

```
keel/
├── AGENTS.md  README.md  .gitignore
├── docs/{architecture,decisions,install,update,troubleshooting}.md
├── mkosi.conf                      mkosi.conf.d/*.conf
├── mkosi.initrd.conf               ← 只影响默认 initrd(含清空 FinalizeScripts 的补丁)
├── mkosi.profiles/{install,slot-a,slot-b}.conf
├── mkosi.repart/                   ← 安装镜像布局(esp + root-a + root-b + volume)
├── mkosi.repart-slot/              ← 载荷布局(esp + 目标槽 root)
├── mkosi.extra/                    ← 静态文件:单元、preset、sysctl、nix.conf、motd、sshd 片段
├── mkosi.postinst                  mkosi.finalize
├── machines/README.md              ← 只放 README,有真实需求再建
├── in-image/{os-update,os-install,os-status,os-rescue} + lib/
└── tools/{verify.sh,build.sh,burn.sh}
```

**提交顺序**(每个 commit 都能独立跑 `tools/verify.sh`):

| # | 内容 | 完成标志 |
|---|---|---|
| 1 | `mkosi.conf` + `mkosi.conf.d/` + `mkosi.initrd.conf` | `mkosi --profile install summary` 通过 |
| 2 | `mkosi.repart/` + `mkosi.repart-slot/` + 三个 profile | repart dry-run 报出预期分区表 |
| 3 | `mkosi.extra/` + `postinst` + `finalize` | `systemd-analyze verify` 全过;finalize 幂等可重入 |
| 4 | `in-image/os-*` + `/usr/lib/keel/*` | `shellcheck` 全过;`--help` 可用 |
| 5 | `tools/{verify,build,burn}.sh` | `tools/verify.sh` 一条命令全绿 |
| 6 | `docs/{install,update,troubleshooting}.md` + AGENTS TODO 更新 | — |
| 7 | (等你第一次构建反馈之后)`desktop` profile | — |

---

## 13. 待验证清单与风险

### 13.1 开写后立刻要验证的假设

| # | 假设 | 若不成立的退路 |
|---|---|---|
| 1 | `root=PARTLABEL=root-a` 与 `systemd.mount-extra=PARTLABEL=volume:...` 在 initrd 里能被解析 | 改用 mkosi 的 `root=PARTUUID` 自动替换 + 固定 `Seed=` 让 PARTUUID 跨构建稳定 |
| 2 | `systemd-sysupdate` 的 `Type=partition` transfer 能按我们的双槽布局匹配"当前未使用的那个分区" | 门面后面换成 `systemd-repart --copy-source` + 直接写分区,接口不变 |
| 3 | `/usr/lib/firmware/{amd,intel}-ucode` 被 mkosi 正确前置进 UKI | 手工用 `ukify --microcode` 或 `io.mkosi.microcode` 工件目录 |
| 4 | Debian 上移除 `initramfs-tools` 后内核包不会报错、mkosi 仍能找到 vmlinuz | 保留该包但清掉它的 hook |
| 5 | `systemd-boot` 的 `e` 键能给 UKI 追加 cmdline(未启用 Secure Boot) | 调试改走备用槽 / live U 盘 / UKI addon |

### 13.2 风险(按严重程度)

| # | 风险 | 缓解 |
|---|---|---|
| R1 | **`/Volume` schema 迁移与回滚不兼容** —— 共享可写分区做 A/B 的最大隐患 | 只增不破的硬约定 + 声明式迁移 + 由旧系统执行 + 迁移后回滚演练 |
| R2 | `/etc` upper 里留下新版本才认识的配置,回滚后旧版本行为异常 | `os-rescue --reset-etc` 兜底;文档写清 |
| R3 | **nix store 的 DB schema 单向升级** —— 基底升级 nix 后回滚,旧 nix 可能读不了新 DB | 基底里的 nix 版本保守升级;发版说明标注;必要时回滚前 `nix-store --repair` |
| R4 | 部分主板固件会清 EFI 变量(NVRAM)⇒ `LoaderEntryPreferred` 丢失 | fallback 路径 `EFI/BOOT/BOOTX64.EFI` 保证能起;`loader.conf` 的 `default` 兜底;文档给手动切槽步骤 |
| R5 | **槽位尺寸装机即定死**,将来变体放不下就只能重装 | 首次装机前按最大变体留足(现在 6 GiB);在架构文档里写明这个约束 |
| R6 | dm-verity + 两个 root 分区时的 roothash 归属问题 | v2 专项设计;`SplitArtifacts=partitions` 文档明确支持"root + verity + UKI"组合,工具链具备 |
| R7 | 未启用 `non-free-firmware` 会导致微码/固件包找不到 | 构建会直接失败(不会静默),`tools/verify.sh` 里加一条断言 |
| R8 | **本容器无法验证任何东西**:没 KVM、没 loop 设备、ext4 不支持 reflink | 首次真机构建预计还要 2–3 轮修;每个不确定处都在代码里留注释说明"报错时怎么改" |
