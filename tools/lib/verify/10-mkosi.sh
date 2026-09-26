# shellcheck shell=bash
# keel verify 模块:mkosi 配置解析(原 tools/verify.sh 第 34-130 行,逐字搬移;sourced 库,故意不带 shebang)

verify_mkosi() {

# ---------------------------------------------------------------------------
head1 "1. mkosi 配置解析"
# ---------------------------------------------------------------------------
if ! have mkosi; then
    skip "没装 mkosi,跳过"
else
    for p in $PROFILES; do
        out=$(tmpd)
        if mkosi --profile "$p" summary >"$out/summary" 2>&1; then
            ok "--profile $p 解析通过"
        else
            no "--profile $p 解析失败"
            grep -E '^‣' "$out/summary" | head -5 | sed 's/^/      /'
        fi
    done
    # 虚拟机测试用的组合(install + test)也要能解析。它不在上面的 PROFILES 里,但正是
    # docs/install.md §1 让人跑的命令 —— 漏检的话"新增一个 profile 导致组合解析失败"要等到
    # 真机上才发现。
    out=$(tmpd)
    if mkosi --profile install --profile test summary >"$out/summary" 2>&1; then
        ok "--profile install --profile test 解析通过(虚拟机测试用的组合)"
    else
        no "--profile install --profile test 解析失败"
        grep -E '^‣' "$out/summary" | head -5 | sed 's/^/      /'
    fi
    # RepartDirectories 的守卫。**刻意不解析 mkosi 的输出**:那条路已被证明是版本相关的
    # (25.x 与 27 的 --json 结构不同;而 verify.sh 开了 pipefail,mkosi 一旦不支持 --json
    #  整条管道就失败,断言会误报),而且它只是"症状"。
    # 改成检查**输入侧的不变量** —— 它们正是导致故障的两个条件,与 mkosi 版本无关:
    #   ① 源码树里不能存在名为 mkosi.repart 的目录(mkosi 会把它当隐式默认值);
    #   ② 每个产物 profile 必须恰好设一个 RepartDirectories=,且那个目录存在、里面有 .conf。
    # 背景:mkosi 把"存在 mkosi.repart/"当默认值 + 集合型设置是追加语义 ⇒ 两者叠加会让
    # 两套分区布局同时生效。真机上的表现是 repart 拒绝同名 split(docs/traps.md 坑 #20)。
    if [ -e mkosi.repart ]; then
        no "源码树里存在 mkosi.repart/ —— 它会成为 RepartDirectories= 的隐式默认值,和 profile 里设的目录叠加(坑 #20);请把布局放到 repart/ 下的子目录"
    else
        ok "源码树里没有 mkosi.repart/(不会触发隐式默认值)"
    fi
    for p in $PROFILES; do
        f="mkosi.profiles/$p.conf"
        cnt=$(grep -c '^RepartDirectories=' "$f" 2>/dev/null || true)
        dir=$(sed -n 's/^RepartDirectories=//p' "$f" 2>/dev/null | head -1)
        if [ "$cnt" != 1 ]; then
            no "$f 里 RepartDirectories= 出现 $cnt 次(必须恰好 1 次)"
        elif [ ! -d "$dir" ]; then
            no "$f 指向的目录不存在:$dir"
        elif ! ls "$dir"/*.conf >/dev/null 2>&1; then
            no "$f 指向的目录里没有分区定义:$dir"
        else
            ok "--profile $p → $dir(存在且含分区定义)"
        fi
    done
    # 尽力而为:如果 mkosi 的输出恰好能解析出来,再核对一次实际解析结果。
    # 解析不出来**不判失败** —— 输出格式是版本相关的,不该让校验依赖它。
    resolved=$(mkosi --profile install summary 2>/dev/null | awk '
        # summary 里有多个镜像(先 tools tree、再 initrd、最后才是主镜像),
        # 每出现一次 "Repart Directories:" 就重置一次计数,END 时打印的就是主镜像那份。
        /Repart Directories:/ {
            col = index($0, "Repart Directories:") + length("Repart Directories:")
            v = substr($0, col + 1)
            gsub(/^[ \t]+|[ \t]+$/, "", v)
            n = (v == "" || v == "none") ? 0 : 1
            inblock = 1
            next
        }
        inblock && /^[ \t]+[^ \t]/ {
            if (match($0, /[^ \t]/) - 1 >= col) { n++; next }
            inblock = 0
            next
        }
        inblock && !/^[ \t]*$/ { inblock = 0 }
        END { if (inblock || n != "") print n }
    ' | tail -1)
    case "$resolved" in
        1)   ok "mkosi 实际解析出的 RepartDirectories 也是 1 个" ;;
        '')  warn "没能从 mkosi summary 里解析出 RepartDirectories(不影响判定,输入侧已检查)" ;;
        *)   warn "mkosi 实际解析出 $resolved 个 RepartDirectories —— 输入侧看起来正常,若是真异常请把 'mkosi --profile install summary' 的输出报告出来" ;;
    esac

    # 不带 --profile 会解析成功但没有任何 root=(产物形态必须显式选)。
    # 拦截点在构建期:mkosi.finalize 检查 $MKOSI_CONFIG。这里断言两件事:
    #   ① 不带 profile 确实没有 root=;② finalize 里的守卫还在。
    nf=$(tmpd)
    mkosi summary >"$nf/s" 2>/dev/null || true
    if grep -q 'root=PARTLABEL=root-' "$nf/s" 2>/dev/null; then
        no "不带 --profile 竟然也带 root=,产物形态的隔离被破坏了"
    else
        ok "不带 --profile 时没有 root=(构建期会被 finalize 守卫拦下)"
    fi
    if grep -q 'root=PARTLABEL=root-\[ab\]' mkosi.finalize; then
        ok "mkosi.finalize 里的 cmdline 守卫存在"
    else
        no "mkosi.finalize 里的 cmdline 守卫不见了 —— 两个产物 profile 同时启用会静默产出坏镜像"
    fi
fi

}
