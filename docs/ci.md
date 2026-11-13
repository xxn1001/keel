# CI 设计（GitHub Actions）

> 状态：accepted | 更新：2026-11-10
> 当前阶段：GitHub-hosted runner，无常驻服务器，无 KVM。
> 测试分层见 [`testing.md`](testing.md)。

## 1. 目标

- PR 快速反馈：lint + unit，默认不跑 30–60 分钟的 Buildroot 构建。
- `main` 始终可构建、可启动。
- tag 有可下载的构建产物和测试证据。
- 不让 CI 变成“点一下等一小时”的负担。
- 没有 KVM 就不假装有 KVM；破坏性测试留到 E2/E3。

## 2. Workflow 划分

| 文件 | 触发 | 内容 |
|---|---|---|
| `.github/workflows/pr.yml` | `pull_request` | lint、unit、docs、branch/commit policy；`ci:build` 时加 build+smoke |
| `.github/workflows/main.yml` | push `main` | build + smoke + artifact |
| `.github/workflows/release.yml` | tag `v*` | build + smoke + release artifact |
| `.github/workflows/nightly.yml` | schedule（可选） | build + smoke；KVM 可用时加 slow |

所有 workflow 都支持 `workflow_dispatch` 手动触发。

## 3. PR 默认 job

### 3.1 `lint`

- `tools/check-ascii.sh`
- `clang-format --dry-run --Werror`
- `clang-tidy`（有 compile_commands 时）
- `cppcheck`（可选）
- `shellcheck`
- `shfmt -d`
- `ruff check` / `ruff format --check`（Python）
- `markdownlint-cli2`
- `lychee` 链接检查
- `yamllint`
- `gitleaks`

### 3.2 `unit`

- 安装 `libcmocka-dev`。
- `make test-unit`。
- ASan/UBSan。
- 上传 coverage 报告（先不设硬门槛）。

### 3.3 `docs`

- `docs/` 链接检查。
- Markdown lint。
- 可选：ADR/Q 索引一致性检查。

### 3.4 `policy`

- 分支名：`tools/check-branch-name.sh "$GITHUB_HEAD_REF"`。
- PR 标题：Conventional Commits。
- commit message：`tools/check-commit-msg.sh`。
- `feat/*` 的 `Design-PR:` 字段检查（先人工，后加 action）。

## 4. `ci:build` label

PR 默认不跑 Buildroot。维护者加 `ci:build` 标签后：

1. `build` job 跑 `make bootstrap && make defconfig && make build`。
2. `smoke` job 依赖 `build`，用 QEMU TCG 启动，检查串口登录和挂载。
3. 上传 `out/images/`、manifest、串口日志。
4. 标签用完后移除；下次 push 需要重新加。

触发条件：

```text
pull_request: types: [opened, synchronize, reopened, labeled]
if: contains(github.event.pull_request.labels.*.name, 'ci:build')
```

agent 可以请求加标签，但不能依赖它来“让 CI 绿”；默认检查必须过。

## 5. `main` 和 tag

### 5.1 push `main`

自动跑：

```text
build -> smoke -> upload artifact
```

`main` 红了要优先修；不允许长期红。

### 5.2 tag `v*`

```text
build -> smoke -> upload release artifact -> release notes
```

Release 资产：

- `root.erofs`
- `keel-a.efi` / `keel-b.efi`（或构建时的槽 UKI）
- `initrd`
- `manifest`（Buildroot 版本、commit、defconfig hash、构建时间）
- 测试日志

v1 不做镜像签名；release 资产不带签名。

## 6. 缓存

| 内容 | 是否缓存 | key |
|---|---|---|
| Buildroot 下载 `dl/` | 是 | `versions.env` + Buildroot 版本 |
| ccache | 可选 | 编译器版本 + 架构 |
| `out/` | **否** | 容易脏，跨 PR 不复用 |
| Buildroot tarball | 是 | `versions.env` 的 SHA256 |

`dl/` 缓存能省下载，不省编译；首次构建仍然慢。

## 7. 超时、并发、权限

- `timeout-minutes: 120`（build）；smoke 30。
- `concurrency`: 同 PR 新 push 取消旧 run。
- `permissions: contents: read`。
- 不使用 `pull_request_target`。
- PR 不拿 secrets。
- 不自动 merge；不自动打 tag。

## 8. 没有 KVM 的边界

GitHub-hosted runner 没有 `/dev/kvm`，QEMU 只能 TCG：

- 能做：启动、登录、挂载、`bootctl list`、基本命令。
- 不能可靠做：更新/回滚时序、watchdog、panic 复位、长时间 soak。
- 这些测试标 `requires_kvm`，在 E2/E3 手动跑，记录到 `verification.md`。

不要为了让 CI “看起来全绿”而把 destructive 测试改成假通过。

## 9. 升级到 self-hosted runner

有 x86_64 + KVM 的常驻 runner 后：

1. `runs-on: [self-hosted, linux, x86_64, kvm]`。
2. 把 `build` + `smoke` 变成 PR required。
3. 加 `nightly` 的 slow/destructive。
4. 加 E2 的 update/rollback/rescue/install。
5. 仍然保持 PR 默认快；full 用 label/nightly。
6. self-hosted runner 不跑不可信 fork 的任意代码；PR 需要审批。

## 10. 安全

- workflow 权限最小化。
- 不把 token/密钥传给 build。
- 不上传机器 ID、SSH key、真实密码。
- artifact 保留 7–30 天。
- 第三方 action 钉 commit SHA，不用 `@latest`。

## 11. Workflow 落地顺序

1. 先落 `pr.yml` 的 lint/unit/docs/policy（不依赖 Buildroot）。
2. 第一个 Makefile + unit test 落地后，接 `make test-unit`。
3. 第一个可构建镜像后，落 `ci:build` + smoke。
4. 有 tag 后，落 release。
5. 有 runner 后，落 KVM/nightly。

workflow 文件在对应能力可用后再加，避免空转/假绿。

## 12. Changelog

| 日期 | 变更 |
|---|---|
| 2026-11-10 | 初稿：GitHub-hosted、无 KVM、`ci:build` 手动重活 |
