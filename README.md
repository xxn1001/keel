# common-os

一个 **不可变基座 + A/B 双槽 + nix 用户态** 的操作系统镜像项目。

用 [mkosi](https://github.com/systemd/mkosi) 构建,基底是 Debian stable。设计要点:

- **基础系统只读**。A/B 两个槽,每个槽带一个完整的 UKI(内核 + initrd + `root=` 配对),
  更新写入非活动槽 → 重启切换 → 启动失败自动回滚(固件/引导器级别的 boot counting)。
- **可写状态全部集中在 `/Volume` 一个分区上**:
  `/var`、`/root`、`/nix` 是指向 `/Volume` 的符号链接,`/home` 是 bind mount。
- **`/etc` 可写**。只读镜像的 `/etc` 作为 lower,`/Volume/overlayfs/etc` 作为 upper 挂 overlayfs:
  配置改动会持久化,同时新版本镜像里的默认值依然生效(不会被旧副本永久遮蔽)。
- **用户软件走 nix**,`/nix` 落在 `/Volume` 上 —— 于是"基础系统原子更新"和"随便装软件"彻底解耦。
  基础镜像里不放应用,也不留可用的发行版包管理器。

最终目标是把它装到一台**不可变基座 + 虚拟化服务器**上(GPU 直通给 VM,宿主不需要显卡驱动);
现阶段先跑在笔记本上,边用边改,等上服务器时问题已经磨平。

## 现在是什么状态

早期开发中。构建、安装、更新方式会写在 `docs/`(待补)。
**要接手这个项目,请先读 [`AGENTS.md`](AGENTS.md)** —— 里面有架构不变量、目录约定和已知的坑。

## 快速开始(待实现)

```bash
tools/verify.sh                 # 静态校验:mkosi summary / repart dry-run / systemd-analyze / shellcheck
tools/build.sh                  # 产出安装镜像 + A/B 更新载荷 + manifest
sudo tools/burn.sh /dev/nvme0n1 # 写入目标盘
```
