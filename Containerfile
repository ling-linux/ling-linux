# SPDX-License-Identifier: GPL-2.0-only
# Ling Linux - Build Container
# Ubuntu 24.04 with kernel compilation toolchain + Alpine apk for rootfs
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Kernel build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    flex bison \
    libssl-dev \
    libelf-dev \
    bc \
    cpio \
    xz-utils \
    zstd \
    wget \
    git \
    python3 \
    rsync \
    bash \
    ca-certificates \
    ccache \
    && rm -rf /var/lib/apt/lists/*

# ccache configuration for kernel builds
ENV CC="ccache gcc" \
    CXX="ccache g++" \
    HOSTCC="ccache gcc" \
    CCACHE_DIR=/ccache \
    CCACHE_MAXSIZE=2G \
    CCACHE_SLOPPINESS=file_macro,time_macros,include_file_mtime,include_file_ctime

# Download Alpine static apk for building the Alpine rootfs
# apk.static is a self-contained binary that works on any glibc host
ENV ALPINE_RELEASE=3.24
ARG APK_TOOLS_VERSION=3.0.6-r0
RUN wget "https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_RELEASE}/main/x86_64/apk-tools-static-${APK_TOOLS_VERSION}.apk" \
    -O /tmp/apk-tools-static.apk && \
    mkdir -p /usr/local/alpine && \
    tar xzf /tmp/apk-tools-static.apk -C /usr/local/alpine && \
    ln -sf /usr/local/alpine/sbin/apk.static /usr/local/bin/apk.static && \
    rm /tmp/apk-tools-static.apk

WORKDIR /build

COPY config/ config/
COPY overlay/ overlay/
COPY scripts/ scripts/
COPY build.sh .

ENTRYPOINT ["/bin/bash", "/build/build.sh"]
