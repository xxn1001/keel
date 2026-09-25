#!/usr/bin/env bash
# keel:两条构建路径**共用**的参数解析与宿主判定
#
# ── 为什么要有这个文件 ──────────────────────────────────────────────
# keel 有两条构建路径:
#   tools/build.sh             原生路径(FHS 发行版:mkosi 直接可用)
#   tools/build-container.sh   适配器(NixOS 等不被 mkosi 支持的宿主:构建放进容器)
#
# 它们必须对**同一套选项给出同样的行为**。2026-09 审计时发现两条路各写各的,已经漂移出四处:
#   * build.sh **完全不解析参数** —— `-p/--password` 与 `--profile` 被静默忽略
#     (最危险的是 -p:敲了密码却得到"没有密码"的产物,然后登不进去);
#   * `--profile`(变体)只有环境变量 KEEL_EXTRA_PROFILES 一条路,而这个变量**没有**被
#     `-e` 传进容器 ⇒ NixOS 那条路上根本加不了 profile;
#   * `--` 之后的 mkosi 额外参数只有容器路径支持;
#   * `-h` 只有容器路径有。
# 所以:CLI 只写一份。**新增选项先加到这里**,两边自然同时具备;确实只属于某一条路径的
# 选项(容器引擎、模式等)才留在各自脚本里,并在 AGENTS.md 的对照表里写清楚。
#
# ── 用法 ────────────────────────────────────────────────────────────
#   . "$(dirname "$0")/lib-build-cli.sh"
#   keel_cli_parse "$@" || exit 2
#   if [ "$KEEL_HELP" = 1 ]; then keel_cli_usage_common; exit 0; fi
#
# 解析结果(全局变量):
#   KEEL_PASSWORD      初始密码,空 = 没给
#   KEEL_PROFILES      额外叠加的 profile(数组)
#   KEEL_EXTRA_MKOSI   `--` 之后的 mkosi 额外参数(数组)
#   KEEL_POSITIONAL    其余位置参数(交给各脚本自己判断含义;build.sh 用它报错)
#   KEEL_HELP          1 = 用户要帮助
#   KEEL_VM            1 = 用户要 --vm(构建完起一遍 QEMU)
#   KEEL_DRILL         1 = 用户要 --drill(跑完整的 OTA 演练)
#
# ⚠ 这个文件**不** set -euo pipefail(它要被 source,不能改调用方的 shell 选项)。
# shellcheck shell=bash
# 这里定义的全局变量是给调用方(sourced 之后)用的,shellcheck 按单文件看不出用途:
# shellcheck disable=SC2034

keel_cli_err() { printf 'keel: 错误:%s\n' "$*" >&2; }

# 共用选项的说明文字(两条路径共用同一份,免得措辞漂移)
keel_cli_usage_common() {
    cat >&2 <<'EOF'
  -p, --password <密码>   给镜像里的 admin 设初始密码(决策 D21:root 始终锁定)。
                          不落盘、不进 git;不加 = 产物只认 authorized_keys 里的 SSH 公钥。
      --profile <名字>    额外叠加一个 mkosi profile(可重复,例如 desktop / server / test)。
                          等价于给 mkosi 追加 `--profile <名字>`;产物形态仍由 install/slot-* 决定。
      --vm                构建完直接在 QEMU 里起一遍(需要 /dev/kvm;等价容器的 vm 模式)
      --drill             OTA 演练:载荷 + 引导镜像 + 本地 HTTP 源 + VM 里自动跑
                          check/fetch/stage/重启/确认/回滚(等价容器的 drill 模式)
      -- <参数…>          `--` 之后的参数原样交给 mkosi。
                          注意:mkosi 的 `vm` 只读上一次 build 的 history ⇒ 这些参数
                          **build 与 vm 两次调用都必须带上**(见 docs/traps.md 坑 #30)。
  -h, --help              显示帮助
EOF
}

keel_cli_parse() {
    KEEL_PASSWORD=""
    KEEL_PASSWORD_SET=0
    KEEL_PROFILES=()
    KEEL_EXTRA_MKOSI=()
    KEEL_POSITIONAL=()
    KEEL_HELP=0
    KEEL_VM=0
    KEEL_DRILL=0
    while [ $# -gt 0 ]; do
        case "$1" in
            -p|--password)
                [ $# -ge 2 ] || { keel_cli_err "$1 后面要跟密码"; return 2; }
                KEEL_PASSWORD=$2; KEEL_PASSWORD_SET=1; shift 2 ;;
            --password=*)
                KEEL_PASSWORD=${1#*=}; KEEL_PASSWORD_SET=1; shift ;;
            --vm)
                # 构建完直接在 QEMU 里起一遍。两条路径都认:`build.sh --vm` 与
                # `build-container.sh --vm`(后者同时支持位置参数的 `vm` 模式写法)。
                KEEL_VM=1; shift ;;
            --drill)
                # 跑一遍完整的 OTA 演练。两条路径共用同一份编排(tools/ota-drill-container.sh)。
                KEEL_DRILL=1; shift ;;

            --profile)
                [ $# -ge 2 ] || { keel_cli_err "$1 后面要跟 profile 名"; return 2; }
                KEEL_PROFILES+=("$2"); shift 2 ;;
            --profile=*)
                KEEL_PROFILES+=("${1#*=}"); shift ;;
            --)
                shift; KEEL_EXTRA_MKOSI=("$@"); break ;;
            -h|--help)
                KEEL_HELP=1; shift ;;
            -*)
                keel_cli_err "不认识的选项:$1(用 -h 看用法)"; return 2 ;;
            *)
                KEEL_POSITIONAL+=("$1"); shift ;;
        esac
    done
    return 0
}

# 额外 profile 的最终名单 = 环境变量 KEEL_EXTRA_PROFILES(旧用法,保留)+ --profile。
# 去重但保持顺序;输出成一行(空格分隔),便于直接喂给 for。
keel_cli_extra_profiles() {
    local p seen="" out=""
    for p in ${KEEL_EXTRA_PROFILES:-} ${KEEL_PROFILES[@]+"${KEEL_PROFILES[@]}"}; do
        [ -n "$p" ] || continue
        case " $seen " in *" $p "*) continue ;; esac
        seen="$seen $p"; out="$out $p"
    done
    printf '%s' "${out# }"
}

# ── 宿主判定 ────────────────────────────────────────────────────────
# 判断的是**构建宿主**(不是目标镜像,也不是 keel 自己那份 os-release ——
# keel 的 ID=keel,别把自己当成宿主),依据 ID / ID_LIKE,不靠"记忆里上次是哪台机器"。
#
#   输出 fhs      → 原生路径:tools/build.sh(mkosi 支持的发行版)
#        nixos    → 适配器:tools/build-container.sh(mkosi 不认 NixOS)
#        unknown  → 先试原生;报"Distribution can't be detected"就换适配器
keel_host_kind() {
    local f id="" like=""
    for f in /etc/os-release /usr/lib/os-release; do
        [ -r "$f" ] || continue
        id=$(sed -n 's/^ID=//p' "$f" | head -1 | tr -d '"')
        like=$(sed -n 's/^ID_LIKE=//p' "$f" | head -1 | tr -d '"')
        break
    done
    case "$id $like" in
        *nixos*) printf 'nixos' ;;
        # mkosi 支持的发行版家族(它的发行版检测就是认这些包管理器:apt/dnf/pacman/zypper)
        *debian*|*ubuntu*|*fedora*|*centos*|*rhel*|*rocky*|*alma*|*arch*|*cachyos*|\
        *manjaro*|*endeavouros*|*opensuse*|*suse*) printf 'fhs' ;;
        *) printf 'unknown' ;;
    esac
}

# 把宿主判定变成一句人话(报错/提示里用),并给出该走哪条路
keel_host_hint() {
    case "$(keel_host_kind)" in
        nixos) printf '宿主是 NixOS(mkosi 不把 NixOS 当受支持的宿主)⇒ 用 tools/build-container.sh' ;;
        fhs)   printf '宿主看起来是 mkosi 支持的发行版 ⇒ 直接跑 tools/build.sh' ;;
        *)     printf '认不出宿主发行版:mkosi 可能会说 "Distribution can'"'"'t be detected";那就改用 tools/build-container.sh' ;;
    esac
}
