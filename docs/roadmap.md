# keel 路线图:v1 之后要做的事

> 这里只放**已经想清楚、但 v1 刻意不做**的事。每条都写清:为什么现在不做、做的时候要注意什么。
> v1 的已知限制同时写在 `dist/keel-<版本>/install.md` 与 release notes 里。
> 决策与理由见 [`decisions.md`](decisions.md),踩过的坑见 [`AGENTS.md`](../AGENTS.md) §3。

## 1. 安全(目前 v1 明确不做)

| # | 事项 | 现在为什么不做 | 动手时要一起改什么 |
|---|---|---|---|
| 1.1 | **更新载荷签名**(`manifest.sig` 真验签) | v1 的更新**手动触发**、源由用户自己配;先把"更新链路本身"跑通。代码里已经有接口:`os-update fetch` 见到 `manifest.sig` 就用 `/usr/share/keel/update-key.pub` 验签,公钥缺失时直接报错、不静默降级 | ① 决定密钥放哪(烤进 UKI 凭据区 / 单独一个小分区 / 首次配置);② 提供 `tools/sign.sh` 生成与轮换密钥;③ 密钥轮换路径(载荷里带 key id);④ 写进 `docs/update.md` §6 |
| 1.2 | **Secure Boot** | 需要自己的密钥 + 签名 UKI + 处理固件密钥库;开着还会关掉"引导菜单里按 `e` 改 cmdline"这条调试通道(`docs/traps.md` 坑 #4) | 引导链:用 `systemd-shiim`/自签 `db` 签 UKI;同时**解封** `systemd-pcrlock*`(决策 D20 把它们 mask 掉了 —— 解封是这一步的一部分);`tools/verify.sh` 要加"解封了没有"的断言 |
| 1.3 | **TPM 封印的密钥**(LUKS / `/data` 加密) | v1 的 `/data` 是**不加密**的(决策 D6),笔记本丢了数据就没了 | 与 1.2 一起做:`systemd-cryptenroll` + `pcrlock`/`systemd-measure` 把密钥封印到启动链;`/data` 换 LUKS 会**改分区布局** ⇒ 必须按"只增不破"迁移(不变量 6) |
| 1.4 | **dm-verity 校验根分区** | 与"每台机器的 `/data` 迁移/机器专属字节"冲突(决策 D19 方案 D 已否决) | 需要先把"根镜像逐字节可校验"这条保住:任何往根里写机器专属数据的设计都要先排除 |

## 2. 系统功能

| # | 事项 | 说明 |
|---|---|---|
| 2.1 | **`desktop` profile** | 笔记本日常用:Wi-Fi 固件 + NetworkManager(或 networkd 的 wpa_supplicant 路径)、GPU 固件/驱动、字体、桌面环境。桌面软件走 nix(不变量 7),但**固件与内核模块必须在基底**。做的时候顺手把 admin 加进 `video`/`audio`/`render` 组(决策 D21 里刻意留到那时) |
| 2.2 | **`server` profile** | 虚拟化宿主(GPU 直通):`vfio-pci` 绑定、KVM、libvirt 走 nix;cmdline 里的 `iommu=pt` 等已经是机器无关超集(§5.1) |
| 2.3 | **`/usr/lib/modules` 外置模块** | 为"第三方内核模块不进基底"做准备:把 `/usr/lib/modules/<kver>` 挂 overlay 后 `depmod` + 模块加载是否成立(`architecture.md` §13.1 待验证第 3 条) |
| 2.4 | **`cache` 分区** | 把"可丢弃的缓存"(`/nix` store、journal)与"不可丢的状态"(`/home`、`/etc` upper、`/data/keel`)物理分开。只增分区即可(不变量 6 允许);决策 D23 里先做了预算 + 看门人,等真机用一段时间看清增长曲线再定 |
| 2.5 | **`systemd-sysupdate` 换掉"直接写盘"** | `os-update` 是门面,底层可替换(决策 D8)。要先验证 `Type=partition` 对双槽布局的匹配语义,再换 |
| 2.6 | **自动更新定时器** | v1 刻意手动触发(`docs/update.md` §8),便于在笔记本上边用边观察;之后可以按"检查频率 + 只下载不安装"的保守策略加 |
| 2.7 | **`os-install` 的两个 TODO** | ① 根文件系统实际占用超过目标分区尺寸时的截断检查;② `keel-confirm` 的 pending/running_slot 边界 |
| 2.8 | **`/data` schema 迁移的真实演练** | v1 还没有任何一次真实迁移;第一次做 schema 变更时必须按 `docs/update.md` §4 走完整流程(**含回滚演练**),并把结果写进那张表 |

## 3. 顺手要还的技术债

| # | 事项 | 说明 |
|---|---|---|
| 3.1 | `--autologin` 秒退的根因 | 坑 #26/#28 只查清到"`/bin/login` 缺失"这一层;autologin 那条路径为什么秒退没再深挖(v1 不用它) |
| 3.2 | 微码是否真的进了 UKI | 目前只有"VM 能启动"这种间接证据;真机上 `dmesg | grep -i microcode` 可以直接确认 |
| 3.3 | 文档里的历史陈述 | `docs/*.md` 里还留着一些"尚未实现/待验证"的旧话术,发 v1 时统一清一遍 |
| 3.4 | `machines/` 目录 | 有真实按机型分支的需求(比如某台笔记本要特殊固件/电源参数)时再建,现在只有 README |
