#!/bin/sh
set -e
# SPDX-License-Identifier: GPL-2.0-only

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/env.sh"

echo "[04-assemble] Step 4: Assembling LingLinux.efi..."

KERNEL_VERSION=$(cat "$WORKDIR/.kernel-version")
THREADS=$(nproc)

# --- Step A: Create CPIO from rootfs ---
echo "[04-assemble] Creating CPIO archive from rootfs..."
cd "$ROOTFS_DIR"
CPIO_PATH="/tmp/rootfs-${KERNEL_VERSION}.cpio"
find . -print0 | cpio --null --format=newc --quiet -o > "$CPIO_PATH"
CPIO_SIZE=$(du -sh "$CPIO_PATH" | cut -f1)
echo "[04-assemble] CPIO created. Size: $CPIO_SIZE"

# --- Step B: Compress CPIO ---
echo "[04-assemble] Compressing initramfs..."
zstd -19 -T0 --rm "$CPIO_PATH"
INITRAMFS_PATH="${CPIO_PATH}.zst"
INITRAMFS_SIZE=$(du -sh "$INITRAMFS_PATH" | cut -f1)
echo "[04-assemble] Compressed initramfs size: $INITRAMFS_SIZE"

# --- Step C: Embed initramfs into kernel ---
echo "[04-assemble] Embedding initramfs into kernel..."
cd "$KERNEL_DIR"
scripts/config --set-str CONFIG_INITRAMFS_SOURCE "$INITRAMFS_PATH"
make ARCH=x86_64 olddefconfig

echo "[04-assemble] Rebuilding kernel with embedded initramfs..."
make ARCH=x86_64 -j$THREADS

# --- Step D: Copy output ---
echo "[04-assemble] Copying output..."
mkdir -p "$OUTPUT_DIR"
cp arch/x86/boot/bzImage "$OUTPUT_DIR/LingLinux.efi"

EFI_SIZE=$(du -sh "$OUTPUT_DIR/LingLinux.efi" | cut -f1)

# --- Clean up ---
rm -f "$INITRAMFS_PATH" "$CPIO_PATH"

# --- Summary ---
echo ""
echo "===================================="
echo "  Build Summary"
echo "===================================="
echo "Kernel version:   $KERNEL_VERSION"
echo "CPIO (raw):       $CPIO_SIZE"
echo "CPIO (zst):       $INITRAMFS_SIZE"
echo "EFI size:         $EFI_SIZE"
echo "Output:           $OUTPUT_DIR/LingLinux.efi"
echo "===================================="

echo "[04-assemble] Done."
