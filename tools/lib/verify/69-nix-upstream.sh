# shellcheck shell=bash
# keel verify 模块:上游 nix 供给(v1.2 1.5 / 决策 D29 / B1)
#
# 盯四件事:
#   ① 供给是**固定版本 + 哈希**:tools/nix-fetch.sh 钉死 2.35.2 与 64 位 sha256,
#      fetch 每次校验,不校验的入口被 env 闸住(只给自测);
#   ② Debian 的 nix 包**退场**了,接替品齐全:自己的 daemon 单元、nixbld 用户(sysusers.d)、
#      /usr/bin 命令入口(符号链接指向 profile);
#   ③ 运行时是**加性同步**:只拷缺失、先问空间(留 256 MiB 不变量 10)、临时名再 mv、
#      load-db 登记、profile 重指;失败时不重指(旧 nix 仍可用);
#   ④ 功能测试(不靠 grep):假 tarball 走完"解包 → 加性同步 → load-db → 重指",
#      并验证"哈希错必须拒"、"第二次不覆盖"、"空间问不出来必须拒绝且不切 profile"。

verify_nix_upstream() {
head1 "13. nix 上游供给(B1:固定版本+哈希 → 数据骨架 → 加性同步)"

NF=tools/nix-fetch.sh
NS=mkosi.extra/usr/lib/keel/nix-sync
US=mkosi.extra/usr/lib/sysusers.d/keel-nix.conf
PK=mkosi.conf.d/20-packages.conf
KCHK=mkosi.extra/usr/share/keel/keel-check

# ── ① 钉死的版本/哈希 + fail-closed 的取用 ────────────────────────────────
if grep -q '^readonly NIX_VERSION=2.35.2$' "$NF" &&
   grep -qE '^readonly NIX_SHA256=[0-9a-f]{64}$' "$NF" &&
   grep -q 'releases.nixos.org/nix/nix-' "$NF" &&
   grep -q 'mkosi.pkgcache' "$NF"; then
    ok "tools/nix-fetch.sh 钉死上游版本(2.35.2)+ 64 位 sha256 + 官方 URL,缓存落在 mkosi.pkgcache/"
else
    no "tools/nix-fetch.sh 没有钉死版本/哈希/URL(那就不是"固定版本+哈希"的供给)"
fi
if grep -qF 'check_tarball "$TARBALL"' "$NF" &&
   grep -qF 'unpack "$TARBALL"' "$NF" &&
   grep -qF '哈希不匹配' "$NF"; then
    ok "fetch 先校验哈希再解包,不匹配直接失败(不解出未校验的 nix)"
else
    no "fetch 的"校验 → 解包"链路不完整"
fi
if grep -qF 'KEEL_NIX_UNVERIFIED' "$NF"; then
    ok "不校验哈希的 unpack 入口被 KEEL_NIX_UNVERIFIED 闸住(构建只走 fetch)"
else
    no "unpack 没有闸:构建路径以外可以塞进未校验的 nix"
fi
if grep -qF 'NIX_FETCH=tools/nix-fetch.sh' tools/build.sh &&
   grep -qF '"$NIX_FETCH" fetch' tools/build.sh &&
   grep -qF 'nix-fetch.sh fetch' tools/build-container.sh; then
    ok "build.sh 与 build-container.sh(vm)都在 mkosi 之前取上游 nix"
else
    no "有构建路径没有调用 tools/nix-fetch.sh fetch"
fi

# ── ② Debian 包退场 + 接替品 ──────────────────────────────────────────────
if ! grep -qE '^[[:space:]]*nix-(bin|setup-systemd)[[:space:]]*$' "$PK"; then
    ok "Packages 里不再有 nix-bin / nix-setup-systemd(唯一供给是上游 tarball,决策 D29)"
else
    no "Packages 里还有 Debian 的 nix 包 ⇒ 会与上游供给互相覆盖 /nix 与命令入口"
fi
if [ -f mkosi.extra/usr/lib/systemd/system/nix-daemon.service ] &&
   [ -f mkosi.extra/usr/lib/systemd/system/nix-daemon.socket ] &&
   [ -f mkosi.extra/usr/lib/systemd/system/keel-nix-sync.service ] &&
   grep -q '^enable keel-nix-sync.service' mkosi.extra/usr/lib/systemd/system-preset/00-keel.preset; then
    ok "我们自己的 nix-daemon.service/.socket + keel-nix-sync.service 都在,preset 已启用"
else
    no "接替 nix-setup-systemd 的单元不全/未启用"
fi
u_n=$(grep -c '^u! nixbld' "$US" || true)
m_n=$(grep -c '^m nixbld' "$US" || true)
if grep -q '^g nixbld ' "$US" && [ "$u_n" -eq 32 ] && [ "$m_n" -eq 32 ]; then
    ok "nixbld 由 sysusers.d 声明(1 组 + 32 用户 + 32 成员,与上游 installer 默认一致)"
else
    no "sysusers.d 的 nixbld 声明不完整(组/用户/成员计数不对)"
fi
bin_missing=""
for b in nix nix-daemon nix-store nix-shell nix-env nix-collect-garbage nix-build; do
    if [ -L "mkosi.extra/usr/bin/$b" ] &&
       [ "$(readlink "mkosi.extra/usr/bin/$b")" = "/nix/var/nix/profiles/default/bin/$b" ]; then :; else
        bin_missing="$bin_missing $b"
    fi
done
if [ -z "$bin_missing" ]; then
    ok "命令入口是 /usr/bin/<name> → profile 的符号链接(nix-store / nix-collect-garbage 也在)"
else
    no "缺少命令入口(符号链接或目标不对):$bin_missing"
fi

# ── ③ 加性同步的语义 ──────────────────────────────────────────────────────
sync_missing=""
grep -qF '[ -e "$NIX_ROOT/store/$name" ] && continue' "$NS" || sync_missing="$sync_missing [只拷缺失]"
grep -qF 'df -B1 --output=avail' "$NS" || sync_missing="$sync_missing [空间检查]"
grep -qF 'RESERVE_BYTES' "$NS" || sync_missing="$sync_missing [留余量]"
grep -qF '.incoming-' "$NS" || sync_missing="$sync_missing [临时名再 mv]"
grep -qF -- '"$NIX_ROOT/store/$NIXNAME/bin/nix-store" --load-db' "$NS" || sync_missing="$sync_missing [登记 DB(完整 store 路径)]"
grep -qF 'ln -sfn "$LINK" "$NIX_ROOT/var/nix/profiles/default"' "$NS" || sync_missing="$sync_missing [profile 重指]"
if [ -z "$sync_missing" ]; then
    ok "nix-sync:只拷缺失 + 先问空间(留 256 MiB)+ 临时名再 mv + load-db + profile 重指"
else
    no "nix-sync 缺少加性/安全环节:$sync_missing"
fi
if grep -qF '保留旧 profile' "$NS"; then
    ok "失败语义:拷贝/登记失败时不重指 profile(旧 nix 仍可用)"
else
    no "nix-sync 失败时可能已经切了 profile(半同步),旧 nix 不再可信"
fi
if grep -qF 'usr/share/keel/data-skeleton/nix/store' mkosi.postinst &&
   grep -qF 'usr/bin/nix' mkosi.postinst; then
    ok "postinst 回读断言:骨架里有上游 nix + /usr/bin/nix 入口(缺了拒绝出产物)"
else
    no "postinst 没有"上游 nix 必须在骨架里"的回读断言"
fi
if grep -qF '判定:nix 来自本槽骨架' mkosi.extra-test/usr/lib/keel/ota-drill &&
   grep -qF '判定:nix 来自本槽骨架' tools/ota-drill-container.sh; then
    ok "演练把 nix 自检也算进宿主侧关键判定(nix 缺失/版本不对/profile 没跟上 ⇒ 演练失败)"
else
    no "演练没有把 nix 自检算进关键判定(1.5 就没有端到端证据)"
fi
if grep -qF 'nix profile 指向本槽骨架' "$KCHK"; then
    ok "keel-check 核对 profile 指向本槽骨架(版本跟槽走的现场判据)"
else
    no "keel-check 不核对 nix profile 与骨架的一致性"
fi

# ── ④ 功能测试 ────────────────────────────────────────────────────────────
# 真缓存存在就验一次哈希;没有就跳过(下载一次之后这条会真跑)。
if [ -s mkosi.pkgcache/nix-2.35.2-x86_64-linux.tar.xz ]; then
    if bash "$NF" verify >/dev/null 2>&1; then
        ok "缓存里的上游 tarball 与钉死的 sha256 一致(2.35.2,约 27 MB)"
    else
        no "缓存里的上游 tarball 哈希对不上(缓存坏了,或钉的哈希要更新)"
    fi
else
    skip "缓存里没有 nix-2.35.2 tarball(跑一次 tools/nix-fetch.sh fetch 后这条会真跑)"
fi
# fetch 对错哈希必须拒绝
ft="$(tmpd)"; mkdir -p "$ft/cache"
printf 'not a nix tarball' >"$ft/cache/nix-2.35.2-x86_64-linux.tar.xz"
if KEEL_NIX_CACHE="$ft/cache" KEEL_NIX_STAGE="$ft/stage" bash "$NF" fetch >/dev/null 2>&1; then
    no "fetch 接受了哈希不匹配的 tarball(钉死的哈希形同虚设)"
else
    ok "fetch 对哈希不匹配的 tarball 直接失败(不会解出未校验的 nix)"
fi

if ! have tar || ! command -v xz >/dev/null 2>&1; then
    skip "没有 tar/xz,跳过 nix 解包与加性同步的功能测试"
else
    fake=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nix-2.35.2
    src="$ft/src"; mkdir -p "$src/nix-2.35.2-x86_64-linux/store/$fake/bin"
    printf 'sha256:deadbeef\n' >"$src/nix-2.35.2-x86_64-linux/.reginfo"
    printf 'sentinel\n' >"$src/nix-2.35.2-x86_64-linux/store/$fake/sentinel"
    cat >"$src/nix-2.35.2-x86_64-linux/store/$fake/bin/nix-store" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >>"$ft/load-db.calls"
cat >/dev/null
STUB
    printf '#!/bin/sh\nexit 0\n' >"$src/nix-2.35.2-x86_64-linux/store/$fake/bin/nix-daemon"
    chmod 0755 "$src/nix-2.35.2-x86_64-linux/store/$fake/bin/nix-store" "$src/nix-2.35.2-x86_64-linux/store/$fake/bin/nix-daemon"
    tar -cJf "$ft/fake.tar.xz" -C "$src" nix-2.35.2-x86_64-linux
    if KEEL_NIX_UNVERIFIED=1 KEEL_NIX_STAGE="$ft/stage" bash "$NF" unpack "$ft/fake.tar.xz" >/dev/null 2>&1 &&
       [ -x "$ft/stage/store/$fake/bin/nix-store" ] &&
       [ -s "$ft/stage/var/nix/reginfo" ] &&
       [ "$(readlink "$ft/stage/var/nix/profiles/default")" = "/nix/store/$fake" ]; then
        ok "unpack 产出 store/reginfo/profile 三件套(端到端布局,不是 grep)"
    else
        no "unpack 的产物布局不对(store / reginfo / profile 三件套)"
    fi
    # 第一次同步:拷贝 + load-db + 重指
    r1=0
    KEEL_NIX_SKEL="$ft/stage" KEEL_NIX_ROOT="$ft/root" KEEL_NIX_DATA_FS="$ft" \
        bash "$NS" >/dev/null 2>&1 || r1=$?
    if [ "$r1" = 0 ] &&
       [ -f "$ft/root/store/$fake/sentinel" ] &&
       [ "$(readlink "$ft/root/var/nix/profiles/default")" = "/nix/store/$fake" ] &&
       grep -q -- '--load-db' "$ft/load-db.calls" 2>/dev/null; then
        ok "nix-sync 把 store path 拷进目标、跑了 load-db、并把 profile 重指到骨架里的 nix"
    else
        no "nix-sync 第一次同步没有完成(rc=$r1)"
    fi
    # 加性:改过的哨兵不能被第二次同步覆盖
    chmod -R u+w "$ft/root/store/$fake" 2>/dev/null || true
    printf 'changed-by-test\n' >"$ft/root/store/$fake/sentinel"
    KEEL_NIX_SKEL="$ft/stage" KEEL_NIX_ROOT="$ft/root" KEEL_NIX_DATA_FS="$ft" bash "$NS" >/dev/null 2>&1 || true
    if [ "$(cat "$ft/root/store/$fake/sentinel")" = "changed-by-test" ]; then
        ok "第二次同步不覆盖已有的 store path(加性:哨兵改动保留)"
    else
        no "nix-sync 会覆盖已有的 store path ⇒ 不是加性同步"
    fi
    # 失败语义:空间问不出来 ⇒ 失败,而且不能重指 profile
    if KEEL_NIX_SKEL="$ft/stage" KEEL_NIX_ROOT="$ft/root2" KEEL_NIX_DATA_FS="$ft/definitely-not-a-fs" \
           bash "$NS" >/dev/null 2>&1; then
        no "空间检查失败时 nix-sync 仍然成功(不变量 10 被绕过)"
    elif [ -e "$ft/root2/var/nix/profiles/default" ]; then
        no "空间不够时 nix-sync 已经重指了 profile(半同步)"
    else
        ok "空间检查失败时拒绝拷贝且不重指 profile(旧 nix 保留可用)"
    fi
fi

}
