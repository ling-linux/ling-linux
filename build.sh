#!/bin/sh
set -e
# SPDX-License-Identifier: GPL-2.0-only

echo "=========================================="
echo "  灵 Linux (Ling Linux) - Build System"
echo "=========================================="
echo ""

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_DIR="$SCRIPT_DIR/scripts"

# Source environment (defines WORKDIR, paths, versions)
. "$SCRIPTS_DIR/env.sh"

# Run build steps in sequence
for step in "$SCRIPTS_DIR"/0*.sh; do
    step_name=$(basename "$step")
    echo ""
    echo "═══════════════════════════════════════════"
    echo "  Running: $step_name"
    echo "═══════════════════════════════════════════"
    if ! sh "$step"; then
        echo ""
        echo "[ERROR] $step_name failed. Aborting."
        exit 1
    fi
done

echo ""
echo "=========================================="
echo "  Build Complete Successfully"
echo "  Output: output/LingLinux.efi"
echo "=========================================="
