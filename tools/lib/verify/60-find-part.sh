# shellcheck shell=bash
# keel verify 模块:os-install find_part 假 sysfs 功能测试(原第 586-619 行,逐字搬移)

verify_find_part() {
# os-install 的 find_part:live 盘与目标盘**分区同名**(都是 root-a / esp / data),
# 所以必须按"父设备等于目标盘"筛;而且刚写完分区表时 udev 可能还没把 PARTLABEL 填上
# (2026-09 真机踩过:repart 建好了四个分区,这里一个都找不到,坑 #33)⇒ 先扫 sysfs。
# 这段逻辑纯文本可测:造一棵假 sysfs 树(含另一块盘上的同名分区)真跑一遍。
if have sed && have readlink; then
    ft=$(tmpd)
    mkdir -p "$ft/sys/class/block" "$ft/sys/devices/block/vda/vda1" \
             "$ft/sys/devices/block/vda/vda2" "$ft/sys/devices/block/vdb/vdb1"
    printf 'PARTNAME=root-a\n' >"$ft/sys/devices/block/vda/vda1/uevent"
    printf 'PARTNAME=data\n' >"$ft/sys/devices/block/vda/vda2/uevent"
    printf 'PARTNAME=root-a\n' >"$ft/sys/devices/block/vdb/vdb1/uevent"
    ln -s ../../devices/block/vda      "$ft/sys/class/block/vda"
    ln -s ../../devices/block/vda/vda1 "$ft/sys/class/block/vda1"
    ln -s ../../devices/block/vda/vda2 "$ft/sys/class/block/vda2"
    ln -s ../../devices/block/vdb/vdb1 "$ft/sys/class/block/vdb1"
    {
        echo 'keel_log() { :; }'
        echo 'lsblk() { return 0; }'
        echo 'blockdev() { :; }'
        echo 'udevadm() { :; }'
        echo 'TARGET=/dev/vda; TARGET_NAME=vda'
        sed -n '/^find_part() {/,/^}/p' mkosi.extra/usr/bin/os-install \
            | sed "s|/sys/class/block|$ft/sys/class/block|g; s|sleep 1|:|"
    } >"$ft/fn.sh"
    got_a=$(bash -c '. '"$ft"'/fn.sh; find_part root-a' 2>/dev/null)
    got_v=$(bash -c '. '"$ft"'/fn.sh; find_part data' 2>/dev/null)
    got_x=$(bash -c '. '"$ft"'/fn.sh; find_part esp' 2>/dev/null)
    if [ "$got_a" = "/dev/vda1" ] && [ "$got_v" = "/dev/vda2" ] && [ -z "$got_x" ]; then
        ok "find_part 按父设备筛分区(假 sysfs:vda 命中、vdb 上的同名分区被忽略、查不到时输出为空)"
    else
        no "find_part 逻辑不对:root-a=[$got_a] data=[$got_v] esp=[$got_x](期望 /dev/vda1 /dev/vda2 空)"
    fi
fi

}
