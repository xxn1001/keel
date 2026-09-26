# shellcheck shell=bash
# keel verify 模块:一致性断言核心(类型 UUID / 骨架 / /data 与 ESP 挂载;原第 358-454 行,逐字搬移)

verify_consistency_core() {
# ---------------------------------------------------------------------------
head1 "6. 一致性断言(改一处忘一处的经典位置)"
# ---------------------------------------------------------------------------
uuid_repart=$(sed -n 's/^Type=\(.*\)$/\1/p' repart/install/30-data.conf | head -1)
uuid_grow=$(sed -n 's/^Type=\(.*\)$/\1/p' mkosi.extra/usr/lib/keel/repart.d/40-data-grow.conf | head -1)
[ -n "$uuid_repart" ] && [ "$uuid_repart" = "$uuid_grow" ] \
    && ok "类型 UUID 在安装镜像与扩容定义里一致" \
    || no "类型 UUID 不一致:安装=[$uuid_repart] 扩容=[$uuid_grow]"

skel_repart=$(grep -o 'CopyFiles=[^:]*' repart/install/30-data.conf | head -1 | cut -d= -f2)
if grep -q "$skel_repart" mkosi.finalize; then
    ok "骨架路径 $skel_repart 在 finalize 里也出现"
else
    no "骨架路径 $skel_repart 只在 repart 定义里出现,finalize 没有生成它"
fi

# ---- /data 与 ESP 的挂载方式(坑 #24 / #25)---------------------------------
# /data 不能再靠 cmdline 的 systemd.mount-extra(依赖 udev 符号链接 ⇒ 与 /etc overlay 成环),
# 必须由 keel-mounts.service 自己挂,而且不能通过 .mount 单元引入依赖。
if grep -qE '^[[:space:]]*RequiresMountsFor=/data' mkosi.extra/usr/lib/systemd/system/keel-mounts.service; then
    no "keel-mounts.service 里有 RequiresMountsFor=/data —— 会拉进依赖 udev 的 data.mount,重新造出依赖环(坑 #24)"
else
    ok "keel-mounts.service 没有 RequiresMountsFor=/data(不会引入 udev 依赖环)"
fi

if grep -q 'PARTNAME=\$want' mkosi.extra/usr/lib/keel/lib.sh \
   && grep -q 'keel_part_dev data' mkosi.extra/usr/lib/keel/mounts; then
    ok "lib.sh 用 sysfs 的 PARTNAME 找分区(不依赖 udev),mounts 调它挂 data 分区"
else
    no "找不到「按 PARTNAME 扫 sysfs」的查找逻辑(lib.sh 的 keel_part_dev + mounts 里的调用)—— /data 就挂不上了"
fi

if grep -q 'Before=systemd-random-seed.service' mkosi.extra/usr/lib/systemd/system/keel-mounts.service; then
    ok "keel-mounts 排在 systemd-random-seed 之前(/var 符号链接此时已有效)"
else
    no "keel-mounts 没有排在 systemd-random-seed 之前 —— 它会往悬空的 /var 符号链接写随机种子然后失败(坑 #24)"
fi

# /data 是分区挂载点,镜像树里必须有这个空目录(否则 mount 报 mount point does not exist)
if grep -qE '^[[:space:]]*install -d .*"\$R/data"' mkosi.finalize; then
    ok "mkosi.finalize 建了 /data 挂载点目录"
else
    no "mkosi.finalize 没有建 /data 目录 —— 运行时挂载会失败(坑 #24)"
fi

# ---------------------------------------------------------------------------
# ESP(坑 #36):必须由 keel-mounts 自己扫 PARTNAME=esp 挂上,而且 lib.sh 不许再把
# bootctl 的"猜测路径"当成真挂载点("每个步骤都成功、结果全落空"就是这么来的)。
# ---------------------------------------------------------------------------
if grep -q 'keel_esp_mount' mkosi.extra/usr/lib/keel/mounts \
   && grep -q 'mount -t vfat' mkosi.extra/usr/lib/keel/lib.sh \
   && grep -q 'PARTNAME=\$want' mkosi.extra/usr/lib/keel/lib.sh; then
    ok "keel-mounts 自己挂 ESP(lib.sh 的 keel_esp_mount:按 PARTNAME=esp 扫 sysfs + mount vfat)"
else
    no "keel-mounts 没有自己挂 ESP,或者 lib.sh 里没有 keel_esp_mount(坑 #36)"
fi

if grep -q 'KEEL_ESP_MOUNTED' mkosi.extra/usr/lib/keel/lib.sh \
   && grep -q 'KEEL_ESP_MOUNTED' mkosi.extra/usr/bin/os-status \
   && grep -q 'KEEL_ESP_MOUNTED' mkosi.extra/usr/bin/os-update \
   && grep -q 'KEEL_ESP_MOUNTED' mkosi.extra/usr/lib/keel/confirm; then
    ok "ESP 没挂上时 os-status / os-update / keel-confirm 都会明确报出来(不再静默)"
else
    no "拿 KEEL_ESP_MOUNTED 报错的三处没接好:os-status / os-update / keel-confirm(坑 #36)"
fi

# 顺序:os-update 必须**先**确认 ESP 可用,再 dd 根分区 —— 反过来会留下"新根 + 旧内核"
# 的槽,违反不变量 3,而且失败点离原因很远。
esp_line=$(grep -n 'keel_esp_mount' mkosi.extra/usr/bin/os-update | head -n1 | cut -d: -f1)
dd_line=$(grep -n 'dd if="\$payload" of="\$dev"' mkosi.extra/usr/bin/os-update | head -n1 | cut -d: -f1)
if [ -n "$esp_line" ] && [ -n "$dd_line" ] && [ "$esp_line" -lt "$dd_line" ]; then
    ok "os-update 先确认 ESP(第 $esp_line 行)再写根分区(第 $dd_line 行)"
else
    no "os-update 里 ESP 检查和写根分区的顺序不对(必须先检查 ESP)"
fi

# gpt-auto 必须退场:它对 ESP 的自动挂载静默且不可靠,而我们自己挂了
if grep -q '^[[:space:]]*systemd\.gpt_auto=no' mkosi.conf.d/30-content.conf; then
    ok "cmdline 里有 systemd.gpt_auto=no(gpt-auto 不再插手 ESP,坑 #36)"
else
    no "cmdline 里没有 systemd.gpt_auto=no —— gpt-auto 可能又悄悄挂/不挂 ESP(坑 #36)"
fi

# ESP 挂在哪由我们自己定(/boot),不再依赖 gpt-auto 的选择
if grep -q 'bootctl --print-esp-path' mkosi.extra/usr/lib/keel/lib.sh; then
    ok "lib.sh 里 bootctl --print-esp-path 只作兜底(且必须真的是挂载点)"
else
    no "lib.sh 里连 bootctl 兜底都没了 —— 手工挂到非 /boot 路径的系统会找不到 ESP"
fi

if grep -rn '/efi/EFI' mkosi.extra/usr/bin mkosi.extra/usr/lib/keel 2>/dev/null | grep -v 'lib.sh' | grep -q .; then
    no "有脚本硬编码 /efi/EFI 路径(应该用 \$KEEL_UKI_DIR):"
    grep -rn '/efi/EFI' mkosi.extra/usr/bin mkosi.extra/usr/lib/keel 2>/dev/null | grep -v 'lib.sh' | head -5 | sed 's/^/      /'
else
    ok "没有脚本硬编码 /efi/EFI(都用 \$KEEL_UKI_DIR)"
fi

}
