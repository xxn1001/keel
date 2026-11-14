# 测试策略

> 状态：accepted | 更新：2026-11-14
> 本文定义 unit / build / integration / real-hardware 的分层、标准、何时跑。
> CI 具体 job 见 [`ci.md`](ci.md)；验证环境见 [`verification.md`](verification.md)。

## 1. 测试金字塔

| 层 | 在哪跑 | 典型耗时 | 何时跑 | 作用 |
|---|---|---|---|---|
| Unit | host | 秒级 | 每个 PR | 纯逻辑、错误路径 |
| Build/config | host | 10–60 分钟 | `ci:build` / `main` / tag | Buildroot 配置、交叉编译、镜像产物 |
| Integration smoke | QEMU TCG | 5–15 分钟 | `ci:build` / `main` / tag | 能启动、能登录、关键挂载 |
| Full integration | QEMU KVM | 30–90 分钟 | nightly / 手动 / E2 | 更新、回滚、救援、安装 |
| Real hardware | E3 服务器 | 小时/天 | release / 手动 | 真固件、真磁盘、真网络 |

原则：

- 越往下越贵，越少跑。
- 每个 PR 必须有 unit；涉及启动/存储的 PR 必须有 build + smoke。
- 破坏性场景（坏槽、坏 VG、清空 ESP）不进默认 PR CI。
- 没有证据的“测试通过”不算通过。

## 2. 单元测试

### 2.1 框架

- C：**cmocka**。
- Rust：`cargo test`（如果以后用）。
- Python：`pytest`。
- 目录：`tests/unit/`，按 `src/` 模块镜像。

C 测试的构建方式：

- host `cc` 编译，不经过 Buildroot 交叉编译。
- `pkg-config cmocka`；CI 装 `libcmocka-dev`。
- 开启 `-fsanitize=address,undefined -fno-omit-frame-pointer`。
- `gcov`/`lcov` 生成覆盖率报告。

### 2.2 写什么

优先测纯函数和状态转换：

- `/proc/cmdline` 的 `root=/dev/system/root_a|root_b` 解析。
- 当前槽/目标槽选择；拒绝目标等于当前。
- payload 大小、分区大小、ESP 剩余空间检查。
- boot entry 文件名：`keel-b+3.efi` vs entry ID `keel-b`。
- 路径拼接、`by-partlabel`/`by-uuid` 解析。
- 状态文件解析、版本比较。
- 错误码映射与日志文本。

必须测错误路径：

- `ENOSPC`、`EACCES`、`EIO`。
- 短写、`fsync` 失败。
- 目标已挂载。
- payload 缺失/超大。
- 非法 slot 名。

### 2.3 规则

- 每个新模块必须有 unit test。
- 每个 bug fix 必须先有 regression test（红），再修（绿）。
- 测试不依赖 root、不依赖真实磁盘、不依赖网络。
- 用临时目录/内存 fixture；测试后清理。
- 不把机器身份/真实密钥放进 fixture。
- 目标：关键模块（更新器、槽选择、空间检查）覆盖率 80%+；整体先报告不设硬门槛。
- 测试命名：`test_<module>_<behavior>`。

### 2.4 命令

目标接口（第一个 Makefile 落地时实现）：

```sh
make test-unit
make test-unit COVERAGE=1
```

CI 必须调用同一个入口，避免“本地能过、CI 不一样”。

## 3. Build / config 测试

### 3.1 Buildroot 构建

```sh
make bootstrap
make defconfig
make build
```

检查：

- `out/images/` 有 root.erofs、recovery.erofs、UKI、initrd、manifest。
- `out/build/` 没有编译警告（`-Werror`）。
- `make savedefconfig` 后 `configs/*_defconfig` 无 drift。
- `utils/check-package -b package/...` 通过。
- 改 package recipe 时跑 `utils/test-pkg`（如果 external package 可用）。
- 可选 `make legal-info` 检查 license。

### 3.2 规则

- 不修改 `vendor/buildroot/`；CI 检查它没有被改。
- 构建产物不提交。
- Buildroot 版本升级单独 PR，跑完整 build + smoke。
- 不靠 Buildroot autobuilders；那是上游的。
- `ci:build` 标签由维护者加；agent 可以请求。

## 4. 集成测试

### 4.1 Harness

- 目录：`tests/integration/`。
- Python + `pytest`。
- QEMU x86_64 + OVMF；串口 socket/file；qcov2 磁盘。
- 测试自己构建或使用 CI artifact；本地可用已有 `out/images/`。
- 每个测试保存：串口日志、`journalctl -b`、`findmnt`、`lvs`、`bootctl list`。

### 4.2 标记

```python
@pytest.mark.smoke        # boot/login/mounts
@pytest.mark.slow         # update/rollback/install
@pytest.mark.destructive  # bad slot/bad VG/wipe ESP
@pytest.mark.requires_kvm # needs E2
```

默认 `pytest -m smoke`；完整用 `pytest -m "slow or destructive"`。

### 4.3 场景

| 场景 | 层 | 检查 |
|---|---|---|
| boot | smoke | 串口登录；`systemctl --failed` 为空 |
| mounts | smoke | `findmnt / /etc /var /home /boot` |
| erofs | smoke | `/` 是 erofs，`ro` |
| LVM | smoke | `lvs` 显示 `root_a`/`root_b`/`etc` active |
| data | smoke | `findmnt /var /home` 是 btrfs 子卷 |
| etc | smoke | `/etc` 是 ext4；machine-id 稳定 |
| A/B update | slow | stage → reboot → 新槽 → bless |
| rollback | destructive | 坏 B 槽 → 自动回 A |
| recovery | destructive | `keel.recovery=1` 进 recovery；LVM/etc/data 失败自动 fallback |
| install | slow | 空 qcow2 → GPT/LVM/btrfs/recovery → 首启 |
| var-full | destructive | 写满 `/var`，`/etc` 仍可写，`/home` 受影响 |
| zram | slow | `swapon --show` 有 zram0 |
| podman | slow | `podman run --rm hello-world` |
| headless | smoke | 串口 + SSH；拔网线不影响启动 |

### 4.4 TCG vs KVM

- GitHub hosted runner 没有 `/dev/kvm`，只能 TCG（E1）。
- TCG 适合 smoke；更新/回滚/救援的时序可能变慢，不能替代 E2/E3。
- 没有 KVM 时，destructive 测试手动跑，记录到 `verification.md`。
- 有 self-hosted KVM 后，把 slow/destructive 加进 nightly/PR full。

## 5. 何时跑

| 时机 | 必须跑 |
|---|---|
| 设计 PR | 文档 link/lint；不跑 build/integration |
| 每个代码 PR | unit + lint；涉及启动/存储时请求 `ci:build` 标签跑 build + smoke |
| PR `ci:build` | build + smoke |
| merge 到 `main` | build + smoke |
| nightly（可选） | build + smoke；KVM 可用时加 slow |
| tag | build + smoke + release 检查；E3 手动 |
| 手动 E2/E3 | full + destructive + 真机 |

## 6. 证据

每次测试记录：

- 环境：E0/E1/E2/E3。
- 命令原文。
- 关键输出，不是“成功”。
- 版本/commit。
- 失败：现象、根因、下一步。

写到 [`verification.md`](verification.md)，不要只留在聊天里。

## 7. Flaky 测试

- 不自动重试掩盖失败；先定位。
- 确认是环境抖动（QEMU 启动慢、TCG 超时）才加 timeout/retry。
- 隔离 flaky 测试，开 issue/Q；不要长期 `skip`。
- 测试必须可重复；依赖时间/随机数要固定 seed。

## 8. 测试数据

- 用合成 payload、临时 qcow2、测试用 host key。
- 不放真实机器 ID、真实 SSH key、真实密码。
- `tests/fixtures/` 只放小文件；大镜像不进 git。
- 测试结束清理临时目录/挂载。

## 9. Changelog

| 日期 | 变更 |
|---|---|
| 2026-11-10 | 初稿：cmocka unit、Buildroot build、QEMU smoke/full 分层 |
