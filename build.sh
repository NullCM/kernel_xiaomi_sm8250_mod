#!/usr/bin/env bash
# MIUI kernel build script (refactored). Original build logic credits: UtsavBalar1231.

set -euo pipefail
# -e: exit on error; -u: error on unset vars; -o pipefail: fail pipeline if any stage fails

TOOLCHAIN_PATH="$HOME/zyc-clang/bin"
GIT_COMMIT_ID=$(git rev-parse --short=8 HEAD)
TARGET_DEVICE="${1:-}"
KSU_FLAG="${2:-}"

# ---------- argument / environment validation ----------
if [[ -z "$TARGET_DEVICE" ]]; then
	cat >&2 <<'EOF'
Error: No argument provided, please specify a target device.
If you need KernelSU, please add [ksu] as the second arg.
Examples:
    bash build.sh lmi
    bash build.sh umi ksu
EOF
	exit 1
fi

if [[ ! -d "$TOOLCHAIN_PATH" ]]; then
	echo "TOOLCHAIN_PATH [$TOOLCHAIN_PATH] does not exist." >&2
	exit 1
fi
export PATH="$TOOLCHAIN_PATH:$PATH"

for cmd in aarch64-linux-gnu-ld arm-linux-gnueabi-ld clang; do
	if ! command -v "$cmd" >/dev/null 2>&1; then
		echo "[$cmd] does not exist, please check your environment." >&2
		exit 1
	fi
done

# ---------- ccache ----------
export CCACHE_DIR="$HOME/.cache/ccache_mikernel"
export CC="clang"
export CXX="clang++"
export PATH="/usr/lib/ccache:$PATH"
export CCACHE_COMPILERCHECK=content
export CCACHE_SLOPPINESS=time_macros,include_file_mtime,include_file_ctime
echo "CCACHE_DIR: [$CCACHE_DIR]"

# ---------- make arguments (array form) ----------
readonly MAKE_ARGS=(
	ARCH=arm64
	SUBARCH=arm64
	O=out
	CC=clang
	HOSTCC=clang
	CLANG_TRIPLE=aarch64-linux-gnu-
	CROSS_COMPILE=aarch64-linux-gnu-
	CROSS_COMPILE_ARM32=arm-linux-gnueabi-
	CROSS_COMPILE_COMPAT=arm-linux-gnueabi-
	LD=ld.lld
	AR=llvm-ar
	NM=llvm-nm
	OBJCOPY=llvm-objcopy
	OBJDUMP=llvm-objdump
	STRIP=llvm-strip
)

# ---------- special modes ----------
if [[ "$TARGET_DEVICE" == "j1" ]]; then
	make "${MAKE_ARGS[@]}" -j1
	exit 0
fi
if [[ "$TARGET_DEVICE" == "continue" ]]; then
	make "${MAKE_ARGS[@]}" -j"$(nproc)"
	exit 0
fi

# ---------- defconfig existence ----------
DEFCONFIG="arch/arm64/configs/${TARGET_DEVICE}_defconfig"
if [[ ! -f "$DEFCONFIG" ]]; then
	echo "No target device [${TARGET_DEVICE}] found." >&2
	echo "Available defconfigs:" >&2
	ls arch/arm64/configs/*_defconfig >&2
	exit 1
fi

echo "[clang --version]:"; clang --version

# ---------- KSU flag ----------
KSU_ENABLE=0
KSU_ZIP_STR="NoKernelSU"
if [[ "$KSU_FLAG" == "ksu" ]]; then
	KSU_ENABLE=1
	KSU_ZIP_STR="ReSukiSU-SUSFS"
fi
echo "TARGET_DEVICE: $TARGET_DEVICE"

# ---------- external integrations ----------
if [[ "$KSU_ENABLE" -eq 1 ]]; then
	echo "KSU is enabled"
	# -f makes curl fail on HTTP errors; with pipefail the pipeline aborts
	curl -fLSs "https://raw.githubusercontent.com/Baka-SU/BakaSU/main/kernel/setup.sh" | bash
else
	echo "KSU is disabled"
fi

echo "Integrating Baseband-guard..."
curl -fLSs "https://github.com/vc-teahouse/Baseband-guard/raw/main/setup.sh" | bash
sed -i '/^config LSM$/,/^help$/{ /^[[:space:]]*default/ { /baseband_guard/! s/selinux/selinux,baseband_guard/ } }' security/Kconfig

if [[ "$KSU_ENABLE" -eq 1 ]]; then
	echo "Integrating SUSFS inline hook patches..."
	curl -fLSs "https://raw.githubusercontent.com/JackA1ltman/NonGKI_Kernel_Build_2nd/refs/heads/mainline/Patches/susfs_inline_hook_patches.sh" -o susfs_inline_hook_patches.sh
	chmod +x susfs_inline_hook_patches.sh
	bash susfs_inline_hook_patches.sh
	rm -f susfs_inline_hook_patches.sh
fi

# ---------- clean & fetch AnyKernel3 ----------
echo "Cleaning..."
rm -rf out/ anykernel/
git clone https://github.com/liyafe1997/AnyKernel3 -b kona --single-branch --depth=1 anykernel

# ---------- local version injection + DTS backup ----------
local_version_str="-perf"
local_version_date_str="-$(date +%Y%m%d)-${GIT_COMMIT_ID}-perf"

dts_source="arch/arm64/boot/dts/vendor/qcom"
DTS_BACKUP=".dts.bak"
rm -rf "$DTS_BACKUP"
cp -a "$dts_source" "$DTS_BACKUP"

restore_dts() {
	# shellcheck disable=SC2317
	if [[ -d "$DTS_BACKUP" ]]; then
		rm -rf "$dts_source"
		mv "$DTS_BACKUP" "$dts_source"
	fi
	return 0
}

restore_defconfig() {
	# shellcheck disable=SC2317
	if grep -q -- "$local_version_date_str" "$DEFCONFIG" 2>/dev/null; then
		sed -i "s/${local_version_date_str}/${local_version_str}/g" "$DEFCONFIG"
	fi
	return 0
}

cleanup() {
	# shellcheck disable=SC2317
	restore_dts
	restore_defconfig
}
trap cleanup EXIT

sed -i "s/${local_version_str}/${local_version_date_str}/g" "$DEFCONFIG"

# ---------- DTS modifications for MIUI ----------
# Grouping rule: only commands with identical "pattern -> replacement -> file set"
# are merged; differing triples stay separate to preserve original semantics.
subst_in() {
	local expr="$1"; shift
	local f
	for f in "$@"; do
		if [[ ! -f "$f" ]]; then
			echo "ERROR: expected file not found: $f" >&2
			return 1
		fi
		sed -i "$expr" "$f"
	done
}

# panel dimension corrections
subst_in 's/<154>/<1537>/g' \
	"${dts_source}"/dsi-panel-j1s* \
	"${dts_source}"/dsi-panel-j2*

subst_in 's/<155>/<1544>/g' \
	"${dts_source}"/dsi-panel-j3s-37-02-0a-dsc-video.dtsi

subst_in 's/<155>/<1545>/g' \
	"${dts_source}"/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi

subst_in 's/<155>/<1546>/g' \
	"${dts_source}"/dsi-panel-k11a-38-08-0a-dsc-cmd.dtsi \
	"${dts_source}"/dsi-panel-l11r-38-08-0a-dsc-cmd.dtsi

subst_in 's/<70>/<695>/g' \
	"${dts_source}"/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi \
	"${dts_source}"/dsi-panel-j3s-37-02-0a-dsc-video.dtsi \
	"${dts_source}"/dsi-panel-k11a-38-08-0a-dsc-cmd.dtsi \
	"${dts_source}"/dsi-panel-l11r-38-08-0a-dsc-cmd.dtsi

subst_in 's/<71>/<710>/g' \
	"${dts_source}"/dsi-panel-j1s* \
	"${dts_source}"/dsi-panel-j2*

# smart-fps / qsync (all dsi-panel files)
sed -i \
	-e 's/\/\/ mi,mdss-dsi-pan-enable-smart-fps/mi,mdss-dsi-pan-enable-smart-fps/g' \
	-e 's/\/\/ mi,mdss-dsi-smart-fps-max_framerate/mi,mdss-dsi-smart-fps-max_framerate/g' \
	-e 's/\/\/ qcom,mdss-dsi-pan-enable-smart-fps/qcom,mdss-dsi-pan-enable-smart-fps/g' \
	-e 's/qcom,mdss-dsi-qsync-min-refresh-rate/\/\/qcom,mdss-dsi-qsync-min-refresh-rate/g' \
	"${dts_source}"/dsi-panel*

# refresh rates
subst_in 's/120 90 60/120 90 60 50 30/g' \
	"${dts_source}"/dsi-panel-g7a-36-02-0c-dsc-video.dtsi \
	"${dts_source}"/dsi-panel-g7a-37-02-0a-dsc-video.dtsi \
	"${dts_source}"/dsi-panel-g7a-37-02-0b-dsc-video.dtsi

subst_in 's/144 120 90 60/144 120 90 60 50 48 30/g' \
	"${dts_source}"/dsi-panel-j3s-37-02-0a-dsc-video.dtsi

# brightness control restore
subst_in 's/\/\/39 00 00 00 00 00 03 51 03 FF/39 00 00 00 00 00 03 51 03 FF/g' \
	"${dts_source}"/dsi-panel-j9-38-0a-0a-fhd-video.dtsi

subst_in 's/\/\/39 00 00 00 00 00 03 51 0D FF/39 00 00 00 00 00 03 51 0D FF/g' \
	"${dts_source}"/dsi-panel-j2-p2-1-38-0c-0a-dsc-cmd.dtsi

subst_in 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' \
	"${dts_source}"/dsi-panel-j1s-42-02-0a-dsc-cmd.dtsi \
	"${dts_source}"/dsi-panel-j1s-42-02-0a-mp-dsc-cmd.dtsi \
	"${dts_source}"/dsi-panel-j2-mp-42-02-0b-dsc-cmd.dtsi \
	"${dts_source}"/dsi-panel-j2-p2-1-42-02-0b-dsc-cmd.dtsi \
	"${dts_source}"/dsi-panel-j2s-mp-42-02-0a-dsc-cmd.dtsi

subst_in 's/\/\/39 01 00 00 00 00 03 51 00 00/39 01 00 00 00 00 03 51 00 00/g' \
	"${dts_source}"/dsi-panel-j2-38-0c-0a-dsc-cmd.dtsi

subst_in 's/\/\/39 01 00 00 00 00 03 51 03 FF/39 01 00 00 00 00 03 51 03 FF/g' \
	"${dts_source}"/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi \
	"${dts_source}"/dsi-panel-j9-38-0a-0a-fhd-video.dtsi

subst_in 's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g' \
	"${dts_source}"/dsi-panel-j1u-42-02-0b-dsc-cmd.dtsi \
	"${dts_source}"/dsi-panel-j2-42-02-0b-dsc-cmd.dtsi \
	"${dts_source}"/dsi-panel-j2-p1-42-02-0b-dsc-cmd.dtsi

subst_in 's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g' \
	"${dts_source}"/dsi-panel-j1u-42-02-0b-dsc-cmd.dtsi \
	"${dts_source}"/dsi-panel-j2-42-02-0b-dsc-cmd.dtsi \
	"${dts_source}"/dsi-panel-j2-p1-42-02-0b-dsc-cmd.dtsi

subst_in 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' \
	"${dts_source}"/dsi-panel-j1s-42-02-0a-dsc-cmd.dtsi \
	"${dts_source}"/dsi-panel-j1s-42-02-0a-mp-dsc-cmd.dtsi \
	"${dts_source}"/dsi-panel-j2-mp-42-02-0b-dsc-cmd.dtsi \
	"${dts_source}"/dsi-panel-j2-p2-1-42-02-0b-dsc-cmd.dtsi \
	"${dts_source}"/dsi-panel-j2s-mp-42-02-0a-dsc-cmd.dtsi

subst_in 's/\/\/39 01 00 00 01 00 03 51 03 FF/39 01 00 00 01 00 03 51 03 FF/g' \
	"${dts_source}"/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi

subst_in 's/\/\/39 01 00 00 11 00 03 51 03 FF/39 01 00 00 11 00 03 51 03 FF/g' \
	"${dts_source}"/dsi-panel-j2-p2-1-38-0c-0a-dsc-cmd.dtsi

# ---------- configure & build ----------
make "${MAKE_ARGS[@]}" "${TARGET_DEVICE}_defconfig"

if [[ "$KSU_ENABLE" -eq 1 ]]; then
	scripts/config --file out/.config \
		-d KSU_MANUAL_HOOK \
		-e KSU \
		-e KSU_MULTI_MANAGER_SUPPORT \
		-e KSU_SUSFS \
		-e KSU_SUSFS_ENABLE_LOG \
		-e KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
		-e KSU_SUSFS_OPEN_REDIRECT \
		-e KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
		-e KSU_SUSFS_SPOOF_UNAME \
		-e KSU_SUSFS_SUS_KSTAT \
		-e KSU_SUSFS_SUS_MAP \
		-e KSU_SUSFS_SUS_MOUNT \
		-e KSU_SUSFS_SUS_PATH \
		-e THREAD_INFO_IN_TASK
else
	scripts/config --file out/.config -d KSU
fi

scripts/config --file out/.config \
	--set-str STATIC_USERMODEHELPER_PATH /system/bin/micd \
	-d ARM64_BTI \
	-d ARM64_BTI_KERNEL \
	-d ARM64_PTR_AUTH \
	-d DEBUG_FS \
	-d KPM \
	-d LTO_CLANG \
	-d MI_MEMORY_SYSFS \
	-d REKERNEL \
	-d REKERNEL_NETWORK \
	-e BBG \
	-e BINDER_OPT \
	-e BOOTUP_RECLAIM \
	-e KPERFEVENTS \
	-e LTO_NONE \
	-e MI_FRAGMENTION \
	-e MI_RECLAIM \
	-e MIGT \
	-e MIGT_ENERGY_MODEL \
	-e MIHW \
	-e MILLET \
	-e MIUI_ZRAM_MEMORY_TRACKING \
	-e OVERLAY_FS \
	-e PACKAGE_RUNTIME_INFO \
	-e PERF_CRITICAL_RT_TASK \
	-e PERF_HELPER \
	-e PERF_HUMANTASK \
	-e RTMM \
	-e SF_BINDER \
	-e TASK_DELAY_ACCT \
	-e XIAOMI_MIUI

make "${MAKE_ARGS[@]}" -j"$(nproc)"

if [[ ! -f "out/arch/arm64/boot/Image" ]]; then
	echo "Build failed: out/arch/arm64/boot/Image does not exist." >&2
	exit 1
fi
echo "The file [out/arch/arm64/boot/Image] exists. MIUI Build successfully."

echo "Generating dtb..."
find out/arch/arm64/boot/dts -name '*.dtb' -exec cat {} + > out/arch/arm64/boot/dtb

# explicit restore before packaging; clear trap so cleanup runs once
restore_dts
restore_defconfig
trap - EXIT

# ---------- package ----------
rm -rf anykernel/kernels/
mkdir -p anykernel/kernels/
cp out/arch/arm64/boot/Image anykernel/kernels/
cp out/arch/arm64/boot/dtb   anykernel/kernels/

ZIP_FILENAME="Kernel_MIUI_${TARGET_DEVICE}_${KSU_ZIP_STR}_$(date +'%Y%m%d_%H%M%S')_anykernel3_${GIT_COMMIT_ID}.zip"
(
	cd anykernel
	zip -r9 "$ZIP_FILENAME" ./* -x .git .gitignore out/ ./*.zip
	mv "$ZIP_FILENAME" ../
)

echo "Done. The flashable zip is: [./$ZIP_FILENAME]"
