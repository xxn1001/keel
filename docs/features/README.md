# 特征索引

> 状态：living document | 更新：2026-11-10
> 特征表（ID / 状态 / 目标版本）的**唯一来源**是 [`../outline.md`](../outline.md) 第 2 节。
> 本文只写工作流和规则，不复制表。

## 1. 什么是 feature

Feature 是一个**能力**，不是任务。例如“A/B 更新 + 回滚”是一个 feature；“写 update 脚本”不是。

- ID：`F-xxx`，三位数字，一旦分配不复用。
- 一个 feature 一个文件：`F-xxx-short-name.md`。
- 文件名 ASCII，小写，连字符。
- 状态：`idea` / `proposed` / `accepted` / `design` / `implementing` / `done` / `deferred` / `rejected`。
- 目标：`v0.1` / `v0.2` / `v0.3` / `v0.4` / `v1.0` / `future`。

## 2. 新增 feature

1. 先在 `outline.md` 的特征表加一行（维护者）。
2. 复制 [`../templates/feature.md`](../templates/feature.md) 到 `F-xxx-name.md`。
3. 填 front matter 和 Why/Scope；状态先 `idea` 或 `accepted`。
4. 如果涉及架构决策，写 `open/Q-xxxx.md`，不要自己拍板。
5. 设计完成后状态改 `design`；开始写代码改 `implementing`；验收通过改 `done`。

### 2.1 设计与实现分开

- `F-xxx` 只用于**文档索引**；不要写进分支名、commit scope、PR 标题。
- 设计阶段分支用 `docs/design-<slug>`，先合设计 PR。
- 实现阶段分支用 `feat/<slug>`，PR 里写 `Design-PR: #123`。
- 设计 PR 只改 feature/ADR/Q，不写代码；实现 PR 不静默改架构。
- 详细规则见 [`../workflow.md`](../workflow.md)。

## 3. 写作要求

- 开头写 `Context`，假设读者没看过其他文档。
- 写清 **non-goals**；范围膨胀是主要风险。
- 接口必须可观察：命令、unit、文件、cmdline、退出码。
- 失败模式必须写：起不来、挂不上、空间不足、回滚失败。
- 验收标准必须是命令/输出，不是“工作正常”。
- 链接 ADR，不复制决策理由。
- 单文件 < 300 行；超了拆成子 feature 或设计文档。

## 4. 依赖

依赖只写 feature ID，不写“先做 X 再说”。依赖图由 `outline.md` 的表维护。

## 5. 分组

| 组 | Features |
|---|---|
| 基底 | F-001, F-002, F-004, F-015 |
| 启动 | F-005, F-006 |
| 更新 | F-003, F-011 |
| 运维 | F-012, F-013, F-014 |
| 用户态 | F-007, F-008 |
| 未来 | F-009, F-010 |

## 6. 模板

- [`../templates/feature.md`](../templates/feature.md)
- [`../templates/adr.md`](../templates/adr.md)
- [`../templates/open-question.md`](../templates/open-question.md)
- [`../templates/verification.md`](../templates/verification.md)
