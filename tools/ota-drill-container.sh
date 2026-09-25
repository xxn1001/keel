#!/bin/bash
# keel OTA 演练:容器侧编排(由 tools/build-container.sh 的 drill 模式调用)
#
# 这个脚本**在构建容器里以 root 运行**(cwd = /work = 仓库挂载点),它负责:
#   1. 静态校验
#   2. tools/build.sh → 新版本载荷 dist/keel-<时间戳>/
#   3. 用**显式更旧的版本号**构建引导镜像(否则 os-update check 会说"已经是最新")
#   4. 把安装镜像 truncate 到 40G(载荷 4 个产物约 13 GiB,而 live 镜像的 /data 只有 1 GiB)
#   5. 起本地 HTTP 源(见下面"为什么必须在容器里起")
#   6. 起 VM:guest 里的 keel-ota-drill.service 会自己跑完 check/fetch/stage/重启/确认/回滚
#
# 为什么要拆成独立脚本:整个流程要塞进 `bash -lc "…"` 的话,引号要套三层
# (容器 → PAYLOAD → mkosi),第一次跑就栽在"容器里没有 curl"这种小地方,
# 而独立脚本里可以正常写、正常报错。
#
# 为什么 HTTP 源必须起在容器里:guest 访问的 10.0.2.2 是 QEMU 用户态网络的"网关",
# SLIRP 实际是让 **qemu 进程**去连它自己网络命名空间里的地址 —— qemu 跑在容器里,
# 所以服务也必须在容器里;宿主机上起的服务它够不着。
set -euo pipefail
cd "$(dirname "$0")/.."

DRILL_BOOT_VERSION=${KEEL_DRILL_BOOT_VERSION:-2000.01.01.0001}
DRILL_PORT=${KEEL_DRILL_PORT:-8000}
DRILL_VM_TIMEOUT=${KEEL_DRILL_VM_TIMEOUT:-1500}
ROOTPW_ARGS=()
[ -n "${KEEL_ROOT_PASSWORD:-}" ] && ROOTPW_ARGS=("--root-password=$KEEL_ROOT_PASSWORD")

step() { printf '\n== %s ==\n' "$*"; }

step "1/7 静态校验"
tools/verify.sh

step "2/7 构建新版本载荷(tools/build.sh)"
# KEEL_EXTRA_PROFILES=test:**新槽里也必须有没有自检/状态机**,否则重启到新槽之后
# 状态机就断了(第一次演练就栽在这里:新槽是生产载荷,里面没有 keel-ota-drill,
# 于是 p1/p2 永远不会跑,VM 就停在 login 提示符上)。
env KEEL_EXTRA_PROFILES=test tools/build.sh
DRILL_PAYLOAD=$(ls -1d dist/keel-* 2>/dev/null | sort -V | tail -n1) || DRILL_PAYLOAD=""
[ -n "$DRILL_PAYLOAD" ] || { echo "错误:dist/ 下没有载荷目录" >&2; exit 1; }
echo "   载荷目录:$DRILL_PAYLOAD(版本 $(sed -n 's/^version=//p' "$DRILL_PAYLOAD/manifest" | head -n1))"

step "3/7 构建引导镜像(版本 $DRILL_BOOT_VERSION,必须旧于载荷)"
mkosi --profile install --profile test --image-version="$DRILL_BOOT_VERSION" \
      "${ROOTPW_ARGS[@]+"${ROOTPW_ARGS[@]}"}" --force build

step "4/7 把安装镜像放大到 40G(首启的 repart + resize2fs 会把 data 扩到整盘)"
truncate -s 40G mkosi.output/keel.raw
ls -l mkosi.output/keel.raw | awk '{ print "   keel.raw = " $5 " 字节" }'

step "5/7 起本地 HTTP 源(guest 会访问 http://10.0.2.2:$DRILL_PORT/good)"
rm -rf /tmp/drill-serve
mkdir -p /tmp/drill-serve
ln -sfn "/work/$DRILL_PAYLOAD" /tmp/drill-serve/good
( cd /tmp/drill-serve && nohup python3 -m http.server "$DRILL_PORT" --bind 0.0.0.0 >/tmp/drill-http.log 2>&1 & )
sleep 2
# 用 python3 探测(容器里**没有 curl** —— 第一次就栽在这:mkosi 不依赖它)
python3 - "$DRILL_PORT" <<'PY'
import sys, urllib.request
port = sys.argv[1]
url = f"http://127.0.0.1:{port}/good/manifest"
try:
    with urllib.request.urlopen(url, timeout=5) as r:
        body = r.read()
    print(f"   本地源就绪:{url} → HTTP {r.status},{len(body)} 字节")
except Exception as e:  # noqa: BLE001
    print(f"   错误:本地源探测失败:{e}", file=sys.stderr)
    sys.exit(1)
PY

step "6/7 准备**坏载荷**(让某个槽真的起不来,验自动回滚)"
# 思路:坏载荷 = 好载荷的"镜像",只把**目标槽的根镜像**换成一个起不来的文件系统:
# 删掉 PID1(/usr/lib/systemd/systemd)与内核的 init 兜底(/bin/sh → dash、bash)
# ⇒ 内核找不到任何 init ⇒ panic ⇒ cmdline 里的 panic=-1 立即重启(决策 D24)
# ⇒ 下次启动回到持久默认(旧槽),keel-confirm 于是能判定"更新失败已回滚"。
#
# 演练里"目标槽"总是**另一个槽**:p2 阶段跑在槽 a 上,所以要用 slot-b 的产物。
# 大的根镜像用 cp --reflink(不行就普通复制);其余文件用符号链接,省 13 GiB 的拷贝。
BAD_SLOT=${KEEL_DRILL_BAD_SLOT:-b}
command -v debugfs >/dev/null 2>&1 || {
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends e2fsprogs >/dev/null 2>&1
}
rm -rf /tmp/drill-serve/bad
mkdir -p /tmp/drill-serve/bad
for f in /work/"$DRILL_PAYLOAD"/*; do
    b=$(basename "$f")
    [ "$b" = "manifest" ] && continue
    [ "$b" = "slot-$BAD_SLOT.root.raw" ] && continue
    ln -sfn "$f" "/tmp/drill-serve/bad/$b"
done
cp --reflink=auto --sparse=always "/work/$DRILL_PAYLOAD/slot-$BAD_SLOT.root.raw" \
   "/tmp/drill-serve/bad/slot-$BAD_SLOT.root.raw"
BAD_IMG=/tmp/drill-serve/bad/slot-$BAD_SLOT.root.raw
for target in /usr/lib/systemd/systemd /usr/bin/dash /usr/bin/bash; do
    # 注意:**不要**只看 debugfs 的退出码 —— 它干什么都返回 0(坑 #47 实测)
    debugfs -w -R "rm $target" "$BAD_IMG" >/dev/null 2>&1 || true
done
# 回读确认真的删掉了:判据只能是**输出文本**(`File not found by ext2_lookup`),
# 因为 `debugfs -R "stat …"` 对不存在的路径同样返回 0(实测)。
for target in /usr/lib/systemd/systemd /usr/bin/dash /usr/bin/bash; do
    if debugfs -R "stat $target" "$BAD_IMG" 2>&1 | grep -q 'File not found'; then
        echo "   已确认删掉:$target"
    else
        echo "   错误:坏载荷里 $target 还在(或 debugfs 读不出来)⇒ 那个槽不会 panic,演练没有意义" >&2
        debugfs -R "stat $target" "$BAD_IMG" 2>&1 | tail -2 >&2
        exit 1
    fi
done
echo "   已把 slot-$BAD_SLOT.root.raw 做成起不来的(删掉 PID1 与 init 兜底,回读已确认)"
# manifest:版本比好载荷再高一档(否则 stage 会说"不比当前新"),并把被改过的那个产物的
# sha256 换成新值 —— 其余行为原样复制(其余产物是符号链接,内容没变)
GOOD_VER=$(sed -n 's/^version=//p' "/work/$DRILL_PAYLOAD/manifest" | head -n1)
BAD_SHA=$(sha256sum "$BAD_IMG" | cut -d' ' -f1)
sed -e "s/^version=.*/version=${GOOD_VER}.bad/" \
    -e "s|^sha256_slot-$BAD_SLOT.root.raw=.*|sha256_slot-$BAD_SLOT.root.raw=$BAD_SHA|" \
    "/work/$DRILL_PAYLOAD/manifest" >/tmp/drill-serve/bad/manifest
echo "   坏载荷版本:${GOOD_VER}.bad(slot-$BAD_SLOT.root.raw 的 sha256 已更新)"

step "7/7 起 VM(演练状态机自己跑;p3 结束时会 poweroff,所以这次 VM 会自己退出)"
set +e
timeout "$DRILL_VM_TIMEOUT" mkosi --profile install --profile test \
    "${ROOTPW_ARGS[@]+"${ROOTPW_ARGS[@]}"}" vm
rc=$?
set -e
if [ "$rc" = 124 ]; then
    echo "   注意:VM 到了 ${DRILL_VM_TIMEOUT}s 超时上限被结束 —— 演练可能卡在某个阶段,"
    echo "         把上面控制台输出里最后一段 keel-ota-drill[...] 的内容发出来。"
else
    echo "   VM 退出码:$rc(0 = 演练跑到 p2 并自己 poweroff)"
fi
