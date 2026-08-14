#!/usr/bin/env bash
set -euo pipefail

AVD_NAME="${AVD_NAME:-homelab_api${ANDROID_API}}"
DEVICE_PROFILE="${DEVICE_PROFILE:-pixel_6}"
RAM_MB="${RAM_MB:-4096}"
CORES="${CORES:-4}"
DATA_MB="${DATA_MB:-8192}"
GPU_MODE="${GPU_MODE:-swiftshader_indirect}"
EMULATOR_EXTRA_ARGS="${EMULATOR_EXTRA_ARGS:-}"

# ---- root phase: fix /dev/kvm perms, then drop privileges -----------------
if [ "$(id -u)" = "0" ]; then
  if [ -e /dev/kvm ]; then
    chmod 0666 /dev/kvm || true
  else
    echo "FATAL: /dev/kvm is not present in the container." >&2
    echo "       Add  devices: [\"/dev/kvm\"]  and verify KVM on the host (kvm-ok)." >&2
    exit 1
  fi
  mkdir -p /home/android/.android/avd
  chown -R android:android /home/android
  exec setpriv --reuid=1001 --regid=1001 --init-groups "$0" "$@"
fi

PKG="system-images;android-${ANDROID_API};${SYSTEM_IMAGE_TAG};${ABI}"
CONFIG="${ANDROID_AVD_HOME}/${AVD_NAME}.avd/config.ini"

# ---- create the AVD once; it then lives in the mounted volume -------------
if [ ! -f "$CONFIG" ]; then
  echo ">> Creating AVD '${AVD_NAME}' from ${PKG} (device: ${DEVICE_PROFILE})"
  echo "no" | avdmanager create avd \
      --force \
      --name "$AVD_NAME" \
      --package "$PKG" \
      --device "$DEVICE_PROFILE"

  {
    echo "hw.ramSize=${RAM_MB}"
    echo "vm.heapSize=576"
    echo "disk.dataPartition.size=${DATA_MB}M"
    echo "hw.cpu.ncore=${CORES}"
    echo "hw.keyboard=yes"
    echo "hw.gpu.enabled=yes"
    echo "hw.gpu.mode=${GPU_MODE}"
    echo "hw.audioInput=no"
    echo "hw.audioOutput=no"
    echo "showDeviceFrame=no"
  } >> "$CONFIG"
fi

echo ">> Baked system image: ${PKG}"

# ---- bridge the emulator's loopback-only ports out to the container NIC ---
# The emulator binds 127.0.0.1 only. socat re-exposes adbd (5555) on 5585 and
# the telnet console (5554) on 5584 so a remote host can `adb connect`.
socat TCP-LISTEN:5585,fork,reuseaddr,keepalive TCP:127.0.0.1:5555 &
socat TCP-LISTEN:5584,fork,reuseaddr,keepalive TCP:127.0.0.1:5554 &

# ---- boot watcher: reports readiness, then releases adbd for the remote ---
# adbd accepts ONE adb server connection at a time, so the in-container adb
# server must be killed before your Mac connects.
(
  for _ in $(seq 1 120); do
    sleep 5
    booted="$(adb -s emulator-5554 shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)"
    if [ "$booted" = "1" ]; then
      adb -s emulator-5554 shell getprop ro.build.fingerprint 2>/dev/null | \
        sed 's/^/>> ro.build.fingerprint: /'
      adb kill-server >/dev/null 2>&1 || true
      echo ">> BOOT COMPLETE - connect from your Mac:  adb connect <tailscale-host>:5555"
      exit 0
    fi
  done
  adb kill-server >/dev/null 2>&1 || true
  echo ">> WARNING: boot not confirmed after ~10 min; emulator still running."
) &

echo ">> Starting emulator (headless, gpu=${GPU_MODE}, ram=${RAM_MB}M, cores=${CORES})"
exec emulator "@${AVD_NAME}" \
  -ports 5554,5555 \
  -no-window \
  -no-audio \
  -no-boot-anim \
  -no-metrics \
  -gpu "${GPU_MODE}" \
  -memory "${RAM_MB}" \
  -cores "${CORES}" \
  -accel on \
  -camera-back none \
  -camera-front none \
  ${EMULATOR_EXTRA_ARGS}
