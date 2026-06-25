#!/bin/bash
#===============================================================================
# Termux Linux Desktop - Automated Proot + Ubuntu + XFCE Setup
# Built-in VNC server for embedded desktop rendering
# Incorporates architecture from termux-x11: clean entry points,
# preference management, and X display session handling
#===============================================================================
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
err()   { echo -e "${RED}[x]${NC} $1"; }
header(){ echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
          echo -e "${CYAN}  $1${NC}"
          echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/termux-linux"
INSTALL_DIR="${CONFIG_DIR}/ubuntu"
BIN_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/termux-linux/bin"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/termux-linux"
UBUNTU_VERSION="${UBUNTU_VERSION:-24.04}"
DESKTOP_USER="${DESKTOP_USER:-termux}"
DESKTOP_PASS="${DESKTOP_PASS:-termux}"

detect_pkg_manager() {
    if command -v apt &>/dev/null; then
        PKG_MANAGER="apt"; PKG_INSTALL="apt install -y"; PKG_UPDATE="apt update"
    elif command -v dnf &>/dev/null; then
        PKG_MANAGER="dnf"; PKG_INSTALL="dnf install -y"; PKG_UPDATE="dnf check-update || true"
    elif command -v pacman &>/dev/null; then
        PKG_MANAGER="pacman"; PKG_INSTALL="pacman -S --noconfirm"; PKG_UPDATE="pacman -Sy"
    elif command -v zypper &>/dev/null; then
        PKG_MANAGER="zypper"; PKG_INSTALL="zypper install -y"; PKG_UPDATE="zypper refresh"
    else
        err "No supported package manager found (apt, dnf, pacman, zypper)"
        exit 1
    fi
    info "Package manager: ${PKG_MANAGER}"
}

install_deps() {
    header "Installing System Dependencies"
    case $PKG_MANAGER in
        apt)
            $PKG_UPDATE
            $PKG_INSTALL proot wget curl tar xz-utils python3 python3-gi \
                python3-gi-cairo gir1.2-gtk-3.0 gir1.2-pango-1.0 \
                gir1.2-gdkpixbuf-2.0 pulseaudio
            # Install gtk-vnc for embedded VNC viewer (optional, falls back to external viewer)
            $PKG_INSTALL gir1.2-gtvnc-1.0 2>/dev/null || warn "gtk-vnc not available, using external VNC viewer"
            ;;
        dnf)
            $PKG_UPDATE
            $PKG_INSTALL proot wget curl tar xz python3 python3-gobject \
                gtk3 pulseaudio gtk-vnc2 2>/dev/null || warn "gtk-vnc not available"
            ;;
        pacman)
            $PKG_UPDATE
            $PKG_INSTALL proot wget curl tar xz python python-gobject \
                gtk3 pulseaudio gtk-vnc 2>/dev/null || warn "gtk-vnc not available"
            ;;
        zypper)
            $PKG_UPDATE
            $PKG_INSTALL proot wget curl tar xz python3 python3-gobject \
                gtk3 pulseaudio gtk-vnc 2>/dev/null || warn "gtk-vnc not available"
            ;;
    esac
}

setup_dirs() {
    header "Setting Up Directories"
    mkdir -p "$CONFIG_DIR" "$BIN_DIR" "$DATA_DIR"
    info "Config: $CONFIG_DIR"
    info "Rootfs: $INSTALL_DIR"
    info "Scripts: $BIN_DIR"
}

download_ubuntu() {
    header "Downloading Ubuntu ${UBUNTU_VERSION} Rootfs"
    [ -f "${DATA_DIR}/ubuntu-base.tar.gz" ] && { warn "Already downloaded"; return; }
    local url="https://cdimage.ubuntu.com/ubuntu-base/releases/${UBUNTU_VERSION}/release/ubuntu-base-${UBUNTU_VERSION}-base-amd64.tar.gz"
    info "Downloading from: ${url}"
    wget -O "${DATA_DIR}/ubuntu-base.tar.gz" "$url" || {
        err "Download failed"; exit 1
    }
}

extract_ubuntu() {
    header "Extracting Ubuntu Rootfs"
    [ -d "$INSTALL_DIR" ] && [ -f "${INSTALL_DIR}/bin/bash" ] && { warn "Already extracted"; return; }
    mkdir -p "$INSTALL_DIR"
    tar -xzf "${DATA_DIR}/ubuntu-base.tar.gz" -C "$INSTALL_DIR"
    info "Extraction complete"
}

setup_resolv_conf() {
    local f="${INSTALL_DIR}/etc/resolv.conf"
    [ ! -f "$f" ] || [ ! -s "$f" ] && echo -e "nameserver 8.8.8.8\nnameserver 1.1.1.1" > "$f"
}

bootstrap_ubuntu() {
    header "Bootstrapping Ubuntu - Installing XFCE, VNC Server, and Tools"
    [ -f "${INSTALL_DIR}/.bootstrapped" ] && { warn "Already bootstrapped"; return; }

    local pc="proot -0 -r ${INSTALL_DIR} -b /dev -b /proc -b /sys -b /tmp \
        -w /root /usr/bin/env -i HOME=/root PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        TERM=$TERM LANG=C.UTF-8"

    info "Updating package lists..."
    $pc apt update || true

    info "Installing XFCE desktop and core packages..."
    $pc apt install -y --no-install-recommends \
        apt-utils software-properties-common sudo adduser \
        dbus-x11 xfce4 xfce4-terminal \
        gnome-icon-theme tango-icon-theme \
        pulseaudio pavucontrol \
        nano vim wget curl \
        mesa-utils dbus ca-certificates \
        rxvt-unicode xterm || warn "Some packages failed"

    info "Installing VNC server for embedded display..."
    $pc apt install -y --no-install-recommends \
        tightvncserver x11vnc xvfb xfonts-base || {
        warn "TightVNC failed, trying x11vnc+xvfb..."
        $pc apt install -y --no-install-recommends x11vnc xvfb xfonts-base
    }

    info "Creating user '${DESKTOP_USER}'..."
    $pc useradd -m -s /bin/bash "${DESKTOP_USER}" 2>/dev/null || true
    echo "${DESKTOP_USER}:${DESKTOP_PASS}" | $pc chpasswd 2>/dev/null || true
    $pc usermod -aG sudo "${DESKTOP_USER}" 2>/dev/null || true

    info "Setting up VNC configuration for ${DESKTOP_USER}..."
    local vnc_dir="${INSTALL_DIR}/home/${DESKTOP_USER}/.vnc"
    mkdir -p "$vnc_dir"

    # xstartup file - starts XFCE when VNC connects
    cat > "${vnc_dir}/xstartup" << 'VNCEOF'
#!/bin/bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LANG=C.UTF-8
export SHELL=/bin/bash
export XDG_SESSION_TYPE=x11
test -x /etc/X11/xinit/xinitrc && exec /etc/X11/xinit/xinitrc
exec startxfce4
VNCEOF
    chmod +x "${vnc_dir}/xstartup"

    mkdir -p "${INSTALL_DIR}/home/${DESKTOP_USER}/.config/xfce4"
    $pc chown -R "${DESKTOP_USER}:${DESKTOP_USER}" "/home/${DESKTOP_USER}"

    # Set VNC password (hardcoded for automation)
    $pc bash -c "echo -e '${DESKTOP_PASS}\n${DESKTOP_PASS}\nn\n' | su - ${DESKTOP_USER} -c 'vncpasswd 2>/dev/null'" 2>/dev/null || true

    $pc apt clean
    touch "${INSTALL_DIR}/.bootstrapped"
    info "Ubuntu bootstrap complete! XFCE + VNC server installed."
}

install_launcher_scripts() {
    header "Installing Launcher Scripts"
    cp "$SCRIPT_DIR/modules/functions.sh" "${CONFIG_DIR}/functions.sh"
    chmod +x "${CONFIG_DIR}/functions.sh"

    # termux-linux-session: open a shell in proot Ubuntu
    cat > "${BIN_DIR}/termux-linux-session" << 'SCRIPT'
#!/bin/bash
# Termux Linux Desktop - Proot Session Launcher
# Clean entry point inspired by termux-x11's CmdEntryPoint pattern
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/termux-linux"
INSTALL_DIR="${CONFIG_DIR}/ubuntu"
DESKTOP_USER="${DESKTOP_USER:-termux}"
[ -d "$INSTALL_DIR" ] || { echo "Rootfs not found. Run setup.sh"; exit 1; }
B=""
for d in /dev /proc /sys /tmp /run /etc/resolv.conf; do [ -e "$d" ] && B="$B -b $d"; done
[ -d /dev/dri ] && B="$B -b /dev/dri"
[ -d /dev/shm ] && B="$B -b /dev/shm"
exec proot -0 -r "$INSTALL_DIR" $B -w "/home/${DESKTOP_USER}" -b "${HOME}:/host-home" \
    /usr/bin/env -i HOME=/home/${DESKTOP_USER} USER=${DESKTOP_USER} \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    TERM="${TERM:-xterm-256color}" LANG=C.UTF-8 \
    DISPLAY="${DISPLAY:-:0}" PULSE_SERVER="${PULSE_SERVER:-unix:/run/user/$(id -u)/pulse/native}" \
    /bin/bash --login "$@"
SCRIPT
    chmod +x "${BIN_DIR}/termux-linux-session"

    # termux-linux-desktop: manage VNC-based desktop session
    cat > "${BIN_DIR}/termux-linux-desktop" << 'SCRIPT'
#!/bin/bash
# Termux Linux Desktop - VNC Session Manager
# Inspired by termux-x11's X display session management
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/termux-linux"
INSTALL_DIR="${CONFIG_DIR}/ubuntu"
DESKTOP_USER="${DESKTOP_USER:-termux}"
DESKTOP_PASS="${DESKTOP_PASS:-termux}"
SESSION_FILE="/tmp/termux-linux-desktop.pid"
VNC_DISPLAY="${VNC_DISPLAY:-:1}"
VNC_PORT=$((5900 + ${VNC_DISPLAY#:}))

start() {
    if [ -f "$SESSION_FILE" ]; then
        pid=$(cat "$SESSION_FILE"); kill -0 "$pid" 2>/dev/null && { echo "Already running (PID: $pid)"; return 0; }
        rm -f "$SESSION_FILE"
    fi
    echo "Starting XFCE desktop on display ${VNC_DISPLAY} (port ${VNC_PORT})..."
    B=""; for d in /dev /proc /sys /tmp /run /etc/resolv.conf /etc/hosts; do [ -e "$d" ] && B="$B -b $d"; done
    [ -d /dev/dri ] && B="$B -b /dev/dri"
    [ -d /dev/shm ] && B="$B -b /dev/shm"
    [ -d /dev/snd ] && B="$B -b /dev/snd"

    local cmd="proot -0 -r ${INSTALL_DIR} ${B} -w /home/${DESKTOP_USER} \
        /usr/bin/env -i HOME=/home/${DESKTOP_USER} USER=${DESKTOP_USER} \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        TERM=xterm-256color LANG=C.UTF-8 DISPLAY=${VNC_DISPLAY} \
        su - ${DESKTOP_USER} -c 'vncserver ${VNC_DISPLAY} -geometry 1280x720 -depth 24 -localhost -fg 2>&1'"

    nohup bash -c "$cmd" > /tmp/termux-linux-desktop.log 2>&1 &
    echo $! > "$SESSION_FILE"

    for i in $(seq 1 10); do
        sleep 1
        if ss -tlnp | grep -q ":${VNC_PORT} "; then
            echo "VNC server ready on port ${VNC_PORT}"
            return 0
        fi
    done
    echo "VNC server may not be ready yet. Check /tmp/termux-linux-desktop.log"
    return 1
}

stop() {
    [ ! -f "$SESSION_FILE" ] && { echo "Not running"; return 0; }
    pid=$(cat "$SESSION_FILE")
    echo "Stopping desktop session..."
    B=""; for d in /dev /proc /sys /tmp /run; do [ -e "$d" ] && B="$B -b $d"; done
    proot -0 -r "$INSTALL_DIR" $B /usr/bin/env -i HOME=/root PATH=/usr/sbin:/usr/bin:/sbin:/bin \
        su - "${DESKTOP_USER}" -c "vncserver -kill ${VNC_DISPLAY}" 2>/dev/null || true
    kill "$pid" 2>/dev/null; sleep 1; kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
    rm -f "$SESSION_FILE"
    echo "Stopped"
}

status() {
    if [ -f "$SESSION_FILE" ]; then
        pid=$(cat "$SESSION_FILE")
        if kill -0 "$pid" 2>/dev/null && ss -tlnp 2>/dev/null | grep -q ":${VNC_PORT} "; then
            echo "running:${pid}:${VNC_PORT}"; return 0
        fi
        rm -f "$SESSION_FILE"
    fi
    echo "stopped"; return 1
}

case "${1:-status}" in
    start) start ;;
    stop)  stop ;;
    restart) stop; sleep 1; start ;;
    status) status ;;
    *) echo "Usage: $0 {start|stop|restart|status}" ;;
esac
SCRIPT
    chmod +x "${BIN_DIR}/termux-linux-desktop"

    # Main GUI launcher wrapper
    cat > "${BIN_DIR}/termux-linux" << 'SCRIPT'
#!/bin/bash
exec python3 "$(dirname "$0")/../../termux-linux" "$@"
SCRIPT
    chmod +x "${BIN_DIR}/termux-linux"

    ln -sf "${BIN_DIR}/termux-linux-session" "${BIN_DIR}/tls" 2>/dev/null || true
    ln -sf "${BIN_DIR}/termux-linux-desktop" "${BIN_DIR}/tld" 2>/dev/null || true

    info "Launcher scripts installed to ${BIN_DIR}"
}

create_desktop_entry() {
    header "Creating Desktop Entry"
    mkdir -p "${HOME}/.local/share/applications"
    sed "s|%BIN_DIR%|${BIN_DIR}|g" "$SCRIPT_DIR/modules/termux-linux.desktop" \
        > "${HOME}/.local/share/applications/termux-linux.desktop"
    info "Desktop entry created"
}

save_prefs() {
    cat > "${CONFIG_DIR}/prefs.conf" << EOF
# Termux Linux Desktop Preferences
DISPLAY="${DISPLAY:-:0}"
DESKTOP_USER="${DESKTOP_USER}"
UBUNTU_VERSION="${UBUNTU_VERSION}"
PULSE_SERVER="unix:/run/user/$(id -u)/pulse/native"
VNC_DISPLAY=":1"
VNC_GEOMETRY="1280x720"
VNC_DEPTH="24"
AUTO_START=false
EOF
    info "Default preferences saved"
}

print_summary() {
    header "Setup Complete!"
    echo ""
    echo "  ┌─────────────────────────────────────────────┐"
    echo "  │  Termux Linux Desktop is ready!             │"
    echo "  │                                             │"
    echo "  │  Launch GUI:  termux-linux                  │"
    echo "  │  Start XFCE:  tld start                     │"
    echo "  │  Stop XFCE:   tld stop                      │"
    echo "  │  Terminal:    tls                           │"
    echo "  │                                             │"
    echo "  │  XFCE runs on display :1, VNC port 5901    │"
    echo "  │  User: ${DESKTOP_USER} / ${DESKTOP_PASS}                    │"
    echo "  └─────────────────────────────────────────────┘"
    echo ""
}

main() {
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║   Termux Linux Desktop Installer     ║${NC}"
    echo -e "${CYAN}║   Proot + Ubuntu ${UBUNTU_VERSION} + XFCE4     ║${NC}"
    echo -e "${CYAN}║   Embedded VNC — no external deps    ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    detect_pkg_manager
    install_deps
    setup_dirs
    download_ubuntu
    extract_ubuntu
    setup_resolv_conf
    bootstrap_ubuntu
    install_launcher_scripts
    create_desktop_entry
    save_prefs
    print_summary
}

main "$@"
