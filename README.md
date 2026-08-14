# android-docker-emulator

Run an **official Google Android emulator** headless inside Docker on a Linux
homelab, and drive it from any other machine (macOS, Windows, another Linux box)
over your private network — no Android Studio required on the client, no
third-party Android builds anywhere.

The Android system image is downloaded at build time by Google's own
`sdkmanager` from `dl.google.com`, checksum-verified against Google's manifest.
You pick the Android version and image flavour with two lines in a `.env` file.

```
Client (scrcpy / Android Studio / adb)
        │   private network (Tailscale, LAN, VPN…)
        ▼
Linux host ──► Docker container ──► qemu + KVM ──► official Android system image
```

By default this ships pointed at the **latest Android** Google publishes to the
command-line SDK — currently **Android 17 (API 37.0)**, a preview build. Pinning
to a stable release (Android 16 / API 36) is a two-line change in `.env`; see
[Choosing the Android version](#version-selecting-a-release).

- **License:** MIT (see `LICENSE`)
- **Status:** works on any x86_64 Linux host with KVM. See host support below.

---

## Table of contents

- [What this repo does](#what-this-repo-does)
- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Choosing the Android version and image type](#choosing-the-android-version-and-image-type)
  - [Version: selecting a release](#version-selecting-a-release)
  - [Flavour: Google APIs vs Google Play vs AOSP](#flavour-google-apis-vs-google-play-vs-aosp)
  - [CPU arch: x86_64 vs ARM](#cpu-arch-x86_64-vs-arm)
- [Configuration reference](#configuration-reference)
- [Connecting a client](#connecting-a-client)
  - [macOS](#macos-client)
  - [Windows](#windows-client)
  - [Linux](#linux-client)
- [Host setup by platform](#host-setup-by-platform)
- [Verifying the image is genuinely Google's](#verifying-the-image-is-genuinely-googles)
- [Performance tuning](#performance-tuning)
  - [Reading CPU% correctly](#reading-cpu-correctly)
  - [The two resource layers](#the-two-resource-layers-important)
  - [If the emulator is slow](#if-the-emulator-is-slow)
- [Docker command reference](#docker-command-reference)
- [Troubleshooting](#troubleshooting)
  - [Fixing a crash loop](#fixing-a-crash-loop)
- [Security notes](#security-notes)
- [FAQ](#faq)
- [Contributing](#contributing)

---

## What this repo does

It gives you a reproducible, headless Android device that lives on a server
instead of your laptop. Concretely:

1. **Builds a container** that installs the Android command-line tools, platform
   tools, the emulator, a platform, and a system image — all from Google's SDK
   repository, all checksum-verified.
2. **Creates an AVD** (Android Virtual Device) from that system image on first
   run, and stores it in a Docker volume so apps, accounts, and settings persist
   across restarts.
3. **Boots the emulator headless** (`-no-window`) with KVM acceleration, so it
   runs at near-native speed on x86_64 hardware.
4. **Bridges ADB out** of the container so a remote machine can `adb connect` and
   then mirror the screen with `scrcpy`, or deploy/debug from Android Studio.

Typical uses: a shared test device for a team, an always-on device for CI or
automation, offloading the emulator off a low-RAM laptop, or running app tests
against a specific Android version without cluttering your workstation SDK.

**What it is not:** it is not a cloud device farm, and it is not for running the
emulator with a visible desktop window on the host. Display happens on the client
via `scrcpy` (screen streamed over ADB) — see [Connecting a client](#connecting-a-client).

## How it works

| Piece | Role |
|---|---|
| `Dockerfile` | Installs the SDK from Google, resolves the requested API level, verifies the exact system image exists, installs it, records the resolved level. |
| `entrypoint.sh` | On container start: fixes `/dev/kvm` perms, drops to an unprivileged user, creates the AVD once, boots the emulator headless, and bridges the emulator's loopback-only ADB port out to the container network so a remote host can reach it. |
| `docker-compose.yml` | Wires in `/dev/kvm`, the persistent volume, the build args, and the port binding. This is the file you run. |
| `.env` | Your local settings (version, image flavour, RAM/cores, and the address ADB binds to). Never committed — `.gitignore` excludes it. |
| `init-repo.sh` | Convenience script to publish this folder to GitHub as a private repo via the `gh` CLI. |

The emulator binds ADB to `127.0.0.1` inside the container only. `entrypoint.sh`
uses `socat` to re-expose it on the container's network interface, and
`docker-compose.yml` publishes that to a host address you choose. Point that host
address at a private interface (Tailscale IP, VPN, or LAN) so the device is never
exposed to the internet.

## Requirements

- **x86_64 Linux host** with hardware virtualization (Intel VT-x / AMD-V) enabled
  in BIOS, and `/dev/kvm` present. This is non-negotiable — the emulator needs KVM
  for acceleration, and KVM needs bare metal or a VM with nested virtualization.
- **Docker** + the **Docker Compose v2** plugin.
- **~3 GB free disk** for the image plus the AVD.
- A **private network path** from your client to the host (Tailscale recommended,
  but any LAN/VPN works).

> The **host must be Linux**. macOS and Windows cannot run this container — Docker
> Desktop there runs Linux in a VM without KVM passthrough. macOS/Windows are fine
> as **clients**; they just can't be the host. (See [Host setup](#host-setup-by-platform).)

## Quick start

```bash
git clone <your-fork-url> android-docker-emulator
cd android-docker-emulator
cp .env.example .env
nano .env          # set BIND_ADDR, and optionally ANDROID_API / SYSTEM_IMAGE_TAG

docker compose build          # ~10 min, downloads ~2.5 GB from dl.google.com
docker compose up -d
docker compose logs -f        # wait for ">> BOOT COMPLETE"
```

First cold boot takes 2–5 minutes. Subsequent starts use Quick Boot snapshots and
are much faster. Then connect a client — see [Connecting a client](#connecting-a-client).

---

## Choosing the Android version and image type

Everything is driven by three build args, all set in `.env`:

| `.env` variable | Controls | Default |
|---|---|---|
| `ANDROID_API` | Android **version** token, or `auto` for newest on the channel | `37.0` |
| `SYSTEM_IMAGE_TAG` | Image **flavour** (Google APIs / Play / AOSP / ATD) | `google_apis` |
| `SDK_CHANNEL` | SDK release channel (`0` stable … `3` canary) | `3` |

After changing any of them, rebuild:

```bash
docker compose build --no-cache && docker compose up -d && docker compose logs -f
```

<a id="version-selecting-a-release"></a>
### Version: selecting a release

`ANDROID_API` must equal a platform package name **exactly as `sdkmanager` lists
it** — specifically the part after `android-`. This is the single most common
source of build errors, because the format differs by channel:

| Channel | Package name | What you set |
|---|---|---|
| **Stable** (`SDK_CHANNEL=0`) | `platforms;android-36` | `ANDROID_API=36` |
| **Preview** (`SDK_CHANNEL=3`) | `platforms;android-37.0` | `ANDROID_API=37.0` |

The rule: **copy the token after `android-` verbatim.** Stable releases use a bare
integer (`36`); preview releases carry a minor version (`37.0`, `37.1`,
`37.2-beta2`). Setting `ANDROID_API=37` when the package is `android-37.0` fails
with "not found" — the build then prints the list of what *is* available so you
can correct it.

Common selections:

| You want | `.env` lines |
|---|---|
| **Android 17 (API 37.0), preview** — *default* | `ANDROID_API=37.0` · `SDK_CHANNEL=3` |
| **Android 16 (API 36), stable** | `ANDROID_API=36` · `SDK_CHANNEL=0` |
| **Newest stable, auto-detected** | `ANDROID_API=auto` · `SDK_CHANNEL=0` |
| **Newest preview, auto-detected** | `ANDROID_API=auto` · `SDK_CHANNEL=3` |
| **A specific older release** | e.g. `ANDROID_API=34` · `SDK_CHANNEL=0` |

> **Preview caveat.** Preview images (37.x) can boot slower or behave less
> predictably than stable. For a production-like, reproducible device, pin
> `ANDROID_API=36` with `SDK_CHANNEL=0`.

The build verifies the exact image exists on your chosen channel **before**
installing; if it can't find it, it lists the available images and stops cleanly
rather than failing cryptically.

### Checking what's available

To see exactly which versions and images Google currently publishes to the
command-line SDK — the authoritative source, and what actually determines what
this project can install — run this one-off container. It builds a throwaway SDK
lister in memory (nothing is saved to disk) and prints matching packages:

```bash
docker run --rm ubuntu:24.04 bash -c '
apt-get update -qq && apt-get install -y -qq openjdk-21-jdk-headless curl unzip >/dev/null 2>&1
cd /tmp && curl -fsSL https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip -o c.zip
mkdir -p /sdk/cmdline-tools && unzip -q c.zip && mv cmdline-tools /sdk/cmdline-tools/latest
yes | /sdk/cmdline-tools/latest/bin/sdkmanager --sdk_root=/sdk --licenses >/dev/null 2>&1
/sdk/cmdline-tools/latest/bin/sdkmanager --sdk_root=/sdk --list --channel=3 2>/dev/null \
  | grep "system-images"
'
```

- Change `--channel=3` to `0` to see only stable images.
- Narrow the results by piping to a tighter `grep`, e.g. `grep "android-37"` for
  one release, or `grep "google_apis;x86_64"` for one flavour/arch.
- Read the **third column** of the row you want and copy the token after
  `android-` into `ANDROID_API`, and the tag (`google_apis`,
  `google_apis_playstore`, …) into `SYSTEM_IMAGE_TAG`.

Example row and the settings it implies:

```
system-images;android-37.0;google_apis;x86_64   | 6 | Google APIs Intel x86_64 Atom System Image
                       ^^^^  ^^^^^^^^^^  ^^^^^^
                ANDROID_API  SYSTEM_IMAGE_TAG  ABI
```

→ `ANDROID_API=37.0`, `SYSTEM_IMAGE_TAG=google_apis`, `SDK_CHANNEL=3`.

**Reference links** (human-readable, for orientation — the command above is the
ground truth for what's installable):

- Android SDK Platform release notes — <https://developer.android.com/tools/releases/platforms>
- Android API level / version reference — <https://apilevels.com/>
- `sdkmanager` documentation — <https://developer.android.com/tools/sdkmanager>

### Flavour: Google APIs vs Google Play vs AOSP

Set with `SYSTEM_IMAGE_TAG` in `.env`.

| | `google_apis` | `google_apis_playstore` | AOSP (`default` / no Google) |
|---|---|---|---|
| Play **Services** (Maps, location, FCM, sign-in) | Yes | Yes | No |
| Play **Store** app (install apps, sign into a Google account) | No | Yes | No |
| `adb root` / writable `/system` | **Yes** | **No** | **Yes** |
| Signed / locked | No | Yes (production-like) | No |
| Typical use | Dev & testing (**default**) | Reproduce real install/account flows | Test without Google, or pure AOSP work |

Plus a fourth, performance-oriented option:

- **`google_atd`** (Automated Test Device) — a `google_apis` variant with the UI
  apps and animations stripped out. Boots roughly twice as fast and uses less RAM,
  but has no launcher to look at. Ideal for CI / instrumentation runs, wrong choice
  if you want to tap around the screen via `scrcpy`.

**How to switch, by goal:**

| Goal | `.env` line |
|---|---|
| Default dev image, rootable, has Play Services | `SYSTEM_IMAGE_TAG=google_apis` |
| **With** the Play Store (sign into a Google account, install from Store) | `SYSTEM_IMAGE_TAG=google_apis_playstore` |
| **Without** any Google (pure open source) | `SYSTEM_IMAGE_TAG=default` |
| Fast headless CI, no visible UI | `SYSTEM_IMAGE_TAG=google_atd` |

> Choosing `google_apis_playstore` **disables `adb root`** and `-writable-system`.
> That is a Google restriction on signed Play images, not something this container
> imposes. If you need root, use `google_apis`.

### CPU arch: x86_64 vs ARM

The system image comes in CPU-architecture builds. In the SDK Manager you'll see
labels like "x86_64 Atom System Image" and "ARM 64 v8a System Image":

- **x86_64 ("Atom")** — 64-bit Intel/AMD. "Atom" is legacy branding from Intel's
  early emulator images; it is **not** limited to Atom CPUs. This is what your
  Intel/AMD Linux host uses, and it's the default here (`ABI=x86_64`).
- **ARM 64 v8a** — 64-bit ARM, for Apple Silicon and ARM hosts.

The emulator is fast only when the **guest arch matches the host** (so KVM can
accelerate it). On an x86_64 server, always use the x86_64 image. Running an ARM
image on x86 works but is painfully slow (full CPU emulation). This is also why an
Apple Silicon Mac's own Android Studio installs the ARM image — same Android,
different CPU build. This repo targets x86_64 hosts, so `ABI` is left at `x86_64`;
change it only if you're running on an ARM Linux server.

---

## Configuration reference

Full list of `.env` variables (see `.env.example`):

| Variable | Default | Meaning |
|---|---|---|
| `BIND_ADDR` | `127.0.0.1` | Host address ADB is published on. **Set to your Tailscale/VPN/LAN IP** so remote clients can reach it. Leaving it at `127.0.0.1` keeps it host-only. |
| `ANDROID_API` | `37.0` | Version token, or `auto`. See [version selection](#version-selecting-a-release). |
| `SYSTEM_IMAGE_TAG` | `google_apis` | Image flavour. See [flavour table](#flavour-google-apis-vs-google-play-vs-aosp). |
| `SDK_CHANNEL` | `3` | `0`=stable, `1`=beta, `2`=dev, `3`=canary. Preview versions (37.x) need `3`. |
| `DEVICE_PROFILE` | `pixel_6` | AVD hardware profile. `avdmanager list device` shows options. |
| `RAM_MB` | `4096` | Guest RAM in MB. |
| `CORES` | `4` | vCPUs given to the guest. |
| `DATA_MB` | `8192` | Userdata partition size in MB. |
| `GPU_MODE` | `swiftshader_indirect` | `swiftshader_indirect` = software GL (safe, headless). `host` needs a GPU + `/dev/dri` and is fragile headless. |
| `ABI` | `x86_64` | Guest CPU arch. Leave unless on an ARM host. |

Ports (in `docker-compose.yml`):

| Container | Host | Purpose |
|---|---|---|
| 5585 → emulator 5555 | `${BIND_ADDR}:5555` | ADB — this is what clients `adb connect` to |
| 5584 → emulator 5554 | `${BIND_ADDR}:5554` | Emulator telnet console (optional) |

---

## Connecting a client

The host exposes a plain **network ADB device**. Any machine with `adb` can
attach; add `scrcpy` to see and control the screen.

Replace `<host>` below with your `BIND_ADDR` IP (e.g. the Tailscale `100.x.y.z`)
or the host's Tailscale MagicDNS name.

### macOS client

```bash
brew install scrcpy android-platform-tools
adb connect <host>:5555
adb devices                # should show "<host>:5555   device"
scrcpy --serial <host>:5555
```

### Windows client

```powershell
# Install via winget (or scoop/choco)
winget install --id=Genymobile.scrcpy -e
winget install --id=Google.PlatformTools -e   # provides adb

adb connect <host>:5555
adb devices
scrcpy --serial <host>:5555
```

Or download `scrcpy` for Windows from its releases page — it bundles `adb`.

### Linux client

```bash
sudo apt install -y scrcpy adb        # Debian/Ubuntu
# or: sudo dnf install scrcpy android-tools

adb connect <host>:5555
adb devices
scrcpy --serial <host>:5555
```

**On any client**, once `adb connect` succeeds the device also appears in
**Android Studio's** device dropdown, so you can Run/Debug an app straight onto the
homelab emulator. Handy flags for connecting over a slower link:

```bash
scrcpy --max-fps 30 --video-bit-rate 4M
adb install ./app-debug.apk
```

---

## Host setup by platform

The **host** (the machine that runs the container) must be x86_64 Linux with KVM.

### Ubuntu / Debian host

```bash
sudo apt update && sudo apt install -y cpu-checker docker.io docker-compose-v2
sudo kvm-ok               # must print: KVM acceleration can be used
ls -l /dev/kvm            # must exist
sudo usermod -aG docker "$USER" && newgrp docker
```

### Fedora / RHEL host

```bash
sudo dnf install -y @virtualization docker docker-compose
sudo systemctl enable --now docker
lsmod | grep kvm          # kvm_intel or kvm_amd should be loaded
```

If `/dev/kvm` is missing, enable **Intel VT-x** / **AMD-V** in BIOS/UEFI. In a VM,
enable **nested virtualization** on the hypervisor first.

### macOS / Windows as host — not supported

Docker Desktop on macOS and Windows runs containers inside a lightweight Linux VM
that does **not** pass through KVM, so the emulator can't accelerate and generally
won't run. Use a Linux box (a NUC, an old desktop, a homelab server, or a
cloud/bare-metal instance with nested virt) as the host, and use your Mac/PC as a
[client](#connecting-a-client).

### Private networking (recommended: Tailscale)

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
tailscale ip -4           # put this in .env as BIND_ADDR
```

Tailscale gives every machine a stable `100.x.y.z` address over WireGuard, so
binding ADB to that IP means only your tailnet can reach the device — no ports
open to the LAN or internet. Any VPN or a trusted LAN IP works too.

---

## Verifying the image is genuinely Google's

Nothing here uses a third-party Android build:

- `sdkmanager` is Google's own tool, pulling from
  `dl.google.com/android/repository/`, and it checksum-verifies every package
  against Google's manifest before installing. A tampered download fails.
- The build log prints `sdkmanager --list_installed`, showing the exact
  `system-images;android-<API>;<flavour>;x86_64` package and revision.
- At runtime the entrypoint prints `ro.build.fingerprint`, which for an official
  emulator image looks like `google/sdk_gphone64_x86_64/emu64x:…/userdebug/…`.

```bash
docker compose exec android-emulator sdkmanager --list_installed
adb -s <host>:5555 shell getprop ro.build.fingerprint
adb -s <host>:5555 shell getprop ro.build.version.sdk
```

List what's currently published (any channel) before choosing a version:

```bash
docker compose exec android-emulator \
  sdkmanager --list --channel=0 | grep "system-images;android-" | grep google_apis
```

---

## Performance tuning

| Knob (`.env`) | Suggested | Why |
|---|---|---|
| `RAM_MB` | `4096` | Guest RAM. On a 16 GB host, 4 GB + ~1.3 GB overhead leaves headroom. |
| `CORES` | `4` | Guest vCPUs. On a 6-core CPU, leave 1–2 for the host. |
| `MEM_LIMIT` | `8g` | Outer cgroup memory ceiling. Keep it **well above** `RAM_MB` + ~1.3 GB. |
| `CPU_LIMIT` | `5` | Outer cgroup CPU ceiling. Leave at least one core for the host. |
| `GPU_MODE` | `swiftshader_indirect` | Software GL — the reliable choice on a headless server. |
| `SYSTEM_IMAGE_TAG` | `google_atd` | Swap in for CI/instrumentation: boots ~2× faster, much lighter. |

**Expectation:** with SwiftShader you get a smooth-enough UI for app development,
testing, and CI (~15–30 fps for normal Compose/View UIs). It is CPU-rendered, so it
will never match a hardware-accelerated simulator on a laptop, and it's not for 3D
games or GPU benchmarking. Hardware GL (`GPU_MODE=host` + mounting `/dev/dri`) is
possible but fragile headless — only try it after the SwiftShader path works.

### Reading CPU% correctly

In `docker stats`, **100% = one full CPU core.** On a 6-core host the ceiling is
600%. So `212%` means the emulator is using ~2.1 cores spread across the scheduler's
choice of cores — it is *not* one core maxed out. A headless SwiftShader emulator
normally wants 1–2 cores while active and drops to near-idle once booted.

### The two resource layers (important)

The container has an **outer** limit (Docker cgroup: `CPU_LIMIT`, `MEM_LIMIT`) and an
**inner** footprint (the emulator's own `RAM_MB` + `CORES`). They must agree:

- `MEM_LIMIT` must stay **above** `RAM_MB` + ~1.3 GB QEMU/SwiftShader overhead.
  If the cap sits right at what the guest needs, Android thrashes (constant paging/GC),
  which *looks* like high CPU but is really memory starvation. Symptom: memory pegged
  near the cap (e.g. `4.1GiB / 4.5GiB`) **and** CPU above the CPU cap at the same time.
- If `MEM_LIMIT` is set **below** what the guest needs, Docker's OOM killer terminates
  the emulator mid-boot and `restart: unless-stopped` loops it forever.

### If the emulator is slow

Work down this list:

1. **Check whether it's starved, not throttled.** Run `docker stats android-emulator`.
   If memory is pinned near `MEM_LIMIT`, it's thrashing — **raise the cap**, don't lower RAM:
   ```bash
   docker update --cpus 5 --memory 8g --memory-swap 8g android-emulator
   ```
   This is live (no recreate). Make it permanent in `.env`:
   ```bash
   sed -i '/^RAM_MB=/d;/^CORES=/d;/^MEM_LIMIT=/d;/^CPU_LIMIT=/d' .env
   printf 'RAM_MB=4096\nCORES=4\nMEM_LIMIT=8g\nCPU_LIMIT=5\n' >> .env
   docker compose up -d --force-recreate android-emulator
   ```

2. **Don't over-cap CPU.** A `cpus:2` limit chokes an emulator that wants ~2 cores.
   Give it `CPU_LIMIT=5` on a 6-core host — leave one core for the host and let it
   breathe. Other idle containers (databases, HA, n8n) use ~0% and need no protection.

3. **Confirm settings actually applied.** The startup log line must match your `.env`:
   ```
   >> Starting emulator (headless … ram=4096M, cores=4)
   ```
   If it shows old numbers, the container wasn't recreated — use
   `docker compose up -d --force-recreate android-emulator` (a bare `docker restart`
   keeps the old settings).

4. **Switch to a lighter image.** The biggest single speedup on a headless host is the
   ATD image, which strips the launcher, UI apps, and animations:
   ```bash
   sed -i 's/^SYSTEM_IMAGE_TAG=.*/SYSTEM_IMAGE_TAG=google_atd/' .env
   docker compose build && docker compose up -d --force-recreate android-emulator
   ```
   Trade-off: no Play Store, bare UI — fine for automation/logic/UI testing.

5. **Pin cores to avoid contention (optional).** If you *do* run other CPU-hungry
   containers, uncomment `cpuset` in `docker-compose.yml` to keep the emulator on
   specific cores rather than competing for all of them.

### Do the limits protect other containers?

Only if something is actually competing. Check with `docker stats` — if every other
container sits near 0% CPU (the common case), the emulator is not starving them, and a
loose ceiling (`CPU_LIMIT=5`, `MEM_LIMIT=8g`) is purely a safety rail against runaway
behaviour, not a throttle you need for day-to-day use.

---

## Docker command reference

Common operations for this project. Run them from the project folder (where
`docker-compose.yml` lives).

**Lifecycle — recreate vs restart vs rebuild** (the distinction matters):

| Goal | Command | Rebuilds image? | Picks up `.env` changes? |
|---|---|---|---|
| Apply `.env` / compose changes, reuse built image | `docker compose up -d --force-recreate android-emulator` | No | **Yes** |
| Stop + remove container, keep AVD, then start | `docker compose down` then `docker compose up -d` | No | Yes |
| Just restart the same container | `docker restart android-emulator` | No | **No** (keeps old settings) |
| Stop / start without removing | `docker compose stop` / `docker compose start` | No | No |

**Building images:**

```bash
# Normal build — reuses cached layers (fast; re-run after editing the Dockerfile)
docker compose build

# Force a clean build — ignore the layer cache (use after changing ANDROID_API,
# SYSTEM_IMAGE_TAG, SDK_CHANNEL, or when a download looks stale/corrupt)
docker compose build --no-cache

# Build then start in one go
docker compose up -d --build
```

> Rule of thumb: change something in `.env` that's only an **environment** value
> (`RAM_MB`, `CORES`, `MEM_LIMIT`, `BIND_ADDR`) → just `--force-recreate`, no build.
> Change a **build arg** (`ANDROID_API`, `SYSTEM_IMAGE_TAG`, `SDK_CHANNEL`) → rebuild,
> and use `--no-cache` so the SDK step re-resolves the version.

**Live resource limits (no recreate):**

```bash
docker update --cpus 5 --memory 8g --memory-swap 8g android-emulator
docker stats android-emulator          # watch CPU / mem live (Ctrl-C to exit)
```

**Logs and inspection:**

```bash
docker compose logs -f                  # follow live (wait for ">> BOOT COMPLETE")
docker compose logs --tail=50           # last 50 lines
docker compose ps                       # status of the service
docker exec -it android-emulator bash   # shell inside the container
docker exec android-emulator getprop sys.boot_completed   # 1 = booted
```

**AVD / volume management:**

```bash
docker volume ls | grep avd             # find the AVD volume name
docker compose down                     # remove container, KEEP the AVD volume
docker compose down -v                  # remove container AND wipe the AVD (clean device)
```

**Cleanup (reclaim disk):**

```bash
docker image prune                      # remove dangling images
docker image rm homelab/android-emulator:37.0   # remove this project's image
docker builder prune                    # clear the build cache
```

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `FATAL: /dev/kvm is not present` | Enable VT-x/AMD-V in BIOS; check `kvm-ok`; confirm `devices: ["/dev/kvm"]` in compose. |
| Build: `Failed to find package 'platforms;android-37'` | Preview releases carry a minor version. Use `ANDROID_API=37.0` (not `37`) with `SDK_CHANNEL=3`; run the ["Checking what's available"](#checking-whats-available) command to see the exact token. |
| Build: `'…google_apis;x86_64' not found on channel N` | The version/flavour/channel combo isn't published. The log lists what *is* available — pick from that. |
| `adb connect` hangs or flaps | adbd allows one adb server at a time. Run `adb disconnect` everywhere; don't run `adb` inside the container while a client is attached. |
| Device shows `offline` | `adb disconnect && adb kill-server && adb connect <host>:5555`. |
| Boot never completes | `docker compose logs -f`; if the host is swapping, raise `MEM_LIMIT` (don't lower `RAM_MB` — see [Performance](#performance-tuning)). |
| `FATAL: A snapshot operation … timeout has expired` then restart loop | A stale/corrupt Quick Boot snapshot. Stop the container, wipe snapshots + locks, and disable snapshots. See [Fixing a crash loop](#fixing-a-crash-loop). |
| `FATAL: Running multiple emulators with the same AVD` | Stale AVD lock from a previous run. Stop the container and delete `*.lock` from the AVD dir — see [Fixing a crash loop](#fixing-a-crash-loop). |
| Container restarts endlessly (`exited with code 1 (restarting)`) | `restart: unless-stopped` is respinning a failing boot. Read the FATAL line just above each restart; usually snapshot/lock (above) or OOM (raise `MEM_LIMIT`). |
| Emulator slow; memory pinned near `MEM_LIMIT` + CPU above cap | Memory thrash, not CPU. Raise the cap: `docker update --cpus 5 --memory 8g --memory-swap 8g android-emulator`. See [If the emulator is slow](#if-the-emulator-is-slow). |
| Startup log shows old `ram=…/cores=…` after an `.env` change | Container wasn't recreated. Use `docker compose up -d --force-recreate` — `docker restart` keeps old settings. |
| Flood of `socat … 127.0.0.1:5555 Connection refused` at startup | Harmless. socat is bridging the ADB port before the emulator has opened it; the errors stop once boot completes. Only a concern if they persist *after* `BOOT COMPLETE`. |
| Reachable from LAN unexpectedly | `BIND_ADDR` isn't your private IP. Check `ss -ltnp \| grep 5555`. |
| Want a clean device | `docker compose down -v && docker compose up -d` (wipes the AVD volume). |
| `unauthorized` device state | Emulator images normally allow unauthenticated ADB. If you hit this, mount your client's `~/.android/adbkey.pub` into the container at `/home/android/.android/adbkey.pub` and restart. |

### Fixing a crash loop

A stuck snapshot or stale lock makes the emulator die and respin forever. Break it by
stopping the container, clearing the offending files from the AVD volume, and (for
snapshots) launching with `-no-snapshot` so it never touches them:

```bash
cd /opt/docker/<you>/android-docker-emulator

# 1. stop the loop
docker compose stop android-emulator

# 2. find the volume name, then wipe snapshots + locks inside it
docker volume ls | grep avd
docker run --rm -v <project>_avd-data:/a alpine sh -c '
  rm -rf /a/avd/<AVD_NAME>.avd/snapshots/* ;
  rm -f  /a/avd/<AVD_NAME>.avd/*.lock ;
  echo cleared'

# 3. recreate (no rebuild)
docker compose up -d --force-recreate android-emulator
docker compose logs -f
```

Replace `<project>_avd-data` with what `docker volume ls` prints, and `<AVD_NAME>`
with your AVD (e.g. `homelab_api37.0`). This project already launches the emulator
with `-no-snapshot`, so a fresh cold boot is expected after wiping.

---

## Security notes

- **Bind to a private address.** `BIND_ADDR` should be a Tailscale/VPN/LAN IP, never
  `0.0.0.0`. ADB has no authentication by default; anyone who can reach the port can
  control the device and run shell commands.
- **`.env` is git-ignored** because it contains your private IP and host tuning.
  Only `.env.example` is committed. `init-repo.sh` refuses to proceed if `.env` is
  staged.
- **The container runs the emulator as an unprivileged user** (uid 1001); root is
  used only briefly to fix `/dev/kvm` permissions, then dropped.

---

## FAQ

**Can I run this on a Raspberry Pi / ARM server?** Only with an ARM system image
(`ABI=arm64-v8a`) and an ARM host; x86 images won't accelerate there. Performance
varies a lot by board.

**Can I run multiple emulators?** Yes — copy the service in compose with a
different container name, volume, and host port pair, and give each a distinct
`AVD_NAME`.

**Does the AVD survive `docker compose down`?** Yes. It lives in the `avd-data`
volume. Use `down -v` to wipe it.

**Why not just use the Play Store image always?** It disables `adb root` and a
writable system, which you often want for development. Use it only when you
specifically need a Google account or the Store install flow.

**Can I view it in a browser instead of scrcpy?** Not with this repo. If you need
browser access, Google's
[android-emulator-container-scripts](https://github.com/google/android-emulator-container-scripts)
adds a WebRTC UI (heavier: needs Envoy + Nginx + Firebase). This repo deliberately
stays minimal and uses ADB + scrcpy.

---

## Contributing

Issues and PRs welcome. This is intentionally a small, readable set of scripts —
please keep changes minimal and documented. When filing a bug, include your host
OS, `kvm-ok` output, the relevant `.env` lines (with `BIND_ADDR` redacted), and the
`docker compose logs` around the failure.

## License

MIT — see [`LICENSE`](LICENSE).
