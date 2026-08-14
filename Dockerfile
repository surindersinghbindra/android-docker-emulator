# Official Google Android Emulator in Docker (headless, KVM-accelerated)
#
# Everything Android-related is downloaded at build time by Google's own
# `sdkmanager` from https://dl.google.com/android/repository/ and is
# checksum-verified against Google's repository manifest. No third-party
# emulator images are used.

FROM ubuntu:24.04

# ---- Which Android release to bake in -------------------------------------
# API 37 = Android 17 (Cinnamon Bun). Override at build time, e.g.
#   docker compose build --build-arg ANDROID_API=36
ARG ANDROID_API=37
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

# Re-accept licenses with the upgraded tools, then pull the official bits.
RUN set -eux; \
    yes | sdkmanager --licenses > /dev/null; \
    sdkmanager \
      "platform-tools" \
      "emulator" \
      "platforms;android-${ANDROID_API}" \
      "system-images;android-${ANDROID_API};${SYSTEM_IMAGE_TAG};${ABI}" \
    > /dev/null; \
    sdkmanager --list_installed

# Record what was baked in so the entrypoint can build the AVD from it.
ENV ANDROID_API=${ANDROID_API} \
    SYSTEM_IMAGE_TAG=${SYSTEM_IMAGE_TAG} \
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
