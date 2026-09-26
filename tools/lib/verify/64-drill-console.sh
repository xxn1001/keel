# shellcheck shell=bash
# keel verify 模块:keel-confirm 挂载点 / 扩容 / OTA 演练 / bootctl 动词 / UKI 名 / 控制台级别 / panic / 坏载荷(原第 844-1001 行,逐字搬移)

verify_drill_console() {
# ---------------------------------------------------------------------------
# keel-confirm 必须**同时**挂在 boot-complete.target 与 multi-user.target 上(坑 #41):
# boot-complete.target 只在"计数启动"时被 generator 拉进事务,而回滚发生在非计数启动上。
CONFIRM=mkosi.extra/usr/lib/systemd/system/keel-confirm.service
if grep -qE '^WantedBy=.*boot-complete\.target' "$CONFIRM" &&
   grep -qE '^WantedBy=.*multi-user\.target' "$CONFIRM" &&
   grep -q '^Requires=.*boot-complete\.target' "$CONFIRM"; then
    ok "keel-confirm 由 multi-user 拉起(并 Requires=boot-complete.target)⇒ 回滚那次非计数启动也会记录失败"
else
    no "keel-confirm 少了 multi-user.target 那条 WantedBy ⇒ 回滚后不会记录失败/清理坏条目(坑 #41)"
fi

# /data 的文件系统扩容:必须有 resize2fs 兜底(坑 #42:systemd-growfs 对"自己 mount(8)
# 挂的"挂载点会失败,2026-09 用 40G 假盘复现过"分区扩到 27G、文件系统还是 974M")。
if grep -q 'command -v systemd-growfs' mkosi.extra/usr/lib/keel/firstboot &&
   grep -q 'resize2fs "$vol"' mkosi.extra/usr/lib/keel/firstboot &&
   grep -q 'systemd 包不带它' mkosi.extra/usr/lib/keel/firstboot &&
   grep -q 'part_bytes / 20' mkosi.extra/usr/lib/keel/firstboot; then
    ok "keel-firstboot:growfs 有则试、resize2fs 必跑、按 5% 容差判断是否扩到位(坑 #42)"
else
    no "keel-firstboot 的扩容逻辑不完整(缺 resize2fs / 缺 growfs 存在性判断 / 缺 5% 容差)"
fi
if grep -q 'resize2fs "$data_dev"' mkosi.extra/usr/bin/os-rescue &&
   grep -q '现在的大小:分区' mkosi.extra/usr/bin/os-rescue; then
    ok "os-rescue --grow-data 同样有 resize2fs 兜底,并打印分区/文件系统两个尺寸"
else
    no "os-rescue --grow-data 没有 resize2fs 兜底(坑 #42)"
fi

# OTA 演练(mkosi.extra-test/):必须只在 test profile,且被 test preset 启用
if [ -x mkosi.extra-test/usr/lib/keel/ota-drill ] &&
   [ -f mkosi.extra-test/usr/lib/systemd/system/keel-ota-drill.service ]; then
    ok "OTA 演练脚本与单元在 mkosi.extra-test/ 里(只有 test profile 会挂进镜像)"
else
    no "OTA 演练文件缺失或 ota-drill 不可执行"
fi
if grep -q '^enable keel-ota-drill.service'       mkosi.extra-test/usr/lib/systemd/system-preset/01-keel-test.preset; then
    ok "test preset 启用了 keel-ota-drill.service"
else
    no "test preset 没启用 keel-ota-drill"
fi
if grep -rq 'keel-ota-drill' mkosi.postinst mkosi.finalize mkosi.extra 2>/dev/null; then
    no "正式镜像的构建脚本/目录里出现了 keel-ota-drill(它必须只活在 test profile)"
else
    ok "正式产物完全不含 OTA 演练"
fi
if grep -q 'drill)' tools/build-container.sh &&
   grep -q 'ota-drill-container.sh' tools/build-container.sh &&
   [ -x tools/ota-drill-container.sh ] &&
   grep -q 'DRILL_IMAGE_SIZE' tools/ota-drill-container.sh &&
   grep -q 'DRILL_BOOT_VERSION' tools/ota-drill-container.sh &&
   grep -q 'python3 -m http.server' tools/ota-drill-container.sh &&
   grep -q 'urllib.request' tools/ota-drill-container.sh; then
    ok "drill 模式:独立编排脚本(远古引导版本 + 可配镜像尺寸 + 容器内 HTTP 源 + python3 探测)"
else
    no "drill 编排不完整(见 tools/build-container.sh / tools/ota-drill-container.sh)"
fi
if grep -q 'systemctl poweroff' mkosi.extra-test/usr/lib/keel/ota-drill; then
    ok "演练 p2 结束会 poweroff(宿主不用靠 timeout 杀 VM)"
else
    no "演练结束后不会自己关机 ⇒ 宿主每次都得等 timeout"
fi

# 槽切换用的 bootctl 动词(坑 #43):Debian 的 systemd 257 没有 set-preferred,
# 所以候选槽必须走 set-oneshot、持久选择走 set-default,而且都收敛到 lib.sh 的 helper。
# systemd-bless-boot 在 /usr/lib/systemd/ 下,不在 PATH 里(坑 #60):
# os-rescue --mark-bad 以前用 `command -v systemd-bless-boot` 判「装没装」⇒ 永远说找不到。
n_abs=$(grep -n '/usr/lib/systemd/systemd-bless-boot' mkosi.extra/usr/bin/os-rescue | head -1 | cut -d: -f1)
n_cmd=$(grep -n 'command -v systemd-bless-boot' mkosi.extra/usr/bin/os-rescue | head -1 | cut -d: -f1)
if [ -n "$n_abs" ] && { [ -z "$n_cmd" ] || [ "$n_abs" -lt "$n_cmd" ]; }; then
    ok "os-rescue 先按绝对路径找 systemd-bless-boot(它不在 PATH 里;command -v 只作兜底,坑 #60)"
else
    no "os-rescue 用 command -v 找 systemd-bless-boot ⇒ 二进制明明在也会报「找不到」(坑 #60)"
fi
if grep -q '^keel_boot_candidate() { bootctl set-oneshot' mkosi.extra/usr/lib/keel/lib.sh &&
   grep -q '^keel_boot_default() { bootctl set-default' mkosi.extra/usr/lib/keel/lib.sh; then
    ok "lib.sh 定义了 keel_boot_candidate(set-oneshot)/keel_boot_default(set-default)(坑 #43)"
else
    no "lib.sh 缺少 bootctl 动词的封装(坑 #43)"
fi
if grep -q 'keel_boot_candidate "\$candidate_id"' mkosi.extra/usr/bin/os-update &&
   grep -q 'candidate_id="keel-\${target}.efi"' mkosi.extra/usr/bin/os-update &&
   grep -q 'keel_boot_default "\$pref"' mkosi.extra/usr/bin/os-update &&
   grep -q 'keel_boot_default "\$uki_name"' mkosi.extra/usr/lib/keel/confirm; then
    ok "os-update(stage=候选/switch=固化)与 keel-confirm(固化)都走 helper"
else
    no "还有调用点没改用 helper(候选槽 set-oneshot / 固化 set-default)"
fi
# 只看**非注释行**:注释里提到"原设计用的是 set-preferred"是解释,不是调用
if grep -rn '^[^#]*bootctl set-preferred' mkosi.extra/ >/dev/null 2>&1; then
    bad=$(grep -rln '^[^#]*bootctl set-preferred' mkosi.extra/ | tr '\n' ' ')
    no "仍有代码调用 bootctl set-preferred(systemd 257 会报 Unknown command verb):$bad"
else
    ok "没有任何地方再调用 bootctl set-preferred(它只出现在解释性注释里)"
fi

# 安装镜像 ESP 里的 UKI 名字必须是 keel-a.efi(mkosi 默认是 &e-&k = keel-<内核版本>,
# 那样 os-update rollback / switch 在一台刚装好的机器上找不到槽 a 的条目 —— 坑 #44)
if grep -qE '^UnifiedKernelImageFormat=keel-a$' mkosi.profiles/install.conf; then
    ok "install profile 钉住 UnifiedKernelImageFormat=keel-a(ESP 里的槽 a 条目就叫 keel-a.efi)"
else
    no "install profile 没钉 UnifiedKernelImageFormat ⇒ ESP 里会是 keel-<kver>.efi,按槽名找不到(坑 #44)"
fi
if grep -q 'selected' mkosi.extra/usr/lib/keel/confirm &&
   grep -q 'entry_\$slot' mkosi.extra/usr/lib/keel/confirm; then
    ok "keel-confirm 在 keel-<槽>.efi 不存在时退回「本次启动选中的条目」,并把名字记进 state(坑 #44)"
else
    no "keel-confirm 缺少条目名兜底(坑 #44)"
fi

# 控制台日志级别(决策 D27 / 坑 #61):内核 console_loglevel 出厂是 7 ⇒ 图形/串口控制台
# 会被 audit(PAM 认证)记录时不时刷一屏;我们用 sysctl 降到 4(dmesg/journal 一条不少,
# systemd 自己的 [ OK ] 启动进度照旧)。
if grep -qE '^kernel\.printk = 4 4 1 7$' mkosi.extra/etc/sysctl.d/10-keel-console.conf 2>/dev/null; then
    ok "sysctl drop-in 把内核控制台日志级别降到 4(不刷 audit,又不按掉启动进度,坑 #61)"
else
    no "缺少 mkosi.extra/etc/sysctl.d/10-keel-console.conf 或里面的 kernel.printk 不对(坑 #61)"
fi
# 启动早期顺序(sysctl / journald / journal-flush 都必须排在 keel-mounts 之后)
KM=mkosi.extra/usr/lib/systemd/system/keel-mounts.service
miss=""
for u in systemd-sysctl.service systemd-journald.service systemd-journal-flush.service; do
    grep -q "^Before=$u$" "$KM" || miss="$miss $u"
done
if [ -z "$miss" ]; then
    ok "keel-mounts 排在这三个单元之前:sysctl / journald / journal-flush(否则用户 drop-in 不生效、日志不落盘,坑 #61)"
else
    no "keel-mounts 缺 Before 顺序:$miss ⇒ /etc overlay 还没挂上它们就跑了(坑 #61)"
fi
# 自动回滚的前提:panic 会自动重启(决策 D24 / 坑 #46)
if grep -qE '^[[:space:]]*panic=-1$' mkosi.conf.d/30-content.conf; then
    ok "cmdline 里有 panic=-1(内核 panic ⇒ 立即重启 ⇒ 候选槽那次失败之后能自动回退)"
else
    no "cmdline 里没有 panic=-1 ⇒ 新槽 panic 时机器会停在黑屏,自动回滚不会发生(坑 #46)"
fi
if grep -q 'debugfs' tools/ota-drill-container.sh &&
   grep -q 'slot-\$BAD_SLOT.root.raw' tools/ota-drill-container.sh &&
   grep -q 'File not found' tools/ota-drill-container.sh &&
   grep -q '不要.*只看 debugfs 的退出码' tools/ota-drill-container.sh; then
    ok "演练会做一个起不来的坏载荷(debugfs 删 PID1 + **按输出文本**回读确认 + 重算 sha256)"
else
    no "drill 模式缺少坏载荷的准备(破坏性回滚验不了)"
fi
# v1.1:槽载荷换成 erofs 之后,debugfs(ext4 专用)打不开它,而且它对打不开的文件
# **也返回 0**(坑 #47)⇒ 会产出"看起来坏了其实没坏"的载荷,回滚演练变假绿。
# 现在的方法是**按文件系统选工具**:erofs 走 fsck.erofs --extract → 改树 → mkfs.erofs,
# ext4 仍走 debugfs;认不出就明确失败。
if grep -q 'fs_kind' tools/ota-drill-container.sh &&
   grep -q 'e2e1f5e0' tools/ota-drill-container.sh &&
   grep -q 'sabotage_erofs' tools/ota-drill-container.sh &&
   grep -q 'fsck.erofs --extract' tools/ota-drill-container.sh &&
   grep -q 'mkfs.erofs' tools/ota-drill-container.sh &&
   grep -q 'sabotage_ext4' tools/ota-drill-container.sh; then
    ok "演练的坏载荷构造按文件系统分派(erofs:解包/改树/重打包;ext4:debugfs;认不出则失败)"
else
    no "drill 的坏载荷构造没有覆盖 erofs ⇒ 载荷换成 erofs 后会静默产出假坏载荷,回滚演练变假绿"
fi

}
