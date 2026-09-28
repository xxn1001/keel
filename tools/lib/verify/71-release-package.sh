# shellcheck shell=bash
# keel verify 模块:发布包收紧(v1.2 2.10)
#
# 盯四件事:
#   ① 发布目录是 output/keel-<版本>/,不再放 14 GiB 的 keel.raw(压缩成 keel.img.zst + size/sha256);
#   ② 发布目录里自带 install.sh(宿主只要有 zstd,不需要 mkosi),安全判据齐全;
#   ③ burn.sh 烧之前核对版本(镜像里的 IMAGE_VERSION vs output/ 里最新发布版本),不一致就拒;
#   ④ 功能测试(不靠 grep):真把假镜像 zstd 压/解一遍(--to),版本一致/不一致/--force 三条路径都跑。

verify_release_package() {
head1 "15. 发布包收紧(output/ + keel.img.zst + install.sh + burn.sh 版本核对)"

B=tools/build.sh
I=tools/install-release.sh
BU=tools/burn.sh

pkg_missing=""
grep -qF 'DIST=output' "$B" || pkg_missing="$pkg_missing [DIST=output]"
grep -qF 'keel.img.zst' "$B" || pkg_missing="$pkg_missing [压缩安装镜像]"
grep -qF 'keel.img.zst.size' "$B" || pkg_missing="$pkg_missing [解压尺寸 sidecar]"
grep -qF 'keel.img.zst.sha256' "$B" || pkg_missing="$pkg_missing [压缩件 sha256]"
grep -qF 'install-release.sh' "$B" || pkg_missing="$pkg_missing [install.sh 进发布目录]"
grep -qF 'keel.raw.version' "$B" || pkg_missing="$pkg_missing [burn.sh 用的版本 sidecar]"
grep -qF 'rm -f "$D/keel.raw"' "$B" || pkg_missing="$pkg_missing [发布目录不放 keel.raw]"
if [ -z "$pkg_missing" ]; then
    ok "build.sh:发布目录 output/keel-<版本>/,安装镜像压成 keel.img.zst(+size/sha256),自带 install.sh,写版本 sidecar"
else
    no "发布包组装缺环节:$pkg_missing"
fi

# 反向断言:活的代码里不许再出现旧的 dist/keel-* 路径
old_refs=""
for f in "$B" tools/libvirt-test.sh tools/stress-libvirt.sh tools/ota-drill-container.sh; do
    if grep -q 'dist/keel' "$f"; then old_refs="$old_refs $f"; fi
done
if [ -z "$old_refs" ]; then
    ok "活的代码里没有残留的 dist/keel-* 路径(发布目录统一成 output/)"
else
    no "这些文件里还有旧的 dist/keel-* 路径:$old_refs"
fi

if [ -x "$I" ] &&
   grep -qF 'command -v zstd' "$I" &&
   grep -qF 'keel.img.zst.size' "$I" &&
   grep -qF '不是整块盘' "$I" &&
   grep -qF '是当前系统所在的盘' "$I" &&
   grep -qF 'zstd -dc "$IMG"' "$I"; then
    ok "install.sh:只要宿主有 zstd;查尺寸/整块盘/当前系统盘;zstd -dc 写盘(不需要 mkosi)"
else
    no "install.sh 的安全判据/依赖检查不全"
fi
if grep -qF 'objcopy -O binary --only-section=.osrel' "$BU" &&
   grep -qF 'IMAGE_VERSION' "$BU" &&
   grep -qF '版本不一致' "$BU" &&
   grep -qF -- '--check-only' "$BU" &&
   grep -qF -- '--force' "$BU" &&
   grep -qF 'mkosi --profile install burn' "$BU"; then
    ok "burn.sh:先读镜像的 .osrel 版本,和 output/ 最新发布比对,不一致拒绝(--force 才放行);仍走 mkosi burn"
else
    no "burn.sh 的版本核对不完整"
fi

# ── 功能测试 ────────────────────────────────────────────────────────────────
# ① install.sh --to:真的压/解一遍,内容必须一致;重复写要有保护
if ! command -v zstd >/dev/null 2>&1; then
    skip "宿主没有 zstd,跳过 install.sh 的解压功能测试"
else
    rp="$(tmpd)"; mkdir -p "$rp/rel"
    cp "$I" "$rp/rel/install.sh"; chmod 0755 "$rp/rel/install.sh"
    # 造一个 1 MiB 的"镜像"(内容可校验),压成 keel.img.zst + 写 size
    head -c 1048576 /dev/urandom >"$rp/orig.raw"
    zstd -3 -q -f "$rp/orig.raw" -o "$rp/rel/keel.img.zst"
    stat -c %s "$rp/orig.raw" >"$rp/rel/keel.img.zst.size"
    if "$rp/rel/install.sh" --to "$rp/out.raw" --yes >/dev/null 2>&1 &&
       cmp -s "$rp/orig.raw" "$rp/out.raw"; then
        ok "install.sh --to:解压出来的内容和原镜像逐字节一致(功能测试)"
    else
        no "install.sh --to 解压结果和原镜像不一致"
    fi
    if "$rp/rel/install.sh" --to "$rp/out.raw" --yes >/dev/null 2>&1; then
        no "install.sh --to 会静默覆盖已存在的文件(应该要 --force)"
    else
        ok "install.sh --to 拒绝覆盖已存在的文件(要 --force)"
    fi
    printf '1' >"$rp/rel/keel.img.zst.size"   # 故意写错尺寸
    if "$rp/rel/install.sh" --to "$rp/out2.raw" --yes --force >/dev/null 2>&1; then
        no "install.sh 在解压尺寸不符时仍然成功 ⇒ size sidecar 形同虚设"
    else
        ok "install.sh 发现解压尺寸不符时失败(不留下一个尺寸不对的镜像)"
    fi
    stat -c %s "$rp/orig.raw" >"$rp/rel/keel.img.zst.size"
    # ② 非块设备目标必须拒绝(非 root 会先在 root 检查那步拒绝 —— 两种都算拒绝)
    if "$rp/rel/install.sh" "$rp/orig.raw" --yes >/dev/null 2>&1; then
        no "install.sh 居然接受了一个普通文件当目标盘"
    else
        ok "install.sh 拒绝把普通文件当目标盘(块设备/root 检查)"
    fi
    # ③ burn.sh 的版本核对:一致 / 不一致 / --force 三条路径
    bp="$(tmpd)"; mkdir -p "$bp/out/keel-1.0.0" "$bp/out/keel-2.0.0"
    : >"$bp/out/keel-1.0.0/manifest"; : >"$bp/out/keel-2.0.0/manifest"
    printf '1.0.0\n' >"$bp/img.version"; : >"$bp/img.raw"
    if KEEL_BURN_IMAGE="$bp/img.raw" KEEL_BURN_VERSION_FILE="$bp/img.version" \
       KEEL_BURN_EFI="$bp/no-such.efi" KEEL_BURN_OUTPUT_DIR="$bp/out" \
       bash "$BU" --check-only >/dev/null 2>&1; then
        no "burn.sh --check-only 对'镜像 = 最新发布'也拒绝(版本核对写反了?)"
    else
        # 上面是 1.0.0 vs 最新 2.0.0 ⇒ 应当拒绝;下面把版本改成 2.0.0 再验通过路径
        printf '2.0.0\n' >"$bp/img.version"
        if KEEL_BURN_IMAGE="$bp/img.raw" KEEL_BURN_VERSION_FILE="$bp/img.version" \
           KEEL_BURN_EFI="$bp/no-such.efi" KEEL_BURN_OUTPUT_DIR="$bp/out" \
           bash "$BU" --check-only >/dev/null 2>&1; then
            ok "burn.sh 版本核对:不一致时拒绝,一致时放行(功能测试)"
        else
            no "burn.sh --check-only 在版本一致时仍然失败"
        fi
    fi
    printf '1.0.0\n' >"$bp/img.version"
    if KEEL_BURN_IMAGE="$bp/img.raw" KEEL_BURN_VERSION_FILE="$bp/img.version" \
       KEEL_BURN_EFI="$bp/no-such.efi" KEEL_BURN_OUTPUT_DIR="$bp/out" \
       bash "$BU" --check-only --force >/dev/null 2>&1; then
        ok "burn.sh --force 在版本不一致时按明确知情放行"
    else
        no "burn.sh --force 没能放行版本不一致(那用户就无路可走了)"
    fi
fi

}
