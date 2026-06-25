#!/bin/bash
#===============================================================================
# Termux Linux Desktop - Shared Functions
# VNC-based session management with embedded desktop display
# Architecture inspired by termux-x11's session/X display patterns
#===============================================================================

TL_VERSION="0.1.0"
TL_ROOT="${XDG_CONFIG_HOME:-$HOME/.config}/termux-linux"
TL_INSTALL="${TL_ROOT}/ubuntu"
TL_USER="${DESKTOP_USER:-termux}"
TL_SESSION_FILE="/tmp/termux-linux-desktop.pid"
TL_PREFS="${TL_ROOT}/prefs.conf"
TL_LOG="/tmp/termux-linux-desktop.log"

[ -f "$TL_PREFS" ] && . "$TL_PREFS"

VNC_DISPLAY="${VNC_DISPLAY:-:1}"
VNC_GEOMETRY="${VNC_GEOMETRY:-1280x720}"
VNC_DEPTH="${VNC_DEPTH:-24}"
VNC_PORT=$((5900 + ${VNC_DISPLAY#:}))

tl_bindings() {
    local binds=""
    for b in /dev /proc /sys /tmp /run /etc/resolv.conf /etc/hosts /etc/hostname; do
        [ -e "$b" ] && binds="$binds -b $b"
    done
    [ -d /dev/dri ] && binds="$binds -b /dev/dri"
    [ -d /dev/shm ] && binds="$binds -b /dev/shm"
    [ -d /dev/snd ] && binds="$binds -b /dev/snd"
    [ -d /dev/dri ] && binds="$binds -b /dev/dri"
    [ -e /etc/machine-id ] && binds="$binds -b /etc/machine-id"
    echo "$binds"
}

tl_env() {
    local display="${1:-$VNC_DISPLAY}"
    echo "HOME=/home/${TL_USER} USER=${TL_USER} \
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
TERM=xterm-256color LANG=C.UTF-8 DISPLAY=${display}"
}

tl_session() {
    [ -d "$TL_INSTALL" ] || { echo "Rootfs not found. Run setup.sh." >&2; return 1; }
    local binds="$(tl_bindings)" display="${DISPLAY:-${VNC_DISPLAY}}"
    shift
    if [ $# -eq 0 ]; then
        exec proot -0 -r "$TL_INSTALL" $binds -w "/home/${TL_USER}" -b "${HOME}:/host-home" \
            /usr/bin/env -i $(tl_env "$display") PULSE_SERVER="${PULSE_SERVER:-unix:/run/user/$(id -u)/pulse/native}" \
            /bin/bash --login
    else
        exec proot -0 -r "$TL_INSTALL" $binds -w "/home/${TL_USER}" -b "${HOME}:/host-home" \
            /usr/bin/env -i $(tl_env "$display") PULSE_SERVER="${PULSE_SERVER:-unix:/run/user/$(id -u)/pulse/native}" \
            "$@"
    fi
}

tl_vnc_start() {
    if [ -f "$TL_SESSION_FILE" ]; then
        local pid=$(cat "$TL_SESSION_FILE")
        kill -0 "$pid" 2>/dev/null && { echo "running:$pid:$VNC_PORT"; return 0; }
        rm -f "$TL_SESSION_FILE"
    fi
    local binds="$(tl_bindings)"
    echo "Starting XFCE on ${VNC_DISPLAY} (port ${VNC_PORT})..."

    local cmd="proot -0 -r ${TL_INSTALL} ${binds} -w /home/${TL_USER} \
        /usr/bin/env -i $(tl_env) \
        su - ${TL_USER} -c 'vncserver ${VNC_DISPLAY} -geometry ${VNC_GEOMETRY} -depth ${VNC_DEPTH} -localhost -fg 2>&1'"

    nohup bash -c "$cmd" > "$TL_LOG" 2>&1 &
    echo $! > "$TL_SESSION_FILE"

    for i in $(seq 1 15); do
        sleep 1
        if command -v ss &>/dev/null && ss -tlnp 2>/dev/null | grep -q ":${VNC_PORT} "; then
            echo "ready:$VNC_PORT"
            return 0
        fi
        if command -v netstat &>/dev/null && netstat -tlnp 2>/dev/null | grep -q ":${VNC_PORT} "; then
            echo "ready:$VNC_PORT"
            return 0
        fi
    done
    echo "timeout"
    return 1
}

tl_vnc_stop() {
    [ ! -f "$TL_SESSION_FILE" ] && { echo "stopped"; return 0; }
    local pid=$(cat "$TL_SESSION_FILE")
    local binds="$(tl_bindings)"
    proot -0 -r "$TL_INSTALL" $binds /usr/bin/env -i HOME=/root PATH=/usr/sbin:/usr/bin:/sbin:/bin \
        su - "${TL_USER}" -c "vncserver -kill ${VNC_DISPLAY}" 2>/dev/null || true
    kill "$pid" 2>/dev/null
    sleep 1; kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
    rm -f "$TL_SESSION_FILE"
    echo "stopped"
}

tl_vnc_status() {
    if [ -f "$TL_SESSION_FILE" ]; then
        local pid=$(cat "$TL_SESSION_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            local listening=false
            command -v ss &>/dev/null && ss -tlnp 2>/dev/null | grep -q ":${VNC_PORT} " && listening=true
            command -v netstat &>/dev/null && netstat -tlnp 2>/dev/null | grep -q ":${VNC_PORT} " && listening=true
            if $listening; then echo "running:$pid:$VNC_PORT"; return 0; fi
        fi
        rm -f "$TL_SESSION_FILE"
    fi
    echo "stopped"; return 1
}

tl_rootfs_info() {
    if [ -d "$TL_INSTALL" ] && [ -f "${TL_INSTALL}/bin/bash" ]; then
        local size=$(du -sh "$TL_INSTALL" 2>/dev/null | cut -f1)
        local bootstrapped="no"
        [ -f "${TL_INSTALL}/.bootstrapped" ] && bootstrapped="yes"
        echo "installed:${size}:${bootstrapped}:${TL_INSTALL}"
    else
        echo "not_installed"
    fi
}

tl_config() {
    local key="$1" val="$2"
    if [ -n "$val" ]; then
        echo "${key}=\"${val}\"" >> "$TL_PREFS"
    fi
}
