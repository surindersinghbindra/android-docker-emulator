# Official Google Android Emulator in Docker (headless, KVM-accelerated)
#
# Everything Android-related is downloaded at build time by Google's own
# `sdkmanager` from https://dl.google.com/android/repository/ and is
# checksum-verified against Google's repository manifest. No third-party
# emulator images are used.

FROM ubuntu:24.04

# ---- Which Android release to bake in -------------------------------------
# The value must match a package name exactly as `sdkmanager` lists it, which
# is the part AFTER "android-". On the STABLE channel that's a bare integer
# (e.g. 36). On PREVIEW channels it carries a minor version (e.g. 37.0, 37.1).
# See the README ("Checking what's available") for the one-liner that prints
# the exact token to use.
#   ANDROID_API=37.0  -> Android 17 (CinnamonBun) preview  [default]
#   ANDROID_API=36    -> Android 16 (Baklava) stable
#   ANDROID_API=auto  -> newest on the selected channel
ARG ANDROID_API=37.0
# google_apis            -> Google Play services, rootable via `adb root`
# google_apis_playstore  -> adds Play Store, but NOT rootable
# aosp_atd / google_atd  -> stripped-down, much faster, no UI apps
ARG SYSTEM_IMAGE_TAG=google_apis
ARG ABI=x86_64
# SDK channel to search: 0=stable, 1=beta, 2=dev, 3=canary.
# Preview releases (e.g. 37.x) live on canary, so this defaults to 3 to match
# the default ANDROID_API above. Set to 0 when pinning a stable version.
ARG SDK_CHANNEL=3

# Bootstrap copy of cmdline-tools. It immediately upgrades itself to
# "cmdline-tools;latest" below, so this pinned build number only has to be
# new enough to run once.
ARG CMDLINE_TOOLS_ZIP=commandlinetools-linux-11076708_latest.zip

ENV DEBIAN_FRONTEND=noninteractive \
    ANDROID_SDK_ROOT=/opt/android-sdk \
    ANDROID_HOME=/opt/android-sdk \
    JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64

RUN apt-get update && apt-get install -y --no-install-recommends \
      openjdk-21-jdk-headless \
      curl ca-certificates unzip socat procps net-tools iproute2 \
      util-linux tzdata \
      # runtime libs the emulator + SwiftShader need, even headless
      libpulse0 libnss3 libxcb1 libx11-6 libxext6 libxdamage1 libxfixes3 \
      libxcomposite1 libxcursor1 libxi6 libxrandr2 libxtst6 libxkbcommon0 \
      libgl1 libglu1-mesa libegl1 libgbm1 libdrm2 libasound2t64 \
      libfreetype6 libfontconfig1 libc++1 \
    && rm -rf /var/lib/apt/lists/*

ENV PATH=$PATH:$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$ANDROID_SDK_ROOT/platform-tools:$ANDROID_SDK_ROOT/emulator

# ---- Install the SDK ------------------------------------------------------
RUN set -eux; \
    mkdir -p "$ANDROID_SDK_ROOT/cmdline-tools"; \
    curl -fsSL "https://dl.google.com/android/repository/${CMDLINE_TOOLS_ZIP}" -o /tmp/cmdline.zip; \
    unzip -q /tmp/cmdline.zip -d /tmp/cmdline; \
    mv /tmp/cmdline/cmdline-tools "$ANDROID_SDK_ROOT/cmdline-tools/bootstrap"; \
    rm -rf /tmp/cmdline.zip /tmp/cmdline; \
    yes | "$ANDROID_SDK_ROOT/cmdline-tools/bootstrap/bin/sdkmanager" --licenses > /dev/null; \
    "$ANDROID_SDK_ROOT/cmdline-tools/bootstrap/bin/sdkmanager" "cmdline-tools;latest" > /dev/null; \
    rm -rf "$ANDROID_SDK_ROOT/cmdline-tools/bootstrap"

# Re-accept licenses, resolve the API level, then pull the official bits.
# The resolved integer is written to /etc/android-api so the entrypoint can
# read it back regardless of whether 'auto' or a number was requested.
RUN set -eux; \
    yes | sdkmanager --licenses > /dev/null; \
    CH="--channel=${SDK_CHANNEL}"; \
    if [ "$ANDROID_API" = "auto" ]; then \
      # Newest platform on the chosen channel. Handles bare integers (36) and
      # preview tokens with minor/beta suffixes (37.0, 37.2-beta2) via sort -V.
      API="$(sdkmanager --list $CH 2>/dev/null \
              | grep -oE 'platforms;android-[0-9]+(\.[0-9]+)?(-beta[0-9]+)?' \
              | sed 's/^platforms;android-//' \
              | sort -V | tail -1)"; \
      [ -n "$API" ] || { echo 'Could not resolve an API level'; exit 1; }; \
    else \
      API="$ANDROID_API"; \
    fi; \
    echo "Resolved ANDROID_API=$API (channel ${SDK_CHANNEL})"; \
    IMG="system-images;android-${API};${SYSTEM_IMAGE_TAG};${ABI}"; \
    # Fail early with a clear message if that exact image isn't published.
    if ! sdkmanager --list $CH 2>/dev/null | grep -qF "$IMG"; then \
      echo "ERROR: '$IMG' not found on channel ${SDK_CHANNEL}."; \
      echo "Available ${SYSTEM_IMAGE_TAG} ${ABI} images on this channel:"; \
      sdkmanager --list $CH 2>/dev/null \
        | grep -E "system-images;android-[0-9]+;${SYSTEM_IMAGE_TAG};${ABI}" | sort -u; \
      echo "(API 37 needs SDK_CHANNEL=3; stable tops out lower.)"; \
      exit 1; \
    fi; \
    sdkmanager $CH \
      "platform-tools" \
      "emulator" \
      "platforms;android-${API}" \
      "$IMG" \
    > /dev/null; \
    echo "$API" > /etc/android-api; \
    sdkmanager --list_installed

ENV SYSTEM_IMAGE_TAG=${SYSTEM_IMAGE_TAG} \
    ABI=${ABI}

# ---- Unprivileged runtime user -------------------------------------------
RUN useradd -m -u 1001 -s /bin/bash android \
    && chown -R android:android "$ANDROID_SDK_ROOT"

ENV ANDROID_AVD_HOME=/home/android/.android/avd \
    HOME=/home/android

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# 5585 -> bridged adbd (emulator's 5555), 5584 -> bridged console (5554)
EXPOSE 5585 5584

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
