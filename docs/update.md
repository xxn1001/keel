# keel 更新与回滚

> **状态(2026-09)**:`os-update` 的 `check` / `fetch` / `stage` / `switch` / `rollback` / `gc`
> 六个子命令都已实现(见 `mkosi.extra/usr/bin/os-update`),但**完整的 OTA 闭环
> (fetch → stage → 重启 → 槽确认 → 回滚)还没有在任何环境里跑过一次** —— 这是 v1 之前
> 必须补的那一课(见 [`roadmap.md`](roadmap.md))。本文其余部分写的是**目标行为**:
> 实现与它不一致的地方以实际脚本为准,跑通之后会把实测结果回写到本文档与 `architecture.md` §13。
> 已知未做的两处:v1 **不验签**(`manifest.sig` 与 `/usr/share/keel/update-key.pub` 的接口留着,
> 见 §6)、**没有自动更新定时器**(§8)。

## 1. 更新模型(一段话)

根分区是只读的,所以更新不是"修改系统",而是"**整个槽换掉**":A/B 两个槽各有一个**完整 UKI**
(内核 + initrd + `root=PARTLABEL=` + 微码全在一份文件里,永远配对),`os-update stage` 把新版本写进
**当前没在用的那个槽**,重启才切过去;成功与否由 boot counting + `systemd-bless-boot` 判定,
新槽连续 3 次没到 `boot-complete.target`(panic、initrd 失败、systemd 起不来都算)就自动回退到旧槽。
用户软件(nix)不在这里管:基础系统原子更新和随便装软件是彻底解耦的两件事(README)。

## 2. 标准操作流程

```bash
os-status                    # 1. 先看(只读,不需要 root)
sudo os-update check         # 2. 更新源有没有新版本
sudo os-update fetch         # 3. 下载 + 校验(还不写任何槽)
sudo os-update stage         # 4. 写非活动槽 + 指向它,重启后生效
sudo os-update stage --reboot  # 同上,并立即重启
```

| 步骤 | 做什么 | 失败时 |
|---|---|---|
| `os-status` | 当前槽/版本/内核、`/data` 用量、schema 版本、pending 状态、上次更新结果、槽位占用(§9) | — |
| `os-update check` | 查询更新源里有没有比当前更新的版本 | 先查网络,再查 `/data/keel/config` 里的 URL(§6) |
| `os-update fetch` | 下载到 `/data/ota/<ver>/`,校验 sha256、签名(v1 只留接口)、schema 兼容性(§8) | 什么都没写进槽,重试即可 |
| `os-update stage` | §5.3 的 ①–⑦(见下表) | 写分区阶段失败只是白写了一遍非活动槽,当前系统不受影响 |
| 重启 | systemd-boot 选中 preferred,文件名从 `keel-<目标>+3.efi` 退化为 `keel-<目标>+2-1.efi` 并启动;到达 `boot-complete.target` 后 `systemd-bless-boot` 把它改名成 `keel-<目标>.efi`,`keel-confirm.service` 把 preferred 指向它、记 success、清 pending(§5.3 ⑧⑨) | 见 §3 |

`os-update stage` 内部按顺序做这些事(§5.3 ①–⑦):

| # | 动作 | 为什么 |
|---|---|---|
| ① | 读 `/proc/cmdline` 判断当前槽,目标槽 = 另一个 | 绝不会写正在运行的那个槽 |
| ② | **迁移 `/data`**,成功后 bump schema-version | 由**旧系统**执行,声明式,只增不破 —— 见 §4 |
| ③ | 把 `slot-<目标>.root.raw` 写进 `/dev/disk/by-partlabel/root-<目标>`,再 `sync` + `blockdev --flushbufs` | 新根落盘 |
| ④ | 把 `slot-<目标>.uki.efi` 写成 `$KEEL_ESP/EFI/Linux/keel-<目标>+3.efi`(`KEEL_ESP` 由 `bootctl --print-esp-path` 得到,通常是 `/boot`) | 新 UKI + 启动计数 |
| ⑤ | `bootctl set-preferred keel-<目标>+3.efi` | 只写 EFI 变量,不动 `loader.conf` |
| ⑥ | 写 `/data/keel/state` 的 pending 块 | 供下次启动判定成功/失败 |
| ⑦ | 提示重启(`--reboot` 直接重启) | — |

`os-update` 是**门面**:下载/验签/版本比较/写分区交给 `systemd-sysupdate`,槽切换交给 `bootctl`,
我们只写策略(迁移、保留、报告)(决策 D8)。
v1 **没有自动更新定时器**(§8):手动触发,便于在笔记本上边用边观察。

## 3. 回滚

### 3.1 自动回滚:怎么判断它发生了

| 证据 | 在哪看 |
|---|---|
| 重启后槽和版本**都没变**(还是旧槽、旧版本) | `os-status` |
| ESP 上出现 `keel-<目标>.efi.failed` | `ls -l "$(bootctl --print-esp-path)/EFI/Linux/"` |
| `state` 里 pending 被清空、记了 failed | `os-status`;`/data/keel/state` |
| journal 里有 `keel-confirm.service` 的告警 | `journalctl -b -u keel-confirm.service` |
| 条目名带递减的计数 | `bootctl list`,例如 `keel-b+2-1.efi` |

判定逻辑(§5.3 ⑩⑪):连续 3 次没到 `boot-complete.target` → tries-left 归零 → 条目标记 bad →
引导器跳过它、回退到旧槽 → 旧槽起来后 `keel-confirm.service` 发现"跑在旧槽,但 state 说 pending 新槽"
⇒ 判定失败,清 preferred、把坏 UKI 挪成 `.failed` 并告警。

### 3.2 手动回滚与标记坏槽

```bash
sudo os-update rollback     # 把 preferred 指回上一个已知良好的槽
sudo os-rescue --mark-bad   # 把当前槽标记为 bad(systemd-bless-boot bad)
```

| 命令 | 什么时候用 | 注意 |
|---|---|---|
| `os-update rollback` | 新版本起来了但行为不对(服务异常、硬件不工作),想干净地回到上一个版本 | 只改"下次启动用哪个槽",当前运行的系统不被修改;重启才生效 |
| `os-rescue --mark-bad` | **当前槽能启动但不可用**,想让引导器下次跳过它(§9) | 它标记的是"当前正在运行的这个槽"。如果你恰好在唯一可用的槽上执行,就把自己锁在门外了 —— 先确认另一个槽是好的 |

失败的载荷不会自动删:留在 `/data/ota/` 里(§4.2),查清原因后用 `os-update gc` 清理
(保留最近 2 个版本 + 当前,§8)。

## 4. `/data` 的 schema 迁移约定(最重要的一节)

`/data` 是 A/B 两个槽**共享**的可写分区。回滚时旧系统挂载的是**同一份** `/data`,
所以新版本写下的任何东西都必须让旧系统读得懂。这是整套架构最大的风险点(§13.2 R1)。

硬规则(`AGENTS.md` 不变量 6):

| 规则 | 含义 |
|---|---|
| **只增不破** | 只能加目录、加文件、补权限。**不许**删除、重命名、改语义、改文件格式、改已有目录的用途 |
| **由旧系统执行** | 迁移发生在 `os-update stage` 阶段(§5.3 ②),由**当前运行的旧系统**完成,不是新系统首启时做。理由:旧系统自己做的迁移,按定义就是它自己能读懂的;若让新系统首启迁移而它启动失败,回滚后的旧系统面对的是一份"被新系统改过"的分区 |
| **声明式,不跑脚本** | 步骤写在 `manifest` 里(建哪些目录/文件、什么权限),由 `os-update` 按声明执行。**绝不执行从更新源下载的任意脚本** |
| **必须 bump 版本** | 动了 `/data` 布局就要 bump `/data/keel/schema-version`,并在下面那张表里记一行;`fetch` 阶段会做 schema 兼容性校验(§8) |

操作上就是三条:

1. 加东西之前先问:旧系统看到这个新目录/新文件,会不会误解?不会才能加。
2. 需要"改"旧结构时:新建一个,旧的留着不动(留到下一个大版本再谈)。
3. 每次 schema 变更后**做一次完整回滚演练**:stage → 重启 → 确认新系统 → `os-update rollback` →
   重启 → 确认旧系统在这份被改过的 `/data` 上正常工作。**没演练过的 schema 变更不算完成。**

### schema 版本记录

| schema-version | 变更 | 引入版本 |
|---|---|---|
| 1 | 初始骨架(`architecture.md` §4.2) | 首个版本(待实现) |

## 5. 已知的跨版本风险

| 风险 | 症状 | 处理 |
|---|---|---|
| **`/etc` overlay 的 upper 是共享的**(R2) | 新版本往 `/etc` 写了旧版本不认识的配置(新 drop-in、新格式),回滚后旧系统行为异常 | `sudo os-rescue --reset-etc` 兜底:清空 overlay upper,下次启动重新从镜像播种。**它会丢掉你在 `/etc` 里的本机配置**(ssh 主机密钥、machine-id、账号、网络配置)——先备份到 `/data/home/...` 再执行 |
| **nix store 的 DB schema 单向升级**(R3) | 基底升级 nix 后回滚,旧 nix 报数据库 schema 太新,`nix` 不可用 | 基底里的 nix **保守升级**;发版说明标注 nix 版本变化;必要时按 §13.2 R3 用 `nix-store --repair` |
| 槽位尺寸不足(R5) | `stage` 写不下新的根镜像 | 尺寸装机时定死,只能重装;装机前按最大变体留足 |
| 主板固件清空 NVRAM(R4) | `LoaderEntryPreferred` 丢失,重启后起的还是原来那个槽 | fallback 路径 `EFI/BOOT/BOOTX64.EFI` 保证能起;按 `troubleshooting.md` 手动切槽 |

## 6. 更新源怎么配

更新源 URL 在 `/data/keel/config` 里(§4.2、§8),支持三种形式:

| 形式 | 例子 | 用途 |
|---|---|---|
| `https://` | `https://example.invalid/keel/` | 正式发布 |
| `file://` | `file:///data/ota/local/` | 本机/离线目录,自测 |
| 挂载的 U 盘目录 | U 盘挂到 `/mnt`,指向 `/mnt/keel-<version>/` | 无网环境装机后升级 |

```
# /data/keel/config
UPDATE_SOURCE=https://example.invalid/keel/
SWAPFILE_SIZE=            # 可留空:默认 min(内存, 8G) 且不小于 1G
```

`check` / `fetch` 会去这个地址找 `manifest` 和四个**扁平命名**的载荷:
`slot-a.root.raw`、`slot-a.uki.efi`、`slot-b.root.raw`、`slot-b.uki.efi`
(不是 `slot-a/` 子目录 —— 见 `architecture.md` §6 的发布目录结构)。
`manifest` 刻意是最朴素的 `key=value` 文本:镜像里没有 jq,清单不该依赖它。

下载后所有校验都在本地完成:`fetch` 逐个文件验 sha256、再检查 schema 兼容性;
`manifest.sig` 存在时会用 `/usr/share/keel/update-key.pub` 验签(公钥缺失直接报错,
不做静默降级),不存在时打印醒目警告后继续 —— 这是 v1 的权宜策略。

## 7. 给将来维护者:发一个新版本要做什么

| # | 步骤 | 说明 |
|---|---|---|
| 1 | `tools/verify.sh` | 静态校验必须全绿(§12) |
| 2 | 有 `/data` schema 变更? | 先在 manifest 里写声明式迁移步骤、bump `schema-version`,并在本文档 §4 的表里加一行 —— **这步不能跳过** |
| 3 | `tools/build.sh` | 一次跑 `install` / `slot-a` / `slot-b` 三个 profile,产出 `dist/keel-<version>/`(§6) |
| 4 | 检查产物目录 | `manifest`(版本、构建时间、Debian 快照、内核版本、槽位尺寸、schema 版本、迁移步骤、各产物 sha256)、`keel.raw`、`slot-a/`、`slot-b/`、`install.md` |
| 5 | 上传整个目录 | 放到 `/data/keel/config` 指向的更新源;版本号由 `mkosi.version` + 构建时 `-B` 自动 bump(§6) |
| 6 | 在真机演练 | 至少一次 `check → fetch → stage --reboot`;**有 schema 变更时必须加一次回滚演练**(§4) |
| 7 | 回写文档 | 踩到的坑进 `AGENTS.md`;新决策进 `decisions.md`;命令或单元的行为变化同步到本文档 |

## 9. 怎么复验更新与回滚(VM 演练)

```bash
sudo tools/build-container.sh -p <临时密码> drill
```

一条命令做完这件事(细节见 `tools/build-container.sh` 的 `drill` 模式与
`mkosi.extra-test/usr/lib/keel/ota-drill`):

1. `tools/build.sh` 构建**新版本载荷** → `dist/keel-<版本>/`;
2. 用显式**较旧**的版本号(`2000.01.01.0001`)构建引导镜像 —— 这样
   `os-update check` 才会认为"有新版本";镜像里的 test profile 带一个**自驱动状态机**
   (`keel-ota-drill.service`,状态在 `/data/keel/ota-drill.state`,跨重启);
3. 把安装镜像 `truncate -s 40G`(载荷 4 个产物约 13 GiB,而 live 镜像的 `/data` 只有 1 GiB;
   首启会把 `data` 扩到整盘 ⇒ 27 GiB);
4. 在容器里起 HTTP 源(guest 走 QEMU 用户态网络访问 `http://10.0.2.2:8000/good`);
5. 起 VM,状态机自己跑:

| 阶段 | 做什么 | 期望证据 |
|---|---|---|
| p0 | 等源 → `check` → `fetch` → `stage` → 重启 | `/data/ota/<新版本>/` 里 4 个产物 + sha256 全对;ESP 上出现 `keel-b+3.efi`;`state` 里有 pending |
| p1 | 已在新槽:记录证据 → `rollback` → 重启 | 当前槽 b、版本 = 载荷版本;ESP 上条目已 bless 成 `keel-b.efi`;`keel-confirm` 日志显示"更新成功"、`last_result=success`、pending 已清 |
| p2 | 已回旧槽:记录证据 | 当前槽 a、版本回到引导镜像那个(2000.01.01.0001) |

证据全在控制台(宿主终端的 `mkosi vm` 输出)与 guest 的 `/data/keel/ota-drill.log` 里。
**还没做的**:破坏性回滚演练(让新槽连着三次到不了 `boot-complete`,看引导器自动退回旧槽)——
见 `docs/roadmap.md`。
