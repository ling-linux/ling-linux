#!/bin/sh
set -e
# SPDX-License-Identifier: GPL-2.0-only

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/env.sh"

echo "[03-kernel] Step 3: Configuring and compiling kernel..."

KERNEL_VERSION=$(cat "$WORKDIR/.kernel-version")
THREADS=$(nproc)

cd "$KERNEL_DIR"

# Helper to enable/disable config options
kernel_enable()  { scripts/config -e "$1" 2>/dev/null || true; }
kernel_disable() { scripts/config -d "$1" 2>/dev/null || true; }

# --- Baseline ---
echo "[03-kernel] Creating defconfig baseline..."
make ARCH=x86_64 defconfig

# --- Enable essentials ---
echo "[03-kernel] Enabling essential features..."

# Platform
kernel_enable 64BIT
kernel_enable X86_64
kernel_enable SMP
kernel_enable ACPI
kernel_enable X86_LOCAL_APIC
kernel_enable X86_IO_APIC

# EFI boot
kernel_enable EFI
kernel_enable EFI_STUB
kernel_enable EFI_HANDOVER_PROTOCOL
kernel_enable EFI_MIXED

# Initramfs
kernel_enable BLK_DEV_INITRD
kernel_enable RD_ZSTD
kernel_enable INITRAMFS_COMPRESSION_ZSTD

# Pseudo-filesystems
kernel_enable PROC_FS
kernel_enable SYSFS
kernel_enable TMPFS
kernel_enable DEVTMPFS
kernel_enable DEVTMPFS_MOUNT

# Binary formats
kernel_enable BINFMT_ELF
kernel_enable BINFMT_SCRIPT

# Console
kernel_enable TTY
kernel_enable VT
kernel_enable VT_CONSOLE
kernel_enable UNIX98_PTYS

# Block / filesystem
kernel_enable BLOCK
kernel_enable BLK_DEV_SD
kernel_enable SATA_AHCI
kernel_enable NVME_CORE
kernel_enable BLK_DEV_NVME
kernel_enable EFI_PARTITION
kernel_enable EXT4_FS
kernel_enable VFAT_FS

# PCI
kernel_enable PCI
kernel_enable PCI_MSI

# USB HID (keyboard)
kernel_enable USB_SUPPORT
kernel_enable USB_XHCI_HCD
kernel_enable USB_XHCI_PCI
kernel_enable USB_EHCI_HCD
kernel_enable USB_EHCI_PCI
kernel_enable USB_HID

# Input
kernel_enable INPUT
kernel_enable INPUT_KEYBOARD
kernel_enable KEYBOARD_ATKBD
kernel_enable INPUT_MOUSE
kernel_enable INPUT_EVDEV

# Framebuffer
kernel_enable FB
kernel_enable FB_EFI
kernel_enable FB_SIMPLE
kernel_enable SYSFB_SIMPLEFB
kernel_enable FRAMEBUFFER_CONSOLE
kernel_enable FONT_SUPPORT
kernel_enable FONTS
kernel_enable FONT_8x16

# --- Kernel compression (ZSTD: fast, low-memory decompress for EFI stub) ---
# XZ needs large contiguous memory for LZMA2 dictionary which fails with
# big embedded initramfs. ZSTD uses ~512KB window vs XZ's 8-64MB.
kernel_enable KERNEL_ZSTD
kernel_disable KERNEL_GZIP
kernel_disable KERNEL_XZ

# Misc
kernel_enable PRINTK
kernel_enable SERIAL_8250
kernel_enable SERIAL_8250_CONSOLE
kernel_enable MODULES

# --- Kernel command line ---
kernel_enable CMDLINE_BOOL
scripts/config --set-str CMDLINE "console=tty1"

# --- Trim aggressively ---
echo "[03-kernel] Disabling unnecessary features..."

# Networking: enable full networking stack (required by D-Bus, Wayland, udev, SSH).
kernel_enable NET
kernel_enable INET
kernel_enable UNIX
kernel_disable HAMRADIO
kernel_disable CAN
kernel_disable NFC

# --- DRM / GPU (Phase 2: labwc Wayland) ---
kernel_enable DRM
kernel_enable DRM_FBDEV_EMULATION
kernel_enable DRM_AMDGPU
kernel_enable DRM_AMDGPU_SI
kernel_enable DRM_AMDGPU_CIK
kernel_enable DRM_I915
# Virtual GPU drivers (QEMU / Bochs / EFI fallback)
kernel_enable DRM_BOCHS
kernel_enable DRM_SIMPLEDRM
kernel_enable DRM_VIRTIO_GPU
kernel_enable DRM_QXL

# Virtio transport (required by virtio-gpu)
kernel_enable VIRTIO
kernel_enable VIRTIO_PCI

# --- Firmware loading (GPU needs firmware blobs) ---
kernel_enable FW_LOADER

# --- Sound
kernel_enable SOUND
kernel_enable SND
kernel_enable SND_HDA_INTEL
kernel_enable SND_HDA_CODEC_GENERIC
kernel_enable SND_HDA_CODEC_REALTEK
kernel_enable SND_HDA_CODEC_CONEXANT
kernel_enable SND_HDA_CODEC_HDMI
kernel_enable SND_USB_AUDIO

# --- Wired network (built-in for EFI stub, ≈ 250 KiB) ---
kernel_enable E1000E
kernel_enable R8169
kernel_enable E1000

# --- Crypto (required by iwd for WiFi WPA2/WPA3 encryption) ---
kernel_enable CRYPTO_USER_API_HASH
kernel_enable CRYPTO_USER_API_SKCIPHER
kernel_enable KEY_DH_OPERATIONS
kernel_enable CRYPTO_ECB
kernel_enable CRYPTO_MD5
kernel_enable CRYPTO_MD4
kernel_enable CRYPTO_CBC
kernel_enable CRYPTO_SHA256
kernel_enable CRYPTO_AES
kernel_enable CRYPTO_DES
kernel_enable CRYPTO_CMAC
kernel_enable CRYPTO_HMAC
kernel_enable CRYPTO_SHA512
kernel_enable CRYPTO_SHA1
kernel_enable CRYPTO_SHA1_SSSE3
kernel_enable CRYPTO_AES_NI_INTEL
kernel_enable CRYPTO_SHA512_SSSE3
kernel_enable CRYPTO_AES_X86_64
kernel_enable CRYPTO_DES3_EDE_X86_64
kernel_enable CRYPTO_SHA256_SSSE3

# Media
kernel_disable MEDIA_SUPPORT

# Unnecessary block / FS
# (BTRFS_FS, XFS_FS, FUSE_FS enabled for gparted/ntfs-3g support)
kernel_disable JFS_FS
kernel_disable REISERFS_FS
kernel_disable NFS_FS
kernel_disable NFSD
kernel_disable CIFS
kernel_disable CODA_FS
kernel_disable AFS_FS
kernel_disable CEPH_FS
kernel_disable NTFS_FS
kernel_disable NTFS3_FS
kernel_disable F2FS_FS
kernel_disable SQUASHFS
kernel_disable CRAMFS
kernel_disable MINIX_FS
kernel_disable ROMFS_FS
kernel_disable EROFS_FS
kernel_disable AUTOFS_FS
kernel_disable QUOTA
kernel_disable MD
kernel_enable BLK_DEV_DM
kernel_enable DM_CRYPT
kernel_disable LVM

# Virtualization — KVM host (built-in, ≈ 600-900 KiB)
# VIRTUALIZATION + KVM are enabled by defconfig as =m;
# kernel_enable promotes INTEL/AMD vendor modules to =y for EFI stub.
kernel_enable KVM_INTEL
kernel_enable KVM_AMD
kernel_disable HYPERVISOR_GUEST

# Debug / tracing
kernel_disable DEBUG_KERNEL
kernel_disable FTRACE
kernel_disable PERF_EVENTS
kernel_disable OPROFILE
kernel_disable KPROBES
kernel_disable UPROBES
kernel_disable BPF_SYSCALL

# Security modules — 纵深防御 (defence in depth)
# Landlock: 非特权自沙箱，零用户空间依赖，glycin/bwrap 降级保护
kernel_enable SECURITY_LANDLOCK
# Lockdown: 阻止 root 篡改内核内存 (/dev/mem/模块加载/EFI)，integrity 模式
kernel_enable SECURITY_LOCKDOWN_LSM
kernel_enable SECURITY_LOCKDOWN_LSM_EARLY
# Yama: ptrace 隔离，防止恶意进程注入同 UID 其他进程
kernel_enable SECURITY_YAMA
# 保持禁用 — 无生态支持或与项目架构不匹配
kernel_disable SECURITY_SELINUX
kernel_disable SECURITY_APPARMOR
kernel_disable SECURITY_TOMOYO
kernel_disable INTEGRITY

# Cgroups / namespaces
# Namespaces must be enabled for bubblewrap/glycin sandbox.
# glycin is GDK-Pixbuf's builtin image loader on Alpine >= 3.24;
# it spawns bwrap(1) to sandbox image decoding. Without USER_NS,
# every GTK app fails with "Loader process exited early".
# Linux 7.x nullfs fixes pivot_root(2) on rootfs so bwrap works.
kernel_enable NAMESPACES
kernel_enable USER_NS

# Power management
kernel_disable HIBERNATION

# Swap / KSM
kernel_disable KSM
kernel_disable KEXEC
kernel_disable CRASH_DUMP

# Audit
kernel_disable AUDIT

# Misc subsystems
kernel_disable WATCHDOG
kernel_disable RTC_CLASS
kernel_disable STAGING
# USB4/Thunderbolt: enabled by defconfig, only need to promote NET to =y
kernel_enable USB4_NET

# --- Prevent objtool/sorttable from being pulled in ---
kernel_disable STACK_VALIDATION
kernel_disable UNWINDER_ORC
kernel_disable UNWINDER_GUESS
kernel_disable BUILDTIME_TABLE_SORT
kernel_disable OBJTOOL
kernel_disable X86_KERNEL_IBT

# --- Resolve and compile ---
echo "[03-kernel] Running olddefconfig..."
make ARCH=x86_64 olddefconfig

echo "[03-kernel] Compiling kernel (first pass, without initramfs)..."
echo "[03-kernel] Using $THREADS threads..."
make ARCH=x86_64 -j$THREADS

echo "[03-kernel] Kernel compiled. Size: $(du -sh arch/x86/boot/bzImage | cut -f1)"
echo "[03-kernel] Done."
