# Official Android Emulator on a Docker homelab, viewed from macOS over Tailscale

Headless Android emulator running on Ubuntu Server (i5-9600K / 16 GB), image pulled
straight from Google, mirrored to your Mac via `scrcpy` over the tailnet.

```
MacBook (scrcpy / Android Studio)
        │  Tailscale (WireGuard)
        ▼
Ubuntu server ──► Docker container ──► qemu + KVM ──► Android 17 system image
```

---

## 1. Host prep (Ubuntu server, once)

```bash
# CPU virtualisation must be on in the BIOS (Intel VT-x)
sudo apt update && sudo apt install -y cpu-checker docker.io docker-compose-v2
sudo kvm-ok            # must print: KVM acceleration can be used
ls -l /dev/kvm         # must exist

sudo usermod -aG docker "$USER" && newgrp docker

# Tailscale, if not already up
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
tailscale ip -4        # note this 100.x.y.z address
```

## 2. Build and run

```bash
cd android-docker-emulator
cp .env.example .env
# set BIND_ADDR to the 100.x.y.z from above
nano .env

docker compose build          # ~10 min, downloads ~2.5 GB from dl.google.com
docker compose up -d
docker compose logs -f        # wait for ">> BOOT COMPLETE"
```

First cold boot takes 2–5 minutes. Subsequent starts use Quick Boot snapshots and
are much faster. The AVD lives in the `avd-data` volume, so app installs, accounts
and settings survive `docker compose down`.

## 3. Attach from macOS

```bash
brew install scrcpy android-platform-tools

adb connect <server>.<tailnet>.ts.net:5555     # or the 100.x.y.z IP
adb devices                                    # should list it as "device"
scrcpy --serial <server>.<tailnet>.ts.net:5555
```

`scrcpy` gives you the screen plus mouse/keyboard/clipboard/drag-and-drop APK
install. Because it's a plain network ADB device, **Android Studio on the Mac also
sees it** in the device dropdown — you can Run/Debug straight onto the homelab box.

Useful extras:

```bash
scrcpy --max-fps 30 --video-bit-rate 4M      # trim bandwidth over WAN
scrcpy --no-audio                            # emulator runs with audio off anyway
adb install ~/Downloads/app-debug.apk
adb shell getprop ro.build.fingerprint       # verify what you're actually running
```

## 4. Proving the image is genuinely Google's

Nothing here uses a third-party Android build:

- `sdkmanager` is Google's own tool from `dl.google.com/android/repository/`, and it
  verifies every package against the checksums in Google's repository manifest
  before installing. A tampered download fails the install.
- Build log prints `sdkmanager --list_installed`, showing the exact
  `system-images;android-37;google_apis;x86_64` package and revision.
- At runtime the entrypoint prints `ro.build.fingerprint`, which for an official
  emulator image looks like `google/sdk_gphone64_x86_64/emu64x:...:userdebug/...`.

```bash
docker compose exec android-emulator sdkmanager --list_installed
adb -s <host>:5555 shell getprop ro.build.fingerprint
adb -s <host>:5555 shell getprop ro.build.version.sdk
```

To confirm what the current newest release actually is before building:

```bash
docker run --rm homelab/android-emulator:api37 \
  bash -lc 'sdkmanager --list | grep "system-images;android-" | grep google_apis'
```

Then rebuild with e.g. `ANDROID_API=38` in `.env` if a newer one has landed.

---

## Tuning notes for your box

| Knob | Value | Why |
|---|---|---|
| `RAM_MB` | 4096 | 16 GB host: 4 GB guest + ~1.5 GB qemu overhead leaves plenty |
| `CORES` | 4 | i5-9600K is 6C/6T; leave 2 for the host and other containers |
| `GPU_MODE` | `swiftshader_indirect` | Software GL — the only reliable choice on a headless server |
| `SYSTEM_IMAGE_TAG` | `google_atd` | Swap to this if you only need API/instrumentation tests; boots ~2× faster, ~40% lighter |

**Performance expectation:** with SwiftShader you get a smooth-enough UI for app
development, testing and CI (roughly 15–30 fps for normal Compose/View UIs).
It is not suitable for 3D games or GPU benchmarking. Hardware GL via the UHD 630
(`GPU_MODE=host` plus mounting `/dev/dri`) is possible but fragile on a headless
host — try it only after the SwiftShader path works.

**Play Store:** set `SYSTEM_IMAGE_TAG=google_apis_playstore` and rebuild. You lose
`adb root` and `-writable-system` on those images; that's a Google restriction, not
a container one.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `FATAL: /dev/kvm is not present` | Enable VT-x in BIOS; check `kvm-ok`; confirm `devices: ["/dev/kvm"]` |
| `adb connect` hangs or flaps | Something else already holds adbd. Run `adb disconnect` everywhere, and don't run `adb` inside the container while the Mac is attached — adbd allows one adb server at a time |
| Device shows `offline` | `adb disconnect && adb kill-server && adb connect <host>:5555` |
| Boot never completes | `docker compose logs -f`; if the host is swapping, drop `RAM_MB` to 3072 |
| Reachable from LAN | `BIND_ADDR` isn't set to the Tailscale IP — check `ss -ltnp \| grep 5555` |
| Want a clean device | `docker compose down -v && docker compose up -d` (wipes the AVD volume) |

## Optional: run it as a systemd-managed service

```bash
sudo systemctl enable docker
# `restart: unless-stopped` in compose already brings it back after reboot
```
