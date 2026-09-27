# shellcheck shell=bash
# keel verify 模块:校验器**自身**的环境与拆分约定(第 11 节)
#
# 为什么要给"校验器自己"上断言:它是唯一的静态门,而**它少跑了几条没有任何人会知道**。
# 2026-09 的 rootless 实测一次抓到两处这种"门坏了却报一切正常":
#   ① 非 root 时第 3 节(repart 分区布局,14 条断言)**整节消失** —— Debian 普通用户
#      的 PATH 里没有 /usr/sbin,而 sfdisk 装在那儿,于是 `have sfdisk` 为假;
#   ② shellcheck 那一项**假红** —— 它把日志写到一个写死的 sbin 之外的固定路径,
#      被 root 跑过一次之后那个文件归 root 所有,非 root 再也写不动。
# 两条都是"环境差异",不是代码错,所以这一节专门盯环境与拆分约定。

verify_gate_env() {
head1 "11. 校验器自身的环境"
# ① 门面必须自己把 sbin 补进 PATH:靠调用者自带的 PATH,就等于"root 与非 root 跑的
#    不是同一套检查",而这正是 ① 那个坑的成因。
if grep -qE '^PATH=.*/usr/sbin' tools/verify.sh; then
    ok "门面把 /usr/sbin 补进 PATH(非 root 也看得见 sfdisk,第 3 节不会整节消失)"
else
    no "tools/verify.sh 没把 sbin 补进 PATH ⇒ 非 root 跑时第 3 节会整节跳过"
fi
# ② 光看代码不够,这里真查一次:非 root 且 PATH 没补上时这条会红。
if have sfdisk; then
    ok "sfdisk 看得见(第 3 节真跑,不是走到「缺工具」那一支)"
else
    no "看不见 sfdisk ⇒ 第 3 节的断言一条都没跑。装 fdisk 包,别拿「没装」换「全绿」"
fi
# ③ 容器路径同理:容器里没有 fdisk 包,第 3 节在那里也是整节消失。
if grep -q 'shellcheck fdisk' tools/build-container.sh; then
    ok "构建容器装了 fdisk(sfdisk)⇒ 容器里的第 3 节也不会少跑"
else
    no "tools/build-container.sh 没装 fdisk ⇒ 容器里跑 verify 时第 3 节整节消失"
fi
# ④ 临时文件不许写死路径:固定名字的世界可写路径,前一个 uid 跑过之后下一个 uid
#    就写不动了(而且预先放个符号链接就能让 root 去截断任意文件)。
#    注意下面这个模式串自己**不会**命中自己("/tmp/" 之后是 "[" 不是字母)。
hard_tmp=$(grep -rnE '/tmp/[[:alpha:]]' tools/verify.sh tools/lib/verify 2>/dev/null || true)
if [ -z "$hard_tmp" ]; then
    ok "校验器里没有写死的临时路径(一律走 tmpd,前一个 uid 留下的文件卡不住下一个 uid)"
else
    no "校验器里有写死的临时路径(改用 tmpd):"
    printf '%s\n' "$hard_tmp" | head -5 | sed 's/^/      /'
fi
# ⑤ 拆分约定:模块是 **sourced 库**,不能带 shebang(带了会被第 5 节多算一个脚本,
#    间接把"脚本数"这条基线搅乱),也不该有可执行位。
mod_bad=""
for m in tools/lib/verify/*.sh; do
    [ -e "$m" ] || continue
    if head -c 2 "$m" 2>/dev/null | grep -q '#!'; then mod_bad="$mod_bad ${m}(带 shebang)"; fi
    if [ -x "$m" ]; then mod_bad="$mod_bad ${m}(有可执行位)"; fi
done
if [ -z "$mod_bad" ]; then
    ok "校验模块都不带 shebang、也没有可执行位(sourced 库的拆分约定)"
else
    no "校验模块的拆分约定被破坏:$mod_bad"
fi
# ⑥ rootless 构建"能跑但产物不等价"(坑 #66)—— 现在原生路径**直接拒绝**非 root。
#    这条断言守着那句 die:被改回"只警告"就意味着有人会拿属主被压成 0 的产物去发布。
if grep -qE '\|\| die "原生构建必须用 root' tools/build.sh; then
    ok "build.sh 直接**拒绝**非 root 构建(坑 #66:非 0 的 uid/gid 会被压成 0),并指向容器适配器"
else
    no "tools/build.sh 不再拒绝非 root 构建 ⇒ 会产出属主被压成 0 的镜像,而且看起来一切正常"
fi

}
