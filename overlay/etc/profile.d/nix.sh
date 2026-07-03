# SPDX-License-Identifier: GPL-2.0-only
#
# Ling Linux - Nix 包管理器环境配置（单用户模式）
[ -z "$HOME" ] && return

export NIX_STORE_DIR="$HOME/.nix-store"
export NIX_STATE_DIR="$HOME/.nix-state"
export NIX_LOG_DIR="$HOME/.nix-log"
export NIX_CONFIG="experimental-features = nix-command flakes"
export PATH="$HOME/.nix-profile/bin:$PATH"
