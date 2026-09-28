#!/usr/bin/env bash
# keel 更新签名密钥:生成 / 启用 / 签名 / 验签 / 轮换(v1.2 的 1.1)
#
# 背景(为什么要有这个脚本):
#   v1.1 的 `os-update fetch` 见到 manifest.sig 才验签,没有 .sig 时**只打印警告后继续**
#   —— 那是 fail-open:能撕掉签名的中间人就能把更新降级回"只靠 sha256"的旧世界。
#   v1.2 改成 fail-closed,并且公钥必须有一个**可信来源**:烤进镜像。
#   私钥永远不进 git(`.gitignore` 覆盖 keys/、*.key、*.pem);公钥由 `sync` 拷进
#   mkosi.extra/usr/share/keel/update-keys/<key_id>.pub,构建期随镜像落地,
#   mkosi.postinst 会回读断言(缺公钥的产物直接拒绝构建)。
#
# 用法:
#   tools/sign.sh gen [<key_id>]     生成一把新密钥(默认 key_id=UTC 时间戳);没有当前钥时启用它
#   tools/sign.sh use <key_id>       把当前签名钥切换成已有的某把(轮换的第二跳)
#   tools/sign.sh rotate [<key_id>]  生成新钥(保持旧钥为当前签名钥)+ 打印两跳轮换步骤
#   tools/sign.sh id                 打印当前签名钥的 key_id(没有就失败)
#   tools/sign.sh sync               把 keys/*.pub 同步进镜像树(构建前必须做过)
#   tools/sign.sh sign <目录>        给 <目录>/manifest 签名 → <目录>/manifest.sig
#   tools/sign.sh verify <目录>      用当前公钥验签(本地自检;镜像里用的是同一条 openssl 命令)
#   tools/sign.sh list               列出本地密钥与当前签名钥
#   tools/sign.sh retire <key_id>    让一把钥退场(私钥+公钥一起移进 keys/retired/,不再进新镜像)
#
# 环境变量:
#   KEEL_KEYS_DIR            私钥目录(默认 keys/;可指向离线介质,但别指向 git 跟踪的路径)
#   KEEL_UPDATE_KEYS_STAGE   公钥在镜像树里的落地目录(默认 mkosi.extra/usr/share/keel/update-keys)
#   KEEL_KEY_BITS            RSA 位数(默认 3072)
#
# 算法选 RSA-3072 的理由:镜像里的验签命令是 `openssl dgst -sha256 -verify`,
# RSA 与 ECDSA 都支持,但 RSA 的 PEM 密钥解析最不挑环境(决策见 docs/update.md §6)。
set -euo pipefail
cd "$(dirname "$0")/.."

KEYS_DIR=${KEEL_KEYS_DIR:-keys}
STAGE_DIR=${KEEL_UPDATE_KEYS_STAGE:-mkosi.extra/usr/share/keel/update-keys}
KEY_BITS=${KEEL_KEY_BITS:-3072}

log() { printf 'keel-sign: %s\n' "$*" >&2; }
die() { printf 'keel-sign: 错误:%s\n' "$*" >&2; exit 1; }

# key_id 会被当文件名用(keys/update-key-<id>.{key,pub}、镜像里的 <id>.pub),
# 也会出现在 manifest 的 key_id= 行里 ⇒ 只允许安全的单层路径分量。
key_id_ok() {
    case "$1" in
        ""|.*|-*|*[!A-Za-z0-9._-]*) return 1 ;;
        *) return 0 ;;
    esac
}

active_id() {
    local id
    [ -f "$KEYS_DIR/active-key-id" ] || return 1
    id="$(cat "$KEYS_DIR/active-key-id" 2>/dev/null)" || return 1
    id="${id//[[:space:]]/}"
    key_id_ok "$id" || return 1
    printf '%s' "$id"
}

usage() {
    sed -n 's/^#   tools\/sign\.sh /  tools\/sign.sh /p' "$0" >&2
    die "用法:tools/sign.sh <gen|use|rotate|id|sync|sign|verify|list> [参数]"
}

cmd_gen() {
    local id="${1:-}" existing
    [ -n "$id" ] || id="$(date -u +%Y%m%d%H%M%S)"
    key_id_ok "$id" || die "key_id 不合法:'${id}'(只允许字母/数字/._-,且不以 . 或 - 开头;它会被当文件名用)"
    mkdir -p "$KEYS_DIR"
    chmod 700 "$KEYS_DIR" 2>/dev/null || true
    [ ! -e "$KEYS_DIR/update-key-$id.key" ] || die "密钥已存在:$KEYS_DIR/update-key-$id.key(换个 key_id,或先 tools/sign.sh list)"
    log "生成 RSA-$KEY_BITS 密钥:$id(可能几秒)"
    openssl genpkey -algorithm RSA -pkeyopt "rsa_keygen_bits:$KEY_BITS" \
        -out "$KEYS_DIR/update-key-$id.key" 2>/dev/null || die "openssl genpkey 失败"
    chmod 600 "$KEYS_DIR/update-key-$id.key"
    openssl pkey -in "$KEYS_DIR/update-key-$id.key" -pubout \
        -out "$KEYS_DIR/update-key-$id.pub" 2>/dev/null || die "导出公钥失败"
    if existing="$(active_id)"; then
        log "新钥已生成,**当前签名钥仍是 $existing**(没动它)—— 轮换要先发过渡版本,再 use $id"
    else
        printf '%s\n' "$id" >"$KEYS_DIR/active-key-id"
        log "已生成并启用第一把签名钥:$id"
    fi
    log "下一步:① tools/sign.sh sync;② 备份 $KEYS_DIR(私钥丢了就再也没法给已装机器发更新)"
}

cmd_use() {
    local id="${1:-}"
    [ -n "$id" ] || die "用法:tools/sign.sh use <key_id>"
    [ -f "$KEYS_DIR/update-key-$id.key" ] || die "没有这把密钥:$KEYS_DIR/update-key-$id.key"
    printf '%s\n' "$id" >"$KEYS_DIR/active-key-id"
    log "当前签名钥已切换为:$id"
}

cmd_rotate() {
    local new="${1:-}" old
    old="$(active_id)" || die "还没有当前签名钥:先 tools/sign.sh gen"
    [ -n "$new" ] || new="$(date -u +%Y%m%d%H%M%S)"
    cmd_gen "$new"
    cat >&2 <<EOF

轮换是**两跳**(细节见 docs/update.md §6),别跳步 —— 跳了会让已装机器拒绝更新:
  1) 现在构建并发布一个**过渡版本**:$KEYS_DIR/ 里已经同时有 $old 与 $new 两把公钥,
     tools/sign.sh sync 会把两把都烤进镜像;这个版本的 manifest **仍然由 $old 签名**
     (当前签名钥还是 $old)。
  2) 确认已装的机器都跑上过渡版本(它们于是同时信任两把公钥)之后,再执行:
         tools/sign.sh use $new
     从那以后的新版本用 $new 签名。老机器只要装过过渡版本就能验过。
  3) 过渡版本全部换代完成后,可以从 $KEYS_DIR/ 里清掉 $old 的私钥(留档也行,别放进 git)。
EOF
}

cmd_id() {
    local id
    id="$(active_id)" || die "还没有签名钥:先跑 tools/sign.sh gen(或在 KEEL_KEYS_DIR 指向的目录里放一把)"
    printf '%s\n' "$id"
}

cmd_list() {
    local active="" f id
    active="$(active_id 2>/dev/null || true)"
    if [ -d "$KEYS_DIR" ]; then
        for f in "$KEYS_DIR"/update-key-*.key; do
            [ -f "$f" ] || continue
            id="$(basename "$f")"; id="${id#update-key-}"; id="${id%.key}"
            if [ "$id" = "$active" ]; then
                printf '  [当前] %s\n' "$id"
            else
                printf '         %s\n' "$id"
            fi
        done
    fi
    [ -n "$active" ] || log "没有当前签名钥(先 tools/sign.sh gen)"
    return 0
}

cmd_sync() {
    local id f n=0 derived
    id="$(active_id)" || die "还没有签名钥:先跑 tools/sign.sh gen"
    # 当前签名钥的公钥必须**与私钥配对**:公钥被换过/陈旧时,构建出的机器会信任一把
    # 我们并不持有的钥匙(或验不过自己签的东西)。这里当场对比(openssl pkey -pubout)。
    derived="$(openssl pkey -in "$KEYS_DIR/update-key-$id.key" -pubout 2>/dev/null)" ||
        die "读不出当前私钥:$KEYS_DIR/update-key-$id.key"
    if [ "$derived" != "$(cat "$KEYS_DIR/update-key-$id.pub" 2>/dev/null)" ]; then
        die "当前签名钥 $id 的 .pub 与私钥不配对(公钥文件被换过?)—— 拒绝把不一致的信任库放进镜像"
    fi
    mkdir -p "$STAGE_DIR"
    # 先清掉上一轮的 .pub:被 retire 的旧钥不该继续留在镜像的信任库里。
    rm -f "$STAGE_DIR"/*.pub 2>/dev/null || true
    for f in "$KEYS_DIR"/update-key-*.pub; do
        [ -f "$f" ] || continue
        # 镜像里的文件名就是 key_id:lib-update.sh 查 $UPDATE_KEYS_DIR/<key_id>.pub
        n="$((n + 1))"
        install -m 0644 "$f" "$STAGE_DIR/$(basename "$f" | sed 's/^update-key-//')"
    done
    [ "$n" -ge 1 ] || die "在 $KEYS_DIR 里找不到任何 update-key-*.pub"
    # 可审计的"当前签名钥"标记:mkosi.postinst 用它断言 <id>.pub 真的进了镜像。
    printf '%s\n' "$id" >"$STAGE_DIR/active-key-id"
    log "已把 $n 个公钥放进镜像树:$STAGE_DIR(当前签名钥 $id)"
}

# 让一把钥退场:私钥与公钥**一起**移进 $KEYS_DIR/retired/。
# 只删私钥是不够的 —— 公钥还在 keys/ 里就会被后续每次 sync 烤进新镜像,
# 那台新机器就永远承认一把已经退休(可能泄露)的钥匙。
cmd_retire() {
    local id="${1:-}" active moved=0 ext
    [ -n "$id" ] || die "用法:tools/sign.sh retire <key_id>"
    active="$(active_id 2>/dev/null || true)"
    [ "$id" != "$active" ] || die "$id 是当前签名钥,不能退场(先 tools/sign.sh use <别的钥>)"
    for ext in key pub; do
        [ -e "$KEYS_DIR/update-key-$id.$ext" ] || continue
        mkdir -p "$KEYS_DIR/retired"
        mv -f "$KEYS_DIR/update-key-$id.$ext" "$KEYS_DIR/retired/" || die "移动 update-key-$id.$ext 失败"
        moved=1
    done
    [ "$moved" = 1 ] || die "找不到 $id 的密钥文件(keys/ 里没有 update-key-$id.{key,pub})"
    log "已让 $id 退场(移进 $KEYS_DIR/retired/):此后 sync 不再把它的公钥放进新镜像"
    log "注意:已经装过带这把公钥镜像的机器,要更新到之后的镜像才会不再信任它(本地信任库没有在线撤销)"
}

manifest_key_id() {
    local v
    v="$(grep -m1 '^key_id=' "$1" 2>/dev/null | cut -d= -f2- || true)"
    v="${v%$'\r'}"
    printf '%s' "$v"
}

cmd_sign() {
    local dir="${1:-}" id mkey
    [ -n "$dir" ] || die "用法:tools/sign.sh sign <目录>(目录里要有 manifest)"
    [ -f "$dir/manifest" ] || die "找不到 $dir/manifest"
    id="$(active_id)" || die "还没有签名钥:先跑 tools/sign.sh gen"
    [ -f "$KEYS_DIR/update-key-$id.key" ] || die "当前签名钥的私钥不在:$KEYS_DIR/update-key-$id.key"
    mkey="$(manifest_key_id "$dir/manifest")"
    [ "$mkey" = "$id" ] || die "manifest 里的 key_id='${mkey:-<缺失>}' 与当前签名钥 '$id' 不一致 —— 拒绝签一份冒用别的钥匙的清单(重新生成 manifest,或先 tools/sign.sh use <key_id>)"
    # -sha256 对 RSA 是 PKCS#1 v1.5;镜像里 lib-update.sh 用的是同参数的 -verify。
    #
    # ⚠ 先写临时文件、再 mv 替换,**不要**用 openssl 的 -out 直写 $dir/manifest.sig:
    # 目标名如果是**符号链接**(演练里 bad/mig 两个源就是),openssl 会顺着链接把签名写进
    # 链接指向的文件 —— 2026-09-28 实测过一次:它把 dist/keel-<版本>/manifest.sig
    # (good 载荷的签名)覆盖成了 mig 清单的签名,而符号链接本身还在。后果是 good 源
    # 验签失败、整条 OTA 链路跳过,而宿主只看到 VM exit 0 的"假绿"。
    # mv 替换的是**链接本身**,永远不碰目标文件。
    local tmpout
    tmpout="$(mktemp "$dir/.manifest.sig.XXXXXX")" || die "mktemp 失败(目录 $dir 可写?)"
    if ! openssl dgst -sha256 -sign "$KEYS_DIR/update-key-$id.key" \
            -out "$tmpout" "$dir/manifest"; then
        rm -f "$tmpout"
        die "openssl dgst -sign 失败"
    fi
    if [ ! -s "$tmpout" ]; then
        rm -f "$tmpout"
        die "签出来的 manifest.sig 是空的"
    fi
    mv -f "$tmpout" "$dir/manifest.sig" || { rm -f "$tmpout"; die "替换 $dir/manifest.sig 失败"; }
    cmd_verify "$dir" >/dev/null || die "自检失败(刚签出来的 manifest.sig 验不过,这不该发生)"
    log "已签名:$dir/manifest.sig(key_id=$id)"
}

cmd_verify() {
    local dir="${1:-}" id pub
    [ -n "$dir" ] || die "用法:tools/sign.sh verify <目录>"
    [ -f "$dir/manifest" ] || die "找不到 $dir/manifest"
    [ -f "$dir/manifest.sig" ] || die "找不到 $dir/manifest.sig"
    id="$(active_id)" || die "还没有签名钥"
    pub="$KEYS_DIR/update-key-$id.pub"
    [ -f "$pub" ] || die "找不到公钥:$pub"
    if openssl dgst -sha256 -verify "$pub" -signature "$dir/manifest.sig" "$dir/manifest" >/dev/null 2>&1; then
        printf 'keel-sign: 验签通过(key_id=%s)\n' "$id"
    else
        die "验签失败:$dir/manifest 与 manifest.sig 不匹配(key_id=$id)"
    fi
}

case "${1:-}" in
    gen)    shift; cmd_gen "${1:-}" ;;
    use)    shift; cmd_use "${1:-}" ;;
    rotate) shift; cmd_rotate "${1:-}" ;;
    id)     cmd_id ;;
    sync)   cmd_sync ;;
    sign)   shift; cmd_sign "${1:-}" ;;
    verify) shift; cmd_verify "${1:-}" ;;
    list)   cmd_list ;;
    retire) shift; cmd_retire "${1:-}" ;;
    -h|--help|help|"") usage ;;
    *)      usage ;;
esac
