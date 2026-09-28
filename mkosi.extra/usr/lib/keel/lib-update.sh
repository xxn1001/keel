# keel 更新链路的机制(os-update 的"可替换底层")
#
# 用法:`. /usr/lib/keel/lib-update.sh`(只由 os-update 引入)
#
# 为什么单独一个文件、而不是继续堆在 os-update 里:`os-update` 是**门面**(决策 D8)——
# 对外的子命令与状态语义稳定、底层可替换(将来可能换成 systemd-sysupdate,roadmap 2.5)。
# 2026-09-27 拆分前它是仓库里长得最快的文件之一(623 行);分成两层之后:
#   * os-update 只剩"解析命令行 + 收集上下文 + 分发",读起来就是一张命令表;
#   * 机制(manifest 解析、下载与校验、写分区/ESP、切槽、回滚、gc)集中在这里,
#     换底层只动这一份;
#   * 两层的**契约**写在下面,不会再出现"读一个没人赋值的变量"这种静默 bug。
#
# 契约(重要):本文件是**库**,不自己收集上下文 —— 下面这些变量由 os-update 在
# source 之后、调用 cmd_* 之前赋值,库里的函数只读它们:
#   CURRENT_SLOT / CURRENT_VERSION / CURRENT_SCHEMA
#   PENDING_SLOT / PENDING_VERSION
#   UPDATE_SOURCE / SRC / LOCAL_SRC / REMOTE / OTA_PAYLOAD_VERSION
# 反过来,库里只对外提供函数与几个常量(ARTIFACTS / MANIFEST / MANIFEST_SIG /
# UPDATE_KEYS_DIR / TRIES),不改调用方的状态。lib.sh 里的东西(keel_* 函数、
# KEEL_ESP / KEEL_UKI_DIR / KEEL_OTA / KEEL_STATE_DIR)由 lib.sh 提供,
# os-update 已经先 source 过它。
#
# shellcheck shell=bash
# shellcheck disable=SC2154  # 见上面的契约:上下文由调用方赋值,在这里"没被赋值"是正常的
readonly ARTIFACTS=(slot-a.root.raw slot-a.uki.efi slot-b.root.raw slot-b.uki.efi)
readonly MANIFEST="manifest"
readonly MANIFEST_SIG="manifest.sig"
# 更新签名公钥的落地目录(镜像里):/usr/share/keel/update-keys/<key_id>.pub。
# key_id 来自 manifest 的 key_id= 行 ⇒ 轮换时镜像可以同时带新旧两把公钥(见 docs/update.md §6)。
# 公钥在构建期由 tools/sign.sh sync 放进镜像树,mkosi.postinst 回读断言。
readonly UPDATE_KEYS_DIR="/usr/share/keel/update-keys"
readonly TRIES=3

die_usage() {
    keel_die "用法:$*"
}

# /data 上的可用字节数(读不到就当 0 —— 宁可不下载,也不要把 /data 写满)。
# 查询本身在 lib.sh 的 keel_data_fs_bytes(与 swapfile/firstboot/data-guard 共用一份)。
free_bytes() {
    local v
    v="$(keel_data_fs_bytes avail)" || v=""
    case "${v:-}" in ''|*[!0-9]*) v=0 ;; esac
    printf '%s' "$v"
}

# ---------------------------------------------------------------------------
# manifest 解析
#
# manifest 是 key=value 文本(**不是 JSON**:镜像里没有 jq,见任务约定)。
# 刻意不用 `. manifest` 引入:那是"执行"而不是"读取",一个被篡改的 manifest
# 就能在解析阶段拿到代码执行。这里只用 grep + cut 取值,值原样返回。
# ---------------------------------------------------------------------------
# 精确前缀匹配:旧实现用 grep -E "^${key}=",而 key 里的 . 是 ERE 通配
# (sha256_slot-a.root.raw 也能匹配 sha256_slot-aXrootYraw=)—— 虽然签名覆盖全部字节、
# 攻击者无法签名,但那是一种"解析与直觉不一致"的歧义,去掉不要。这里按行做**字面前缀**匹配。
manifest_get() {
    local file="$1" key="$2" line v
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            "$key"=*)
                v="${line#"$key"=}"
                # 去掉可能的 \r(更新源在 FAT 文件系统/U 盘上时很常见)
                v="${v%$'\r'}"
                printf '%s\n' "$v"
                return 0
                ;;
        esac
    done <"$file" 2>/dev/null || true
    printf '%s\n' ""
}

# 版本号会直接当目录名用,所以必须是单层安全路径分量:
# 空、以 . 或 - 开头、含 / 或 .. 一律拒绝 —— 否则更新源能借版本号写到 $KEEL_OTA 外面。
validate_version() {
    local v="$1"
    case "$v" in
        ""|.*|-*) keel_die "manifest 里的 version 不合法:'${v}'(必须是非空的单层路径名)" ;;
        */*|*..*) keel_die "manifest 里的 version 不合法:'${v}'(不允许含 / 或 ..)" ;;
        *) : ;;
    esac
}

# ---------------------------------------------------------------------------
# 更新签名(v1.2 的 1.1;背景与轮换步骤见 docs/update.md §6)
#
# v1.1 只在"源带了 manifest.sig"时才验签,源**不带**签名时只打印一句警告就继续 ——
# 那是 fail-open:能撕掉 .sig 的中间人等于把我们降级回"只靠 sha256"的世界(sha256 只能
# 防传输损坏,防不住替换更新源的人)。v1.2 起:
#   * 没有 manifest.sig            → 拒绝
#   * manifest 没有合法 key_id=    → 拒绝
#   * 本机没有该 key_id 的公钥     → 拒绝(并提示轮换步骤)
#   * openssl 验签不通过           → 拒绝
# 验签**排在下载载荷之前** —— 只需要 manifest 与 sig 两个小文件,没必要先下 1 GiB。
# ---------------------------------------------------------------------------

# manifest 里的 key_id(非法/缺失时输出空串)。它会被当文件名拼进路径 ⇒ 白名单字符。
manifest_key_id() {
    local v
    v="$(manifest_get "$1" key_id)"
    case "$v" in
        ""|.*|-*|*[!A-Za-z0-9._-]*) printf '%s\n' "" ; return 0 ;;
    esac
    printf '%s\n' "$v"
}

# 验签,失败一律 keel_die(fail-closed)。$1 = 存放 manifest 与 manifest.sig 的目录。
verify_manifest_signature() {
    local dir="$1" key_id pubkey
    key_id="$(manifest_key_id "$dir/$MANIFEST")"
    if [ -z "$key_id" ]; then
        keel_die "manifest 里缺少合法的 key_id=(签名密钥标识)。v1.2 起更新必须带签名,拒绝安装来源不明的载荷(docs/update.md §6)。"
    fi
    pubkey="$UPDATE_KEYS_DIR/$key_id.pub"
    if [ ! -f "$pubkey" ]; then
        keel_die "本机没有 key_id=${key_id} 的公钥(期望 $pubkey),无法验证更新来源,拒绝安装。如果这是密钥轮换,请先安装带这把新公钥的过渡版本(两跳步骤见 docs/update.md §6)。"
    fi
    if ! command -v openssl >/dev/null 2>&1; then
        keel_die "镜像里没有 openssl,无法验签(构建缺陷:见 mkosi.conf.d/20-packages.conf;v1.2 起没有它就不能更新)。"
    fi
    if ! openssl dgst -sha256 -verify "$pubkey" -signature "$dir/$MANIFEST_SIG" "$dir/$MANIFEST" >/dev/null 2>&1; then
        keel_die "${MANIFEST} 验签失败(key_id=${key_id}):更新源可能被篡改,已中止(什么都没写进槽)。"
    fi
    keel_log "manifest 验签通过(key_id=${key_id})"
}

# 本地源 → 拷贝;https:// → curl。更新源允许 file:// 与裸路径(docs/update.md §6)。
# 目标目录由调用方通过全局 DEST 指定(cmd_fetch 的临时目录)。
fetch_one() {
    local rel="$1"
    case "$SRC" in
        https://*|http://*)
            # -f:HTTP 错误码直接失败(否则 404 页面会被当成载荷存下来)
            curl -fL --retry 2 --connect-timeout 15 -o "$DEST/$rel" "$SRC/$rel"
            ;;
        *)
            cp -- "$LOCAL_SRC/$rel" "$DEST/$rel"
            ;;
    esac
}

# 载荷路径 = $KEEL_OTA/<version>/slot-<槽>.{root.raw,uki.efi}(不检查存在性)
payload_path() {
    printf '%s\n' "$KEEL_OTA/$OTA_PAYLOAD_VERSION/slot-$1.root.raw"
}

uki_payload_path() {
    printf '%s\n' "$KEEL_OTA/$OTA_PAYLOAD_VERSION/slot-$1.uki.efi"
}

# /data 布局版本;文件缺失当作 0(比任何 manifest 的 schema 都旧 ⇒ 会拒绝)
volume_schema() {
    local v
    v="$(cat /data/keel/schema-version 2>/dev/null)" || v=""
    v="${v//[[:space:]]/}"
    # 只认十进制整数;空/被写坏一律当 0(= 比任何 manifest 都旧 ⇒ 会拒绝)。
    # 旧实现把非数字原样返回,而 cmd_fetch 里的 [ "$rs" -gt "$schema" ] 遇到非数字会报错
    # 走 else 分支 ⇒ schema 检查**静默放行**(对抗复核 2026-09-28 发现;需要本机 /data 被写坏,
    # 源侧触发不了,但那正是"本机能坏"的场景)。
    case "$v" in
        ""|*[!0-9]*) printf '0\n' ;;
        *) printf '%s\n' "$v" ;;
    esac
}

# 远端版本严格比当前版本新 → 0;否则非 0。
# 用 sort -V(GNU 版本排序),这样 2025.9.9 < 2025.9.10 也是对的。
version_is_newer() {
    local remote="$1" current="$2" top
    if [ -z "$remote" ] || [ "$remote" = "$current" ]; then
        return 1
    fi
    top="$(printf '%s\n%s\n' "$current" "$remote" | LANG=C sort -V | tail -n1)" || return 1
    [ "$top" = "$remote" ]
}

# ---------------------------------------------------------------------------
# check —— 只读,打印远端版本与当前版本,说明有没有更新
# ---------------------------------------------------------------------------
cmd_check() {
    local mf="$SRC/$MANIFEST" rv rs tmp="" sigtmp="" sigf="" kid="" sig_note=""
    case "$SRC" in
        https://*|http://*) ;;
        *) [ -e "$LOCAL_SRC/$MANIFEST" ] || keel_die "更新源里找不到 $MANIFEST:${LOCAL_SRC}" ;;
    esac
    # https 源先下到临时文件,免得为了看一眼版本就去写 /data/ota
    if [ "$REMOTE" -eq 1 ]; then
        tmp="$(mktemp -t keel-manifest.XXXXXX)"
        if ! curl -fL --retry 2 --connect-timeout 15 -o "$tmp" "$SRC/$MANIFEST"; then
            rm -f "$tmp"
            keel_die "下载 manifest 失败:${SRC}/${MANIFEST}"
        fi
        mf="$tmp"
    fi
    rv="$(manifest_get "$mf" version)"
    rs="$(manifest_get "$mf" schema)"
    if [ -z "$rv" ]; then
        [ -n "$tmp" ] && rm -f "$tmp"
        keel_die "manifest 里没有 version=(格式不对?)"
    fi

    # 签名状态(v1.2 1.1):check 是**只读**的,不阻止 check 本身,但必须说清这个源
    # 能不能被 fetch 接受 —— fail-closed 之后"未签名"意味着 fetch 一定会拒绝。
    if [ "$REMOTE" -eq 1 ]; then
        sigtmp="$(mktemp -t keel-manifest-sig.XXXXXX)"
        if curl -fL --retry 2 --connect-timeout 15 -o "$sigtmp" "$SRC/$MANIFEST_SIG" 2>/dev/null; then
            sigf="$sigtmp"
        else
            rm -f "$sigtmp"; sigtmp=""
        fi
    else
        [ -f "$LOCAL_SRC/$MANIFEST_SIG" ] && sigf="$LOCAL_SRC/$MANIFEST_SIG"
    fi
    if [ -z "$sigf" ]; then
        sig_note="缺失(fetch 会拒绝:未签名的源)"
    else
        kid="$(manifest_key_id "$mf")"
        if [ -z "$kid" ]; then
            sig_note="无法验证(manifest 缺少 key_id=)"
        elif [ ! -f "$UPDATE_KEYS_DIR/$kid.pub" ]; then
            sig_note="无法验证(本机没有 key_id=$kid 的公钥)"
        elif ! command -v openssl >/dev/null 2>&1; then
            sig_note="无法验证(镜像里没有 openssl)"
        elif openssl dgst -sha256 -verify "$UPDATE_KEYS_DIR/$kid.pub" -signature "$sigf" "$mf" >/dev/null 2>&1; then
            sig_note="通过(key_id=$kid)"
        else
            sig_note="**验证失败**(key_id=$kid)—— 这个源不可信,fetch 会拒绝"
        fi
    fi

    echo "更新源       : ${SRC}"
    echo "远端版本     : ${rv}(schema ${rs:-未声明})"
    echo "签名         : ${sig_note}"
    echo "当前版本     : ${CURRENT_VERSION}(槽 ${CURRENT_SLOT:-未知})"

    # 顺手把结论写进 /data/keel/update-check.state(v1.1 ③):手动 check 也刷新状态,
    # 定时器(keel-update-check.timer)走的是同一条路径 —— 只有一个写入点,不会两处漂移。
    # 签名结论也写进状态文件(对抗复核 2026-09-28:原来只打印,os-status 看不到)——
    # 只有"通过"才留空;其余情况让 os-status 与巡检日志都能看到"这个源 fetch 用不了"。
    case "$sig_note" in
        通过*) sig_state="" ;;
        *)     sig_state="源签名:${sig_note}" ;;
    esac
    if version_is_newer "$rv" "$CURRENT_VERSION"; then
        echo "结论         : 有新版本可用 → sudo os-update fetch"
        keel_update_check_state update-available "$rv" "$sig_state"
    elif [ "$rv" = "$CURRENT_VERSION" ]; then
        echo "结论         : 已经是最新版本(远端与当前相同)"
        keel_update_check_state up-to-date "$rv" "$sig_state"
    else
        echo "结论         : 远端版本比当前旧(检查更新源是否指错了目录)"
        keel_update_check_state source-older "$rv" "$sig_state"
    fi

    [ -n "$tmp" ] && rm -f "$tmp"
    [ -n "$sigtmp" ] && rm -f "$sigtmp"
    return 0
}

# ---------------------------------------------------------------------------
# fetch —— 下载 + 校验到 $KEEL_OTA/<version>/
#
# 这一步不写任何槽,所以失败可以直接重来。三道闸:**签名(强制,fail-closed)**、
# schema/迁移(只读 manifest,排在下载前)、sha256(下载后防传输损坏)。
# ---------------------------------------------------------------------------
cmd_fetch() {
    local rv rs schema h actual a fb mig need_hard need_warn
    [ -e "$LOCAL_SRC/$MANIFEST" ] || [ "$REMOTE" -eq 1 ] || keel_die "更新源里找不到 $MANIFEST:${LOCAL_SRC}"

    install -d -m 0755 "$KEEL_OTA"
    # 下载之前先问空间(决策 D23)。v1.1 起根载荷是 **erofs**(不再是钉死的 6 GiB):
    # 一份载荷 = slot-a/b 两个根镜像 + 两个 ~156 MiB 的 UKI。**实测 ~1.1 GiB/份**
    # (erofs 根 401 MiB ×2 + UKI 156 MiB ×2,见 docs/roadmap.md §2.9)。
    # manifest 里只有 sha256、**没有尺寸**,下载前拿不到真实字节数,所以这里用一个
    # **保守但贴着实测**的预算,宁可早拒,不要下到一半 ENOSPC 留下半个载荷;
    # 更糟的是把 /data 填满会连带 /etc 也写不进去(坑 #37),那会连累 machine-id 固化
    # 与 SSH 主机密钥。
    #
    # ⚠ 别把这两个数随手放大:它们直接决定"多小的 /data 还能升级"。2026-09-26 踩过一次 ——
    #   ③ 里一度写成 6 GiB/10 GiB(按"两个 erofs 根各 1.5–2 GiB"估的),结果 20 GiB 的
    #   演练盘(/data 只剩 4.8 GiB)连**演练自己**都跑不起来。实测量到的载荷是 1.1 GiB,
    #   所以 2 GiB 硬下限(载荷 + ~0.9 GiB 余量)才是对的;v1 的 2 GiB 之所以危险,
    #   是因为那时一份载荷 13 GiB —— 数字相同、含义完全不同。
    fb="$(free_bytes)"
    need_hard=$((2 * 1024 * 1024 * 1024))
    need_warn=$((4 * 1024 * 1024 * 1024))
    if [ "$fb" -lt "$need_hard" ]; then
        keel_die "/data 可用空间只有 $((fb / 1048576)) MiB,放不下更新载荷(两个 erofs 根镜像 + 两个 UKI,预算 $((need_hard / 1073741824)) GiB)。先跑 os-update gc,或删掉 /data/ota 下的旧版本。"
    fi
    if [ "$fb" -lt "$need_warn" ]; then
        keel_log "警告:/data 可用空间只有 $((fb / 1048576)) MiB,而这次要下的载荷预算约 $((need_hard / 1073741824)) GiB —— 下完可能就满了;建议先 os-update gc"
    fi
    DEST="$(mktemp -d "$KEEL_OTA/.fetch.XXXXXX")"
    # 任何提前退出都清掉半成品目录;成功路径最后把 DEST 改名成正式目录并摘掉 trap。
    # 单引号是故意的:延迟到 trap 触发时再展开 $DEST,否则拿到的是空值(SC2064)。
    trap 'rm -rf "$DEST"' EXIT

    keel_log "从 ${SRC} 取 manifest"
    fetch_one "$MANIFEST" || keel_die "下载 manifest 失败:${SRC}/${MANIFEST}"
    # 签名**不是可选的**(v1.2 1.1,fail-closed)。取不到就直接拒,而且发生在下载任何
    # 载荷之前 —— 只下两个小文件就能判"这个源配不配被信任"。
    if ! fetch_one "$MANIFEST_SIG" 2>/dev/null; then
        rm -f "$DEST/$MANIFEST_SIG"
        keel_die "更新源没有提供 ${MANIFEST_SIG}(未签名的更新源)。v1.2 起拒绝安装没有签名的更新:只靠 sha256 防得住传输损坏,防不住能替换更新源的人。请让更新源提供 ${MANIFEST_SIG}(tools/sign.sh sign,见 docs/update.md §6)。"
    fi
    verify_manifest_signature "$DEST"

    rv="$(manifest_get "$DEST/$MANIFEST" version)"
    rs="$(manifest_get "$DEST/$MANIFEST" schema)"
    validate_version "$rv"
    # 防重放降级(对抗复核 2026-09-28 提出):验签只证明"这份 manifest 是我们签的",
    # 不证明"它比本机新" —— 攻击者拿任意一份**历史公开发布**的 dist/ 当源就能重放,
    # 全程不需要私钥。所以这里把 check 的版本判据搬进 fetch:比当前旧的一律拒绝。
    # 同版本允许(修一次坏掉的下载,不是降级);要回退旧版本走 sudo os-update rollback(槽切换)。
    if [ "$rv" != "$CURRENT_VERSION" ] && ! version_is_newer "$rv" "$CURRENT_VERSION"; then
        keel_die "更新源给的版本($rv)比本机($CURRENT_VERSION)旧:拒绝安装。验签防得住伪造,防不住重放历史版本(降级);要回退请用 sudo os-update rollback。"
    fi
    keel_log "远端版本:${rv}"

    # ⚠ 这两项检查(迁移、schema)刻意放在**下载之前**:它们只需要 manifest,
    # 而一次下载是 GiB 级(erofs 之后约 4 GiB,见 docs/roadmap.md §2.9)——
    # 先下载再拒绝,既浪费带宽也可能先撞上 /data 满
    # (2026-09 演练实测:检查写在下载后面,结果 curl 先 ENOSPC,"拒绝"压根没发生)。
    # 规矩:**便宜的检查放在动大钱之前**。
    # --- /data 迁移(v1 明确不支持)----------------------------------------
    # manifest 里的 `migrate=` 是**声明式迁移**的位置(docs/update.md §4):由**旧系统**在
    # stage 阶段执行,只增不破。但 v1 **还没有迁移执行器**,所以这里必须**明确拒绝**带迁移的
    # 载荷 —— 比"假装迁移过、装上去,然后回滚时旧系统读不懂 /data"好得多(那条路会静默毁数据)。
    # 真正的实现(含 schema_min 语义、与下面 schema 检查的关系)见 docs/roadmap.md。
    mig="$(manifest_get "$DEST/$MANIFEST" migrate)" || mig=""
    if [ -n "$mig" ]; then
        keel_die "这个载荷声明了 /data 迁移(migrate=${mig}),但 v1 还没有迁移执行器(docs/update.md §4、docs/roadmap.md)。拒绝安装:与其'假装迁移过',不如在这里明确失败。"
    fi

    # --- schema 兼容性 ----------------------------------------------------
    # 只认十进制整数;manifest 里的 schema 是别的东西就当作"读不懂"直接拒绝,
    # 免得 [ "$rs" -gt "$schema" ] 在 set -e 下抛出难懂的错误。
    schema="$CURRENT_SCHEMA"
    case "$rs" in
        "") : ;;
        *[!0-9]*)
            keel_die "manifest 里的 schema 不是整数:'${rs}'(更新源坏了?)"
            ;;
        *)
            if [ "$rs" -gt "$schema" ]; then
                keel_die "这个更新需要更新的 /data 布局(manifest schema=${rs},本机=${schema})。当前系统不认识这个布局,拒绝安装;请先升级到中间版本,或重装。"
            fi
            ;;
    esac


    for a in "${ARTIFACTS[@]}"; do
        keel_log "取 $a"
        if ! fetch_one "$a"; then
            # 失败原因可能是网络,也可能是 /data 满了(ENOSPC 在 curl 那里只表现为"下载失败",
            # 2026-09 演练里就把它误判成过网络问题)。剩余空间不够就直说 + 给下一步。
            fb2="$(free_bytes)"
            if [ "$fb2" -lt $((3 * 1024 * 1024 * 1024)) ]; then
                keel_die "下载失败:${SRC}/${a}
       /data 只剩 $((fb2 / 1048576)) MiB,大概是空间不够(一份载荷是 GiB 级;erofs 之后约 2 GiB/槽)。先跑 os-update gc
       或删掉 /data/ota 下的旧版本(已经装进槽里的内容不受影响),再重试。"
            fi
            keel_die "下载失败:${SRC}/${a}"
        fi
    done

    # --- sha256 -----------------------------------------------------------
    for a in "${ARTIFACTS[@]}"; do
        h="$(manifest_get "$DEST/$MANIFEST" "sha256_$a")"
        if [ -z "$h" ]; then
            keel_die "manifest 里缺少 sha256_$a=,拒绝安装未声明校验和的载荷"
        fi
        actual="$(sha256sum "$DEST/$a" | cut -d' ' -f1)" || keel_die "计算 $a 的 sha256 失败"
        if [ "$actual" != "$h" ]; then
            keel_die "$a 校验和不匹配:期望 $h,实际 $actual(载荷被截断或改过,重下)"
        fi
    done
    keel_log "sha256 全部匹配(4 个产物)"

    # --- 签名 -------------------------------------------------------------
    # 已经在**下载载荷之前**验过(verify_manifest_signature,见上)。这里原来是 v1 的
    # fail-open 段落:"源没有 .sig 就打印一句警告后继续"。v1.2 删掉了它 ——
    # tools/verify.sh 有反向断言守着("没签名也继续"的分支不许存在),别再写回来。

    # --- 落盘到正式目录 ---------------------------------------------------
    # 先删旧的同版本目录:上一次 fetch 可能留下半份坏载荷,cp 不清理多余文件。
    rm -rf "${KEEL_OTA:?}/${rv:?}"
    mv -- "$DEST" "$KEEL_OTA/$rv"
    trap - EXIT
    sync
    keel_log "载荷已就位:$KEEL_OTA/$rv"
    echo "下一步:sudo os-update stage"
}

# ---------------------------------------------------------------------------
# stage —— 写非活动槽(§5.3 ①–⑦)
# ---------------------------------------------------------------------------
cmd_stage() {
    local target payload uki dev part_bytes payload_bytes pref ukisrc base
    local reboot=0 force=0

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --reboot) reboot=1 ;;
            --force) force=1 ;;
            *) die_usage "os-update stage [--reboot] [--force]" ;;
        esac
        shift
    done

    [ -n "$CURRENT_SLOT" ] || keel_die "解析不出当前槽(/proc/cmdline 里没有 root=PARTLABEL=root-<a|b>);拒绝在不确定当前槽的情况下写分区"
    target="$(keel_other_slot "$CURRENT_SLOT")"

    # 用哪个版本的载荷:/data/ota 下版本号最大的那个目录(和 gc 的保留策略一致)
    if [ -z "$OTA_PAYLOAD_VERSION" ]; then
        keel_die "找不到已下载的载荷。先跑:sudo os-update fetch"
    fi
    payload="$(payload_path "$target")"
    uki="$(uki_payload_path "$target")"
    if [ ! -f "$payload" ] || [ ! -f "$uki" ]; then
        keel_die "缺少槽 $target 的载荷($KEEL_OTA/$OTA_PAYLOAD_VERSION);先跑:sudo os-update fetch"
    fi

    # 已经安排过同一个目标槽时,再写一遍没有意义,而且会让 boot counting 的语义变模糊
    if [ "$force" -eq 0 ] && [ "${PENDING_SLOT:-}" = "$target" ]; then
        echo "已经安排过:槽 ${target}(版本 ${PENDING_VERSION:-未知})正在等待下次启动确认。" >&2
        echo "如果确实要重写,用:sudo os-update stage --force" >&2
        exit 1
    fi

    # -----------------------------------------------------------------------
    # ESP 必须**在写根分区之前**确认可用(坑 #36)
    #
    # 顺序很要命:原来的顺序是先 dd 根分区、再 remount ESP 写 UKI。ESP 没挂上时
    # dd 已经成功 ⇒ 目标槽的根换成了新版本,而 UKI 还是**旧的**
    # ⇒ 一旦切过去就是"新内核配旧根"的反面(旧内核配新根),直接违反不变量 3,
    # 而且失败点离原因很远。所以先挂/先检查,再动分区。
    # -----------------------------------------------------------------------
    # ⚠ keel_esp_ensure 必须当普通命令调用(它会就地更新 KEEL_ESP / KEEL_UKI_DIR /
    #   KEEL_ESP_MOUNTED),不能写进 $( ) 或管道(理由见 lib.sh 里的注释)。
    keel_esp_ensure die 'ESP 原来没挂上,已自动挂到' "ESP(PARTNAME=esp)没挂上,也挂不起来 —— 拒绝写分区:没有可写的 ESP 就写不进新 UKI,而只换根分区会让槽里的内核与根不配对(不变量 3)。先检查 lsblk -o NAME,SIZE,PARTLABEL 有没有 esp 分区,再跑 os-rescue --repair-boot"

    # -----------------------------------------------------------------------
    # ESP **空间**也要在写根分区之前确认(不变量 10 的精神,理由同上一段)
    #
    # ESP 只有 1 GiB,一个 UKI 约 157 MiB。如果它被 .failed / 旧条目塞满,
    # `cp` 写到一半失败会留下**半个 UKI**,而那一刻根分区已经是新版本
    # ⇒ 又是"内核与根不配对"(不变量 3),而且失败点离原因很远。
    # 判据取保守值:放得下"新 UKI ×2(自己 + 另一个槽)"再留 50 MiB 给
    # bootctl 的 fallback/NVRAM 小文件。不够就**早拒**,并给出清理入口。
    # -----------------------------------------------------------------------
    uki_bytes="$(stat -c %s "$uki" 2>/dev/null)" || uki_bytes=""
    esp_free="$(df -P -B1 "$KEEL_ESP" 2>/dev/null | awk 'NR==2{print $4}')" || esp_free=""
    if [ -n "$uki_bytes" ] && [ -n "$esp_free" ]; then
        esp_need=$(( uki_bytes * 2 + 50 * 1024 * 1024 ))
        if [ "$esp_free" -lt "$esp_need" ]; then
            keel_die "ESP(${KEEL_ESP})可用空间只有 $((esp_free / 1048576)) MiB,放不下这次要写的 UKI(需约 $((esp_need / 1048576)) MiB = 新 UKI $((uki_bytes / 1048576)) MiB ×2 + 50 MiB 余量)。先清理 ESP 上的残留条目:sudo os-rescue --clean-esp(也可以手工看 ls -l ${KEEL_UKI_DIR})。**拒绝在写不下 UKI 的情况下先动根分区**(不变量 3)。"
        fi
        keel_log "ESP 空间检查通过:可用 $((esp_free / 1048576)) MiB,本次预算 $((esp_need / 1048576)) MiB"
    else
        keel_log "警告:读不到 ESP(${KEEL_ESP})的可用空间,跳过写入前的空间检查"
    fi

    dev="$(keel_slot_device "$target")"
    [ -b "$dev" ] || keel_die "目标分区不存在:${dev}(分区布局不对?)"
    part_bytes="$(blockdev --getsize64 "$dev")" || keel_die "读不到 $dev 的大小"
    payload_bytes="$(stat -c %s "$payload")" || keel_die "读不到 $payload 的大小"
    if [ "$payload_bytes" -gt "$part_bytes" ]; then
        keel_die "载荷太大:$(basename "$payload") = ${payload_bytes} 字节,目标分区 ${dev} 只有 ${part_bytes} 字节。槽位尺寸是布局常量(不变量 9),装不下只能重装。"
    fi

    keel_log "当前槽 ${CURRENT_SLOT} → 目标槽 ${target}(版本 ${OTA_PAYLOAD_VERSION})"
    echo "  ************************************************************"
    echo "  即将写入非活动槽,正在运行的系统不受影响:"
    echo "    根分区镜像 → ${dev}(槽 ${target},整个分区会被覆盖)"
    echo "    内核镜像   → ${KEEL_UKI_DIR}/keel-${target}+${TRIES}.efi"
    echo "  写完后下次启动会用槽 ${target};那次启动没到 boot-complete 就自动回退到当前槽"
    echo "  (候选条目只有一次机会:systemd 257 没有 set-preferred,用 set-oneshot —— 坑 #43)。"
    echo "  ************************************************************"

    keel_log "写根分区(可能耗时几分钟;这里没有输出不是卡死)"
    dd if="$payload" of="$dev" bs=4M conv=fsync status=progress ||
        keel_die "写 ${dev} 失败(分区被占用或磁盘出错?)"
    sync
    keel_log "根分区写入完成"

    # ESP 由 keel-mounts 以 rw 挂上(不变量 2、坑 #36);这里再 remount 一次是兜底
    # (比如被谁手工挂成了 ro),失败就说明它根本不是个真挂载点。
    if ! mount -o remount,rw "$KEEL_ESP" 2>/dev/null; then
        keel_die "挂载点 ${KEEL_ESP} 无法重新挂载为可写:检查它是否真的挂载了(findmnt ${KEEL_ESP});先执行 sudo os-rescue --repair-boot 或手动 mount ${KEEL_ESP}"
    fi
    ukisrc="$KEEL_UKI_DIR/keel-${target}+${TRIES}.efi"
    # ⚠⚠ **必须先把目标槽的正式条目挪开**:它和即将写入的候选条目是**同一个条目 ID**
    #    (bootctl 的 ID = 文件名去掉 `+N` 计数后缀 —— 见下面 set-oneshot 那段的说明)。
    #    不挪开的话,下一次启动时那个 ID 会解析到**旧的正式条目**上,于是:
    #      ① 机器启动的还是**旧 UKI**,而根分区已经换成新载荷 ⇒「旧内核 + 新根」,
    #         直接违反不变量 3(内核与根必须配对),而 keel-confirm 只看槽与版本、
    #         发现不了(它是从**新根**的 os-release 读版本号的);
    #      ② 候选条目永远没人消费,留在 ESP 上吃 156 MiB —— **每次更新漏一个**,
    #         稳态是每个槽各一个孤儿(共 312 MiB),ESP 可用从 710 MiB 掉到 398 MiB,
    #         低于 keel-check 自己的 400 MiB 警告线,离 stage 的空间下限只剩 36 MiB。
    #    2026-09-27 的循环 soak 第 2 轮就复现了(第 1 轮没事,因为那时目标槽还没有
    #    正式条目、ID 是唯一的)。挪开之后 ID 唯一 ⇒ 引导器只会选中候选 ⇒ boot counting
    #    正常 → bless 把它改名成正式名 ⇒ 既不漏空间、也不会"新根配旧内核"。
    #
    #    为什么是**删**而不是改名备份:目标槽的根分区此刻**已经被新载荷覆盖**了,
    #    旧正式条目指向的内容已经不存在,留着只会再漏 156 MiB。删掉之后任何一个断电
    #    窗口都是安全的:此刻持久默认仍指向**正在运行**的那个槽,固件不会没得选。
    rm -f "$KEEL_UKI_DIR/keel-${target}.efi" \
        || keel_die "删不掉目标槽的正式条目 $KEEL_UKI_DIR/keel-${target}.efi:ESP 可写吗?"
    cp -- "$uki" "$ukisrc" || keel_die "写入 $ukisrc 失败(ESP 空间不足?)"
    sync
    keel_log "UKI 已写入 ${ukisrc}(名字里的 +${TRIES} 是 boot counting 的 tries-left)"

    # 清掉同槽的同族残留(+2-1.efi / .failed 等)。不清的话它们会被算作"更旧的条目"
    # 参与 boot counting 的排序,失败判定会变得难以解释(§5.3 ⑧)。
    for stale in "$KEEL_UKI_DIR/keel-${target}.efi.failed" "$KEEL_UKI_DIR/keel-${target}.efi.bad"; do
        if [ -e "$stale" ]; then
            rm -f "$stale" || keel_log "警告:删不掉 $stale(留着不影响启动)"
            keel_log "已清理上次残留:$(basename "$stale")"
        fi
    done
    for stale in "$KEEL_UKI_DIR/keel-${target}"+*.efi; do
        [ -e "$stale" ] || continue
        base="${stale##*/}"
        if [ "$base" = "keel-${target}+${TRIES}.efi" ]; then
            continue
        fi
        rm -f "$stale" || keel_log "警告:删不掉 $stale(留着不影响启动)"
        keel_log "已清理上次残留:${base}"
    done

    # 顺手把**所有**槽的 `.failed` / `.bad` 墓碑也清掉(不只目标槽)。它们是"曾经起不来"
    # 的记录,不参与启动,只占 ESP 空间 —— 而 ESP 空间在动分区之前刚查过,留着只会让
    # 下一次更新更容易被拒。**正式条目(keel-x.efi)与候选条目(+N.efi)一律不碰**,
    # 那才是启动要用的东西。想手工做同一件事:`sudo os-rescue --clean-esp`。
    for stale in "$KEEL_UKI_DIR"/keel-*.efi.failed "$KEEL_UKI_DIR"/keel-*.efi.bad; do
        [ -e "$stale" ] || continue
        rm -f "$stale" || keel_log "警告:删不掉 $stale(留着不影响启动)"
        keel_log "已清理残留:${stale##*/}"
    done

    # 两个名字要分清(坑 #45,演练实测):
    #   * 写进 ESP 的**文件名** = keel-<目标>+3.efi(带计数后缀,引导器靠它做 boot counting);
    #   * bootctl 认的**条目 ID**  = keel-<目标>.efi —— 也就是文件名**去掉计数后缀**
    #     (`bootctl list` 里看得最清楚:文件是 keel-b+3.efi,而 id 是 keel-b.efi)。
    # 给 set-oneshot 传错(带 +3)时,引导器找不到匹配的条目,那次 one-shot 被**静默忽略**
    # ⇒ 又回到持久默认(= 旧槽),keel-confirm 还会把它误判成"更新失败已回滚"。
    pref="keel-${target}+${TRIES}.efi"          # 文件名(带计数)
    candidate_id="keel-${target}.efi"           # 条目 ID(不带计数)
    if ! keel_boot_candidate "$candidate_id"; then
        keel_die "bootctl set-oneshot ${candidate_id} 失败:引导器不接受这个条目(文件确实在 ESP 上?ESP 是可写的?),或固件拒绝写 EFI 变量(部分主板只读这些变量)。可改用开机菜单手动选择槽 ${target}。"
    fi
    keel_log "候选条目(ID ${candidate_id},文件 ${pref})已设为下次启动"

    keel_state_set pending_slot "$target"
    keel_state_set pending_version "$OTA_PAYLOAD_VERSION"
    keel_state_set running_slot "$CURRENT_SLOT"

    # 载荷已经写进槽里了,下载目录留着没意义 ⇒ 顺手清掉旧版本(决策 D23)。
    # 每次成功的 stage 都会留下一个"可以重新下载"的旧载荷,不清就会一直堆积;
    # cmd_gc 保留最近的 2 个版本 + pending 的那个,所以刚 stage 的这个不会被删。
    cmd_gc >/dev/null 2>&1 || keel_log "注意:自动清理旧载荷失败(不影响本次更新;可手动跑 os-update gc)"

    echo "已安排:下次启动使用槽 ${target}(版本 ${OTA_PAYLOAD_VERSION})。"
    echo "重启后 os-status 会显示 pending 状态;启动成功自动确认,失败自动回退。"
    if [ "$reboot" -eq 1 ]; then
        keel_log "3 秒后重启(要取消就按 Ctrl-C)"
        sleep 3
        systemctl reboot
    else
        echo "重启生效:sudo systemctl reboot(或下次用 os-update stage --reboot)"
    fi
}

# ---------------------------------------------------------------------------
# switch / rollback —— 只改 preferred,不写任何分区
# ---------------------------------------------------------------------------
cmd_switch() {
    local slot="${1:-}" pref
    case "$slot" in
        a|b) ;;
        *) die_usage "os-update switch <a|b>" ;;
    esac
    local existing="" f
    pref="keel-${slot}.efi"
    for f in "$KEEL_UKI_DIR"/*.efi; do
        [ -e "$f" ] || continue
        existing="$existing ${f##*/}"
    done
    if [ ! -e "$KEEL_UKI_DIR/$pref" ]; then
        keel_die "ESP 上没有 ${KEEL_UKI_DIR}/${pref}:槽 ${slot} 还没有正式条目(先用 os-update stage 填这个槽,或用 bootctl list 看有没有带计数的 ${slot} 条目)。现有条目:${existing:- 无}
       提示:条目名不一定等于槽名 —— 镜像里那份 UKI 的名字由构建时的 UnifiedKernelImageFormat 决定(坑 #44);
       先 bootctl list 看实际条目名,再 bootctl set-default <那个名字> 手动切槽。"
    fi
    # 只写 EFI 变量 LoaderEntryPreferred,不动 ESP 上的 loader.conf(不变量 4)
    if ! keel_boot_default "$pref"; then
        keel_die "bootctl set-default ${pref} 失败(固件拒绝写 EFI 变量?)。可改用开机菜单(space)手动选择槽 ${slot}。"
    fi
    if [ "$slot" = "$CURRENT_SLOT" ]; then
        keel_log "preferred 已指向当前正在运行的槽 ${slot}(无实际变化)"
    else
        keel_log "preferred 已指向槽 ${slot};重启后生效"
    fi
    echo "重启:sudo systemctl reboot。当前运行的系统没有被修改。"
}

cmd_rollback() {
    local cur other
    cur="$CURRENT_SLOT"
    [ -n "$cur" ] || keel_die "解析不出当前槽,无法判断要切回哪个槽"
    other="$(keel_other_slot "$cur")"
    case "$other" in
        a|b) ;;
        *) keel_die "算不出另一个槽(keel_other_slot 返回 '${other}')" ;;
    esac
    # 先改状态再报"完成":相反的顺序会在 cmd_switch 的输出之后才改 pending,
    # 用户看到"回滚完成"时状态可能还没写。
    keel_state_set pending_slot ""
    keel_state_set pending_version ""
    keel_state_set last_result "failed"
    keel_state_set last_result_version "$CURRENT_VERSION"
    keel_state_set last_result_time "$(date +%s)"
    echo "回滚:把下次启动指向槽 ${other}(当前槽 ${cur},${CURRENT_VERSION})"
    cmd_switch "$other"
    keel_log "已清空 pending,并把上次结果记为 failed(${CURRENT_VERSION})"
    echo "注意:回滚改的是下次启动用哪个槽,/data 上的数据(含 /etc 的改动)不会被回退。"
}

# ---------------------------------------------------------------------------
# gc —— 保留 pending 版本 + 最新 2 个版本
# ---------------------------------------------------------------------------
cmd_gc() {
    local keep="" v dir newest removed=0
    keep="$(keel_state_get pending_version 2>/dev/null)" || keep=""
    # sort -V:版本号按版本语义排序(2025.9.10 > 2025.9.9),取最新两个
    newest="$(find "$KEEL_OTA" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | LANG=C sort -Vr | head -n 2)" || newest=""

    echo "gc:保留版本 ${newest//$'\n'/ }${keep:+ 与 pending 的 $keep};其余删除。"
    for dir in "$KEEL_OTA"/*/; do
        [ -d "$dir" ] || continue
        v="${dir%/}"
        v="${v##*/}"
        case "$v" in .*) continue ;; esac  # 跳过 fetch 的中间目录
        if printf '%s\n' "$newest" | grep -qxF -- "$v"; then
            continue
        fi
        if [ -n "$keep" ] && [ "$v" = "$keep" ]; then
            continue
        fi
        echo "  删除 $dir"
        rm -rf "$dir" || keel_die "删除 $dir 失败"
        removed=$((removed + 1))
    done
    if [ "$removed" -eq 0 ]; then
        echo "没有需要清理的版本目录。"
    else
        echo "已清理 ${removed} 个版本目录。"
    fi
}
