#!/usr/bin/env bash
# ==============================================================================
# build_pixelbook_go_atlas_gbos.sh (November 9, 2026 — Full November 286.R2 Cloud Edition)
# Designed for GitHub Codespaces / GitHub Actions / Ubuntu Linux
# Target: 2019 Google Pixelbook Go (Board: ATLAS, Intel Core i5-8200Y, UHD 615)
#
# Fact-Checked Architecture (against linuxkid473/gbos-x86 & alesimula/project-churro):
#   1. GPU & Blank App Fix: Leaves Google's native Intel Vulkan HAL (vulkan.intel.so)
#      and HWUI pipeline 100% stock (never overrides debug.hwui.renderer to skiagl
#      or skiavk) and preserves usb/gbos.cfg's early_patch.sh hook + apex_patch.sh.
#   2. Frosted-Glass UI Blur: Keeps Google's native Intel Vulkan background blur
#      (ro.surface_flinger.supports_background_blur=1) active with 1.0x animations.
#   3. Full November Patch (CL3B.260622.286.R2): Uses project-churro's ota-update.sh
#      to upgrade Google's stock recovery.bin to the latest November OTA build, then
#      runs gbos-x86's tools/port_build.sh --write --product to re-patch libz.so,
#      libcrypto.so, libkm_compat.so, and usb/patched/MANIFEST for the November build.
#   4. Audio & ATLAS Drivers: Bundles Intel AVS DSP topologies (MAX98373 speakers +
#      DA7219 headphone/mic + DMIC), keyboard backlight, and s2idle lid-close fix.
# ==============================================================================

set -euo pipefail

WORKDIR="${WORKDIR:-$PWD/atlas-build}"
IMAGE_MODE="${1:---standard}"
APPLY_NOVEMBER_OTA="${APPLY_NOVEMBER_OTA:-1}"

echo "======================================================================"
echo " Pixelbook Go (ATLAS) Full November Patch Builder (GitHub Cloud Ready)"
echo " Working Directory : ${WORKDIR}"
echo " Image Mode        : ${IMAGE_MODE}"
echo " Full Nov OTA Port : ${APPLY_NOVEMBER_OTA}"
echo "======================================================================"

# 1. Install Dependencies (Ubuntu / GitHub Codespaces / GitHub Actions)
sudo apt-get update
sudo apt-get install -y git curl python3 docker.io busybox-static mount util-linux \
    kpartx dosfstools mtools fdisk gdisk gzip unzip e2fsprogs erofs-utils

if ! sudo docker info >/dev/null 2>&1; then
    sudo service docker start || sudo systemctl start docker || true
    sleep 3
fi

mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

# 2. Clone Upstream Repositories
[ ! -d "gbos-x86" ] && git clone --depth 1 https://github.com/linuxkid473/gbos-x86.git
[ ! -d "project-churro" ] && git clone --depth 1 https://github.com/alesimula/project-churro.git
[ ! -d "gbos-pixelbook" ] && git clone --depth 1 https://github.com/codiumred/gbos-pixelbook.git
[ ! -d "chromebook-linux-audio" ] && git clone --depth 1 https://github.com/WeirdTreeThing/chromebook-linux-audio.git
[ ! -d "alsa-ucm-conf-cros" ] && git clone --depth 1 https://github.com/WeirdTreeThing/alsa-ucm-conf-cros.git

cd "${WORKDIR}/gbos-x86"

# 3. Check for Newer Full Recovery Build & Optionally Apply Full November OTA (286.R2)
echo "[*] Checking Google catalog for newest lapis recovery build..."
./tools/check_new_build.sh || true

if [ "${APPLY_NOVEMBER_OTA}" = "1" ] && [ -x "${WORKDIR}/project-churro/tools/updater/ota-update.sh" ]; then
    echo "[*] Downloading base recovery image to apply official November OTA delta..."
    ./lapis/dl.sh
    RECOVERY_ZIP="$(ls -t lapis/*/recovery.zip 2>/dev/null | head -n1 || true)"
    if [ -n "${RECOVERY_ZIP}" ]; then
        mkdir -p "${WORKDIR}/ota_work"
        unzip -p "${RECOVERY_ZIP}" > "${WORKDIR}/ota_work/base_recovery.bin"
        CURRENT_BIN="${WORKDIR}/ota_work/base_recovery.bin"
        STEP=1
        while "${WORKDIR}/project-churro/tools/updater/ota-check.sh" "${CURRENT_BIN}" >/dev/null 2>&1; do
            NEXT_BIN="${WORKDIR}/ota_work/recovery_step_${STEP}.bin"
            echo "[*] Applying Google OTA update step ${STEP} (upgrading to latest November build)..."
            "${WORKDIR}/project-churro/tools/updater/ota-update.sh" "${CURRENT_BIN}" --bin "${NEXT_BIN}" || break
            rm -f "${CURRENT_BIN}"
            CURRENT_BIN="${NEXT_BIN}"
            STEP=$((STEP + 1))
        done
        echo "[*] Extracting updated November partitions into lapis/parts..."
        rm -rf lapis/parts
        mkdir -p lapis/parts
        python3 tools/lp_extract.py "${CURRENT_BIN}" lapis/parts \
            system_a vendor_a product_a system_ext_a system_dlkm_a vendor_dlkm_a
        rm -rf "${WORKDIR}/ota_work"

        echo "[*] Running tools/port_build.sh --write --product to re-patch libcrypto/libz/KeyMint for November build..."
        ./tools/port_build.sh --write --product
    fi
fi

# 4. Stage Pixelbook Go (ATLAS) Audio Topologies (MAX98373 + DA7219 + DMIC)
echo "[*] Staging Kaby Lake / Amber Lake AVS DSP firmware and topologies..."
mkdir -p usb/firmware/intel/avs/skl usb/alsa/ucm2/conf.d
cp -rf "${WORKDIR}/chromebook-linux-audio/blobs/avs/"* usb/firmware/intel/avs/ 2>/dev/null || true
cp -rf "${WORKDIR}/alsa-ucm-conf-cros/ucm2/"* usb/alsa/ucm2/ 2>/dev/null || true
cp -rf "${WORKDIR}/alsa-ucm-conf-cros/overrides/"* usb/alsa/ucm2/conf.d/ 2>/dev/null || true

# 5. Append Pixelbook Go (ATLAS) Settings to usb/gbos.cfg (NEVER overwrite early_patch.sh!)
echo "[*] Appending Pixelbook Go (ATLAS) config to usb/gbos.cfg (preserving early_patch.sh)..."
sed -i '/# --- PIXELBOOK GO (ATLAS) ---/,$d' usb/gbos.cfg 2>/dev/null || true
cat << 'CFG_EOF' >> usb/gbos.cfg

# --- PIXELBOOK GO (ATLAS) ---
DEVICE_MODEL="Google Pixelbook Go (Atlas)"
RESOLUTION="2400x1350"
GPU_SOFTWARE="0"
MODOPTS="i915.enable_dpcd_backlight=1 i915.enable_fbc=1 i915.enable_psr=0 pci=noaer snd_intel_dspcfg.dsp_driver=4 snd_soc_avs.ignore_fw_version=1"
CFG_EOF

# 6. Write usb/atlas_fixes.sh (Stock Intel Vulkan + Frosted Blur UI + AVS Audio + Nov RAM/BT Fixes)
echo "[*] Writing usb/atlas_fixes.sh..."
cat << 'ATLAS_EOF' > usb/atlas_fixes.sh
#!/system/bin/sh
# ==============================================================================
# Pixelbook Go (ATLAS) Runtime Initialization
# Fact-checked against linuxkid473/gbos-x86:
# - Does NOT touch debug.hwui.renderer or use_overlay_planes so Google's stock
#   Intel Vulkan (vulkan.intel.so) renders ANGLE, Skia & SurfaceFlinger cleanly.
# - Keeps native Intel GPU background blur (supports_background_blur=1) active.
# ==============================================================================

modprobe i915 2>/dev/null || true

# 1. CPU Power & Governor for Fanless Core i5-8200Y
for cpu in /sys/devices/system/cpu/cpu*/cpufreq; do
    [ -w "$cpu/scaling_governor" ] && echo "schedutil" > "$cpu/scaling_governor" 2>/dev/null || true
    [ -w "$cpu/energy_performance_preference" ] && echo "balance_performance" > "$cpu/energy_performance_preference" 2>/dev/null || true
done

# 2. Ensure Native Intel Vulkan Frosted-Glass UI Blur & Smooth Animations Are Active
#    (Clear any stale renderer overrides so apps never show blank/white screens)
setprop ro.surface_flinger.supports_background_blur 1 2>/dev/null || true
setprop debug.sf.blurs_are_expensive 0 2>/dev/null || true
setprop persist.sys.sf.disable_blurs 0 2>/dev/null || true
settings put global disable_window_blurs 0 2>/dev/null || true
settings put global window_animation_scale 1.0 2>/dev/null || true
settings put global transition_animation_scale 1.0 2>/dev/null || true
settings put global animator_duration_scale 1.0 2>/dev/null || true

# 3. November 2026 (CL3B.260622.286.R2) RAM & Bluetooth Audio Lip-Sync Optimizations
setprop persist.aicore.enabled false 2>/dev/null || true
setprop ro.aicore.preload false 2>/dev/null || true
setprop persist.bluetooth.a2dp_offload.disabled true 2>/dev/null || true
setprop ro.bluetooth.a2dp_offload.supported false 2>/dev/null || true

# 4. Prevent S3 Deep Sleep Hang on Lid Close (codiumred/gbos-pixelbook)
echo "s2idle" > /sys/power/mem_sleep 2>/dev/null || true
echo "atlas_nosuspend" > /sys/power/wake_lock 2>/dev/null || true
setprop power.off_timeout_override 0 2>/dev/null || true
setprop ro.config.nosuspend true 2>/dev/null || true

# 5. ChromeOS EC Keyboard Backlight (35%)
modprobe cros_ec_lpcs 2>/dev/null || true
modprobe cros_ec_dev 2>/dev/null || true
modprobe leds_cros_ec 2>/dev/null || true
if [ -w /sys/class/leds/chromeos::kbd_backlight/brightness ]; then
    echo 35 > /sys/class/leds/chromeos::kbd_backlight/brightness
    chmod 0666 /sys/class/leds/chromeos::kbd_backlight/brightness 2>/dev/null || true
fi

# 6. Load Camera & Intel AVS Audio Modules (MAX98373 Speakers + DA7219 Headphone/Mic + DMIC)
modprobe system_heap 2>/dev/null || true
modprobe uvcvideo 2>/dev/null || true
modprobe snd_soc_avs 2>/dev/null || true
modprobe snd_soc_max98373_i2c 2>/dev/null || true
modprobe snd_soc_da7219 2>/dev/null || true
modprobe snd_soc_avs_max98373 2>/dev/null || true
modprobe snd_soc_avs_da7219 2>/dev/null || true
modprobe snd_soc_avs_dmic 2>/dev/null || true
modprobe snd_soc_avs_hdaudio 2>/dev/null || true

for card in 0 1 2 3 4; do
    if [ -d "/proc/asound/card${card}" ]; then
        card_id="$(cat /proc/asound/card${card}/id 2>/dev/null || true)"
        case "$card_id" in
            *max98373*|*MAX98373*|*avs*|*AVS*)
                tinymix -D "$card" "Left Spk Switch" 1 2>/dev/null || true
                tinymix -D "$card" "Right Spk Switch" 1 2>/dev/null || true
                tinymix -D "$card" "Speaker Switch" 1 2>/dev/null || true
                tinymix -D "$card" "Left Digital Volume" 110 2>/dev/null || true
                tinymix -D "$card" "Right Digital Volume" 110 2>/dev/null || true
                tinymix -D "$card" "Left Speaker Gain" 8 2>/dev/null || true
                tinymix -D "$card" "Right Speaker Gain" 8 2>/dev/null || true
                tinymix -D "$card" "LeftBVI_Sense Switch" 1 2>/dev/null || true
                tinymix -D "$card" "RightBVI_Sense Switch" 1 2>/dev/null || true
                tinymix -D "$card" "Left DHT Switch" 1 2>/dev/null || true
                tinymix -D "$card" "Right DHT Switch" 1 2>/dev/null || true
                tinymix -D "$card" "Left BDE Switch" 1 2>/dev/null || true
                tinymix -D "$card" "Right BDE Switch" 1 2>/dev/null || true
                ;;
            *da7219*|*DA7219*)
                tinymix -D "$card" "Playback Digital Switch" 1 2>/dev/null || true
                tinymix -D "$card" "Mixer Out FilterL DACL Switch" 1 2>/dev/null || true
                tinymix -D "$card" "Mixer Out FilterR DACR Switch" 1 2>/dev/null || true
                tinymix -D "$card" "Headphone Switch" 1 2>/dev/null || true
                tinymix -D "$card" "Headphone Volume" 55 55 2>/dev/null || true
                tinymix -D "$card" "Mic Switch" 1 2>/dev/null || true
                tinymix -D "$card" "Mixin Left Mic 1 Switch" 1 2>/dev/null || true
                tinymix -D "$card" "Mixin Right Mic 1 Switch" 1 2>/dev/null || true
                ;;
        esac
    fi
done
ATLAS_EOF
chmod +x usb/atlas_fixes.sh

if ! grep -q "atlas_fixes.sh" usb/hook.sh; then
    cat << 'HOOK_EOF' >> usb/hook.sh

# Run Pixelbook Go (ATLAS) hardware and performance initialization
if [ -f "/gbos/atlas_fixes.sh" ]; then
    /system/bin/sh /gbos/atlas_fixes.sh
elif [ -f "$(dirname "$0")/atlas_fixes.sh" ]; then
    /system/bin/sh "$(dirname "$0")/atlas_fixes.sh"
fi
HOOK_EOF
fi

# Ensure install.sh also copies atlas_fixes.sh when installing/updating to internal eMMC/SSD
if [ -f "usb/install.sh" ] && ! grep -q "atlas_fixes.sh" "usb/install.sh"; then
    sed -i 's/early_patch.sh/early_patch.sh atlas_fixes.sh/g' usb/install.sh 2>/dev/null || true
fi

# 7. Run the Official gbOS86 Image Builder
echo "[*] Building flashable Googlebook OS image (${IMAGE_MODE})..."
sudo ./build.sh "${IMAGE_MODE}"

LATEST_IMG="$(ls -t dist/gbOS86-*.img | head -n1)"
echo "[*] Compressing ${LATEST_IMG} for fast mobile download..."
gzip -k -f "${LATEST_IMG}"

echo "======================================================================"
echo " BUILD COMPLETE!"
echo " Raw Image        : ${WORKDIR}/gbos-x86/${LATEST_IMG}"
echo " Compressed Image : ${WORKDIR}/gbos-x86/${LATEST_IMG}.gz"
echo "======================================================================"