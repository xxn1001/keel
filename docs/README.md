# keel2 文档地图

> 状态：设计阶段。没有可启动产物。
> 本文是入口；先读这里，再按顺序读。

## 1. 文档分层

| 文件 | 职责 | 变化频率 |
|---|---|---|
| [`outline.md`](outline.md) | 稳定地图：特征、磁盘布局、initrd、版本规划 | 低 |
| [`roadmap.md`](roadmap.md) | 版本、特征映射、gate | 中 |
| [`layout.md`](layout.md) | GPT / LVM / 文件系统 / 挂载的精确表 | 低 |
| [`initrd.md`](initrd.md) | 启动阶段、systemd units、挂载顺序、救援入口 | 低 |
| [`workflow.md`](workflow.md) | 分支、commit、设计 PR、review、merge、release | 低 |
| [`testing.md`](testing.md) | unit / build / integration 分层、标准、证据 | 中 |
| [`ci.md`](ci.md) | GitHub Actions、无 KVM 阶段、job、缓存、artifact | 中 |
| [`features/`](features/) | 一个特征一个文件：why / what / 接口 / 验收 | 中 |
| [`decisions/`](decisions/) | ADR，已拍板，append-only | 只增不改 |
| [`open/`](open/) | 未决问题：选项、建议、阻塞谁 | 到决定为止 |
| [`lessons.md`](lessons.md) | 从上一个项目提取的通用坑，不引用旧编号 | 低 |
| [`verification.md`](verification.md) | 环境分级、假设台账、测试矩阵、证据 | 中 |
| [`conventions.md`](conventions.md) | 语言、命名、文档模板 | 低 |
| [`glossary.md`](glossary.md) | 中文术语 ↔ 英文标识符 | 低 |
| [`templates/`](templates/) | feature / ADR / open question / verification 模板 | 低 |
| [`archive/`](archive/) | 历史讨论稿；不是当前设计 | 不变 |

## 2. 阅读顺序

### 人

1. `README.md`（仓库根）
2. `outline.md`
3. `roadmap.md`
4. `features/README.md`，然后读你关心的 `F-xxx.md`
5. `layout.md`、`initrd.md`
6. `decisions/README.md`，按需读 ADR
7. `workflow.md`、`testing.md`、`ci.md`
8. `verification.md`
9. `lessons.md`

### Agent

1. 本文件
2. `conventions.md`
3. `workflow.md`
4. `testing.md`
5. `ci.md`
6. 你负责的那一个 `features/F-xxx.md`
7. 它链接的 ADR
8. `lessons.md` 中“适用于”该 feature 的条目
9. `verification.md` 中该 feature 的验证状态

不要一次加载整个 `decisions/` 或 `lessons/`；按 feature 链接读。

## 3. 状态图例

### Feature

| 状态 | 含义 |
|---|---|
| `idea` | 只是想法，没有范围 |
| `proposed` | 范围草案，尚未 accepted |
| `accepted` | 范围已定，可以设计 |
| `design` | 正在写设计 |
| `implementing` | 正在写代码 |
| `done` | 验收通过 |
| `deferred` | 明确推迟，不是 v1 |
| `rejected` | 不做，保留理由 |

### ADR

| 状态 | 含义 |
|---|---|
| `accepted` | 已生效 |
| `superseded` | 被新 ADR 取代，正文不再修改 |
| `rejected` | 提案被否决，保留理由 |

### 验证环境

| ID | 含义 |
|---|---|
| `E0` | 只能读文档/静态检查；不能启动内核 |
| `E1` | QEMU TCG（无 KVM），慢，可启动 |
| `E2` | QEMU KVM |
| `E3` | 真机（目标服务器） |

## 4. 写作规则（摘要）

- 文档中文；代码/注释/日志/提交/文件名英文 ASCII。详见 `conventions.md`。
- 一个事实只写在一处；其他文档链接过去。
- ADR 只增不改；新决定写新 ADR。
- 未决问题写进 `open/`，不要藏在聊天里。
- “已验证”必须带环境 + 命令输出；没有证据就写“未验证”。
- 单文件尽量 < 300 行；按 feature 拆。

## 5. 当前阶段

- 文档框架：v0.2（system VG + data 分区 + recovery）。
- 协作规则：已定稿（`workflow.md`、`testing.md`、`ci.md`）。
- 仓库：已 `git init -b main`，尚未提交；等待 initial commit。
- 代码：未开始。
- 第一批要验证的假设：`verification.md` 的 A-001、A-002、A-004、A-017、A-018。
- 在这些假设通过之前，不写安装器和自动回滚。
