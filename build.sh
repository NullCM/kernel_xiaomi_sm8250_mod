#!/bin/bash
set -euo pipefail

TOOLCHAIN_PATH="$HOME/zyc-clang/bin"
GIT_SHORT=$(git rev-parse --short=8 HEAD 2>/dev/null || echo unknown)
OUT=out
DTS=arch/arm64/boot/dts/vendor/qcom
JOBS=$(nproc)

die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '>>> %s\n' "$*"; }

# ---------- args ----------
[[ -z "${1:-}" ]] && { echo "Usage: $0 <device> [ksu]"; exit 1; }
DEVICE="$1"; [[ "$DEVICE" == "j1" || "$DEVICE" == "continue" ]] || TARGET_DEVICE="$DEVICE"
KSU=0; [[ "${2:-}" == "ksu" ]] && KSU=1

# ---------- toolchain ----------
[[ -d "$TOOLCHAIN_PATH" ]] || die "toolchain not found: $TOOLCHAIN_PATH"
export PATH="$TOOLCHAIN_PATH:/usr/lib/ccache:$PATH"
for c in aarch64-linux-gnu-ld arm-linux-gnueabi-ld clang; do
    command -v "$c" >/dev/null || die "$c not found"
done
clang --version

# ---------- env ----------
export ARCH=arm64 SUBARCH=arm64 CC=clang CXX=clang++
export CCACHE_DIR="$HOME/.cache/ccache_mikernel"
export CCACHE_COMPILERCHECK=content
export CCACHE_SLOPPINESS=time_macros,include_file_mtime,include_file_ctime

MAKE_OPTS=(
    ARCH=arm64 SUBARCH=arm64 O="$OUT"
    CC=clang HOSTCC=clang
    CLANG_TRIPLE=aarch64-linux-gnu-
    CROSS_COMPILE=aarch64-linux-gnu-
    CROSS_COMPILE_ARM32=arm-linux-gnueabi-
    CROSS_COMPILE_COMPAT=arm-linux-gnueabi-
    LD=ld.lld AR=llvm-ar NM=llvm-nm
    OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip
)

# 调试快捷入口
case "${1:-}" in
    j1)       exec make "${MAKE_OPTS[@]}" -j1 ;;
    continue) exec make "${MAKE_OPTS[@]}" -j"$JOBS" ;;
esac

DEFCONFIG="arch/arm64/configs/${DEVICE}_defconfig"
[[ -f "$DEFCONFIG" ]] || { ls arch/arm64/configs/*_defconfig; die "no defconfig for: $DEVICE"; }

# ---------- source patches ----------
if [[ $KSU -eq 1 ]]; then
    info "BakaSU"
    curl -LSs "https://raw.githubusercontent.com/Baka-SU/BakaSU/main/kernel/setup.sh" | bash
fi

info "Baseband-guard"
curl -LSs "https://github.com/vc-teahouse/Baseband-guard/raw/main/setup.sh" | bash
sed -i '/^config LSM$/,/^help$/{/^[[:space:]]*default/{/baseband_guard/!s/selinux/selinux,baseband_guard/}}' security/Kconfig

if [[ $KSU -eq 1 ]]; then
    info "SUSFS inline hooks"
    curl -LSs "https://raw.githubusercontent.com/JackA1ltman/NonGKI_Kernel_Build_2nd/refs/heads/mainline/Patches/susfs_inline_hook_patches.sh" -o /tmp/susfs.sh
    bash /tmp/susfs.sh; rm -f /tmp/susfs.sh
fi

info "AnyKernel3"
rm -rf anykernel
git clone -q --depth=1 -b kona https://github.com/liyafe1997/AnyKernel3 anykernel

# ---------- localversion ----------
LV_OLD="-perf"
LV_NEW="-$(date +%Y%m%d)-${GIT_SHORT}-perf"
sed -i "s|${LV_OLD}|${LV_NEW}|g" "$DEFCONFIG"
restore_lv() { sed -i "s|${LV_NEW}|${LV_OLD}|g" "$DEFCONFIG"; }
trap restore_lv EXIT

# ---------- MIUI DTS ----------
info "DTS patches"
rm -rf "$OUT"
cp -a "$DTS" .dts.bak

dts() { # dts <sed-expr> <file...>
    local expr="$1"; shift
    local f
    for f in "$@"; do
        [[ -f "$f" ]] && sed -i "$expr" "$f"
    done
}

# panel dimensions
dts 's/<154>/<1537>/g'  "$DTS"/dsi-panel-j1s* "$DTS"/dsi-panel-j2*
dts 's/<155>/<1544>/g'  "$DTS/dsi-panel-j3s-37-02-0a-dsc-video.dtsi"
dts 's/<155>/<1545>/g'  "$DTS/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi"
dts 's/<155>/<1546>/g'  "$DTS/dsi-panel-k11a-38-08-0a-dsc-cmd.dtsi" "$DTS/dsi-panel-l11r-38-08-0a-dsc-cmd.dtsi"
dts 's/<70>/<695>/g'    "$DTS/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi" "$DTS/dsi-panel-j3s-37-02-0a-dsc-video.dtsi" \
                        "$DTS/dsi-panel-k11a-38-08-0a-dsc-cmd.dtsi" "$DTS/dsi-panel-l11r-38-08-0a-dsc-cmd.dtsi"
dts 's/<71>/<710>/g'    "$DTS"/dsi-panel-j1s* "$DTS"/dsi-panel-j2*

# smartfps / qsync
dts 's|// mi,mdss-dsi-pan-enable-smart-fps|mi,mdss-dsi-pan-enable-smart-fps|g'       "$DTS"/dsi-panel*
dts 's|// mi,mdss-dsi-smart-fps-max_framerate|mi,mdss-dsi-smart-fps-max_framerate|g' "$DTS"/dsi-panel*
dts 's|// qcom,mdss-dsi-pan-enable-smart-fps|qcom,mdss-dsi-pan-enable-smart-fps|g'   "$DTS"/dsi-panel*
dts 's|qcom,mdss-dsi-qsync-min-refresh-rate|//qcom,mdss-dsi-qsync-min-refresh-rate|g' "$DTS"/dsi-panel*

# refresh rates
dts 's/120 90 60/120 90 60 50 30/g' \
    "$DTS/dsi-panel-g7a-36-02-0c-dsc-video.dtsi" \
    "$DTS/dsi-panel-g7a-37-02-0a-dsc-video.dtsi" \
    "$DTS/dsi-panel-g7a-37-02-0b-dsc-video.dtsi"
dts 's/144 120 90 60/144 120 90 60 50 48 30/g' "$DTS/dsi-panel-j3s-37-02-0a-dsc-video.dtsi"

# un-comment DSI brightness commands: //39 xx ... -> 39 xx ...
dts 's|//39 |39 |g' "$DTS"/dsi-panel*

# ---------- config ----------
info "defconfig"
make "${MAKE_OPTS[@]}" "${DEVICE}_defconfig"

CFG=(scripts/config --file "$OUT/.config")

if [[ $KSU -eq 1 ]]; then
    "${CFG[@]}" \
        -d KSU_MANUAL_HOOK \
        -e KSU -e KSU_MULTI_MANAGER_SUPPORT \
        -e KSU_SUSFS -e KSU_SUSFS_ENABLE_LOG \
        -e KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS -e KSU_SUSFS_OPEN_REDIRECT \
        -e KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG -e KSU_SUSFS_SPOOF_UNAME \
        -e KSU_SUSFS_SUS_KSTAT -e KSU_SUSFS_SUS_MAP \
        -e KSU_SUSFS_SUS_MOUNT -e KSU_SUSFS_SUS_PATH \
        -e THREAD_INFO_IN_TASK
else
    "${CFG[@]}" -d KSU
fi

"${CFG[@]}" \
    --set-str STATIC_USERMODEHELPER_PATH /system/bin/micd \
    -d ARM64_BTI -d ARM64_BTI_KERNEL -d ARM64_PTR_AUTH \
    -d DEBUG_FS -d KPM -d LTO_CLANG \
    -d MI_MEMORY_SYSFS -d REKERNEL -d REKERNEL_NETWORK \
    -e BBG -e BINDER_OPT -e BOOTUP_RECLAIM -e KPERFEVENTS -e LTO_NONE \
    -e MI_FRAGMENTION -e MI_RECLAIM -e MIGT -e MIGT_ENERGY_MODEL \
    -e MIHW -e MILLET -e MIUI_ZRAM_MEMORY_TRACKING -e OVERLAY_FS \
    -e PACKAGE_RUNTIME_INFO -e PERF_CRITICAL_RT_TASK -e PERF_HELPER \
    -e PERF_HUMANTASK -e RTMM -e SF_BINDER -e TASK_DELAY_ACCT \
    -e XIAOMI_MIUI

make "${MAKE_OPTS[@]}" olddefconfig

# ---------- build ----------
info "build (${JOBS}j)"
make "${MAKE_OPTS[@]}" -j"$JOBS"

[[ -f "$OUT/arch/arm64/boot/Image" ]] || die "Image not found"

# ---------- restore & pack ----------
rm -rf "$DTS"; mv .dts.bak "$DTS"

find "$OUT/arch/arm64/boot/dts" -name '*.dtb' -exec cat {} + > "$OUT/arch/arm64/boot/dtb"

rm -rf anykernel/kernels; mkdir -p anykernel/kernels
cp "$OUT/arch/arm64/boot/Image" "$OUT/arch/arm64/boot/dtb" anykernel/kernels/

KSU_TAG=NoKernelSU; [[ $KSU -eq 1 ]] && KSU_TAG=ReSukiSU-SUSFS
ZIP="Kernel_MIUI_${DEVICE}_${KSU_TAG}_$(date +%Y%m%d_%H%M%S)_anykernel3_${GIT_SHORT}.zip"

(cd anykernel && zip -qr9 "$ZIP" . -x '.git*' '*.zip' && mv "$ZIP" ..)
info "done: $ZIP"
