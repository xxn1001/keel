# machines/ —— 硬件与单机差异

**这个目录默认是空的,这是有意的。**

按照 `AGENTS.md` 的约定:**构建期差异进仓库,运行期状态进 `/Volume`**。
而"按机器分支"在这个项目里几乎不是一个真实的维度:

| 常见误解 | 实际情况 |
|---|---|
| "AMD 机器要单独一份配置(微码)" | 微码两个厂商都装(`amd64-microcode` + `intel-microcode`),mkosi 会把两家的微码都前置进 UKI 的 initrd,内核自己挑对的。**不需要分支**(不变量 8) |
| "KVM/VFIO 要单独放进去" | `kvm_amd`/`kvm_intel`/`vfio_pci` 本来就在内核包里,装内核就有。**不需要额外做什么** |
| "每台机器的内核参数不一样" | 参数烧在 UKI 里改不了,所以策略是"机器无关的超集"(IOMMU 三件套对所有机器无害)+ 把硬件配置挪进 `/etc`(那里经 overlay 持久化)。后门见 `AGENTS.md` 坑 #4 |

## 什么情况下才该在这里加文件

只有当**构建产物本身**需要按硬件家族不同时,例如:

- 挑固件包:笔记本需要 `firmware-iwlwifi` / `firmware-amd-graphics` 之类,
  而 server 变体几乎不需要任何固件(显卡直通给 VM,宿主不装驱动);
- 按机型需要不同的内核模块集(`KernelModules=`)或不同的 initrd 内容;
- 某个机型需要额外的内核参数(那就必须单独构建,见 `docs/architecture.md` §13 的风险 R5)。

命名约定:`laptop-generic.conf`、`host-<机器名>.conf`、`cpu-amd.conf`……
用 `--include=machines/xxx.conf` 或在命令行显式指定来叠加。

## 千万不要放在这里

- 主机名、Wi-Fi 密码、静态 IP、vfio 绑定哪块显卡、VM 定义 —— 这些是**运行期状态**,
  属于 `/Volume`,不属于 git。
- 任何密钥、口令(仓库的 `.gitignore` 已经排除常见密钥文件名)。

## 备份单机状态的建议做法

运行期状态默认只存在于那台机器上。如果想给它留一份可版本管理的副本,
可以把**非机密**的部分手工导出成一个文件存回来,例如:

```bash
# 在目标机器上
{ echo "# 导出自 $(hostname),$(date -u +%F)"; cat /Volume/keel/config; } \
    > machines/host-$(hostname).conf
```

机密(密钥、口令、Wi-Fi)不要进仓库。
