# 文档与代码约定

> 状态：accepted | 更新：2026-11-10
> 这份文件定义“怎么写”，不定义“写什么”。所有 agent 必须先读。
> 分支/PR 见 [`workflow.md`](workflow.md)，测试见 [`testing.md`](testing.md)，CI 见 [`ci.md`](ci.md)。

## 1. 语言政策

### 1.1 文档

- 文档正文用中文。
- 代码块、命令、路径、键名、标识符用英文 ASCII。
- 中文标点只出现在正文；不要出现在代码块里。

### 1.2 代码

以下内容**只能**是英文 ASCII：

| 范围 | 例子 |
|---|---|
| 标识符 | `root_slot`, `esp_path` |
| 注释 | `/* read the active slot from cmdline */` |
| 日志/错误 | `failed to open root partition` |
| `printf`/`echo` 字符串 | `usage: keel-update stage <dir>` |
| unit `Description=` | `Description=keel update stage` |
| commit message | `feat(update): write root before UKI` |
| 分支名 | `feat/ab-update-rollback` |
| 文件名/目录名 | `keel-update.c`, `initrd/units/` |
| 路径 | `/dev/system/root_a` |
| 用户名/主机名 | `admin`, `keel` |
| kernel cmdline | `root=/dev/system/root_a` |
| config key | `DHCP=yes` |
| 测试输出 | `PASS: root is erofs` |

不要使用：中文、全角标点、智能引号、em dash、中文空格、BOM。

### 1.3 为什么

- 编译器、终端、CI、diff、跨平台编辑器对非 ASCII 源码的处理不一致。
- 字体缺失会导致乱码，日志和报错不可读。
- 代码里的中文注释在 review/搜索/补丁里是负担。
- 文档中文不影响可读性；代码英文保证可移植。

## 2. 编码与换行

- 文档：UTF-8，无 BOM，LF，文件末尾换行。
- 源码/配置/脚本：ASCII，LF，文件末尾换行。
- `.editorconfig` 提供基础设置。
- `tools/check-ascii.sh` 检查源码目录；pre-commit/CI 必须跑。
- 构建时用 `LANG=C.UTF-8`；需要稳定排序时用 `LC_ALL=C`。

## 3. 文档类型与 front matter

### 3.1 Feature

```yaml
---
id: F-003
title: A/B update and rollback
status: design
target: v0.3
owner: TBD
updated: 2026-11-10
depends: [F-002, F-005]
---
```

正文固定章节：

1. Why
2. Scope / non-goals
3. User-visible behavior
4. Interfaces
5. Design
6. Failure modes / recovery
7. Acceptance criteria
8. Open questions / ADR links
9. Test plan
10. Changelog

### 3.2 ADR

```yaml
---
id: ADR-0003
title: Separate /etc volume, no overlay
status: accepted
date: 2026-11-10
deciders: [maintainer]
---
```

正文固定章节：

1. Context
2. Decision
3. Consequences
4. Alternatives rejected
5. References

规则：**accepted 之后不改正文**。要改就写新 ADR，在旧 ADR 头部加 `Superseded by ADR-xxxx`。

### 3.3 Open question

```yaml
---
id: Q-0001
question: podman rootful or rootless in v0.4?
blocking: F-008 / v0.4
owner: TBD
updated: 2026-11-10
---
```

正文：Context / Options / Recommendation / Decision gate / Notes。

### 3.4 Verification

见 `templates/verification.md`。证据必须包含环境 ID、命令、输出摘要、日期。

## 4. ID 规则

- `F-xxx`：feature，三位数字，一旦分配不复用。
- `ADR-xxxx`：四位数字，只增不改。
- `Q-xxxx`：四位数字，决定后关闭，不删除。
- `L-xxx`：lesson，三位数字。
- `A-xxx`：assumption，三位数字。
- `E0`–`E3`：验证环境。

编号不重排；删除的东西在索引里标 `rejected`/`closed`，不回收编号。

## 5. 文档规模

- 目标：单文件 < 300 行。
- 超过 300 行：按 feature/topic 拆，不养“大而全”。
- `outline.md` < 200 行；它只是地图。
- `lessons.md` 可以到 400 行，但每条要短；超过就按 boot/storage/process 拆。

## 6. 多 agent 规则

- 一个 agent 一次只负责一个 feature 文件。
- 不要同时改 `outline.md`、`roadmap.md`、`decisions/`。
- 需要新决策：先写 `open/Q-xxxx.md`，由维护者转成 ADR。
- 需要改已接受的 ADR：写新 ADR，不直接改旧文。
- 文档开头写 `Context`，假设读者没读过其他文件。
- 用链接，不复制表；一个事实只有一个家。
- 分支用 `<type>/<slug>`，不带 `F-xxx`；例如 `feat/ab-update-rollback`。
- `feat/*`、`refactor/*` 和架构性 `ci/*`/`chore/*` 先合设计 PR，再写代码。
- 实现 PR 必须带 unit test；bug fix 必须带 regression test。
- 提交前跑 `tools/check-ascii.sh`、`tools/check-branch-name.sh`、`tools/check-commit-msg.sh`，并更新 feature 的 `status`/`updated`。

## 7. 代码规则

- **关键逻辑编译**：分区写入、更新顺序、启动条目选择、状态读取，用 C/C++/Rust。
- **shell 只做胶水**：启动脚本、一次性安装命令可以 shell；不要写状态机。
- **错误信息英文**，包含“哪个设备/哪个文件/哪个步骤”。
- **不吞错误**：`set -eu`；C/Rust 检查每个返回值。
- **不把机器身份写进仓库/镜像**：machine-id、ssh host key、密码、私钥、个人 authorized_keys。
- **先写临时文件/先确认空间，再改目标**；失败要清理。
- **不覆盖两个槽**；更新只碰非活动槽。
- **单元测试用 cmocka**：host 编译，`tests/unit/`，每个模块/错误路径都有测试；bug fix 先写 regression test。

## 8. Commit 与 PR 规则

- commit 用 Conventional Commits：`<type>(<scope>): <summary>`。
- `scope` 用领域词（`update`、`esp`、`initrd`、`installer`），**不用 `F-xxx`**。
- summary 小写祈使句，<= 72 字符，不加句号；body 写为什么。
- 一个 commit 只做一件事；不要混文档重构和代码改动。
- 分支用 `<type>/<slug>`，全小写英文 ASCII，不带 `F-xxx`；详见 `workflow.md`。
- `feat/*`、`refactor/*` 和架构性 `ci/*`/`chore/*` 必须先合设计 PR；实现 PR 写 `Design-PR: #123`。
- 一个 PR 一个关注点；目标 <= 400 行，超过 800 行必须拆。
- 提交前：
  1. `tools/check-ascii.sh`
  2. `tools/check-branch-name.sh`
  3. `tools/check-commit-msg.sh`
  4. 相关构建/静态检查/unit test
  5. 如果改了启动/存储：在声明环境里启动一次，记录证据
- 不在 commit 里放密钥、机器 ID、真实密码、个人路径。

## 9. Review checklist

- [ ] 文档中文，代码 ASCII。
- [ ] 没有重复的事实表；链接正确。
- [ ] 新决策有 ADR；新问题有 Q。
- [ ] feature 的 status/updated 已更新。
- [ ] 失败模式写了；救援路径可用。
- [ ] 验收标准是可观察的，不是“命令返回 0”。
- [ ] 没有引入只有作者知道的隐式约定。
- [ ] 没有把上一项目的专有名词/编号当上下文。
- [ ] 分支名符合 `<type>/<slug>`，没有 `F-xxx`。
- [ ] `feat/refactor` 有已合并的设计 PR。
- [ ] 代码 PR 有 unit test；bug fix 有 regression test。
- [ ] commit/PR 标题符合 Conventional Commits。

## 10. 归档

- 历史讨论稿放 `docs/archive/`，文件名带日期。
- 被取代的 ADR 不删除；标 `superseded`。
- 被否决的 feature 标 `rejected`，保留理由。
