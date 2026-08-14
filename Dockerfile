# Official Google Android Emulator in Docker (headless, KVM-accelerated)
#
# Everything Android-related is downloaded at build time by Google's own
# `sdkmanager` from https://dl.google.com/android/repository/ and is
# checksum-verified against Google's repository manifest. No third-party
# emulator images are used.

FROM ubuntu:24.04

# ---- Which Android release to bake in -------------------------------------
# ANDROID_API=auto  -> install the newest STABLE platform sdkmanager offers.
# ANDROID_API=36    -> pin a specific level (36 = Android 16 "Baklava", stable).
# NOTE: API 37 (Android 17) is still a PREVIEW release; its google_apis x86_64
# image currently ships only as a 16 KB-page variant on the non-stable channel,
# so a plain "platforms;android-37" install fails with "Failed to find package".
# Stick to 'auto' or a stable number unless you deliberately want the preview.
ARG ANDROID_API=auto
# google_apis            -> Google Play services, rootable via `adb root`
# google_apis_playstore  -> adds Play Store, but NOT rootable
# aosp_atd / google_atd  -> stripped-down, much faster, no UI apps
ARG SYSTEM_IMAGE_TAG=google_apis
ARG ABI=x86_64

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
    if [ "$ANDROID_API" = "auto" ]; then \
      # Newest STABLE platform: list stable channel (0), take the highest android-NN.
      API="$(sdkmanager --list --channel=0 2>/dev/null \
              | grep -oE 'platforms;android-[0-9]+' \
              | grep -oE '[0-9]+$' | sort -n | tail -1)"; \
      [ -n "$API" ] || { echo 'Could not resolve a stable API level'; exit 1; }; \
    else \
      API="$ANDROID_API"; \
    fi; \
    echo "Resolved ANDROID_API=$API"; \
    IMG="system-images;android-${API};${SYSTEM_IMAGE_TAG};${ABI}"; \
    # Fail early with a clear message if that exact image isn't published.
    if ! sdkmanager --list --channel=0 2>/dev/null | grep -qF "$IMG"; then \
      echo "ERROR: '$IMG' not on the stable channel."; \
      echo "Available ${SYSTEM_IMAGE_TAG} ${ABI} images:"; \
      sdkmanager --list --channel=0 2>/dev/null \
        | grep -E "system-images;android-[0-9]+;${SYSTEM_IMAGE_TAG};${ABI}" | sort -u; \
      exit 1; \
    fi; \
    sdkmanager \
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
