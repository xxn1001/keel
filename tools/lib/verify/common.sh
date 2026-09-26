# shellcheck shell=bash
# keel verify 公共 helpers(原单体 tools/verify.sh 第 18-33 行,逐字搬移;由门面 tools/verify.sh 在顶层 source)
# 本文件只定义 helpers / 计数器 / 临时目录清理 trap / 共享全局变量,自身不跑任何检查。
# 故意不带 shebang:它是 sourced 库,带了会改变 §5 统计的脚本数。
pass=0; fail=0; skipped=0
ok()    { printf '  \033[32m✓\033[0m %s\n' "$*"; pass=$((pass+1)); }
no()    { printf '  \033[31m✗\033[0m %s\n' "$*"; fail=$((fail+1)); }
warn()  { printf '  \033[33m!\033[0m %s\n' "$*"; }
skip()  { printf '  \033[33m-\033[0m %s\n' "$*"; skipped=$((skipped+1)); }
head1() { printf '\n\033[1m%s\033[0m\n' "$*"; }
have()  { command -v "$1" >/dev/null 2>&1; }

TMPS=()
cleanup() { local d; for d in ${TMPS[@]+"${TMPS[@]}"}; do rm -rf "$d"; done; }
trap cleanup EXIT
tmpd() { local d; d=$(mktemp -d); TMPS+=("$d"); printf '%s' "$d"; }

# shellcheck disable=SC2034  # PROFILES 由 10-mkosi.sh / 20-cmdline-repart.sh 读取,动态 source 让 shellcheck 看不见
PROFILES="install slot-a slot-b"
# shellcheck disable=SC2034  # WANT_SLOT 同上,由 20-cmdline-repart.sh 读取
declare -A WANT_SLOT=([install]=root-a [slot-a]=root-a [slot-b]=root-b)
