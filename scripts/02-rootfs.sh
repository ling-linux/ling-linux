#!/bin/sh
set -e
# SPDX-License-Identifier: GPL-2.0-only

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/env.sh"

echo "[02-rootfs] Step 2: Building root filesystem..."

# --- Setup APK repositories ---
mkdir -p "$ROOTFS_DIR/etc/apk"
cat > "$ROOTFS_DIR/etc/apk/repositories" <<EOF
${ALPINE_MIRROR}/v${ALPINE_RELEASE}/main
${ALPINE_MIRROR}/v${ALPINE_RELEASE}/community
EOF
echo "[02-rootfs] APK repositories configured."

# --- Bind-mount /dev and /proc (required by apk post-install scripts) ---
# apk add --root auto-chroots into $ROOTFS_DIR for post-install scripts.
# These mounts allow scripts like adduser, dbus-uuidgen, rc-update to work.
echo "[02-rootfs] Setting up chroot environment..."
mount --bind /dev "$ROOTFS_DIR/dev"
mount -t proc none "$ROOTFS_DIR/proc"
# Ensure cleanup even on error
trap 'umount "$ROOTFS_DIR/proc" 2>/dev/null; umount "$ROOTFS_DIR/dev" 2>/dev/null' EXIT

# --- Copy resolv.conf for network access inside chroot ---
cp /etc/resolv.conf "$ROOTFS_DIR/etc/resolv.conf"

# --- Install packages ---
# apk.static --root auto-chroots for post-install scripts when /proc and /dev
# are bind-mounted. This allows post-install to:
#   - adduser/addgroup create system users (dbus, greetd, polkitd)
#   - rc-update registers OpenRC services
#   - dbus-uuidgen generates /var/lib/dbus/machine-id
#   - Package file ownerships are set correctly
PACKAGES=$(grep -v '^#' "$CONFIG_DIR/packages.list" | grep -v '^$' | tr '\n' ' ')
echo "[02-rootfs] Installing packages: $PACKAGES"
APK_CACHE="${APK_CACHE_DIR:-/tmp/apk-cache-build}"
mkdir -p "$APK_CACHE"
apk.static --root "$ROOTFS_DIR" --initdb --cache-dir "$APK_CACHE" add --no-cache $PACKAGES

# --- Run post-install scripts in full chroot ---
# apk.static --root chroots internally, but in Docker without CAP_SYS_ADMIN
# the chroot lacks /proc and /dev, causing scripts to fail silently.
# Per Alpine official practice (alpine-make-rootfs, alpine-chroot-install):
#  1. Install packages with apk.static --root (extracts files)
#  2. Explicitly chroot with /proc /dev /sys mounted
#  3. Run apk fix for triggers + post-install, manually run pre-install steps
echo "[02-rootfs] Running post-install scripts in full chroot..."
chroot "$ROOTFS_DIR" /bin/sh -c "
set -e

echo '  * Fixing triggers & post-install...'
apk fix --no-cache

echo '  * Creating system users (pre-install scripts failed in minimal chroot)...'
# dbus
addgroup -S dbus 2>/dev/null || true
adduser -S -D -H -h /var/run/dbus -s /sbin/nologin -G dbus -g dbus dbus 2>/dev/null || true
# greetd
addgroup -S greetd 2>/dev/null || true
adduser -S -D -H -h /var/lib/greetd -s /sbin/nologin -G greetd -g greetd greetd 2>/dev/null || true
# polkitd
addgroup -S polkitd 2>/dev/null || true
adduser -S -D -H -h /var/lib/polkit-1 -s /sbin/nologin -G polkitd -g polkitd polkitd 2>/dev/null || true
# elogind
addgroup -S elogind 2>/dev/null || true
adduser -S -D -H -s /sbin/nologin -G elogind -g elogind elogind 2>/dev/null || true

echo '  * Generating D-Bus machine-id...'
dbus-uuidgen --ensure 2>/dev/null || true

echo '  * Creating device groups...'
for grp in video seat input render; do
    addgroup -S \$grp 2>/dev/null || true
done

echo '  * Generating SSH host keys...'
ssh-keygen -A 2>/dev/null || true
"

# --- Supplementary: OpenRC service registration ---
# Some packages register services to boot runlevel; ensure default runlevel registration
echo "[02-rootfs] Configuring OpenRC runlevels..."
chroot "$ROOTFS_DIR" /bin/sh -c "
    for svc in dbus elogind seatd greetd iwd bluetooth polkitd sshd; do
        rc-update add \$svc default 2>/dev/null || true
    done
"

# --- Verify post-install artifacts (defensive) ---
echo "[02-rootfs] Verifying post-install artifacts..."
FAILED=""
for user in dbus greetd polkitd elogind; do
    grep -q "^$user:" "$ROOTFS_DIR/etc/passwd" 2>/dev/null || FAILED="$FAILED user:$user"
done
for grp in dbus video seat input render; do
    grep -q "^$grp:" "$ROOTFS_DIR/etc/group" 2>/dev/null || FAILED="$FAILED group:$grp"
done
for path in /var/lib/dbus /var/lib/greetd /etc/polkit-1/rules.d; do
    [ -d "$ROOTFS_DIR$path" ] || FAILED="$FAILED dir:$path"
done
[ -f "$ROOTFS_DIR/var/lib/dbus/machine-id" ] || FAILED="$FAILED file:machine-id"
if [ -n "$FAILED" ]; then
    echo "[02-rootfs] ERROR: Missing post-install artifacts:$FAILED"
    echo "[02-rootfs] Check that /proc and /dev are properly mounted."
    exit 1
fi
echo "[02-rootfs] All post-install artifacts verified."

# --- Supplementary group membership for greetd ---
# greetd package creates the user, but doesn't add to device-access groups.
# wlroots requires video, render, input; seatd requires seat.
echo "[02-rootfs] Adding greetd to device-access groups..."
for grp in video seat input render; do
    chroot "$ROOTFS_DIR" addgroup greetd $grp 2>/dev/null || true
done

# --- Cleanup chroot mounts ---
umount "$ROOTFS_DIR/proc" 2>/dev/null
umount "$ROOTFS_DIR/dev" 2>/dev/null
trap - EXIT

# --- Copy overlay files ---
echo "[02-rootfs] Copying overlay files..."
if [ -d "$OVERLAY_DIR" ]; then
    cp -a "$OVERLAY_DIR/"* "$ROOTFS_DIR/"
fi

# --- Setup essential configs ---
echo "ling-linux" > "$ROOTFS_DIR/etc/hostname"

# Lock root password — no direct login.
# Wheel users can use sudo su / sudo -i instead.
if [ -f "$ROOTFS_DIR/etc/shadow" ]; then
    sed -i 's/^root:[^:]*:/root:!:/' "$ROOTFS_DIR/etc/shadow"
fi

# --- Install 层峦 (cengluan) TTY font ---
echo "[02-rootfs] Downloading cengluan font..."
FONT_DIR="$ROOTFS_DIR/usr/share/consolefonts"
mkdir -p "$FONT_DIR"
wget -q "https://github.com/PJ-568/font-cengluan/releases/latest/download/cengluan.psfu.gz" \
    -O "$FONT_DIR/cengluan.psfu.gz" || \
    echo "[02-rootfs] WARNING: Failed to download cengluan font. Skipping."
echo "[02-rootfs] Font installed."

# --- Install Nix static binary (musl) ---
echo "[02-rootfs] Downloading Nix static binary..."
wget -q "https://hydra.nixos.org/job/nix/master/buildStatic.x86_64-linux/latest/download-by-type/file/binary-dist" \
    -O "$ROOTFS_DIR/usr/local/bin/nix" && \
    chmod +x "$ROOTFS_DIR/usr/local/bin/nix" || \
    echo "[02-rootfs] WARNING: Failed to download Nix. Skipping."

# --- Install greetd IPC helper ---
echo "[02-rootfs] Downloading ling-greetd-ipc..."
wget -q "https://github.com/ling-linux/ling-greetd-ipc/releases/latest/download/ling-greetd-ipc" \
    -O "$ROOTFS_DIR/usr/local/bin/ling-greetd-ipc" && \
    chmod +x "$ROOTFS_DIR/usr/local/bin/ling-greetd-ipc" || \
    echo "[02-rootfs] WARNING: Failed to download IPC helper. Skipping."

# --- Setup getty for login ---
if [ -x "$ROOTFS_DIR/sbin/getty" ]; then
    echo "[02-rootfs] getty found, setting up console login."
fi

# --- Create basic /etc/fstab ---
cat > "$ROOTFS_DIR/etc/fstab" <<EOF
proc  /proc  proc  defaults  0 0
sysfs /sys   sysfs defaults  0 0
EOF

# --- Clean up ---
rm -f "$ROOTFS_DIR/etc/resolv.conf"
rm -rf "$ROOTFS_DIR/var/cache/apk/"*
rm -f "$ROOTFS_DIR/root/.ash_history"

# Ensure /dev/console exists — kernel needs it for early console output
# before devtmpfs is mounted. Alpine rootfs includes it by default.
echo "[02-rootfs] Rootfs built. Size: $(du -sh $ROOTFS_DIR | cut -f1)"

# Save rootfs size for reporting
du -sh "$ROOTFS_DIR" | cut -f1 > "$WORKDIR/.rootfs-size"

echo "[02-rootfs] Done."
