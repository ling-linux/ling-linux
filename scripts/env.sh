#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Ling Linux - Build Environment
#
# Override via env for local/restricted builds:
#   MIRROR_BASE=mirrors.tuna.tsinghua.edu.cn   (Alpine mirror)
#   KERNEL_GIT=https://...                      (kernel source)
#   KERNEL_VERSION=6.12.50                      (pin kernel version)

export WORKDIR="/build"
export ROOTFS_DIR="$WORKDIR/rootfs"
export KERNEL_DIR="$WORKDIR/linux"
export OUTPUT_DIR="$WORKDIR/output"
export OVERLAY_DIR="$WORKDIR/overlay"
export CONFIG_DIR="$WORKDIR/config"

# Mirror configuration (default: official CDN, fast for CI runners)
export MIRROR_BASE="${MIRROR_BASE:-dl-cdn.alpinelinux.org}"

# Versions
export ALPINE_VERSION="${ALPINE_VERSION:-3.24.1}"
export ALPINE_RELEASE="${ALPINE_RELEASE:-3.24}"    # URL path uses major.minor only
export ALPINE_ARCH="x86_64"
export ALPINE_MIRROR="https://${MIRROR_BASE}/alpine"

# Kernel version (fixed for reproducibility; override to use latest)
# Linux 7.x includes nullfs, which makes pivot_root(2) work on rootfs
# (EFI-stub initramfs). This fixes bwrap/glycin sandbox for GTK apps.
export KERNEL_VERSION="${KERNEL_VERSION:-7.1.3}"
export KERNEL_GIT="${KERNEL_GIT:-https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git}"

# Pre-downloaded kernel source directory (mount into container to skip download)
export KERNEL_SRC_CACHE="${KERNEL_SRC_CACHE:-/build/kernel-src}"
