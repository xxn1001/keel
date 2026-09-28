# shellcheck shell=bash
# keel verify 模块:initrd 阶段的兜底(本地包 → 默认 initrd;v1.2 3.0;坑 #76/#77)
#
# 要覆盖两类失败(2026-09-28 各有实测):
#   * **PID1 冻住**(systemd freeze)⇒ 运行时看门狗(softdog + RuntimeWatchdogSec);
#   * **PID1 活着但卡住**(initrd 进 emergency 等人按键 / 切根卡住)⇒ 看门狗**不会**动作,
#     只能靠自己数秒:**keel-initrd-timeout.service** 到点用 sysrq 强制复位。
#
# 交付路径(坑 #76/#77 的真实根因):mkosi 往**默认 initrd**里放文件只有 `InitrdPackages=`
# 这一条"追加"的口子(`Initrds=` 是**替换** —— 设了它内置 initrd 整个不进来,UKI 里只剩我们
# 那几个文件,内核 `VFS: Unable to mount root fs`,实测连正常槽都起不来)。
# 于是四个文件 + 两个启用符号链接被打成一个小 .deb,经 reprepro 本地仓库装进默认 initrd;
# initrd 构建**不跑 preset**,所以启用必须靠包里自带的 .wants 符号链接。

verify_initrd_watchdog() {
head1 "16. initrd 的兜底(包 → 默认 initrd;坑 #76/#77)"

PKG=tools/initrd-watchdog-pkg.sh
SRC=mkosi.initrd-extra
WD_INITRD="$SRC/usr/lib/systemd/system.conf.d/keel-watchdog.conf"
ML_INITRD="$SRC/usr/lib/modules-load.d/keel-watchdog.conf"
TU_UNIT="$SRC/usr/lib/systemd/system/keel-initrd-timeout.service"
TU_EXEC="$SRC/usr/lib/keel/initrd-timeout"
WDFILES=(usr/lib/systemd/system.conf.d/keel-watchdog.conf
         usr/lib/modules-load.d/keel-watchdog.conf
         usr/lib/systemd/system/keel-initrd-timeout.service
         usr/lib/keel/initrd-timeout)
WDLINKS=(usr/lib/systemd/system/sysinit.target.wants/keel-initrd-timeout.service
         usr/lib/systemd/system/initrd-switch-root.target.wants/keel-initrd-timeout.service)

# ── ① 载荷与打包脚本 ────────────────────────────────────────────────────────
if [ -x "$PKG" ] && grep -qF "dpkg-deb --root-owner-group --build" "$PKG" &&
   grep -qF "回读失败" "$PKG" && grep -qF "cmp -s \"\$deb\" \"\$OUT\"" "$PKG"; then
    ok "tools/initrd-watchdog-pkg.sh 齐全:打包 + 回读比对 + 内容没变就不动 mtime(不毁增量缓存)"
else
    no "initrd 打包脚本缺环节(打包 / 回读 / 幂等)"
fi
allfiles=1; alllinks=1
for f in "${WDFILES[@]}"; do [ -s "$SRC/$f" ] || allfiles=0; done
for l in "${WDLINKS[@]}"; do [ -L "$SRC/$l" ] || alllinks=0; done
if [ "$allfiles" = 1 ] && [ "$alllinks" = 1 ]; then
    ok "载荷树齐全:4 个文件(路径 = 装进 initrd 后的路径)+ 2 个 .wants 启用链接"
else
    no "载荷树缺文件或缺启用链接(少了链接 ⇒ 单元根本不会启动)"
fi
if grep -q "^RuntimeWatchdogSec=60$" "$WD_INITRD" && grep -qx "softdog" "$ML_INITRD" &&
   grep -q "^echo b >/proc/sysrq-trigger" "$TU_EXEC" && [ -x "$TU_EXEC" ]; then
    ok "两份载荷都硬:看门狗 RuntimeWatchdogSec=60 + softdog;超时脚本用 sysrq 强制复位(PID1 冻住也走得通)"
else
    no "载荷内容不对(看门狗配置 / softdog / sysrq 复位路径 / 可执行位)"
fi
if grep -q "^Type=simple$" "$TU_UNIT" && grep -q "^ExecStart=/usr/lib/keel/initrd-timeout$" "$TU_UNIT" &&
   grep -q "^WantedBy=sysinit.target initrd-switch-root.target$" "$TU_UNIT" &&
   grep -q "^Before=initrd-switch-root.service$" "$TU_UNIT"; then
    ok "keel-initrd-timeout.service 形态正确:simple + 指向脚本 + 挂 sysinit 与切根两个 target"
else
    no "超时单元的依赖/类型不对(exit=emergency 与切根两条路都要覆盖)"
fi

# ── ② mkosi 接线 + build.sh fail-closed ─────────────────────────────────────
if grep -qE "^PackageDirectories=mkosi.packages$" mkosi.conf.d/20-packages.conf &&
   grep -qE "^InitrdPackages=keel-initrd-watchdog$" mkosi.conf.d/20-packages.conf; then
    ok "mkosi 接线:PackageDirectories=mkosi.packages + InitrdPackages=keel-initrd-watchdog"
else
    no "mkosi 没接上本地包 ⇒ initrd 里不会有看门狗与超时(卡住时没人复位)"
fi
if grep -qF "tools/initrd-watchdog-pkg.sh" tools/build.sh &&
   grep -qF "生成 initrd 看门狗包失败" tools/build.sh; then
    ok "build.sh 构建前生成包、生成不出来就停(fail-closed:不会「构建全绿但兜底没进 initrd」)"
else
    no "build.sh 没有 fail-closed 地生成 initrd 包"
fi

# ── ③ 反向断言:替换语义(Initrds=/--initrd)会炸,不许接回来 ────────────────
repl=""
for f in mkosi.conf mkosi.conf.d/*.conf mkosi.profiles/*.conf \
         tools/build.sh tools/build-container.sh tools/ota-drill-container.sh; do
    [ -f "$f" ] || continue
    grep -qE "^[[:space:]]*Initrds[[:space:]]*=" "$f" && repl="$repl $f"
    if grep -nE -- "--initrd([[:space:]]|=|$)" "$f" 2>/dev/null | grep -qvE "^[0-9]+:[[:space:]]*#"; then
        repl="$repl $f"
    fi
done
if [ -z "$repl" ]; then
    ok "没有构建路径用替换语义(Initrds= / --initrd)—— 内置 initrd 不会被顶掉"
else
    no "这些地方出现了替换语义:$repl(实测 UKI 里只剩我们的文件 ⇒ VFS unable to mount root,先读坑 #77)"
fi

# ── ④ 演练不再声称"缺口" ────────────────────────────────────────────────────
if grep -qF "KEEL_DRILL_SABOTAGE" tools/ota-drill-container.sh &&
   ! grep -qF "initrd 冻结兜底仍是已知缺口" tools/ota-drill-container.sh; then
    ok "演练不再声称「initrd 冻结是已知缺口」(那个破坏模式现在能真验自动回退)"
else
    no "演练还在说 initrd 冻结是已知缺口 ⇒ 与已修好的事实不符"
fi

# ── 功能测试 1:打包脚本真的产出 .deb,路径/内容/权限/链接都对 ────────────────
if ! have dpkg-deb; then
    skip "没有 dpkg-deb,跳过 initrd 包的功能测试"
else
    it="$(tmpd)"
    deb="$it/keel-initrd-watchdog_1.0_all.deb"
    if KEEL_INITRD_PKG_OUTDIR="$it" bash "$PKG" >/dev/null 2>&1 && [ -s "$deb" ]; then
        ok "功能测试:打包脚本产出 keel-initrd-watchdog_1.0_all.deb"
        listing=$(dpkg-deb -c "$deb" | awk '{print $6}' | sed 's#^\./##')
        miss=""
        for f in "${WDFILES[@]}" "${WDLINKS[@]}"; do
            printf "%s\n" "$listing" | grep -qx "$f" || miss="$miss $f"
        done
        if [ -z "$miss" ]; then
            ok "功能测试:包里 4 个文件 + 2 个符号链接都在(第 6 字段是路径)"
        else
            no "包里缺:$miss"
        fi
        mkdir -p "$it/x"
        bad=""
        if dpkg-deb -x "$deb" "$it/x"; then
            for f in "${WDFILES[@]}"; do
                cmp -s "$SRC/$f" "$it/x/$f" || bad="$bad $f"
            done
            for l in "${WDLINKS[@]}"; do
                [ "$(readlink "$it/x/$l")" = "$(readlink "$SRC/$l")" ] || bad="$bad $l"
            done
        else
            bad=" 解包失败"
        fi
        if [ -z "$bad" ]; then
            ok "功能测试:包里的内容与仓库载荷逐字节一致(文件内容 + 链接目标)"
        else
            no "包内容与源不一致:$bad"
        fi
        if [ "$(stat -c %a "$it/x/usr/lib/systemd/system.conf.d/keel-watchdog.conf")" = 644 ] &&
           [ "$(stat -c %a "$it/x/usr/lib/systemd/system/keel-initrd-timeout.service")" = 644 ] &&
           [ "$(stat -c %a "$it/x/usr/lib/keel/initrd-timeout")" = 755 ]; then
            ok "功能测试:配置文件 0644、超时脚本 0755(权限压错会让 initrd 读不到 / 跑不起来)"
        else
            no "包里的权限不对(配置要 0644,脚本要 0755)"
        fi
    else
        no "打包脚本跑不出 .deb"
    fi
    # 定向变异:载荷文件缺失时必须拒绝
    empty="$(tmpd)"
    if KEEL_INITRD_PKG_SRC="$empty" KEEL_INITRD_PKG_OUTDIR="$(tmpd)" bash "$PKG" >/dev/null 2>&1; then
        no "载荷缺失时打包脚本仍然成功(必填/回读断言是空的)"
    else
        ok "载荷缺失时打包脚本拒绝(定向变异:必填与回读断言非空)"
    fi
fi

# ── 功能测试 2:拆开手边那份 UKI 的 .initrd —— 注入成功的**唯一直接证据** ─────
uki=""
for c in mkosi.output/keel.efi output/keel-*/slot-a.uki.efi output/keel-*/slot-b.uki.efi; do
    [ -f "$c" ] && { uki="$c"; break; }
done
if [ -z "$uki" ]; then
    skip "手边没有构建产物(UKI),跳过「initrd 里到底有没有那几样东西」的直接证据(构建后重跑本节)"
elif ! have objcopy || ! have zstd || ! have cpio; then
    skip "缺 objcopy/zstd/cpio,跳过拆 UKI 的检查"
else
    it="$(tmpd)"
    if objcopy --dump-section ".initrd=$it/initrd" "$uki" 2>/dev/null && [ -s "$it/initrd" ]; then
        # .initrd 是多段拼接(内置 initrd ++ 内核模块 initrd):cpio 列完第一段会在拼接处
        # 报错退出(非 0 是**预期**的)⇒ 只看清单,别让 pipefail 把它判成失败。
        zstd -dc "$it/initrd" 2>/dev/null | cpio -t --quiet 2>/dev/null >"$it/list" || true
        miss=""
        for f in "${WDFILES[@]}" "${WDLINKS[@]}"; do
            grep -qx "$f" "$it/list" || miss="$miss $f"
        done
        if [ -z "$miss" ]; then
            ok "拆 $uki 的 .initrd:4 个文件 + 2 个启用链接**真的**在里面(注入路径生效)"
        else
            no "initrd 里缺:$miss ⇒ 兜底没生效(先看 mkosi.conf.d 的 InitrdPackages 与 build.sh)"
        fi
        zstd -dc "$it/initrd" 2>/dev/null |
            cpio -i --to-stdout "usr/lib/keel/initrd-timeout" >"$it/tu" 2>/dev/null || true
        if grep -q "^echo b >/proc/sysrq-trigger" "$it/tu" && [ -s "$it/tu" ]; then
            ok "initrd 里那份超时脚本带 sysrq 强制复位(不是空文件/旧版本)"
        else
            no "initrd 里的超时脚本内容不对(读不到 sysrq 复位)"
        fi
    else
        no "从 $uki 里取不出 .initrd(objcopy --dump-section 失败)"
    fi
fi

# === PART_B_END ===

}
