#!/bin/sh
set -e
# SPDX-License-Identifier: GPL-2.0-only

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/env.sh"

echo "[01-fetch] Step 1: Downloading sources..."

# --- Alpine minirootfs ---
echo "[01-fetch] Downloading Alpine $ALPINE_VERSION minirootfs for $ALPINE_ARCH..."
ALPINE_URL="${ALPINE_MIRROR}/v${ALPINE_RELEASE}/releases/${ALPINE_ARCH}/alpine-minirootfs-${ALPINE_VERSION}-${ALPINE_ARCH}.tar.gz"
wget -q --show-progress "$ALPINE_URL" -O /tmp/alpine-rootfs.tar.gz
echo "[01-fetch] Alpine rootfs downloaded."

# --- Linux kernel ---
echo "[01-fetch] Using kernel version: $KERNEL_VERSION"

# Step 1: Check if source already present at KERNEL_DIR (CI cache mount)
if [ -d "$KERNEL_DIR" ] && [ -f "$KERNEL_DIR/Makefile" ]; then
    cd "$KERNEL_DIR"
    CURRENT_VER=$(make -s kernelversion 2>/dev/null || echo "unknown")
    echo "[01-fetch] Found existing kernel: v$CURRENT_VER"
    if [ "$CURRENT_VER" = "$KERNEL_VERSION" ]; then
        echo "[01-fetch] Version matches, skipping download."
        echo "$KERNEL_VERSION" > "$WORKDIR/.kernel-version"
    else
        echo "[01-fetch] Version mismatch, re-fetching..."
        # Clear contents (not the dir itself — may be a Docker volume mount)
        find "$KERNEL_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
    fi
fi

# Step 2: If still no source, try cache or download
if [ ! -d "$KERNEL_DIR" ] || [ ! -f "$KERNEL_DIR/Makefile" ]; then
    FETCHED=false

    # Try local cache directory (for manual/offline builds)
    if [ -d "$KERNEL_SRC_CACHE" ] && [ -f "$KERNEL_SRC_CACHE/Makefile" ]; then
        echo "[01-fetch] Copying from local cache: $KERNEL_SRC_CACHE"
        cp -a "$KERNEL_SRC_CACHE" "$KERNEL_DIR"
        FETCHED=true
    fi

    # Try local cache tarball
    if [ "$FETCHED" = false ] && [ -f "$KERNEL_SRC_CACHE.tar.xz" ]; then
        echo "[01-fetch] Extracting local cache tarball..."
        mkdir -p "$KERNEL_DIR"
        tar xf "$KERNEL_SRC_CACHE.tar.xz" -C "$KERNEL_DIR" --strip-components=1
        FETCHED=true
    fi

    # Fallback: git shallow clone
    if [ "$FETCHED" = false ]; then
        echo "[01-fetch] Cloning Linux $KERNEL_VERSION via git (shallow)..."
        git clone --depth 1 --branch "v${KERNEL_VERSION}" \
            "$KERNEL_GIT" "$KERNEL_DIR" || {
            echo "[01-fetch] git clone failed."
            echo "[01-fetch]"
            echo "[01-fetch] ================================================"
            echo "[01-fetch]  Download failed. Pre-download the kernel:"
            echo "[01-fetch]    linux-${KERNEL_VERSION}.tar.xz"
            echo "[01-fetch]  Place as kernel-src.tar.xz and mount into container."
            echo "[01-fetch] ================================================"
            exit 1
        }
        echo "[01-fetch] Kernel source cloned."
    fi

    echo "$KERNEL_VERSION" > "$WORKDIR/.kernel-version"
fi

# --- Extract ---
echo "[01-fetch] Extracting Alpine rootfs to $ROOTFS_DIR..."
mkdir -p "$ROOTFS_DIR"
tar xzf /tmp/alpine-rootfs.tar.gz -C "$ROOTFS_DIR"

# Save kernel version for later steps
echo "$KERNEL_VERSION" > "$WORKDIR/.kernel-version"

# Cleanup
rm -f /tmp/alpine-rootfs.tar.gz

echo "[01-fetch] Done."
