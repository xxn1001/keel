#!/usr/bin/env bash
# shellcheck disable=SC2154  # pass/fail/skipped 在 common.sh 里赋值,动态 source 让 shellcheck 看不见
# keel 静态校验 —— 不需要 loop 设备、不构建镜像
#
# 大部分检查不需要 root;只有「假镜像树实跑 mkosi.finalize」那条需要(它要 chown admin 家目录),
# 非 root 时那条会**明确跳过**而不是假装失败(在 NixOS 宿主上以 admin 跑过一次,见坑 #52)。
#
# 能在这里查的:
#   1. mkosi 三个 profile 的配置解析
#   2. kernel cmdline 一致性(每个产物恰好一个 root=PARTLABEL=root-<槽>,且和产物对得上)
#   3. repart 分区布局(真跑 systemd-repart,用假镜像树喂 CopyFiles)
#   4. systemd 单元语法(systemd-analyze verify)
#   5. shell 脚本(shellcheck + bash -n)
#   6. 几处"改一处忘一处"的一致性断言
#
# 查不了的:真实构建与启动。那是 tools/build.sh + 真机/虚拟机的事(docs/architecture.md §13)。
set -uo pipefail

# ── 环境归一化:sbin 目录 ────────────────────────────────────────────────────
# Debian 普通用户的默认 PATH 里**没有** /usr/sbin 与 /sbin,而校验要用的 sfdisk
# (fdisk 包)恰恰装在那儿 ⇒ 非 root 跑 verify 时第 3 节会以「缺 sfdisk」为由
# **整节跳过**,root 跑同一份代码却跑得满满当当:同一个仓库给出两套答案。
# 2026-09 的 rootless 实测就是这么发现的(root 191 通过 / 0 跳过,非 root 173 通过 /
# 4 跳过,差额正是这一节)+ 后面 shellcheck 那项因为写死的 /tmp 路径假红。
# 门面只在这里做一次环境归一化,不给每条检查各写一份兜底。
# 只**追加**,不前置:绝不遮蔽调用者自己的 PATH。
PATH="${PATH:+$PATH:}/usr/sbin:/sbin"
export PATH

verify_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
cd "$(dirname "$0")/.." || exit 1

# ── 主题模块:全部 source 进同一个 shell(无 local 的赋值仍是全局的,跨模块状态不变)──
. "$verify_dir/lib/verify/common.sh"
. "$verify_dir/lib/verify/10-mkosi.sh"
. "$verify_dir/lib/verify/20-cmdline-repart.sh"
. "$verify_dir/lib/verify/30-units-shell.sh"
. "$verify_dir/lib/verify/40-consistency-core.sh"
. "$verify_dir/lib/verify/50-build-flags.sh"
. "$verify_dir/lib/verify/60-find-part.sh"
. "$verify_dir/lib/verify/61-packages.sh"
. "$verify_dir/lib/verify/62-install-todos.sh"
. "$verify_dir/lib/verify/63-mounts-network.sh"
. "$verify_dir/lib/verify/64-drill-console.sh"
. "$verify_dir/lib/verify/65-esp-clean-watchdog.sh"
. "$verify_dir/lib/verify/66-libvirt.sh"
. "$verify_dir/lib/verify/67-keel-check.sh"
. "$verify_dir/lib/verify/80-accounts.sh"
. "$verify_dir/lib/verify/90-identity.sh"
. "$verify_dir/lib/verify/95-data-budget.sh"
. "$verify_dir/lib/verify/96-manifest-protocol.sh"
. "$verify_dir/lib/verify/97-gate-env.sh"

# ── 按原顺序调用(顺序即输出顺序)──
verify_mkosi
verify_cmdline
verify_repart
verify_units
verify_shell
verify_consistency_core
verify_build_flags
verify_find_part


# ── 旧名字自检:除了这个文件自己的排除项,别处不许再出现 `common-os` ──
# ⚠ 必须**跳过构建产物**:dist/ + mkosi.output/ + mkosi.*cache/ 一次构建就是十几个 GB
#   (载荷镜像、安装镜像、解开的包树),而这里原来是"把整棵树当文本 grep 一遍"。
#   2026-09-27 实测:加排除之前这一步 **60 秒都跑不完**(被 timeout 掐掉),加之后 **4 毫秒**。
#   它跑在每一次 verify 里,而 `build.sh` 每次构建前都要先跑 verify。
#   只排除**生成物**:它们是源码生成的,源码里真有残留照样会被抓到。
#   顺带:原来同样的 grep 写了两遍(判空一遍、打印一遍),现在只跑一遍。
common_os_hits=$(grep -rn 'common-os' --include='*' \
    --exclude-dir=.git --exclude-dir=dist --exclude-dir=mkosi.output \
    --exclude-dir=mkosi.cache --exclude-dir=mkosi.pkgcache --exclude-dir=mkosi.tools \
    --exclude-dir=mkosi.workspace \
    . 2>/dev/null | grep -v '^\./tools/verify\.sh:' || true)
if [ -n "$common_os_hits" ]; then
    no "还有残留的旧名字 common-os:"
    printf '%s\n' "$common_os_hits" | head -5 | sed 's/^/      /'
else
    ok "没有残留的旧名字(已跳过构建产物:dist/、mkosi.output/、mkosi.*cache/)"
fi

verify_packages
verify_install_todos
verify_mounts_network
verify_drill_console
verify_esp_clean_watchdog
verify_libvirt
verify_keel_check
verify_accounts
verify_identity
verify_data_budget
verify_manifest_protocol
verify_gate_env

# ---------------------------------------------------------------------------
printf '\n\033[1m结果: %d 通过, %d 失败' "$pass" "$fail"
[ "$skipped" -gt 0 ] && printf ', %d 跳过' "$skipped"
printf '\033[0m\n'
[ "$fail" = 0 ] || exit 1
