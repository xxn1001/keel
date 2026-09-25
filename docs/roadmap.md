# keel 路线图:v1 之后要做的事

> 这里只放**已经想清楚、但 v1 刻意不做**的事。每条都写清:为什么现在不做、做的时候要注意什么。
> v1 的已知限制写在 [`release-notes-v1.md`](release-notes-v1.md)(并随构建进入 `dist/keel-<版本>/`)。
> 决策与理由见 [`decisions.md`](decisions.md),踩过的坑见 [`AGENTS.md`](../AGENTS.md) §3。

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

## 2.95 v1 打包前必须复核的两件事(代码已改,效果待构建验证)

| # | 事项 | 怎么验 |
|---|---|---|
| V1-a | `kernel.printk = 4 4 1 7` 与 `keel-mounts` 的三个 `Before=` 都在**构建产物**里 | 构建后在假镜像树/`debugfs` 里回读文件;真机或 VM 首启后 `cat /proc/sys/kernel/printk` 应为 `4 4 1 7` |
| V1-b | **日志落盘**(顺序修复的真正目的) | 重启一次,`journalctl --list-boots` 必须能看到**上一个启动**;`ls /var/log/journal/*/` 里有 `.journal`;`journalctl -b -1` 能读上一次的日志 |

> 这两条不许写成"已验证":2026-09 只验到了**机制**(手工 `sysctl -w` / `journalctl --flush`
> 能立刻达到预期效果),端到端的"启动顺序生效"要等下一次构建 + 首启。

## 3. 顺手要还的技术债

| # | 事项 | 说明 |
|---|---|---|
| 3.0 | **initrd 阶段的冻结兜底**(v1 明确不覆盖) | 实测(坑 #50):候选槽的根镜像坏掉时 initrd 会停在 `Switch root target contains no usable init.` 并**冻结**;主系统的看门狗已生效(`RuntimeWatchdogUSec=1min`),但**没能救回这次冻结**(挂住 650+ 秒)。待查:① `mkosi.extra-initrd` 里的配置到底进没进 initrd(我们那个检查也可能误报);② initrd 里有没有 `/dev/watchdog`(没有就得把看门狗驱动/`softdog` 加进 initrd 的模块集);③ 或者给 initrd 加超时。查实之后再决定是修还是接受 |
| 3.1 | `--autologin` 秒退的根因 | 坑 #26/#28 只查清到"`/bin/login` 缺失"这一层;autologin 那条路径为什么秒退没再深挖(v1 不用它) |
| 3.2 | 微码是否真的进了 UKI | 目前只有"VM 能启动"这种间接证据;真机上 `dmesg | grep -i microcode` 可以直接确认 |
| 3.3 | 文档里的历史陈述 | `docs/*.md` 里还留着一些"尚未实现/待验证"的旧话术,发 v1 时统一清一遍 |
| 3.4 | `machines/` 目录 | 有真实按机型分支的需求(比如某台笔记本要特殊固件/电源参数)时再建,现在只有 README |
