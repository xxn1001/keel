---
id: Q-0014
question: How are host-specific build parameters kept out of the committed config?
blocking: F-001 / v0.1
owner: TBD
status: closed
updated: 2026-11-22
---

# Q-0014 构建参数与宿主机解耦

## Context

现在 `configs/keel_qemu_x86_64_defconfig` 里写死了 `BR2_JLEVEL=12`。
这是某台机器的属性，不是产物的属性。

反直觉的地方（查 2025.02.19 的 `package/Makefile.in:14`）：

```make
ifeq ($(BR2_JLEVEL),0)
PARALLEL_JOBS := $(shell echo $$((1 + `getconf _NPROCESSORS_ONLN`)))
else
PARALLEL_JOBS := $(BR2_JLEVEL)
endif
```

**`0` 不是安全默认，是 `nproc + 1`。** 在 32 线程/14 GiB 的机器上直接就是 33 个 job，
必然 OOM。所以"删掉这行让它自动"是错的。

## Options

### A. `tools/build.sh` + `build.local`（建议）

- `configs/*defconfig` 里留一个保守值（`BR2_JLEVEL=4`），谁手搓都不会炸。
- `tools/build.sh` 计算并覆盖，`build.local`（不提交）提供每台机器的值。
- 公式：`JOBS = min(nproc, RAM_GiB - 2, 16)`，14 GiB 得到 12，正好是 W-0 实测通过的值。

### B. 保持写死

- 简单，但换一台机器就要改一个提交过的文件，而且改的是"产物配置"。

### C. 只靠环境变量

- 不可发现：新人跑 `make` 直接踩 `nproc+1`。

## Recommendation

A。要覆盖的参数一共四个，都归 `build.local`：

| 参数 | 说明 | 默认 |
|---|---|---|
| `JOBS` | 传给 `BR2_JLEVEL` | `min(nproc, RAM-2, 16)` |
| `DL_DIR` | 下载缓存，跨构建复用 | `$PWD/dl` |
| `O` | 输出目录 | `$PWD/out` |
| `ACCEL` | QEMU 加速方式 | `kvm` 可用则 `kvm`，否则 `tcg` |

`build.local.example` 提交，`build.local` 进 `.gitignore`。

## Decision gate

v0.1 第一次"别人在这台机器之外构建"之前。在那之前 `BR2_JLEVEL=12` 只是记录现状。

## Resolution (2026-11-22)

已实现于 PR #16。

- `tools/build.sh`：`keel_jobs <nproc> <ram_gib>` = `min(nproc, ram_gib - 2, 16)`，下限 1；
  优先级 `--jobs N` > `build.local` 的 `KEEL_JOBS` > 自动。
- `BR2_JLEVEL` 通过 make 命令行传入，**不写回 `out/.config`**——所以在 `.config` 里看到
  的是 defconfig 的保守值 4，实际生效值看构建日志里的 `PARALLEL_JOBS=<n>`。
- `configs/keel_qemu_x86_64_defconfig` 保留 `BR2_JLEVEL=4` 兜底。
- `build.local.example` 提交，`build.local` 进 `.gitignore`。
- `DL_DIR` / `O` 仍是 Buildroot 默认与 `out/`；等真需要再参数化。
