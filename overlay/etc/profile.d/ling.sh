if test -z "${XDG_RUNTIME_DIR}"; then
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
fi
mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null
chmod 0700 "$XDG_RUNTIME_DIR" 2>/dev/null

# Default editor
export EDITOR=nano
export VISUAL=nano
