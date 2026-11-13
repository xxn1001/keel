# 协作与分支模型

> 状态：accepted | 更新：2026-11-10
> 本文定义分支、commit、设计 PR、实现 PR、review、merge、release。
> 测试策略见 [`testing.md`](testing.md)，CI 见 [`ci.md`](ci.md)。

## 1. 原则

1. **主干开发**：`main` 始终可构建、可启动、可发布。
2. **短分支**：所有改动从 `main` 开分支，通过 PR 合并；不搞长期 `develop`。
3. **一个 PR 一件事**：不混功能、重构、格式化、依赖升级。
4. **设计先行**：`feat/*`、`refactor/*` 和架构性 `ci/*`/`chore/*` 先合设计 PR，再写代码。
5. **人 review，机器检查**：agent 写代码和测试；维护者 review 并 merge；CI 只做检查，不自动合并。
6. **Feature 编号只属于文档**：`F-xxx` 是给人看的索引，不进入分支名、commit scope 或 PR 标题。
7. **可回滚**：每个改动都能 revert；不 force-push `main`。

## 2. 角色

| 角色 | 谁 | 能做什么 | 不能做什么 |
|---|---|---|---|
| Author | agent / contributor | 开分支、写代码/文档/测试、开 PR、回应 review | 直接 push `main`、self-approve、merge |
| Maintainer | 项目所有者 | review、approve、merge、打 tag | 绕过 CI（紧急情况也要记录） |
| CI | GitHub Actions | lint、unit、build、smoke、artifact | 修改代码、自动 merge |

## 3. 分支模型

### 3.1 基本规则

- 从最新 `main` 开分支。
- 分支生命周期尽量短；至少每天 rebase 一次 `main`。
- 用 `git rebase origin/main`，不要 `git merge main` 进功能分支（保持线性）。
- 合并后删除远端分支。
- `main` 受保护：禁止直接 push、force push、删除。

### 3.2 命名

格式：

```text
<type>/<slug>
```

`type` 固定为：

| type | 用途 |
|---|---|
| `feat` | 新功能/能力 |
| `fix` | 修 bug |
| `docs` | 文档、ADR、设计 PR |
| `test` | 只改测试 |
| `ci` | CI/构建流程 |
| `refactor` | 不改行为的重构 |
| `chore` | 杂项、版本升级 |
| `build` | 构建系统 |
| `perf` | 性能 |
| `revert` | 回滚某个提交 |

`slug`：

- 全小写英文 ASCII，kebab-case。
- 描述“改什么”，不写“implement/add”。
- 不带 `F-xxx`。
- 不用中文、冒号、下划线、空格。
- 建议 <= 50 字符。

正则：

```text
^(feat|fix|docs|test|ci|refactor|chore|build|perf|revert)/[a-z0-9][a-z0-9.-]*$
```

示例：

```text
feat/ab-update-rollback
feat/system-vg
feat/systemd-initrd
feat/headless-network
fix/esp-space-check
fix/etc-mount-order
docs/design-ab-update-rollback
docs/adr-update-rollback
ci/github-actions
refactor/keel-update-slot
chore/bump-buildroot-2026.02
```

同一功能拆多块时用语义后缀：

```text
feat/ab-update-stage
feat/ab-update-rollback
```

如果两个 agent 真撞名，加语义后缀，不要用无意义的 `-2`。

## 4. Commit message

用 Conventional Commits：

```text
<type>(<scope>): <summary>
```

- `type` 同上；`scope` 是领域，不是 `F-xxx`。
- `summary` 小写祈使句，<= 72 字符，不加句号。
- body 写“为什么”，不写“改了什么”。
- footer 可以写 `Refs: docs/features/F-003-ab-update.md`、`ADR-0006`。

示例：

```text
feat(update): write root before UKI
fix(esp): reject target equal to active slot
docs(adr): record boot counting sequence
test(update): add rollback regression
ci: cache Buildroot downloads
```

规则：

- 一个 commit 一件事。
- 不写 `F-003:` 作为 scope；scope 用 `update`、`esp`、`initrd`、`installer` 等领域词。
- 不把多个不相关改动塞进一个 commit。
- 合并时 squash；PR 标题必须符合上面的格式。

## 5. 设计 PR（强制）

### 5.1 何时需要

| 分支 | 设计 PR |
|---|---|
| `feat/*` | **必须** |
| `refactor/*` | **必须** |
| `ci/*`、`chore/*` 改架构/构建方式 | **必须** |
| `ci/*` 只改缓存/超时等细节 | 不需要 |
| `fix/*` | 不强制；改架构/接口/ADR 时必须 |
| `docs/*`、`test/*` | 不需要 |

### 5.2 内容

设计 PR 只改文档：

- `docs/features/F-xxx.md`（范围、接口、失败模式、验收）。
- 新 ADR 或更新 Q。
- 必要时更新 `layout.md`、`initrd.md`、`roadmap.md`。
- 不写实现代码。

分支：

```text
docs/design-<slug>
```

PR 标题：

```text
docs(design): add A/B rollback design
```

### 5.3 顺序

1. 设计 PR 合并到 `main`。
2. 实现 PR 从最新 `main` 开分支。
3. 实现 PR 描述里写：

```text
Design-PR: #123
```

4. 实现过程中发现设计要变：停下来，开新的设计 PR；不要在实现 PR 里静默改架构。

执行方式：PR 模板 + review 强制；以后可以加 GitHub Action 检查 `feat/*` 是否填了 `Design-PR`。暂时不搞复杂 bot。

## 6. 实现 PR

### 6.1 必须包含

- 代码。
- 单元测试；bug fix 必须有 regression test。
- 文档更新：feature 状态、接口、失败模式、ADR/Q。
- 测试证据：命令 + 关键输出。
- 风险与回滚说明。

### 6.2 PR 模板

模板在 `.github/pull_request_template.md`，固定字段：

```text
Summary
Design-PR
What changed
Why
Tests
Evidence
Docs
Risk / rollback
Checklist
```

### 6.3 大小

- 目标 <= 400 行改动（不含生成的 lockfile/二进制）。
- 超过 800 行必须拆分，或说明为什么不能拆。
- 大 feature 用 stacked PR：每个 PR 可独立 review，按顺序合并。
- 不把重构和功能混在一个 PR。

### 6.4 禁止

- 提交 `out/`、`dl/`、`vendor/buildroot/`、镜像、日志、密钥。
- 为了让 CI 变绿而改 CI/测试（需要单独 PR）。
- 在 PR 里顺手升级 Buildroot/依赖。
- 直接 push `main`。
- 自己 approve 自己的 PR。

## 7. Review 与 merge

维护者 review 每个 PR。合并前必须满足：

- [ ] CI 全绿（required checks）。
- [ ] 至少 1 个 approval（维护者）。
- [ ] 所有 conversation resolved。
- [ ] 分支已 rebase 到最新 `main`。
- [ ] PR 标题符合 Conventional Commits。
- [ ] 没有未说明的架构变化。
- [ ] 测试证据可复现。

规则：

- agent 不能 approve/merge；CI 通过不等于批准。
- push 新 commit 后，旧 approval 失效（dismiss stale approvals）。
- review 后不要 force-push；追加 commit，合并时 squash。
- 用 **squash merge**；禁用 merge commit 和 rebase merge。
- 合并后删除分支。
- 回滚用新 PR `revert: ...`，不要 force-push `main`。

## 8. Release

- tag 格式：`vMAJOR.MINOR.PATCH`，例如 `v0.1.0`。
- annotated tag，从 `main` 打。
- 只有 `docs/roadmap.md` 的 gate 通过、release CI 绿、真机验证记录存在时才打 tag。
- v1 不建长期 release 分支；需要维护旧版本时再开 `release/v0.3`。
- hotfix：`fix/*` PR 到 `main`，重新打 patch tag；不直接改 tag。
- Release notes 写：版本、变更、已知问题、验证环境。

## 9. GitHub 设置清单

`main` 分支保护：

- [x] Require a pull request before merging.
- [x] Require approvals: 1.
- [x] Dismiss stale pull request approvals when new commits are pushed.
- [x] Require review from Code Owners（如果启用）。
- [x] Require status checks to pass.
- [x] Require branches to be up to date before merging.
- [x] Require conversation resolution.
- [x] Require linear history.
- [x] Do not allow force pushes.
- [x] Do not allow deletions.
- [x] Include administrators.
- [x] Restrict who can push.

仓库设置：

- [x] Allow squash merging only.
- [x] Automatically delete head branches.
- [x] Actions permissions: read-only by default.
- [x] No auto-merge.

## 10. Changelog

| 日期 | 变更 |
|---|---|
| 2026-11-10 | 初稿：trunk-based、`type/name`、设计 PR 强制、squash merge |
